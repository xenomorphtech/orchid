defmodule Orchid.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # ETS table for lock-free agent state reads (public so Tasks can write)
    :ets.new(:orchid_agent_states, [:named_table, :public, :set, read_concurrency: true])
    # Runtime control table for agent lifecycle and in-flight worker tracking
    :ets.new(:orchid_agent_runtime, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Fixed-size in-memory event log for planner/agent/CLI lifecycle traces
    Orchid.EventLog.setup!()

    children = [
      # ETS-backed storage for objects and agent state
      Orchid.Store,
      # Registry for looking up agents by ID
      {Registry, keys: :unique, name: Orchid.Registry},
      # Reclaim crashed/killed Podman sandboxes before new work starts
      Orchid.Autonomy.SandboxReaper,
      # DynamicSupervisor for agent processes
      {DynamicSupervisor, strategy: :one_for_one, name: Orchid.AgentSupervisor},
      # Serialized completion-review queue to avoid reviewer call floods
      Orchid.GoalReviewQueue,
      # MCP call event stream for GUI attribution
      Orchid.McpEvents,
      # PubSub for Phoenix
      {Phoenix.PubSub, name: Orchid.PubSub},
      # Phoenix endpoint
      OrchidWeb.Endpoint,
      # Auto-spawn agents for projects with unattended goals
      Orchid.GoalWatcher
    ]

    opts = [strategy: :one_for_one, name: Orchid.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      Orchid.Seeds.seed_templates()
      log_facts_seed_result(Orchid.Facts.seed_from_local_file())
      {:ok, pid}
    end
  end

  defp log_facts_seed_result({:ok, %{missing: true, path: path}}) do
    Logger.info("Local facts file not found at #{path}; skipping facts seed")
  end

  defp log_facts_seed_result({:ok, %{path: path} = result}) do
    Logger.info(
      "Seeded local facts from #{path}: created=#{result.created} updated=#{result.updated} skipped=#{result.skipped}"
    )
  end

  defp log_facts_seed_result(other) do
    Logger.warning("Facts seed returned unexpected result: #{inspect(other)}")
  end
end
