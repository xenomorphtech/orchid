defmodule Orchid.Autonomy.Runtime do
  @moduledoc """
  Minimal Orchid runtime for autonomy benchmark runs.

  The normal OTP application starts the Phoenix endpoint, which requires local
  SSL files that are not present in development worktrees. The autonomy suite
  only needs storage, registry, and dynamic supervision, so this module starts
  that subset directly.
  """

  @doc """
  Start the runtime services required by `Orchid.Autonomy.Runner`.
  """
  @spec ensure_started(keyword()) :: :ok | {:error, term()}
  def ensure_started(opts \\ []) when is_list(opts) do
    with :ok <- ensure_dependency(:jason),
         :ok <- ensure_dependency(:cubdb),
         :ok <- ensure_dependency(:req),
         :ok <- ensure_agent_tables(),
         :ok <- ensure_store(),
         :ok <- ensure_registry(),
         :ok <- ensure_agent_supervisor() do
      seed_facts(opts)
    end
  end

  defp ensure_dependency(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, {:dependency_start_failed, app, reason}}
    end
  end

  defp ensure_agent_tables do
    with :ok <-
           ensure_table(:orchid_agent_states, [
             :named_table,
             :public,
             :set,
             read_concurrency: true
           ]) do
      ensure_table(:orchid_agent_runtime, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end
  end

  defp ensure_table(name, opts) do
    case :ets.info(name) do
      :undefined ->
        try do
          _tid = :ets.new(name, opts)
          :ok
        rescue
          ArgumentError -> :ok
        end

      _info ->
        :ok
    end
  end

  defp ensure_store do
    ensure_process(Orchid.Store, fn -> Orchid.Store.start_link() end)
  end

  defp ensure_registry do
    ensure_process(Orchid.Registry, fn ->
      Registry.start_link(keys: :unique, name: Orchid.Registry)
    end)
  end

  defp ensure_agent_supervisor do
    ensure_process(Orchid.AgentSupervisor, fn ->
      DynamicSupervisor.start_link(strategy: :one_for_one, name: Orchid.AgentSupervisor)
    end)
  end

  defp ensure_process(name, start_fun) when is_atom(name) and is_function(start_fun, 0) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case start_fun.() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, {:process_start_failed, name, reason}}
        end
    end
  end

  defp seed_facts(opts) do
    if Keyword.get(opts, :seed_facts, true) do
      case Orchid.Facts.seed_from_local_file() do
        {:ok, _stats} -> :ok
        other -> {:error, {:facts_seed_failed, other}}
      end
    else
      :ok
    end
  end
end
