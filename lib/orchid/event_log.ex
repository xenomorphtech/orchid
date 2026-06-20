defmodule Orchid.EventLog do
  @moduledoc """
  ETS-backed in-memory event log with a fixed-size circular buffer.
  """

  @default_window 100_000
  @events_table :orchid_event_log
  @meta_table :orchid_event_log_meta
  @topic "event_log"

  def setup! do
    ensure_table(@events_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    ensure_table(@meta_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.insert_new(@meta_table, {:seq, 0})
    :ok
  end

  def window do
    case Application.get_env(:orchid, :event_log_window, @default_window) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_window
    end
  end

  def info(source, message, opts \\ []) when is_binary(message) and is_list(opts) do
    setup!()

    record(%{
      level: :info,
      source: source,
      message: message,
      project_id: Keyword.get(opts, :project_id),
      agent_id: Keyword.get(opts, :agent_id),
      metadata: normalize_metadata(Keyword.get(opts, :metadata, %{}))
    })
  end

  def record(event) when is_map(event) do
    setup!()
    seq = :ets.update_counter(@meta_table, :seq, {2, 1}, {:seq, 0})
    slot = slot_for(seq)
    normalized = normalize_event(event, seq)

    :ets.insert(@events_table, {slot, seq, normalized})
    broadcast(normalized)
    normalized
  end

  def list_recent(opts \\ []) when is_list(opts) do
    setup!()

    limit =
      case Keyword.get(opts, :limit, 40) do
        value when is_integer(value) and value >= 0 -> value
        _ -> 40
      end

    filters = %{
      project_id: Keyword.get(opts, :project_id),
      agent_id: Keyword.get(opts, :agent_id),
      source: normalize_optional_source(Keyword.get(opts, :source))
    }

    current_seq = current_seq()
    oldest_seq = max(current_seq - window() + 1, 1)

    do_list_recent(current_seq, oldest_seq, limit, filters, [])
    |> Enum.reverse()
  end

  def clear do
    setup!()
    :ets.delete_all_objects(@events_table)
    :ets.insert(@meta_table, {:seq, 0})
    :ok
  end

  defp do_list_recent(_seq, _oldest_seq, 0, _filters, acc), do: acc
  defp do_list_recent(seq, oldest_seq, _remaining, _filters, acc) when seq < oldest_seq, do: acc

  defp do_list_recent(seq, oldest_seq, remaining, filters, acc) do
    {acc, remaining} =
      case :ets.lookup(@events_table, slot_for(seq)) do
        [{_slot, ^seq, event}] ->
          if matches_filters?(event, filters) do
            {[event | acc], remaining - 1}
          else
            {acc, remaining}
          end

        _ ->
          {acc, remaining}
      end

    do_list_recent(seq - 1, oldest_seq, remaining, filters, acc)
  end

  defp normalize_event(event, seq) do
    level = normalize_level(Map.get(event, :level, :info))
    source = normalize_source(Map.get(event, :source, :unknown))
    message = normalize_message(Map.get(event, :message))

    %{
      seq: seq,
      inserted_at: Map.get(event, :inserted_at, DateTime.utc_now()),
      level: level,
      source: source,
      message: message,
      line: format_line(level, message),
      project_id: Map.get(event, :project_id),
      agent_id: Map.get(event, :agent_id),
      metadata: normalize_metadata(Map.get(event, :metadata, %{}))
    }
  end

  defp normalize_message(message) when is_binary(message), do: message
  defp normalize_message(message), do: inspect(message)

  defp normalize_level(level) when is_atom(level), do: level

  defp normalize_level(level) when is_binary(level) do
    case String.downcase(level) do
      "debug" -> :debug
      "info" -> :info
      "warning" -> :warning
      "warn" -> :warning
      "error" -> :error
      _ -> :info
    end
  end

  defp normalize_level(_level), do: :info

  defp normalize_source(source) when is_atom(source), do: Atom.to_string(source)
  defp normalize_source(source) when is_binary(source), do: source
  defp normalize_source(_source), do: "unknown"

  defp normalize_optional_source(nil), do: nil
  defp normalize_optional_source(source), do: normalize_source(source)

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(metadata) when is_list(metadata), do: Map.new(metadata)
  defp normalize_metadata(_metadata), do: %{}

  defp format_line(level, message), do: "[#{level}] #{message}"

  defp slot_for(seq), do: rem(seq - 1, window())

  defp current_seq do
    case :ets.lookup(@meta_table, :seq) do
      [{:seq, seq}] when is_integer(seq) and seq >= 0 -> seq
      _ -> 0
    end
  end

  defp matches_filters?(event, filters) do
    matches_project?(event, filters.project_id) and
      matches_agent?(event, filters.agent_id) and
      matches_source?(event, filters.source)
  end

  defp matches_project?(_event, nil), do: true
  defp matches_project?(event, project_id), do: event.project_id == project_id

  defp matches_agent?(_event, nil), do: true
  defp matches_agent?(event, agent_id), do: event.agent_id == agent_id

  defp matches_source?(_event, nil), do: true
  defp matches_source?(event, source), do: event.source == source

  defp broadcast(event) do
    if Process.whereis(Orchid.PubSub) do
      Phoenix.PubSub.broadcast(Orchid.PubSub, @topic, {:event_log, event})
    else
      :ok
    end
  end

  defp ensure_table(name, options) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, options)
      _tid -> name
    end
  end
end
