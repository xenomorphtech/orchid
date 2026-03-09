defmodule Orchid.LLM.OAuth do
  @moduledoc """
  Claude API client using OAuth tokens (subscription-based).
  Requires .claude_tokens.json in project root (same format as query_claude.js).
  """
  require Logger
  alias Orchid.LLM.Catalog

  @api_url "https://api.anthropic.com/v1/messages?beta=true"

  def models, do: Catalog.model_map(:oauth)

  @doc """
  Send a chat request using OAuth tokens.
  """
  def chat(config, context) do
    do_chat(config, context, false, false)
  end

  defp do_chat(config, context, _stream, retried?) do
    with {:ok, token} <- load_token() do
      body = build_request_body(config, context, false)

      case Req.post(@api_url,
             json: body,
             headers: headers(token),
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200, body: response}} ->
          parse_response(response)

        {:ok, %{status: 401, body: _body}} when not retried? ->
          # Token expired mid-request, force refresh and retry
          Logger.info("Got 401, forcing token refresh...")

          case Orchid.LLM.TokenRefresh.force_refresh() do
            {:ok, _} -> do_chat(config, context, false, true)
            {:error, reason} -> {:error, {:refresh_failed, reason}}
          end

        {:ok, %{status: status, body: body}} ->
          Logger.error("OAuth API error: #{status} - #{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Stream a chat request using OAuth tokens.
  """
  def chat_stream(config, context, callback) do
    do_chat_stream(config, context, callback, false)
  end

  defp do_chat_stream(config, context, callback, retried?) do
    with {:ok, token} <- load_token() do
      body = build_request_body(config, context, true)

      # Use Agent to track streaming state
      {:ok, acc_pid} =
        Agent.start_link(fn ->
          %{content: "", tool_calls: [], current_tool: nil, input_json: ""}
        end)

      result =
        Req.post(@api_url,
          json: body,
          headers: headers(token),
          receive_timeout: 300_000,
          into: fn {:data, chunk}, {req, resp} ->
            Agent.update(acc_pid, fn acc ->
              process_sse_chunk(chunk, acc, callback)
            end)

            {:cont, {req, resp}}
          end
        )

      final_acc = Agent.get(acc_pid, & &1)
      Agent.stop(acc_pid)

      case result do
        {:ok, %{status: 200}} ->
          tool_calls = if final_acc.tool_calls == [], do: nil, else: final_acc.tool_calls
          {:ok, %{content: final_acc.content, tool_calls: tool_calls}}

        {:ok, %{status: 401}} when not retried? ->
          Logger.info("Got 401 on stream, forcing token refresh...")

          case Orchid.LLM.TokenRefresh.force_refresh() do
            {:ok, _} -> do_chat_stream(config, context, callback, true)
            {:error, reason} -> {:error, {:refresh_failed, reason}}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Load OAuth token with automatic refresh
  defp load_token do
    alias Orchid.LLM.TokenRefresh
    TokenRefresh.get_token()
  end

  defp headers(access_token) do
    [
      {"accept", "application/json"},
      {"anthropic-beta", "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14"},
      {"anthropic-dangerous-direct-browser-access", "true"},
      {"anthropic-version", "2023-06-01"},
      {"authorization", "Bearer #{access_token}"},
      {"content-type", "application/json"},
      {"user-agent", "claude-cli/2.0.72 (external, cli)"},
      {"x-app", "cli"}
    ]
  end

  @default_system "You are Claude Code, Anthropic's official CLI for Claude."

  defp build_request_body(config, context, stream) do
    model = Catalog.resolve_model(config[:model], :oauth)
    messages = format_messages(context.messages)

    # OAuth tokens require exact Claude Code system prompt
    # Custom instructions get prepended to first user message
    system_text = @default_system

    messages =
      case context[:system] do
        nil ->
          messages

        "" ->
          messages

        custom ->
          # Inject custom instructions into first user message
          case messages do
            [first | rest] ->
              [inject_instructions(first, custom) | rest]

            [] ->
              messages
          end
      end

    tools = format_tools(config)

    %{
      model: model,
      max_tokens: Map.get(config, :max_tokens, 16384),
      messages: messages,
      system: [%{type: "text", text: system_text, cache_control: %{type: "ephemeral"}}],
      tools: tools,
      stream: stream
    }
  end

  defp format_tools(config) do
    Orchid.Tool.list_tools(config[:allowed_tools])
    |> Enum.map(fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        input_schema: tool.parameters
      }
    end)
  end

  defp inject_instructions(%{content: [%{text: text} = content_block | rest]} = msg, instructions) do
    new_text = "[Instructions]\n#{instructions}\n\n[User Message]\n#{text}"
    %{msg | content: [%{content_block | text: new_text} | rest]}
  end

  defp inject_instructions(msg, _instructions), do: msg

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      case msg.role do
        :user ->
          %{
            role: "user",
            content: [%{type: "text", text: msg.content, cache_control: %{type: "ephemeral"}}]
          }

        :assistant ->
          format_assistant_message(msg)

        :tool ->
          %{
            role: "user",
            content: [
              %{
                type: "tool_result",
                tool_use_id: msg.content.tool_use_id,
                content: msg.content.content
              }
            ]
          }
      end
    end)
  end

  defp format_assistant_message(msg) do
    content =
      cond do
        msg[:tool_calls] && msg.tool_calls != [] ->
          text_block =
            if msg.content && msg.content != "" do
              [%{type: "text", text: msg.content}]
            else
              []
            end

          tool_blocks =
            Enum.map(msg.tool_calls, fn tc ->
              %{type: "tool_use", id: tc.id, name: tc.name, input: tc.arguments}
            end)

          text_block ++ tool_blocks

        true ->
          [%{type: "text", text: msg.content || ""}]
      end

    %{role: "assistant", content: content}
  end

  defp parse_response(response) do
    content_blocks = response["content"] || []

    text_content =
      content_blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])
      |> Enum.join("")

    tool_calls =
      content_blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn block ->
        %{id: block["id"], name: block["name"], arguments: block["input"]}
      end)

    tool_calls = if tool_calls == [], do: nil, else: tool_calls
    {:ok, %{content: text_content, tool_calls: tool_calls}}
  end

  defp process_sse_chunk(chunk, acc, callback) do
    chunk
    |> String.split("\n")
    |> Enum.reduce(acc, fn line, acc ->
      cond do
        String.starts_with?(line, "data: ") ->
          data = String.trim_leading(line, "data: ")

          if data != "[DONE]" do
            case Jason.decode(data) do
              {:ok, event} -> handle_sse_event(event, acc, callback)
              _ -> acc
            end
          else
            acc
          end

        true ->
          acc
      end
    end)
  end

  defp handle_sse_event(event, acc, callback) do
    case event["type"] do
      "content_block_start" ->
        block = event["content_block"]

        case block["type"] do
          "tool_use" ->
            %{
              acc
              | current_tool: %{id: block["id"], name: block["name"], arguments: %{}},
                input_json: ""
            }

          _ ->
            acc
        end

      "content_block_delta" ->
        delta = event["delta"]

        case delta["type"] do
          "text_delta" ->
            text = delta["text"] || ""
            callback.(text)
            %{acc | content: acc.content <> text}

          "input_json_delta" ->
            # Accumulate JSON for tool input
            %{acc | input_json: acc.input_json <> (delta["partial_json"] || "")}

          _ ->
            acc
        end

      "content_block_stop" ->
        if acc.current_tool do
          # Parse accumulated JSON
          arguments =
            case Jason.decode(acc.input_json) do
              {:ok, parsed} -> parsed
              _ -> %{}
            end

          tool = %{acc.current_tool | arguments: arguments}
          %{acc | tool_calls: acc.tool_calls ++ [tool], current_tool: nil, input_json: ""}
        else
          acc
        end

      _ ->
        acc
    end
  end
end
