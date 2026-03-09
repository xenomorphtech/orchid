defmodule Orchid.LLM.OpenRouter do
  @moduledoc """
  OpenRouter API client (OpenAI-compatible).
  Handles chat completion with streaming and tool use support.
  """
  require Logger
  alias Orchid.LLM.Catalog

  @base_url "https://openrouter.ai/api/v1/chat/completions"

  def chat(config, context) do
    with {:ok, api_key} <- get_api_key(config) do
      model = Catalog.resolve_model(config[:model], :openrouter)
      body = build_request_body(config, context, model)

      Logger.info("OpenRouter: sending to #{model}, #{length(context.messages)} messages")

      case Req.post(@base_url, json: body, headers: headers(api_key), receive_timeout: 300_000) do
        {:ok, %{status: 200, body: response}} ->
          parse_response(response)

        {:ok, %{status: status, body: resp_body}} ->
          Logger.error("OpenRouter API error #{status}: #{inspect(resp_body)}")
          {:error, {:api_error, status, resp_body}}

        {:error, reason} ->
          Logger.error("OpenRouter request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def chat_stream(config, context, callback) do
    with {:ok, api_key} <- get_api_key(config) do
      model = Catalog.resolve_model(config[:model], :openrouter)
      body = build_request_body(config, context, model) |> Map.put(:stream, true)

      tool_count = length(body[:tools] || [])

      Logger.info(
        "OpenRouter: streaming to #{model}, #{tool_count} tools, #{length(context.messages)} messages"
      )

      acc = %{content: "", tool_calls: [], current_tc_index: nil}

      stream_fun = fn {:data, chunk}, {req, resp} ->
        current = Process.get(:openrouter_acc, acc)
        updated = process_stream_chunk(chunk, current, callback)
        Process.put(:openrouter_acc, updated)
        {:cont, {req, resp}}
      end

      case Req.post(@base_url,
             json: body,
             headers: headers(api_key),
             receive_timeout: 300_000,
             into: stream_fun
           ) do
        {:ok, %{status: 200}} ->
          final = Process.get(:openrouter_acc, acc)
          Process.delete(:openrouter_acc)

          tool_calls =
            case final.tool_calls do
              [] ->
                nil

              tcs ->
                Enum.map(tcs, fn tc ->
                  args =
                    case Jason.decode(tc[:_args_json] || "{}") do
                      {:ok, parsed} -> parsed
                      _ -> %{}
                    end

                  %{id: tc.id, name: tc.name, arguments: args}
                end)
            end

          Logger.info(
            "OpenRouter: response complete, content=#{String.length(final.content)} chars, tool_calls=#{if tool_calls, do: length(tool_calls), else: 0}"
          )

          {:ok, %{content: final.content, tool_calls: tool_calls}}

        {:ok, %{status: status, body: resp_body}} ->
          Process.delete(:openrouter_acc)
          Logger.error("OpenRouter API error #{status}: #{inspect(resp_body)}")
          {:error, {:api_error, status, resp_body}}

        {:error, reason} ->
          Process.delete(:openrouter_acc)
          Logger.error("OpenRouter request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        function: %{
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters
        }
      }
    end)
  end

  # Private

  defp get_api_key(config) do
    case config[:api_key] || Orchid.Object.get_fact_value("openrouter_api_key") do
      nil ->
        {:error,
         {:api_key_missing,
          "openrouter_api_key fact not set. Add it in Settings > Facts or local facts file."}}

      key ->
        {:ok, key}
    end
  end

  defp headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]
  end

  defp build_request_body(config, context, model) do
    messages = format_messages(context)

    body = %{
      model: model,
      messages: messages,
      max_tokens: Map.get(config, :max_tokens, 65536)
    }

    if config[:disable_tools] do
      body
    else
      tools = Orchid.Tool.list_tools(config[:allowed_tools])

      if tools != [] do
        openai_tools = format_tools(tools)
        Map.put(body, :tools, openai_tools)
      else
        body
      end
    end
  end

  defp format_messages(context) do
    system_messages =
      if context.system && context.system != "" do
        system_text = build_system_prompt(context.system, context.objects, context.memory)
        [%{role: "system", content: system_text}]
      else
        []
      end

    chat_messages =
      context.messages
      |> Enum.map(fn msg ->
        case msg.role do
          :user ->
            %{role: "user", content: msg.content || ""}

          :assistant ->
            base = %{role: "assistant"}

            base =
              if msg.content && msg.content != "",
                do: Map.put(base, :content, msg.content),
                else: base

            if msg[:tool_calls] && msg.tool_calls != [] do
              tc =
                Enum.map(msg.tool_calls, fn tc ->
                  %{
                    id: tc.id,
                    type: "function",
                    function: %{name: tc.name, arguments: Jason.encode!(tc.arguments || %{})}
                  }
                end)

              Map.put(base, :tool_calls, tc)
            else
              Map.put(base, :content, msg.content || "")
            end

          :tool ->
            %{
              role: "tool",
              tool_call_id: msg.content[:tool_use_id],
              content: msg.content[:content] || ""
            }
        end
      end)

    system_messages ++ chat_messages
  end

  defp build_system_prompt(base_prompt, objects, memory) do
    parts = [base_prompt]

    parts =
      if objects && objects != "" do
        parts ++ ["\n\n## Available Objects\n\n#{objects}"]
      else
        parts
      end

    parts =
      if memory && map_size(memory) > 0 do
        memory_str =
          memory
          |> Enum.map(fn {k, v} -> "- #{k}: #{inspect(v)}" end)
          |> Enum.join("\n")

        parts ++ ["\n\n## Memory\n\n#{memory_str}"]
      else
        parts
      end

    Enum.join(parts)
  end

  defp parse_response(response) do
    message = get_in(response, ["choices", Access.at(0), "message"]) || %{}
    text = extract_text_content(message, response)

    tool_calls =
      case message["tool_calls"] do
        nil ->
          nil

        [] ->
          nil

        tcs ->
          Enum.map(tcs, fn tc ->
            %{
              id: tc["id"],
              name: get_in(tc, ["function", "name"]),
              arguments:
                case Jason.decode(get_in(tc, ["function", "arguments"]) || "{}") do
                  {:ok, args} -> args
                  _ -> %{}
                end
            }
          end)
      end

    {:ok, %{content: text, tool_calls: tool_calls}}
  end

  defp extract_text_content(message, response) do
    base =
      case Map.get(message, "content") do
        text when is_binary(text) ->
          text

        parts when is_list(parts) ->
          parts
          |> Enum.map(fn
            %{"type" => "text", "text" => t} when is_binary(t) -> t
            %{"text" => t} when is_binary(t) -> t
            %{"content" => t} when is_binary(t) -> t
            t when is_binary(t) -> t
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        _ ->
          ""
      end

    if String.trim(base) != "" do
      base
    else
      fallback =
        message["reasoning"] ||
          message["reasoning_content"] ||
          message["refusal"] ||
          get_in(response, ["choices", Access.at(0), "text"]) ||
          ""

      if is_binary(fallback), do: fallback, else: inspect(fallback)
    end
  end

  defp process_stream_chunk(chunk, acc, callback) do
    chunk
    |> String.split("\n")
    |> Enum.reduce(acc, fn line, acc ->
      cond do
        String.starts_with?(line, "data: [DONE]") ->
          acc

        String.starts_with?(line, "data: ") ->
          data = String.trim_leading(line, "data: ")

          case Jason.decode(data) do
            {:ok, event} ->
              delta = get_in(event, ["choices", Access.at(0), "delta"]) || %{}

              # Handle text content
              acc =
                case delta["content"] do
                  nil ->
                    acc

                  "" ->
                    acc

                  text ->
                    callback.(text)
                    %{acc | content: acc.content <> text}
                end

              # Handle tool calls (streamed incrementally)
              case delta["tool_calls"] do
                nil ->
                  acc

                tool_deltas ->
                  Enum.reduce(tool_deltas, acc, fn td, acc ->
                    idx = td["index"]

                    if td["id"] do
                      # New tool call starting
                      tc = %{
                        id: td["id"],
                        name: get_in(td, ["function", "name"]) || "",
                        _args_json: get_in(td, ["function", "arguments"]) || ""
                      }

                      %{acc | tool_calls: acc.tool_calls ++ [tc], current_tc_index: idx}
                    else
                      # Continuation of existing tool call (appending arguments)
                      args_chunk = get_in(td, ["function", "arguments"]) || ""
                      tc_list = acc.tool_calls
                      # Find the tool call at this index
                      tc_pos = length(tc_list) - 1

                      if tc_pos >= 0 do
                        tc = Enum.at(tc_list, tc_pos)
                        existing = tc[:_args_json] || ""
                        updated_tc = Map.put(tc, :_args_json, existing <> args_chunk)
                        updated_list = List.replace_at(tc_list, tc_pos, updated_tc)
                        %{acc | tool_calls: updated_list}
                      else
                        acc
                      end
                    end
                  end)
              end

            _ ->
              acc
          end

        true ->
          acc
      end
    end)
  end
end
