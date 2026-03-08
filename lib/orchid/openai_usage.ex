defmodule Orchid.OpenAIUsage do
  @moduledoc """
  Tracks OpenAI ChatGPT subscription usage for Codex-authenticated sessions.

  Reads Codex auth from `CODEX_HOME/auth.json`, polls the ChatGPT usage endpoint,
  and publishes updates over PubSub for LiveView surfaces.
  """
  use GenServer
  require Logger

  @topic "openai_usage"
  @refresh_interval_ms 60_000
  @default_base_url "https://chatgpt.com/backend-api"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def subscribe do
    Phoenix.PubSub.subscribe(Orchid.PubSub, @topic)
  end

  def get do
    GenServer.call(__MODULE__, :get)
  end

  def refresh do
    GenServer.call(__MODULE__, :refresh, 20_000)
  end

  def refresh_async do
    GenServer.cast(__MODULE__, :refresh)
  end

  @doc false
  def normalize_base_url(base_url) when is_binary(base_url) do
    base_url =
      base_url
      |> String.trim()
      |> String.trim_trailing("/")

    cond do
      base_url == "" ->
        @default_base_url

      (String.starts_with?(base_url, "https://chatgpt.com") or
         String.starts_with?(base_url, "https://chat.openai.com")) and
          not String.contains?(base_url, "/backend-api") ->
        base_url <> "/backend-api"

      true ->
        base_url
    end
  end

  @doc false
  def parse_id_token(jwt) when is_binary(jwt) and jwt != "" do
    with [_header, payload, _sig] <- String.split(jwt, ".", parts: 3),
         {:ok, payload_json} <- decode_jwt_segment(payload),
         {:ok, claims} <- Jason.decode(payload_json) do
      auth_claims = Map.get(claims, "https://api.openai.com/auth", %{})
      profile_claims = Map.get(claims, "https://api.openai.com/profile", %{})

      %{
        email: claims["email"] || profile_claims["email"],
        plan_type: normalize_plan_type(auth_claims["chatgpt_plan_type"]),
        raw_plan_type: auth_claims["chatgpt_plan_type"],
        user_id: auth_claims["chatgpt_user_id"] || auth_claims["user_id"],
        account_id: auth_claims["chatgpt_account_id"]
      }
    else
      _ -> %{}
    end
  end

  def parse_id_token(_), do: %{}

  @doc false
  def snapshot_from_payload(payload, auth_info) when is_map(payload) and is_map(auth_info) do
    payload_plan = normalize_plan_type(payload["plan_type"]) || auth_info[:plan_type]
    credits = parse_credits(payload["credits"])

    limits =
      [
        build_limit_snapshot(
          "codex",
          nil,
          payload["rate_limit"],
          credits,
          payload_plan
        )
      ] ++
        Enum.map(List.wrap(payload["additional_rate_limits"]), fn item ->
          build_limit_snapshot(
            item["metered_feature"] || "unknown",
            item["limit_name"],
            item["rate_limit"],
            nil,
            payload_plan
          )
        end)

    now = DateTime.utc_now()

    %{
      fetched_at: now,
      source_url: usage_url(auth_info),
      account: %{
        email: auth_info[:email],
        account_id: auth_info[:account_id],
        plan_type: payload_plan || auth_info[:plan_type],
        raw_plan_type: auth_info[:raw_plan_type],
        user_id: auth_info[:user_id]
      },
      credits: credits,
      limits: limits,
      primary_limit: Enum.find(limits, &(&1.limit_id == "codex")) || List.first(limits)
    }
  end

  @impl true
  def init(_opts) do
    state = %{
      loading: true,
      snapshot: nil,
      last_checked_at: nil,
      last_error: nil,
      auth_file: auth_file_path(),
      timer_ref: nil
    }

    send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:refresh, _from, state) do
    new_state = refresh_state(state)
    {:reply, new_state, schedule_refresh(new_state)}
  end

  @impl true
  def handle_cast(:refresh, state) do
    new_state = refresh_state(state)
    {:noreply, schedule_refresh(new_state)}
  end

  @impl true
  def handle_info(:refresh, state) do
    new_state = refresh_state(state)
    {:noreply, schedule_refresh(new_state)}
  end

  defp schedule_refresh(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: Process.send_after(self(), :refresh, @refresh_interval_ms)}
  end

  defp refresh_state(state) do
    auth_file = auth_file_path()

    new_state =
      case load_auth_info(auth_file) do
        {:ok, auth_info} ->
          case fetch_usage_payload(auth_info) do
            {:ok, payload} ->
              snapshot = snapshot_from_payload(payload, auth_info)

              %{
                state
                | loading: false,
                  snapshot: snapshot,
                  last_checked_at: snapshot.fetched_at,
                  last_error: nil,
                  auth_file: auth_file
              }

            {:error, reason} ->
              %{
                state
                | loading: false,
                  last_checked_at: DateTime.utc_now(),
                  last_error: format_error(reason),
                  auth_file: auth_file
              }
          end

        {:error, reason} ->
          %{
            state
            | loading: false,
              snapshot: nil,
              last_checked_at: DateTime.utc_now(),
              last_error: format_error(reason),
              auth_file: auth_file
          }
      end

    Phoenix.PubSub.broadcast(Orchid.PubSub, @topic, {:openai_usage_updated, new_state})
    new_state
  end

  defp load_auth_info(auth_file) do
    with true <- File.exists?(auth_file) or {:error, :missing_auth_file},
         {:ok, raw} <- File.read(auth_file),
         {:ok, auth_json} <- Jason.decode(raw) do
      auth_mode = auth_json["auth_mode"]
      tokens = auth_json["tokens"] || %{}
      access_token = tokens["access_token"]

      cond do
        auth_mode != "chatgpt" ->
          {:error, {:unsupported_auth_mode, auth_mode}}

        not is_binary(access_token) or access_token == "" ->
          {:error, :missing_access_token}

        true ->
          id_token_info = parse_id_token(tokens["id_token"])

          {:ok,
           %{
             access_token: access_token,
             account_id: tokens["account_id"] || id_token_info[:account_id],
             email: id_token_info[:email],
             plan_type: id_token_info[:plan_type],
             raw_plan_type: id_token_info[:raw_plan_type],
             user_id: id_token_info[:user_id],
             base_url: read_base_url(auth_file)
           }}
      end
    else
      {:error, reason} -> {:error, {:auth_read_failed, reason}}
      false -> {:error, :missing_auth_file}
      _ -> {:error, :invalid_auth_file}
    end
  end

  defp fetch_usage_payload(auth_info) do
    headers =
      [
        {"authorization", "Bearer #{auth_info.access_token}"},
        {"user-agent", "orchid"},
        {"accept", "application/json"}
      ] ++
        if is_binary(auth_info.account_id) and auth_info.account_id != "" do
          [{"ChatGPT-Account-Id", auth_info.account_id}]
        else
          []
        end

    case Req.get(url: usage_url(auth_info), headers: headers, receive_timeout: 15_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        decode_payload(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body_to_string(body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp decode_payload(body) when is_map(body), do: {:ok, body}

  defp decode_payload(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _} -> {:error, :unexpected_payload}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp decode_payload(_), do: {:error, :unexpected_payload}

  defp build_limit_snapshot(limit_id, limit_name, rate_limit, credits, plan_type) do
    rate_limit = unwrap_nullable(rate_limit)

    %{
      limit_id: normalize_limit_id(limit_id),
      limit_name: blank_to_nil(limit_name),
      primary: parse_window(rate_limit && rate_limit["primary_window"]),
      secondary: parse_window(rate_limit && rate_limit["secondary_window"]),
      credits: credits,
      plan_type: plan_type
    }
  end

  defp parse_window(nil), do: nil

  defp parse_window(window) do
    window = unwrap_nullable(window)

    if is_map(window) do
      %{
        used_percent: to_float(window["used_percent"]),
        window_minutes: seconds_to_minutes(window["limit_window_seconds"]),
        resets_at: unix_to_datetime(window["reset_at"])
      }
    end
  end

  defp parse_credits(nil), do: nil

  defp parse_credits(credits) do
    credits = unwrap_nullable(credits)

    if is_map(credits) do
      %{
        has_credits: truthy?(credits["has_credits"]),
        unlimited: truthy?(credits["unlimited"]),
        balance: blank_to_nil(unwrap_nullable(credits["balance"]))
      }
    end
  end

  defp truthy?(value) when value in [true, 1, "1", "true", "TRUE"], do: true
  defp truthy?(_), do: false

  defp unwrap_nullable(nil), do: nil
  defp unwrap_nullable(value), do: value

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value / 1

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp to_float(_), do: nil

  defp seconds_to_minutes(value) when is_integer(value) and value > 0 do
    div(value + 59, 60)
  end

  defp seconds_to_minutes(_), do: nil

  defp unix_to_datetime(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp unix_to_datetime(_), do: nil

  defp usage_url(auth_info) do
    auth_info.base_url
    |> normalize_base_url()
    |> Kernel.<>("/wham/usage")
  end

  defp read_base_url(auth_file) do
    env_base =
      System.get_env("CHATGPT_BASE_URL") ||
        System.get_env("OPENAI_CHATGPT_BASE_URL") ||
        System.get_env("CODEX_CHATGPT_BASE_URL")

    cond do
      is_binary(env_base) and String.trim(env_base) != "" ->
        normalize_base_url(env_base)

      true ->
        auth_file
        |> Path.dirname()
        |> Path.join("config.toml")
        |> read_base_url_from_config()
        |> normalize_base_url()
    end
  end

  defp read_base_url_from_config(config_path) do
    if File.exists?(config_path) do
      case File.read(config_path) do
        {:ok, content} ->
          case Regex.run(~r/chatgpt_base_url\s*=\s*"([^"]+)"/, content) do
            [_, base_url] -> base_url
            _ -> @default_base_url
          end

        {:error, _reason} ->
          @default_base_url
      end
    else
      @default_base_url
    end
  end

  defp auth_file_path do
    Path.join(System.get_env("CODEX_HOME") || Path.expand("~/.codex"), "auth.json")
  end

  defp decode_jwt_segment(segment) do
    padded =
      case rem(byte_size(segment), 4) do
        0 -> segment
        rem_size -> segment <> String.duplicate("=", 4 - rem_size)
      end

    Base.url_decode64(padded)
  end

  defp normalize_plan_type(value) when is_binary(value) do
    case String.downcase(value) do
      "free" -> "Free"
      "go" -> "Go"
      "plus" -> "Plus"
      "pro" -> "Pro"
      "team" -> "Team"
      "business" -> "Business"
      "enterprise" -> "Enterprise"
      "education" -> "Edu"
      "edu" -> "Edu"
      other -> other
    end
  end

  defp normalize_plan_type(_), do: nil

  defp normalize_limit_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp normalize_limit_id(_), do: "codex"

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(value), do: value

  defp body_to_string(body) when is_binary(body), do: body
  defp body_to_string(body) when is_map(body), do: Jason.encode!(body)
  defp body_to_string(body), do: inspect(body)

  defp format_error(:missing_auth_file), do: "Codex auth.json was not found."
  defp format_error(:missing_access_token), do: "Codex auth.json is missing ChatGPT access tokens."
  defp format_error(:invalid_auth_file), do: "Codex auth.json could not be parsed."
  defp format_error(:unexpected_payload), do: "Usage endpoint returned an unexpected payload."
  defp format_error({:unsupported_auth_mode, mode}), do: "Codex auth mode is not ChatGPT: #{inspect(mode)}."

  defp format_error({:auth_read_failed, reason}),
    do: "Failed to read Codex auth.json: #{inspect(reason)}."

  defp format_error({:request_failed, reason}),
    do: "Usage request failed: #{inspect(reason)}."

  defp format_error({:invalid_json, reason}),
    do: "Usage response JSON was invalid: #{inspect(reason)}."

  defp format_error({:http_error, status, body}) do
    preview = body |> String.slice(0, 240) |> String.replace("\n", " ")
    "Usage endpoint returned HTTP #{status}: #{preview}"
  end

  defp format_error(other), do: inspect(other)
end
