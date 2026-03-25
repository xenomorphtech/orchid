defmodule Orchid.LLM.CLI do
  @moduledoc """
  Claude CLI-based provider.
  Uses the `claude` CLI tool which handles auth via subscription.

  ## Config options
  - `:model` - :sonnet, :haiku, :opus, or model string
  - `:session_id` - Session ID for persistent conversations
  - `:resume` - Resume an existing session (boolean)
  - `:output_format` - "text", "json", or "stream-json" (default: "text")
  - `:max_turns` - Maximum agentic turns (default: unlimited)
  - `:allowed_tools` - List of allowed tools
  - `:permission_mode` - Permission mode for tool execution
  """
  require Logger
  alias Orchid.LLM.Catalog

  @doc """
  Send a chat request via Claude CLI.
  """
  def chat(config, context) do
    do_chat(config, context, false)
  end

  defp do_chat(config, context, retried?) do
    prompt = get_prompt(context)
    args = build_args(config, context, prompt)

    Logger.debug("Claude CLI args: #{inspect(args)}")

    with {:ok, spec} <- build_command_spec(config, args) do
      try do
        # Run in a Task so the owning process controls the CLI subprocess lifetime.
        task =
          Task.async(fn ->
            command_message = "CLI exec (full): #{format_command_spec(spec)}"
            Logger.info(command_message)

            Orchid.EventLog.info(:cli, command_message,
              project_id: config[:project_id],
              agent_id: config[:agent_id],
              metadata: %{
                model: config[:model],
                output_format: config[:output_format]
              }
            )

            {output, status} = run_command(spec)
            result = String.trim(output)

            Logger.info(
              "CLI result (#{byte_size(result)} bytes, exit=#{status}): #{String.slice(result, 0, 500)}"
            )

            {result, status}
          end)

        # Orchestrators with MCP tools need much longer — they spawn agents and wait
        timeout = if config[:use_orchid_tools], do: 3_600_000, else: 600_000

        case Task.yield(task, timeout) do
          {:ok, {content, status}} ->
            handle_cli_result(content, status, config, context, retried?)

          nil ->
            Task.shutdown(task, :brutal_kill)
            Logger.error("CLI timeout after #{div(timeout, 1000)}s")
            {:error, :timeout}
        end
      after
        cleanup_command_spec(spec)
      end
    end
  end

  @doc """
  Stream a chat request via Claude CLI.
  Streams output via callback.
  """
  def chat_stream(config, context, callback) do
    # For CLI, we run the command and stream the result after
    # True streaming would require parsing stream-json format
    case chat(config, context) do
      {:ok, %{content: content}} = result ->
        callback.(content)
        result

      error ->
        error
    end
  end

  defp build_command_spec(config, args) do
    claude_path = System.find_executable("claude")
    run_in_container = run_in_container?(config)

    cond do
      # Orchestrator with Orchid tools — run on host with MCP server
      config[:use_orchid_tools] && config[:project_id] ->
        mcp_config = orchid_mcp_config(config[:project_id], config[:agent_id])

        with_executable(claude_path, "claude", fn executable ->
          {:ok,
           %{
             command: executable,
             args:
               args ++
                 ["--mcp-config", mcp_config, "--strict-mcp-config", "--tools", ""],
             env: [{"CLAUDECODE", ""}],
             cleanup_paths: [mcp_config]
           }}
        end)

      # Worker agent in VM mode — run inside sandbox container
      config[:project_id] && run_in_container ->
        container = "orchid-project-#{config[:project_id]}"
        podman_path = System.find_executable("podman")

        with_executable(podman_path, "podman", fn executable ->
          {:ok,
           %{
             command: executable,
             args: ["exec", "-w", "/workspace", container, "claude"] ++ args
           }}
        end)

      # Worker agent in host mode — run on host in project directory
      config[:project_id] ->
        workspace = Orchid.Project.files_path(config[:project_id]) |> Path.expand()

        with_executable(claude_path, "claude", fn executable ->
          {:ok,
           %{
             command: executable,
             args: args,
             cd: workspace
           }}
        end)

      # No project — run on host
      true ->
        with_executable(claude_path, "claude", fn executable ->
          {:ok,
           %{
             command: executable,
             args: args
           }}
        end)
    end
  end

  defp orchid_mcp_config(project_id, agent_id) do
    cookie = File.read!(Path.expand("~/.erlang.cookie")) |> String.trim()
    orchid_root = File.cwd!()
    script = Path.join(orchid_root, "priv/mcp/orchid_mcp.exs")

    config = %{
      mcpServers: %{
        orchid: %{
          command: "elixir",
          args:
            [
              "--name",
              "mcp-#{:erlang.unique_integer([:positive])}@127.0.0.1",
              "--cookie",
              cookie,
              script,
              project_id
            ] ++ if(agent_id, do: [agent_id], else: [])
        }
      }
    }

    # Write to temp file
    path = Path.join(System.tmp_dir!(), "orchid-mcp-#{:erlang.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(config))
    path
  end

  defp run_command(spec) do
    Orchid.OS.Command.run(spec.command, spec.args,
      cd: spec[:cd],
      env: spec[:env],
      stderr_to_stdout: true
    )
  end

  defp handle_cli_result("", _status, _config, _context, _retried?) do
    Logger.error("CLI returned empty response")
    {:error, "CLI returned empty response"}
  end

  defp handle_cli_result(content, status, config, context, retried?) do
    cond do
      not retried? and oauth_token_expired_error?(content) ->
        Logger.warning("CLI auth expired; forcing token refresh and retrying once")

        case Orchid.LLM.TokenRefresh.force_refresh() do
          {:ok, _} ->
            do_chat(config, context, true)

          {:error, reason} ->
            Logger.error("CLI token refresh failed: #{inspect(reason)}")
            {:error, {:refresh_failed, reason}}
        end

      status != 0 ->
        Logger.error("CLI exited with status #{status}: #{String.slice(content, 0, 500)}")
        {:error, {:exit_status, status, content}}

      String.starts_with?(content, "Error:") or String.starts_with?(content, "error:") ->
        Logger.error("CLI error: #{String.slice(content, 0, 500)}")
        {:error, {:api_error, content}}

      true ->
        {:ok, %{content: content, tool_calls: nil}}
    end
  end

  defp with_executable(nil, name, _fun), do: {:error, "#{name} executable not found"}
  defp with_executable(path, _name, fun), do: fun.(path)

  defp cleanup_command_spec(spec) do
    Enum.each(spec[:cleanup_paths] || [], fn path ->
      File.rm(path)
    end)
  end

  defp format_command_spec(spec) do
    env =
      spec[:env]
      |> List.wrap()
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{shell_escape(value)}" end)

    cmd =
      [spec.command | spec.args]
      |> Enum.map_join(" ", &shell_escape/1)

    prefix =
      case spec[:cd] do
        nil -> nil
        dir -> "cd #{shell_escape(dir)} &&"
      end

    [prefix, env, cmd]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp shell_escape(arg) do
    escaped = String.replace(arg, "'", "'\\''")
    "'#{escaped}'"
  end

  defp get_prompt(context) do
    # Prefer the last user message; never return empty for --print mode.
    prompt =
      context.messages
      |> Enum.reverse()
      |> Enum.find_value(fn msg ->
        if msg.role == :user and is_binary(msg.content) do
          content = String.trim(msg.content)
          if content != "", do: content
        end
      end)

    cond do
      is_binary(prompt) and prompt != "" ->
        prompt

      true ->
        context.messages
        |> Enum.reverse()
        |> Enum.find_value(fn msg ->
          if is_binary(msg.content) do
            content = String.trim(msg.content)
            if content != "", do: content
          end
        end)
        |> case do
          nil -> "Continue based on system instructions and return a concise response."
          content -> content
        end
    end
  end

  defp build_args(config, context, prompt, opts \\ []) do
    streaming = Keyword.get(opts, :stream, false)
    prompt = ensure_non_empty_prompt(prompt, context)

    # Start with --print flag (non-interactive mode)
    args = ["--print"]

    # Output format
    args =
      if streaming do
        args ++ ["--output-format", "stream-json"]
      else
        format = config[:output_format] || "text"
        args ++ ["--output-format", format]
      end

    # Model
    args = args ++ model_flag(config[:model])

    # System prompt
    args =
      if context[:system] && context.system != "" do
        args ++ ["--system-prompt", context.system]
      else
        args
      end

    # Max turns — allow enough tool calls for real work (read, edit, test, etc.)
    # Orchid's agent loop handles higher-level re-kicking if needed
    max_turns = config[:max_turns] || 100
    args = args ++ ["--max-turns", to_string(max_turns)]

    # Disable tools entirely for one-shot meta tasks (summarization/review)
    args =
      if config[:disable_tools] do
        args ++ ["--tools", ""]
      else
        args
      end

    # Allowed tools
    args =
      if config[:allowed_tools] && config[:allowed_tools] != [] do
        tools = Enum.join(config[:allowed_tools], ",")
        args ++ ["--allowed-tools", tools]
      else
        args
      end

    # Permission mode — sandbox containers skip permissions by default
    args =
      cond do
        config[:permission_mode] ->
          args ++ ["--permission-mode", config[:permission_mode]]

        config[:project_id] && run_in_container?(config) ->
          args ++ ["--dangerously-skip-permissions"]

        true ->
          args
      end

    # Prompt is a positional argument at the end.
    # Use `--` so prompt text is never parsed as a flag.
    args ++ ["--", prompt]
  end

  defp model_flag(model) do
    case Catalog.resolve_model(model, :cli) do
      nil -> []
      resolved -> ["--model", resolved]
    end
  end

  defp oauth_token_expired_error?(content) when is_binary(content) do
    lc = String.downcase(content)

    String.contains?(lc, "oauth token has expired") or
      String.contains?(lc, "\"authentication_error\"")
  end

  defp ensure_non_empty_prompt(prompt, context) when is_binary(prompt) do
    trimmed = String.trim(prompt)

    if trimmed != "" do
      trimmed
    else
      fallback_prompt(context)
    end
  end

  defp ensure_non_empty_prompt(_prompt, context), do: fallback_prompt(context)

  defp fallback_prompt(context) do
    context.messages
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      if is_binary(msg.content) do
        content = String.trim(msg.content)
        if content != "", do: content
      end
    end)
    |> case do
      nil -> "Continue based on system instructions and return a concise response."
      content -> content
    end
  end

  defp run_in_container?(config) do
    mode = config[:execution_mode]

    config[:project_id] && !config[:use_orchid_tools] &&
      mode not in [:host, "host", :root_vm, "root_vm"]
  end
end
