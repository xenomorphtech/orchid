defmodule Orchid.LLM.Codex do
  @moduledoc """
  OpenAI Codex SDK-backed provider.

  Orchid uses a small local Node bridge under `priv/codex_sdk/` so Elixir can
  call the supported Codex SDK surface with structured JSON instead of shelling
  out through a single escaped command string.
  """

  require Logger

  alias Orchid.LLM.Catalog

  @container_bridge_dir "/opt/orchid-codex-sdk"
  @container_mcp_proxy Path.join(@container_bridge_dir, "mcp_stdio_proxy.mjs")

  @doc """
  Send a chat request via the Codex SDK bridge.
  """
  def chat(config, context) do
    prompt = build_prompt(context)
    request = build_request(config, prompt)

    Logger.debug("Codex SDK request: #{inspect(request)}")

    timeout = if config[:use_orchid_tools], do: 3_600_000, else: 600_000

    case run_request(config, request, timeout) do
      {:ok, %{"ok" => true, "content" => content}} when is_binary(content) ->
        if String.trim(content) == "" do
          Logger.error("Codex SDK returned empty response")
          {:error, "Codex SDK returned empty response"}
        else
          {:ok, %{content: content, tool_calls: nil}}
        end

      {:ok, %{"ok" => false, "error" => error}} ->
        Logger.error("Codex SDK error: #{String.slice(error, 0, 500)}")
        {:error, {:api_error, error}}

      {:ok, response} ->
        Logger.error("Codex SDK returned unexpected response: #{inspect(response)}")
        {:error, {:api_error, "Codex SDK returned unexpected response"}}

      {:error, :timeout} ->
        Logger.error("Codex SDK timeout after #{div(timeout, 1000)}s")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("Codex SDK execution failed: #{inspect(reason)}")
        {:error, {:api_error, reason}}
    end
  end

  @doc """
  Stream a chat request via the Codex SDK bridge.

  This currently preserves Orchid's existing buffered Codex behavior by invoking
  the callback once with the final response.
  """
  def chat_stream(config, context, callback) do
    case chat(config, context) do
      {:ok, %{content: content}} = result ->
        callback.(content)
        result

      error ->
        error
    end
  end

  defp run_request(config, request, timeout) do
    task = Task.async(fn -> execute_request(config, request) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp execute_request(config, request) do
    payload = Jason.encode!(request)

    result =
      if run_in_container?(config) do
        execute_in_container(config, payload)
      else
        execute_on_host(config, payload)
      end

    with {:ok, raw} <- result,
         {:ok, decoded} <- decode_bridge_output(raw) do
      {:ok, decoded}
    end
  end

  defp execute_on_host(config, payload) do
    node = System.find_executable("node") || "node"
    runner = host_runner_path()
    env = host_env(config)

    with_request_file(payload, fn request_path ->
      exec(node, [runner, request_path], stderr_to_stdout: true, env: env)
    end)
  end

  defp execute_in_container(config, payload) do
    container = Orchid.Sandbox.container_name(config[:project_id])
    remote_request = "/tmp/orchid-codex-request-#{System.unique_integer([:positive])}.json"

    with_container_codex_home(config, container, fn remote_home ->
      with_request_file(payload, fn request_path ->
        with {:ok, _} <-
               exec("podman", ["cp", request_path, "#{container}:#{remote_request}"],
                 stderr_to_stdout: true
               ),
             {:ok, output} <-
               exec(
                 "podman",
                 [
                   "exec",
                   "-w",
                   "/workspace",
                   "-e",
                   "HOME=/home/agent",
                   "-e",
                   "CODEX_HOME=#{remote_home}",
                   "-e",
                   "ORCHID_CODEX_CLI_PATH=/usr/local/bin/codex",
                   container,
                   "sh",
                   "-lc",
                   container_codex_command(remote_request, remote_home)
                 ],
                 stderr_to_stdout: true
               ) do
          {:ok, output}
        end
      end)
    end)
  end

  defp exec(command, args, opts) do
    try do
      case Orchid.OS.Command.run(command, args, opts) do
        {output, 0} ->
          {:ok, output}

        {output, code} ->
          {:error, format_command_error(command, code, output)}
      end
    rescue
      error in [ArgumentError, ErlangError] ->
        {:error, Exception.message(error)}
    end
  end

  defp with_request_file(payload, fun) do
    path =
      Path.join(
        System.tmp_dir!(),
        "orchid-codex-request-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, payload)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end

  defp decode_bridge_output(raw) do
    raw = String.trim(raw)

    case Jason.decode(raw) do
      {:ok, decoded} ->
        {:ok, decoded}

      _ ->
        raw
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.find_value(fn line ->
          case Jason.decode(line) do
            {:ok, decoded} -> {:ok, decoded}
            _ -> nil
          end
        end)
        |> case do
          nil -> {:error, "Invalid Codex SDK output: #{String.slice(raw, 0, 500)}"}
          decoded -> decoded
        end
    end
  end

  defp format_command_error(command, code, output) do
    summary = String.trim(output)

    if summary == "" do
      "#{command} exited with status #{code}"
    else
      "#{command} exited with status #{code}: #{summary}"
    end
  end

  defp shell_escape(arg) do
    escaped = String.replace(arg, "'", "'\\''")
    "'#{escaped}'"
  end

  defp container_codex_command(remote_request, remote_home) do
    request = shell_escape(remote_request)
    home = shell_escape(remote_home)

    "node #{shell_escape(container_runner_path())} #{request}; " <>
      "status=$?; rm -f #{request}; " <>
      "case #{home} in /tmp/orchid-codex-home-*) rm -rf #{home};; " <>
      "*) echo 'refusing to remove unexpected CODEX_HOME path: #{remote_home}' >&2; exit 98;; esac; " <>
      "exit $status"
  end

  defp host_env(config) do
    []
    |> maybe_put_env("CODEX_HOME", orchestrator_codex_home(config))
    |> maybe_put_env("ORCHID_CODEX_CLI_PATH", System.find_executable("codex"))
  end

  defp maybe_put_env(env, _key, nil), do: env
  defp maybe_put_env(env, key, value), do: [{key, value} | env]

  defp orchestrator_codex_home(%{use_orchid_tools: true, project_id: project_id} = config)
       when not is_nil(project_id) do
    setup_orchestrator_home(project_id, config[:agent_id])
  end

  defp orchestrator_codex_home(_), do: nil

  defp host_runner_path do
    System.get_env("ORCHID_CODEX_RUNNER_PATH") || Path.join(sdk_bridge_dir(), "runner.mjs")
  end

  defp container_runner_path do
    Path.join(@container_bridge_dir, "runner.mjs")
  end

  def sdk_bridge_dir do
    System.get_env("ORCHID_CODEX_BRIDGE_DIR") ||
      :code.priv_dir(:orchid) |> to_string() |> Path.join("codex_sdk")
  end

  def container_bridge_dir, do: @container_bridge_dir

  defp build_prompt(context) do
    user_msg =
      context.messages
      |> Enum.reverse()
      |> Enum.find(fn msg -> msg.role == :user end)
      |> case do
        nil -> ""
        msg -> msg.content
      end

    case context[:system] do
      nil -> user_msg
      "" -> user_msg
      system -> "## Instructions\n#{system}\n\n## Task\n#{user_msg}"
    end
  end

  defp build_request(config, prompt) do
    %{"prompt" => prompt}
    |> put_present("model", Catalog.resolve_model(config[:model], :codex))
    |> put_present(
      "modelReasoningEffort",
      normalize_reasoning_effort(config[:model_reasoning_effort])
    )
    |> put_present("workingDirectory", workspace_for(config))
    |> put_present("skipGitRepoCheck", skip_git_repo_check?(config))
    |> put_present("approvalPolicy", approval_policy_for(config))
    |> put_present("sandboxMode", sandbox_mode_for(config))
    |> put_present("bypassApprovalsAndSandbox", bypass_approvals_and_sandbox?(config))
    |> put_present("configOverrides", config_overrides_for(config))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp normalize_reasoning_effort(nil), do: nil
  defp normalize_reasoning_effort(effort) when is_atom(effort), do: Atom.to_string(effort)
  defp normalize_reasoning_effort(effort) when is_binary(effort), do: effort
  defp normalize_reasoning_effort(_), do: nil

  defp workspace_for(config) do
    case config[:project_id] do
      nil ->
        nil

      project_id ->
        workspace =
          cond do
            run_in_container?(config) ->
              "/workspace"

            true ->
              Orchid.Project.files_path(project_id) |> Path.expand()
          end

        unless run_in_container?(config) do
          File.mkdir_p!(workspace)
        end

        workspace
    end
  end

  defp skip_git_repo_check?(config), do: run_in_container?(config)

  defp approval_policy_for(config) do
    if run_in_container?(config), do: "never", else: nil
  end

  defp sandbox_mode_for(config) do
    if run_in_container?(config), do: "danger-full-access", else: "workspace-write"
  end

  defp bypass_approvals_and_sandbox?(config) do
    if run_in_container?(config), do: true, else: nil
  end

  defp config_overrides_for(config) do
    if config[:use_orchid_tools] do
      %{"features" => %{"shell_tool" => false}}
    else
      nil
    end
  end

  # Create a temp CODEX_HOME directory with config.toml that includes the Orchid MCP server.
  # Codex persists MCP config in config.toml rather than accepting it per-invocation.
  defp setup_orchestrator_home(project_id, agent_id) do
    cookie = File.read!(Path.expand("~/.erlang.cookie")) |> String.trim()
    orchid_root = File.cwd!()
    script = Path.join(orchid_root, "priv/mcp/orchid_mcp.exs")

    mcp_args =
      [
        "--name",
        "mcp-#{:erlang.unique_integer([:positive])}@127.0.0.1",
        "--cookie",
        cookie,
        script,
        project_id
      ] ++ if(agent_id, do: [agent_id], else: [])

    args_toml = "[" <> Enum.map_join(mcp_args, ", ", &"\"#{&1}\"") <> "]"
    workspace = Orchid.Project.files_path(project_id) |> Path.expand()

    config_toml = """
    [mcp_servers.orchid]
    command = "elixir"
    args = #{args_toml}

    [projects."#{workspace}"]
    trust_level = "trusted"
    """

    home = Path.join(System.tmp_dir!(), "orchid-codex-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(home)
    seed_codex_home(home)
    File.write!(Path.join(home, "config.toml"), config_toml)

    Logger.info("Codex orchestrator CODEX_HOME: #{home}")
    home
  end

  defp with_container_codex_home(%{project_id: project_id} = config, container, fun)
       when is_binary(project_id) do
    with_host_mcp_bridge(project_id, config[:agent_id], fn bridge ->
      local_home = setup_container_home(bridge.listen_port, bridge.token)
      remote_home = "/tmp/#{Path.basename(local_home)}"

      try do
        with {:ok, _} <-
               exec("podman", ["cp", local_home, "#{container}:/tmp"], stderr_to_stdout: true) do
          fun.(remote_home)
        end
      after
        safe_rm_rf_temp!(local_home, "orchid-codex-home-")
      end
    end)
  end

  defp with_container_codex_home(_config, _container, fun) do
    fun.("/home/agent/.codex")
  end

  defp with_host_mcp_bridge(project_id, agent_id, fun) do
    token = random_proxy_token()
    ready_file = temp_path("orchid-mcp-ready-", ".json")

    with {:ok, bridge} <- start_host_mcp_bridge(project_id, agent_id, token, ready_file) do
      try do
        fun.(bridge)
      after
        stop_host_mcp_bridge(bridge)
      end
    end
  end

  defp start_host_mcp_bridge(project_id, agent_id, token, ready_file) do
    node = System.find_executable("node") || "node"
    script = Path.join(sdk_bridge_dir(), "mcp_host_bridge.mjs")

    args =
      [script, "--project-id", project_id, "--token", token, "--ready-file", ready_file] ++
        if(agent_id, do: ["--agent-id", agent_id], else: [])

    port =
      Port.open(
        {:spawn_executable, node},
        [:binary, :exit_status, :stderr_to_stdout, args: args]
      )

    case await_bridge_ready(port, ready_file, "", System.monotonic_time(:millisecond) + 5_000) do
      {:ok, listen_port} ->
        {:ok,
         %{port_handle: port, listen_port: listen_port, token: token, ready_file: ready_file}}

      {:error, reason} ->
        stop_host_mcp_bridge(%{port_handle: port, ready_file: ready_file})
        {:error, reason}
    end
  end

  defp await_bridge_ready(port, ready_file, output, deadline_ms) do
    case File.read(ready_file) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"port" => listen_port}} when is_integer(listen_port) ->
            {:ok, listen_port}

          _ ->
            {:error, "Invalid Orchid MCP bridge metadata: #{String.trim(raw)}"}
        end

      _ ->
        remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

        cond do
          remaining_ms <= 0 ->
            summary = String.trim(output)

            if summary == "" do
              {:error, "Timed out starting Orchid MCP bridge"}
            else
              {:error, "Timed out starting Orchid MCP bridge: #{summary}"}
            end

          true ->
            receive do
              {^port, {:data, data}} ->
                await_bridge_ready(port, ready_file, output <> data, deadline_ms)

              {^port, {:exit_status, code}} ->
                {:error, format_command_error("node", code, output)}
            after
              min(remaining_ms, 50) ->
                await_bridge_ready(port, ready_file, output, deadline_ms)
            end
        end
    end
  end

  defp stop_host_mcp_bridge(%{port_handle: port_handle, ready_file: ready_file}) do
    File.rm(ready_file)

    try do
      Port.close(port_handle)
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp setup_container_home(listen_port, token) do
    home =
      Path.join(System.tmp_dir!(), "orchid-codex-home-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(home)
    seed_codex_home(home)

    config_toml = """
    [mcp_servers.orchid]
    command = "node"
    args = ["#{@container_mcp_proxy}", "#{mcp_proxy_host()}", "#{listen_port}", "#{token}"]

    [projects."/workspace"]
    trust_level = "trusted"
    """

    File.write!(Path.join(home, "config.toml"), config_toml)
    home
  end

  defp seed_codex_home(home) do
    real_home = System.get_env("CODEX_HOME") || Path.expand("~/.codex")

    if File.dir?(real_home) do
      ~w(auth.json installation_id version.json)
      |> Enum.each(fn entry ->
        source = Path.join(real_home, entry)

        if File.regular?(source) do
          File.cp!(source, Path.join(home, entry))
        end
      end)
    end
  end

  defp safe_rm_rf_temp!(path, prefix) when is_binary(path) and is_binary(prefix) do
    expanded = Path.expand(path)
    tmp = System.tmp_dir!() |> Path.expand()
    base = Path.basename(expanded)

    if String.starts_with?(expanded, tmp <> "/") and String.starts_with?(base, prefix) do
      File.rm_rf(expanded)
    else
      Logger.error("Refusing to remove unexpected Codex temp path: #{expanded}")
    end
  end

  defp random_proxy_token do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp temp_path(prefix, suffix) do
    Path.join(System.tmp_dir!(), "#{prefix}#{System.unique_integer([:positive])}#{suffix}")
  end

  defp mcp_proxy_host do
    System.get_env("ORCHID_MCP_PROXY_HOST") || "host.containers.internal"
  end

  defp run_in_container?(config) do
    mode = config[:execution_mode]

    config[:project_id] &&
      mode not in [:host, "host", :root_vm, "root_vm"]
  end
end
