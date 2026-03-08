defmodule Orchid.LLM.Codex do
  @moduledoc """
  OpenAI Codex CLI-based provider.
  Uses `codex exec` for non-interactive agentic coding.

  Codex handles its own tool calls internally (shell, file ops).
  Returns text-only responses to Orchid (no tool_calls).

  ## Config options
  - `:model` - model string (default: from codex config, typically "gpt-5.3-codex")
  - `:project_id` - project ID for workspace directory
  - `:use_orchid_tools` - when true, runs as orchestrator with Orchid MCP tools
  - `:agent_id` - agent ID (passed to MCP server for tool context)
  """
  require Logger

  @doc """
  Send a chat request via Codex CLI.
  """
  def chat(config, context) do
    prompt = build_prompt(context)
    args = build_args(config, prompt)

    Logger.debug("Codex args: #{inspect(args)}")

    task = Task.async(fn ->
      cmd = build_shell_command(args, config)
      Logger.info("Codex exec: #{String.slice(cmd, 0, 300)}")
      output = :os.cmd(String.to_charlist(cmd))
      raw = to_string(output) |> String.trim()
      Logger.info("Codex raw (#{byte_size(raw)} bytes): #{String.slice(raw, 0, 200)}")
      parse_jsonl(raw)
    end)

    # Orchestrators with MCP tools need much longer — they spawn agents and wait
    timeout = if config[:use_orchid_tools], do: 3_600_000, else: 600_000

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, ""} ->
        Orchid.OpenAIUsage.refresh_async()
        Logger.error("Codex returned empty response")
        {:error, "Codex returned empty response"}

      {:ok, content} ->
        Orchid.OpenAIUsage.refresh_async()

        if String.starts_with?(content, "Error:") or String.starts_with?(content, "error:") do
          Logger.error("Codex error: #{String.slice(content, 0, 500)}")
          {:error, {:api_error, content}}
        else
          {:ok, %{content: content, tool_calls: nil}}
        end

      nil ->
        Orchid.OpenAIUsage.refresh_async()
        Logger.error("Codex timeout after #{div(timeout, 1000)}s")
        {:error, :timeout}
    end
  end

  @doc """
  Stream a chat request via Codex CLI.
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

  # Parse JSONL output from `codex exec --json`.
  # Codex event shapes evolve; keep extraction tolerant so callers don't fail on format drift.
  defp parse_jsonl(raw) do
    {entries, passthrough_lines} =
      raw
      |> String.split("\n")
      |> Enum.reduce({[], []}, fn line, {acc, passthrough} ->
        line = String.trim(line)

        case Jason.decode(line) do
          {:ok, event} when is_map(event) ->
            {acc ++ extract_entries_from_event(event), passthrough}

          _ ->
            if line == "", do: {acc, passthrough}, else: {acc, passthrough ++ [line]}
        end
      end)

    formatted =
      entries
      |> Enum.map(fn
        {:message, text} -> text
        {:command, text} -> "```\n#{text}\n```"
      end)
      |> Enum.join("\n\n")

    if formatted == "" and passthrough_lines != [] do
      Enum.join(passthrough_lines, "\n")
    else
      formatted
    end
  end

  defp extract_entries_from_event(%{"type" => "item.completed", "item" => item}) when is_map(item) do
    extract_entries_from_item(item)
  end

  defp extract_entries_from_event(%{"type" => "response.output_text.delta", "delta" => delta})
       when is_binary(delta) and delta != "" do
    [{:message, delta}]
  end

  defp extract_entries_from_event(%{"type" => "response.output_text.done", "text" => text})
       when is_binary(text) and text != "" do
    [{:message, text}]
  end

  defp extract_entries_from_event(%{"type" => "response.completed", "response" => %{"output" => output}})
       when is_list(output) do
    Enum.flat_map(output, &extract_entries_from_item/1)
  end

  defp extract_entries_from_event(%{"type" => "error", "message" => msg}) when is_binary(msg) do
    [{:message, "Error: #{msg}"}]
  end

  defp extract_entries_from_event(_), do: []

  defp extract_entries_from_item(%{"type" => type} = item)
       when type in ["agent_message", "assistant_message", "message"] do
    text =
      case item do
        %{"text" => t} when is_binary(t) -> t
        %{"content" => content} -> content_to_text(content)
        _ -> ""
      end

    if text == "", do: [], else: [{:message, text}]
  end

  defp extract_entries_from_item(%{"type" => "command_execution"} = item) do
    cmd = item["command"] || item["cmd"] || "(command)"
    output = item["aggregated_output"] || item["output"] || ""
    code = item["exit_code"] || item["status_code"]

    summary =
      "$ #{cmd}\n#{output}" <>
        if(is_integer(code) and code != 0, do: "\n(exit code: #{code})", else: "")

    [{:command, summary}]
  end

  defp extract_entries_from_item(_), do: []

  defp content_to_text(content) when is_binary(content), do: content

  defp content_to_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"type" => "output_text", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp content_to_text(_), do: ""

  defp build_prompt(context) do
    # Codex doesn't have a separate system prompt flag.
    # Prepend system prompt to the user message.
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

  defp build_args(config, prompt) do
    args = ["exec", "--json"]
    run_in_container = run_in_container?(config)

    # Model
    args = case config[:model] do
      nil -> args
      :gpt53 -> args ++ ["-m", "gpt-5.3-codex"]
      model when is_atom(model) -> args ++ ["-m", to_string(model)]
      model when is_binary(model) -> args ++ ["-m", model]
    end

    args =
      case config[:reasoning_effort] do
        effort when effort in [:low, :medium, :high, :xhigh] ->
          args ++ ["-c", "model_reasoning_effort=\"#{effort}\""]

        effort when effort in ["low", "medium", "high", "xhigh"] ->
          args ++ ["-c", "model_reasoning_effort=\"#{effort}\""]

        _ ->
          args
      end

    # Working directory - point at project files
    args = case config[:project_id] do
      nil -> args
      project_id ->
        workspace =
          cond do
            config[:use_orchid_tools] ->
              Orchid.Project.files_path(project_id) |> Path.expand()

            run_in_container ->
              "/workspace"

            true ->
            Orchid.Project.files_path(project_id) |> Path.expand()
          end

        if config[:use_orchid_tools] or not run_in_container, do: File.mkdir_p!(workspace)
        args ++ ["-C", workspace]
    end

    # Execution policy:
    # - Worker agents already run inside Podman sandbox containers. Disable Codex's nested sandbox
    #   so shell commands use container networking/filesystem directly.
    # - Orchestrators keep Codex full-auto behavior.
    args =
      if run_in_container do
        args ++ ["--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check"]
      else
        args ++ ["--full-auto"]
      end

    # Orchestrators: disable shell tool, only use MCP tools
    args = if config[:use_orchid_tools] do
      args ++ ["--disable", "shell_tool"]
    else
      args
    end

    # Prompt at the end
    args ++ [prompt]
  end

  defp build_shell_command(args, config) do
    codex_path = System.find_executable("codex") || "codex"
    escaped_args = Enum.map(args, &shell_escape/1)
    run_in_container = run_in_container?(config)

    cond do
      # Orchestrator: run on host with Orchid MCP tools
      config[:use_orchid_tools] && config[:project_id] ->
        codex_home = setup_orchestrator_home(config[:project_id], config[:agent_id])
        "CODEX_HOME=#{shell_escape(codex_home)} #{codex_path} #{Enum.join(escaped_args, " ")} 2>&1"

      # Worker agent in VM mode: run inside sandbox container for isolation.
      config[:project_id] && run_in_container ->
        container = "orchid-project-#{config[:project_id]}"
        inner_cmd = "cd /workspace && codex #{Enum.join(escaped_args, " ")}"
        "podman exec #{container} sh -c #{shell_escape(inner_cmd)} 2>&1"

      # Worker agent in host mode: run on host.
      config[:project_id] ->
        "#{codex_path} #{Enum.join(escaped_args, " ")} 2>&1"

      # No project: run on host
      true ->
        "#{codex_path} #{Enum.join(escaped_args, " ")} 2>&1"
    end
  end

  # Create a temp CODEX_HOME directory with config.toml that includes the Orchid MCP server.
  # Codex persists MCP config in config.toml rather than accepting it per-invocation.
  defp setup_orchestrator_home(project_id, agent_id) do
    cookie = File.read!(Path.expand("~/.erlang.cookie")) |> String.trim()
    orchid_root = File.cwd!()
    script = Path.join(orchid_root, "priv/mcp/orchid_mcp.exs")

    # Build MCP server command args
    mcp_args = [
      "--name", "mcp-#{:erlang.unique_integer([:positive])}@127.0.0.1",
      "--cookie", cookie,
      script,
      project_id
    ] ++ if(agent_id, do: [agent_id], else: [])

    # Format args as TOML array
    args_toml = "[" <> Enum.map_join(mcp_args, ", ", &"\"#{&1}\"") <> "]"

    # Build config.toml with MCP server and project trust
    workspace = Orchid.Project.files_path(project_id) |> Path.expand()

    config_toml = """
    [mcp_servers.orchid]
    command = "elixir"
    args = #{args_toml}

    [projects."#{workspace}"]
    trust_level = "trusted"
    """

    # Write to temp directory
    home = Path.join(System.tmp_dir!(), "orchid-codex-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "config.toml"), config_toml)

    # Copy auth credentials from the real CODEX_HOME
    real_home = System.get_env("CODEX_HOME") || Path.expand("~/.codex")
    auth_file = Path.join(real_home, "auth.json")
    if File.exists?(auth_file) do
      File.cp!(auth_file, Path.join(home, "auth.json"))
    end

    Logger.info("Codex orchestrator CODEX_HOME: #{home}")
    home
  end

  defp shell_escape(arg) do
    escaped = String.replace(arg, "'", "'\\''")
    "'#{escaped}'"
  end

  defp run_in_container?(config) do
    mode = config[:execution_mode]
    config[:project_id] && !config[:use_orchid_tools] && mode not in [:host, "host", :root_vm, "root_vm"]
  end
end
