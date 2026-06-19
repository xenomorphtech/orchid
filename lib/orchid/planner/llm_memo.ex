defmodule Orchid.Planner.LLMMemo do
  @moduledoc false

  use GenServer

  @table :orchid_planner_llm_memo

  def fetch(key_parts, opts, cacheable?, fun)
      when is_function(cacheable?, 1) and is_function(fun, 0) do
    if enabled?(opts) do
      ensure_started()
      key = cache_key(key_parts)

      case :ets.lookup(@table, key) do
        [{^key, result}] ->
          result

        [] ->
          result = fun.()

          if cacheable?.(result) do
            :ets.insert(@table, {key, result})
          end

          result
      end
    else
      fun.()
    end
  end

  def clear do
    ensure_started()
    GenServer.call(__MODULE__, :clear)
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      _info ->
        :ok
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  defp enabled?(opts) do
    case opts |> normalize_opts() |> Map.get(:llm_memoize, true) do
      false -> false
      "false" -> false
      0 -> false
      _ -> true
    end
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp cache_key(key_parts) do
    :crypto.hash(:sha256, :erlang.term_to_binary(key_parts))
  end

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(_opts), do: %{}
end
