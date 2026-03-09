defmodule Orchid.LLM.Gemini do
  @moduledoc """
  Google Gemini API client.
  Handles chat completion with streaming and tool use support.
  """
  require Logger
  alias Orchid.LLM.Catalog

  @base_url "https://generativelanguage.googleapis.com/v1beta/models"

  @doc """
  Send a chat request to Gemini.
  """
  def chat(config, context) do
    with {:ok, api_key} <- get_api_key(config) do
      model = Catalog.resolve_model(config[:model], :gemini)
      url = "#{@base_url}/#{model}:generateContent"
      body = build_request_body(config, context)

      case Req.post(url, json: body, headers: headers(api_key), receive_timeout: 120_000) do
        {:ok, %{status: 200, body: response}} ->
          parse_response(response)

        {:ok, %{status: status, body: resp_body}} ->
          Logger.error("Gemini API error #{status}: #{inspect(resp_body)}")
          {:error, {:api_error, status, resp_body}}

        {:error, reason} ->
          Logger.error("Gemini request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Send a streaming chat request to Gemini.
  """
  def chat_stream(config, context, callback) do
    with {:ok, api_key} <- get_api_key(config) do
      model = Catalog.resolve_model(config[:model], :gemini)
      url = "#{@base_url}/#{model}:streamGenerateContent?alt=sse"
      body = build_request_body(config, context)

      tool_count = length(get_in(body, [:tools, Access.at(0), :function_declarations]) || [])

      Logger.info(
        "Gemini: sending to #{model}, #{tool_count} tools, #{length(body.contents)} messages"
      )

      acc = %{content: "", tool_calls: [], current_tool: nil}

      stream_fun = fn {:data, chunk}, {req, resp} ->
        current = Process.get(:gemini_acc, acc)
        # Capture raw chunks for error reporting (stream body is consumed)
        raw = Process.get(:gemini_raw, "")
        Process.put(:gemini_raw, raw <> chunk)
        updated = process_stream_chunk(chunk, current, callback)
        Process.put(:gemini_acc, updated)
        {:cont, {req, resp}}
      end

      case Req.post(url,
             json: body,
             headers: headers(api_key),
             receive_timeout: 120_000,
             into: stream_fun
           ) do
        {:ok, %{status: 200}} ->
          final = Process.get(:gemini_acc, acc)
          Process.delete(:gemini_acc)
          Process.delete(:gemini_raw)
          tool_calls = if final.tool_calls == [], do: nil, else: final.tool_calls

          Logger.info(
            "Gemini: response complete, content=#{String.length(final.content)} chars, tool_calls=#{if tool_calls, do: length(tool_calls), else: 0}"
          )

          {:ok, %{content: final.content, tool_calls: tool_calls}}

        {:ok, %{status: status}} ->
          raw_body = Process.get(:gemini_raw, "")
          Process.delete(:gemini_acc)
          Process.delete(:gemini_raw)
          error_detail = if raw_body != "", do: raw_body, else: "(empty response body)"
          Logger.error("Gemini API error #{status}: #{error_detail}")
          log_failed_request(body, status)
          {:error, {:api_error, status, error_detail}}

        {:error, reason} ->
          Process.delete(:gemini_acc)
          Process.delete(:gemini_raw)
          Logger.error("Gemini request failed: #{inspect(reason)}")
          log_failed_request(body, reason)
          {:error, reason}
      end
    end
  end

  @doc """
  Format tools for Gemini API format.
  """
  def format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters
      }
    end)
  end

  @failed_request_log "priv/data/gemini_failed_requests.log"

  defp log_failed_request(body, error) do
    File.mkdir_p!(Path.dirname(@failed_request_log))
    ts = DateTime.utc_now() |> DateTime.to_string()

    # Summarize the request: message count, tool count, content sizes
    msg_count = length(body[:contents] || [])
    tool_count = length(get_in(body, [:tools, Access.at(0), :function_declarations]) || [])

    system_size =
      case body[:system_instruction] do
        %{parts: [%{text: t}]} -> byte_size(t)
        _ -> 0
      end

    body_json = Jason.encode!(body, pretty: true)
    body_size = byte_size(body_json)

    entry = """
    === #{ts} error=#{inspect(error)} ===
    messages=#{msg_count} tools=#{tool_count} system_prompt=#{system_size}B body=#{body_size}B
    #{body_json}
    """

    File.write!(@failed_request_log, entry, [:append])
    Logger.warning("Gemini: failed request logged to #{@failed_request_log} (#{body_size}B)")
  end

  # Private functions

  defp get_api_key(config) do
    case config[:api_key] || Orchid.Object.get_fact_value("gemini_api_key") do
      nil ->
        {:error,
         {:api_key_missing,
          "gemini_api_key fact not set. Add it in Settings > Facts or local facts file."}}

      key ->
        {:ok, key}
    end
  end

  defp headers(api_key) do
    [
      {"x-goog-api-key", api_key},
      {"content-type", "application/json"}
    ]
  end

  defp build_request_body(config, context) do
    contents = format_messages(context.messages)

    generation_config =
      %{
        maxOutputTokens: Map.get(config, :max_tokens, 65536)
      }
      |> maybe_put_response_mime_type(config)
      |> maybe_put_thinking_config(config)

    body = %{
      contents: contents,
      generationConfig: generation_config
    }

    # Add system instruction
    body =
      if context.system && context.system != "" do
        system_text = build_system_prompt(context.system, context.objects, context.memory)
        Map.put(body, :system_instruction, %{parts: [%{text: system_text}]})
      else
        body
      end

    # Add tools
    tools = Orchid.Tool.list_tools(config[:allowed_tools])

    if tools != [] do
      gemini_tools =
        Enum.map(tools, fn tool ->
          params = sanitize_params(tool.parameters)
          %{name: tool.name, description: tool.description, parameters: params}
        end)

      body
      |> Map.put(:tools, [%{function_declarations: gemini_tools}])
      |> Map.put(:tool_config, %{function_calling_config: %{mode: "AUTO"}})
    else
      body
    end
    |> maybe_put_google_search_tool(config)
  end

  defp maybe_put_thinking_config(generation_config, config) do
    case normalize_thinking_level(config[:thinking_level]) do
      nil ->
        generation_config

      level ->
        Map.put(generation_config, :thinkingConfig, %{thinkingLevel: level})
    end
  end

  defp maybe_put_response_mime_type(generation_config, config) do
    case config[:response_mime_type] do
      mime when is_binary(mime) and mime != "" ->
        Map.put(generation_config, :responseMimeType, mime)

      _ ->
        generation_config
    end
  end

  defp maybe_put_google_search_tool(body, config) do
    if config[:google_search] do
      current_tools = Map.get(body, :tools, [])
      Map.put(body, :tools, current_tools ++ [%{googleSearch: %{}}])
    else
      body
    end
  end

  defp normalize_thinking_level(nil), do: nil
  defp normalize_thinking_level(:low), do: "LOW"
  defp normalize_thinking_level(:medium), do: "MEDIUM"
  defp normalize_thinking_level(:high), do: "HIGH"

  defp normalize_thinking_level(level) when is_binary(level) do
    case String.downcase(level) do
      "low" -> "LOW"
      "medium" -> "MEDIUM"
      "high" -> "HIGH"
      _ -> nil
    end
  end

  defp normalize_thinking_level(_), do: nil

  # Gemini doesn't accept "required" or empty properties in certain cases
  defp sanitize_params(params) when is_map(params) do
    params
    |> Map.delete(:required)
    |> Map.delete("required")
    |> Map.update(:properties, %{}, fn props ->
      if props == %{}, do: %{_placeholder: %{type: "string", description: "unused"}}, else: props
    end)
    |> Map.update("properties", nil, fn
      nil ->
        nil

      props when props == %{} ->
        %{"_placeholder" => %{"type" => "string", "description" => "unused"}}

      props ->
        props
    end)
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp sanitize_params(params), do: params

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

  defp format_messages(messages) do
    messages
    |> Enum.map(fn msg ->
      case msg.role do
        :user ->
          %{role: "user", parts: [%{text: msg.content || ""}]}

        :assistant ->
          parts =
            if msg[:tool_calls] && msg.tool_calls != [] do
              text_parts =
                if msg.content && msg.content != "" do
                  [%{text: msg.content}]
                else
                  []
                end

              tool_parts =
                Enum.map(msg.tool_calls, fn tc ->
                  part = %{functionCall: %{name: tc.name, args: tc.arguments || %{}}}
                  # Include thoughtSignature for Gemini 3+ models
                  if tc[:thought_signature],
                    do: Map.put(part, :thoughtSignature, tc.thought_signature),
                    else: part
                end)

              text_parts ++ tool_parts
            else
              [%{text: msg.content || ""}]
            end

          %{role: "model", parts: parts}

        :tool ->
          # Tool results — will be merged with adjacent :tool messages below
          %{
            role: "user",
            parts: [
              %{
                functionResponse: %{
                  name: msg.content[:tool_name] || msg.content[:tool_use_id],
                  response: %{result: msg.content[:content] || ""}
                }
              }
            ]
          }
      end
    end)
    |> merge_consecutive_roles()
  end

  # Gemini requires strictly alternating model/user turns.
  # Merge consecutive messages with the same role into one.
  defp merge_consecutive_roles(messages) do
    messages
    |> Enum.chunk_while(
      nil,
      fn msg, acc ->
        case acc do
          nil ->
            {:cont, msg}

          %{role: role} when role == msg.role ->
            {:cont, %{acc | parts: acc.parts ++ msg.parts}}

          _ ->
            {:cont, acc, msg}
        end
      end,
      fn
        nil -> {:cont, []}
        acc -> {:cont, acc, nil}
      end
    )
  end

  defp parse_response(response) do
    parts = get_in(response, ["candidates", Access.at(0), "content", "parts"]) || []
    extract_parts(parts)
  end

  defp extract_parts(parts) do
    text =
      parts
      |> Enum.filter(&Map.has_key?(&1, "text"))
      |> Enum.map(& &1["text"])
      |> Enum.join("")

    tool_calls =
      parts
      |> Enum.filter(&Map.has_key?(&1, "functionCall"))
      |> Enum.map(fn part ->
        fc = part["functionCall"]

        tc = %{
          id: "call_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}",
          name: fc["name"],
          arguments: fc["args"] || %{}
        }

        # Preserve thoughtSignature for Gemini 3+ models
        if part["thoughtSignature"],
          do: Map.put(tc, :thought_signature, part["thoughtSignature"]),
          else: tc
      end)

    tool_calls = if tool_calls == [], do: nil, else: tool_calls
    {:ok, %{content: text, tool_calls: tool_calls}}
  end

  defp process_stream_chunk(chunk, acc, callback) do
    chunk
    |> String.split("\n")
    |> Enum.reduce(acc, fn line, acc ->
      cond do
        String.starts_with?(line, "data: ") ->
          data = String.trim_leading(line, "data: ")

          case Jason.decode(data) do
            {:ok, event} ->
              parts = get_in(event, ["candidates", Access.at(0), "content", "parts"]) || []

              Enum.reduce(parts, acc, fn part, acc ->
                cond do
                  Map.has_key?(part, "text") ->
                    text = part["text"]
                    callback.(text)
                    %{acc | content: acc.content <> text}

                  Map.has_key?(part, "functionCall") ->
                    fc = part["functionCall"]

                    tc = %{
                      id:
                        "call_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}",
                      name: fc["name"],
                      arguments: fc["args"] || %{}
                    }

                    # Preserve thoughtSignature for Gemini 3+ models
                    tc =
                      if part["thoughtSignature"],
                        do: Map.put(tc, :thought_signature, part["thoughtSignature"]),
                        else: tc

                    %{acc | tool_calls: acc.tool_calls ++ [tc]}

                  true ->
                    acc
                end
              end)

            _ ->
              acc
          end

        true ->
          acc
      end
    end)
  end
end
