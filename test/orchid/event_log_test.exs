defmodule Orchid.EventLogTest do
  use ExUnit.Case, async: false

  alias Orchid.{EventLog, Goals, Object, Projects}
  alias Orchid.LLM.CLI

  @cli_env_vars [
    "ORCHID_TEST_MODE",
    "ORCHID_TEST_OUTPUT"
  ]

  setup do
    {:ok, _} = Application.ensure_all_started(:orchid)

    original_window = Application.get_env(:orchid, :event_log_window)
    EventLog.clear()

    on_exit(fn ->
      restore_env(:event_log_window, original_window)
      EventLog.clear()
    end)

    :ok
  end

  test "retains only the newest events inside the configured window" do
    Application.put_env(:orchid, :event_log_window, 3)
    EventLog.clear()

    Enum.each(1..4, fn idx ->
      EventLog.info(:test, "event #{idx}")
    end)

    assert EventLog.list_recent(source: :test, limit: 10)
           |> Enum.map(& &1.message) == ["event 4", "event 3", "event 2"]
  end

  test "records agent startup events" do
    EventLog.clear()

    assert {:ok, agent_id} =
             Orchid.Agent.create(%{
               execution_mode: :host,
               provider: :cli
             })

    on_exit(fn ->
      Orchid.Agent.stop(agent_id)
    end)

    assert_eventually(fn ->
      EventLog.list_recent(source: :agent, agent_id: agent_id, limit: 5)
      |> Enum.any?(fn event ->
        String.starts_with?(
          event.message,
          "Agent #{agent_id} started, project=nil, mode=host, provider=cli, model="
        )
      end)
    end)
  end

  test "records goal watcher reassignment events with project scoping" do
    {:ok, project} =
      Object.create(
        :project,
        "event-log-goal-watcher-#{System.unique_integer([:positive])}",
        "",
        metadata: %{status: :active}
      )

    {:ok, live_agent_id} =
      Orchid.Agent.create(%{
        project_id: project.id,
        execution_mode: :host,
        provider: :cli
      })

    {:ok, dead_agent_id} =
      Orchid.Agent.create(%{
        project_id: project.id,
        execution_mode: :host,
        provider: :cli
      })

    {:ok, goal} =
      Object.create(
        :goal,
        "Independent verify BEAM demo state",
        "",
        metadata: %{
          project_id: project.id,
          status: :pending,
          depends_on: [],
          parent_goal_id: nil,
          agent_id: dead_agent_id
        }
      )

    :ok = Orchid.Agent.stop(dead_agent_id)
    EventLog.clear()

    on_exit(fn ->
      Orchid.Agent.stop(live_agent_id)
      Goals.clear_project(project.id)
      Projects.delete(project.id)
    end)

    send(Orchid.GoalWatcher, :check)

    assert_eventually(fn ->
      lines =
        EventLog.list_recent(source: :goal_watcher, project_id: project.id, limit: 10)
        |> Enum.map(& &1.line)

      Enum.any?(lines, fn line ->
        String.contains?(
          line,
          "GoalWatcher: project \"#{project.name}\": 1 goal(s) assigned to dead agents"
        )
      end) and
        Enum.any?(lines, fn line ->
          String.contains?(
            line,
            "GoalWatcher:   cleared dead agent from goal \"#{goal.name}\" [#{goal.id}]"
          )
        end)
    end)

    assert {:ok, refreshed_goal} = Object.get(goal.id)
    assert refreshed_goal.metadata[:agent_id] == nil
  end

  test "records CLI command execution events" do
    dir = temp_path("orchid-fake-claude-")
    File.mkdir_p!(dir)

    script = Path.join(dir, "claude")
    File.write!(script, fake_claude_script())
    File.chmod!(script, 0o755)

    original_path = System.get_env("PATH") || ""
    original_env = Map.new(@cli_env_vars, fn key -> {key, System.get_env(key)} end)

    System.put_env("PATH", dir <> ":" <> original_path)
    System.put_env("ORCHID_TEST_MODE", "print")
    System.put_env("ORCHID_TEST_OUTPUT", "hello from fake claude")

    on_exit(fn ->
      restore_env("PATH", original_path)

      Enum.each(original_env, fn {key, value} ->
        restore_env(key, value)
      end)

      File.rm_rf!(dir)
    end)

    EventLog.clear()

    assert {:ok, %{content: "hello from fake claude", tool_calls: nil}} =
             CLI.chat(%{}, context("hello"))

    assert_eventually(fn ->
      EventLog.list_recent(source: :cli, limit: 5)
      |> Enum.any?(fn event ->
        String.starts_with?(event.message, "CLI exec (full): ")
      end)
    end)
  end

  defp context(message) do
    %{
      system: nil,
      messages: [%{role: :user, content: message}],
      objects: "",
      memory: %{}
    }
  end

  defp assert_eventually(fun, timeout_ms \\ 1_500, interval_ms \\ 50) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline_ms, interval_ms, timeout_ms)
  end

  defp do_assert_eventually(fun, deadline_ms, interval_ms, timeout_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("Condition was not met within #{timeout_ms}ms")
      else
        Process.sleep(interval_ms)
        do_assert_eventually(fun, deadline_ms, interval_ms, timeout_ms)
      end
    end
  end

  defp temp_path(prefix, suffix \\ "") do
    Path.join(
      System.tmp_dir!(),
      "#{prefix}#{System.unique_integer([:positive])}#{suffix}"
    )
  end

  defp restore_env(key, nil) when is_binary(key), do: System.delete_env(key)
  defp restore_env(key, value) when is_binary(key), do: System.put_env(key, value)

  defp restore_env(key, nil) when is_atom(key), do: Application.delete_env(:orchid, key)
  defp restore_env(key, value) when is_atom(key), do: Application.put_env(:orchid, key, value)

  defp fake_claude_script do
    """
    #!/bin/sh
    if [ "$ORCHID_TEST_MODE" = "print" ]; then
      printf "%s" "${ORCHID_TEST_OUTPUT:-ok}"
      exit 0
    fi

    exit 1
    """
  end
end
