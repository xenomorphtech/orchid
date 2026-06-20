defmodule Orchid.LLM.CodexHttp do
  @moduledoc """
  Lightweight HTTP provider for OpenAI GPT models via ChatGPT OAuth.

  Uses ~/.codex/auth.json credentials and the chatgpt.com Responses API
  directly, without the Node SDK bridge.
  """

  require Logger

  alias Orchid.LLM.Catalog

  @base_url "https://chatgpt.com/backend-api/codex"
  @refresh_url "https://auth.openai.com/oauth/token"
  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"

  @doc """
  Send a chat request and return the complete response.
  """
  def chat(config, context) do
    do_request(config, context, nil, false)
  end

  @doc """
  Stream a chat request, calling `callback` with each text delta.
  """
  def chat_stream(config, context, callback) do
    do_request(config, context, callback, false)
  end

  defp do_request(config, context, callback, retried?) do
    with {:ok, token} <- load_token() do
      body = build_body(config, context)

      case stream_request(token, body, callback) do
        {:ok, _} = ok ->
          ok

        {:error, :unauthorized} when not retried? ->
          Logger.info("[CodexHttp] 401, refreshing token...")

          case refresh_and_save() do
            {:ok, new_token} ->
              case stream_request(new_token, body, callback) do
                {:ok, _} = ok -> ok
                {:error, reason} -> {:error, reason}
              end

            {:error, reason} ->
              {:error, {:refresh_failed, reason}}
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp stream_request(token, body, callback) do
    url = "#{@base_url}/responses"

    headers = [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]

    {:ok, acc_pid} = Agent.start_link(fn -> "" end)

    result =
      Req.post(url,
        json: body,
        headers: headers,
        receive_timeout: 300_000,
        into: fn {:data, chunk}, {req, resp} ->
          Agent.update(acc_pid, fn text ->
            process_sse_chunk(chunk, text, callback)
          end)

          {:cont, {req, resp}}
        end
      )

    final_text = Agent.get(acc_pid, & &1)
    Agent.stop(acc_pid)

    case result do
      {:ok, %{status: 200}} ->
        if String.trim(final_text) == "" do
          {:error, "CodexHttp returned empty response"}
        else
          {:ok, %{content: final_text, tool_calls: nil}}
        end

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("[CodexHttp] API error #{status}: #{inspect(resp_body)}")
        {:error, {:api_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # SSE parsing

  defp process_sse_chunk(chunk, text, callback) do
    chunk
    |> String.split("\n")
    |> Enum.reduce(text, fn line, text ->
      if String.starts_with?(line, "data: ") do
        data = String.trim_leading(line, "data: ")

        if data == "[DONE]" do
          text
        else
          case Jason.decode(data) do
            {:ok, event} -> handle_event(event, text, callback)
            _ -> text
          end
        end
      else
        text
      end
    end)
  end

  defp handle_event(event, text, callback) do
    case event["type"] do
      "response.output_text.delta" ->
        delta = event["delta"] || ""
        if callback, do: callback.(delta)
        text <> delta

      "response.completed" ->
        if String.trim(text) == "" do
          extract_completed_text(event["response"])
        else
          text
        end

      _ ->
        text
    end
  end

  defp extract_completed_text(nil), do: ""

  defp extract_completed_text(response) do
    (response["output"] || [])
    |> Enum.flat_map(fn item ->
      if item["type"] == "message" do
        (item["content"] || [])
        |> Enum.filter(&(&1["type"] == "output_text"))
        |> Enum.map(&(&1["text"] || ""))
      else
        []
      end
    end)
    |> Enum.join("")
  end

  # Request body

  defp build_body(config, context) do
    model = Catalog.resolve_model(config[:model], :codex_http)
    input = format_messages(context.messages)

    %{model: model, input: input, store: false, stream: true}
    |> maybe_put_instructions(context[:system])
  end

  defp maybe_put_instructions(body, nil), do: body
  defp maybe_put_instructions(body, ""), do: body
  defp maybe_put_instructions(body, system), do: Map.put(body, :instructions, system)

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      case msg.role do
        :user ->
          %{role: "user", content: [%{type: "input_text", text: msg.content}]}

        :assistant ->
          %{role: "assistant", content: [%{type: "output_text", text: msg.content || ""}]}

        :tool ->
          %{
            role: "user",
            content: [%{type: "input_text", text: "[Tool Result] #{inspect(msg.content)}"}]
          }
      end
    end)
  end

  # Auth helpers

  defp auth_path do
    System.get_env("CODEX_AUTH_FILE") || Path.expand("~/.codex/auth.json")
  end

  defp load_token do
    case File.read(auth_path()) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"tokens" => %{"access_token" => token}}} when is_binary(token) ->
            {:ok, token}

          {:ok, _} ->
            {:error, :invalid_auth_format}

          {:error, reason} ->
            {:error, {:json_parse_error, reason}}
        end

      {:error, reason} ->
        {:error, {:auth_file_error, reason}}
    end
  end

  defp refresh_and_save do
    path = auth_path()

    with {:ok, content} <- File.read(path),
         {:ok, auth} <- Jason.decode(content),
         %{"tokens" => %{"refresh_token" => refresh_token}} <- auth do
      case do_refresh(refresh_token) do
        {:ok, new_data} ->
          updated =
            auth
            |> put_in(["tokens", "access_token"], new_data["access_token"])
            |> maybe_put_token(new_data, "refresh_token")
            |> maybe_put_token(new_data, "id_token")

          case File.write(path, Jason.encode!(updated, pretty: true)) do
            :ok ->
              Logger.info("[CodexHttp] Tokens refreshed and saved")

            {:error, reason} ->
              Logger.error("[CodexHttp] Failed to save tokens: #{inspect(reason)}")
          end

          {:ok, new_data["access_token"]}

        {:error, _} = error ->
          error
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_auth_format}
    end
  end

  defp maybe_put_token(auth, data, key) do
    if data[key], do: put_in(auth, ["tokens", key], data[key]), else: auth
  end

  defp do_refresh(refresh_token) do
    case Req.post(@refresh_url,
           json: %{
             client_id: @client_id,
             grant_type: "refresh_token",
             refresh_token: refresh_token
           }
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[CodexHttp] Token refresh failed: #{status}")
        {:error, {:refresh_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end
end
