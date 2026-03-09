defmodule Orchid.GoalWatcherTest do
  use ExUnit.Case

  setup do
    {:ok, _} = Application.ensure_all_started(:orchid)

    {:ok, project} =
      Orchid.Object.create(
        :project,
        "goal-watcher-test-#{System.unique_integer([:positive])}",
        "",
        metadata: %{status: :active}
      )

    on_exit(fn ->
      Orchid.Goals.clear_project(project.id)
      Orchid.Projects.delete(project.id)
    end)

    %{project: project}
  end

  test "does not re-kick idle agents when their assigned goals are blocked", %{project: project} do
    {:ok, agent_id} =
      Orchid.Agent.create(%{
        project_id: project.id,
        execution_mode: :host,
        provider: :codex,
        use_orchid_tools: true
      })

    {:ok, _goal} =
      Orchid.Object.create(
        :goal,
        "blocked task",
        "Investigate a platform blocker.",
        metadata: %{
          project_id: project.id,
          status: :pending,
          depends_on: [],
          parent_goal_id: nil,
          agent_id: agent_id,
          task_outcome: "blocked",
          last_error: "agent_spawn timed out"
        }
      )

    send(Orchid.GoalWatcher, :check)
    Process.sleep(200)

    {:ok, state} = Orchid.Agent.get_state(agent_id)
    assert state.status == :idle
    assert state.messages == []
  end

  test "does not spawn a planner while a project is clearing goals", %{project: project} do
    {:ok, dead_agent_id} =
      Orchid.Agent.create(%{
        project_id: project.id,
        execution_mode: :host,
        provider: :codex,
        use_orchid_tools: true
      })

    {:ok, goal} =
      Orchid.Object.create(
        :goal,
        "stale task",
        "Should be deleted by the clear operation.",
        metadata: %{
          project_id: project.id,
          status: :pending,
          depends_on: [],
          parent_goal_id: nil,
          agent_id: dead_agent_id
        }
      )

    :ok = Orchid.Agent.stop(dead_agent_id)
    {:ok, _project} = Orchid.Object.update_metadata(project.id, %{clearing_goals: true})

    send(Orchid.GoalWatcher, :check)
    Process.sleep(200)

    {:ok, refreshed_goal} = Orchid.Object.get(goal.id)
    assert refreshed_goal.metadata[:agent_id] == dead_agent_id
    assert project_agent_ids(project.id) == []
  end

  test "planner kickoff message includes the saved project brief" do
    message =
      Orchid.GoalWatcher.planner_kickoff_message(
        "Packet Decoder",
        """
        # Packet Decoder

        ## Objective
        Decode the login packets.
        """,
        "- Decode login packet [goal_123]"
      )

    assert message =~ "Project: Packet Decoder"
    assert message =~ "Saved project brief:"
    assert message =~ "# Packet Decoder"
    assert message =~ "Current objectives:\n- Decode login packet [goal_123]"

    {brief_pos, _} = :binary.match(message, "Saved project brief:")
    {goals_pos, _} = :binary.match(message, "Current objectives:")
    assert brief_pos < goals_pos
  end

  defp project_agent_ids(project_id) do
    Orchid.Agent.list()
    |> Enum.filter(fn agent_id ->
      case Orchid.Agent.get_state(agent_id) do
        {:ok, state} -> state.project_id == project_id
        _ -> false
      end
    end)
  end
end
