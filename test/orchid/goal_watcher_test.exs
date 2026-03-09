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
end
