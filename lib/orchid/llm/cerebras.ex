defmodule Orchid.LLM.Cerebras do
  @moduledoc """
  Cerebras API client (OpenAI-compatible).
  Handles chat completion with streaming support.
  """
  require Logger
  alias Orchid.LLM.Catalog

  @base_url "https://api.cerebras.ai/v1/chat/completions"

  @doc """
  Send a chat request to Cerebras.
  """
  def chat(config, context) do
    api_key = config[:api_key] || Orchid.Object.get_fact_value("cerebras_api_key")

    if is_nil(api_key) do
      {:error,
       {:api_key_missing,
        "cerebras_api_key fact not set. Add it in Settings > Facts or local facts file."}}
    else
      model = Catalog.resolve_model(config[:model], :cerebras)
      body = build_request_body(config, context, model)

      IO.puts("[Cerebras] chat request to model=#{model}")
      IO.puts("[Cerebras] messages count=#{length(context.messages)}")

      case Req.post(@base_url,
             json: body,
             headers: headers(api_key),
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200, body: response}} ->
          IO.puts("[Cerebras] chat response OK (200)")
          parse_response(response)

        {:ok, %{status: status, body: body}} ->
          IO.puts("[Cerebras] chat error status=#{status}")
          Logger.error("Cerebras API error: #{status} - #{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          IO.puts("[Cerebras] chat request failed: #{inspect(reason)}")
          Logger.error("Cerebras request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Send a streaming chat request to Cerebras.
  """
  def chat_stream(config, context, callback) do
    api_key = config[:api_key] || Orchid.Object.get_fact_value("cerebras_api_key")

    if is_nil(api_key) do
      {:error,
       {:api_key_missing,
        "cerebras_api_key fact not set. Add it in Settings > Facts or local facts file."}}
    else
      model = Catalog.resolve_model(config[:model], :cerebras)
      body = build_request_body(config, context, model) |> Map.put(:stream, true)

      IO.puts("[Cerebras] chat_stream request to model=#{model}")
      IO.puts("[Cerebras] messages count=#{length(context.messages)}")

      acc = %{content: ""}

      stream_fun = fn {:data, chunk}, {req, resp} ->
        acc = Process.get(:cerebras_acc, acc)
        new_acc = process_stream_chunk(chunk, acc, callback)
        Process.put(:cerebras_acc, new_acc)
        {:cont, {req, resp}}
      end

      case Req.post(@base_url,
             json: body,
             headers: headers(api_key),
             receive_timeout: 120_000,
             into: stream_fun
           ) do
        {:ok, %{status: 200}} ->
          final_acc = Process.get(:cerebras_acc, acc)
          Process.delete(:cerebras_acc)
          IO.puts("[Cerebras] stream complete, total length=#{String.length(final_acc.content)}")
          {:ok, %{content: final_acc.content, tool_calls: nil}}

        {:ok, %{status: status, body: body}} ->
          Process.delete(:cerebras_acc)
          IO.puts("[Cerebras] stream error status=#{status}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Process.delete(:cerebras_acc)
          IO.puts("[Cerebras] stream request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # Private functions

  defp headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]
  end

  defp build_request_body(config, context, model) do
    messages = format_messages(context)

    %{
      model: model,
      messages: messages,
      max_completion_tokens: Map.get(config, :max_tokens, 8192)
    }
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
      |> Enum.filter(fn msg -> msg.role in [:user, :assistant] end)
      |> Enum.map(fn msg ->
        role =
          case msg.role do
            :user -> "user"
            :assistant -> "assistant"
          end

        %{role: role, content: msg.content || ""}
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
    text =
      case get_in(response, ["choices", Access.at(0), "message", "content"]) do
        nil -> ""
        text -> text
      end

    {:ok, %{content: text, tool_calls: nil}}
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
              case get_in(event, ["choices", Access.at(0), "delta", "content"]) do
                nil ->
                  acc

                text ->
                  callback.(text)
                  %{acc | content: acc.content <> text}
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
