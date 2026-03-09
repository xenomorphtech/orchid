defmodule Orchid.Goals do
  @moduledoc """
  Context module for goal business logic.
  All goal operations go through here — no LiveView awareness.
  """

  alias Orchid.Object

  @doc "List goals for a project."
  def list_for_project(project_id) do
    Object.list_goals_for_project(project_id)
  end

  @doc "Create a goal in a project."
  def create(name, description, project_id, opts \\ []) do
    metadata = %{
      project_id: project_id,
      status: :pending,
      depends_on: [],
      parent_goal_id: opts[:parent_goal_id]
    }

    Object.create(:goal, name, description, metadata: metadata)
  end

  @doc "Delete a goal and clean up references from other goals' depends_on lists."
  def delete(goal_id) do
    # Find the goal to get its project_id for the cleanup query
    case Object.get(goal_id) do
      {:ok, goal} ->
        project_id = goal.metadata[:project_id]

        # Remove this goal from any depends_on lists in the same project
        if project_id do
          for other <- list_for_project(project_id) do
            depends_on = other.metadata[:depends_on] || []

            if goal_id in depends_on do
              Object.update_metadata(other.id, %{depends_on: List.delete(depends_on, goal_id)})
            end
          end
        end

        Object.delete(goal_id)

      _ ->
        Object.delete(goal_id)
    end
  end

  @doc "Delete all goals for a project."
  def clear_project(project_id) do
    mark_project_clearing(project_id, true)

    try do
      stop_project_agents(project_id)

      for goal <- list_for_project(project_id) do
        Object.delete(goal.id)
      end

      :ok
    after
      mark_project_clearing(project_id, false)
    end
  end

  @doc "Toggle a goal between :pending and :completed."
  def toggle_status(goal_id) do
    case Object.get(goal_id) do
      {:ok, goal} ->
        new_status =
          case goal.metadata[:status] do
            :completed -> :pending
            _ -> :completed
          end

        Object.update_metadata(goal_id, %{status: new_status})

      error ->
        error
    end
  end

  @doc "Set a goal's status explicitly."
  def set_status(goal_id, status) when is_atom(status) do
    result = Object.update_metadata(goal_id, %{status: status})
    if status == :completed, do: notify_orchestrator(goal_id)
    result
  end

  @doc "True when a goal status is terminal (no further work should be scheduled)."
  def terminal_status?(status), do: status in [:completed, :superseded]

  @doc "True when a goal status is open (eligible for scheduling/work)."
  def open_status?(status), do: not terminal_status?(status)

  @doc "Add a dependency to a goal."
  def add_dependency(goal_id, depends_on_id) do
    case Object.get(goal_id) do
      {:ok, goal} ->
        current_deps = goal.metadata[:depends_on] || []

        if depends_on_id not in current_deps do
          Object.update_metadata(goal_id, %{depends_on: [depends_on_id | current_deps]})
        else
          {:ok, goal}
        end

      error ->
        error
    end
  end

  @doc "Remove a dependency from a goal."
  def remove_dependency(goal_id, depends_on_id) do
    case Object.get(goal_id) do
      {:ok, goal} ->
        current_deps = goal.metadata[:depends_on] || []
        Object.update_metadata(goal_id, %{depends_on: List.delete(current_deps, depends_on_id)})

      error ->
        error
    end
  end

  @doc """
  When a goal is completed, notify the orchestrator (parent goal's agent).
  This creates a reactive feedback loop: worker finishes → orchestrator wakes up → spawns next batch.
  """
  def notify_orchestrator(goal_id) do
    with {:ok, goal} <- Object.get(goal_id),
         parent_id when not is_nil(parent_id) <- goal.metadata[:parent_goal_id],
         {:ok, parent} <- Object.get(parent_id),
         orchestrator_id when not is_nil(orchestrator_id) <- parent.metadata[:agent_id] do
      report = goal.metadata[:report]

      report_section =
        if report, do: "\n\nAgent report:\n#{String.slice(report, 0, 2000)}", else: ""

      message =
        "Goal completed: \"#{goal.name}\" [#{goal_id}].#{report_section}\n\nCheck `goal_list` for updated state and continue with the next steps."

      Orchid.Agent.notify(orchestrator_id, message)
    else
      _ -> :ok
    end
  end

  @doc "Assign a goal to an agent and kick off a message."
  def assign_to_agent(goal_id, agent_id) do
    case Object.get(goal_id) do
      {:ok, goal} ->
        {:ok, _} = Object.update_metadata(goal_id, %{agent_id: agent_id})

        description =
          if goal.content && goal.content != "" do
            "\n\n#{goal.content}"
          else
            ""
          end

        message = "Work on goal: #{goal.name}\nGoal ID: #{goal_id}#{description}"

        Task.start(fn ->
          Orchid.Agent.stream(agent_id, message, fn _chunk -> :ok end)
        end)

        :ok

      error ->
        error
    end
  end

  defp stop_project_agents(project_id) when is_binary(project_id) do
    Orchid.Agent.list()
    |> Enum.reduce([], fn agent_id, acc ->
      case Orchid.Agent.get_state(agent_id, 2000) do
        {:ok, %{project_id: ^project_id} = state} -> [state | acc]
        _ -> acc
      end
    end)
    |> Enum.sort_by(fn state -> if state.config[:use_orchid_tools], do: 0, else: 1 end)
    |> Enum.each(fn state -> Orchid.Agent.stop(state.id) end)
  end

  defp stop_project_agents(_project_id), do: :ok

  defp mark_project_clearing(project_id, clearing) when is_binary(project_id) do
    case Object.update_metadata(project_id, %{clearing_goals: clearing}) do
      {:ok, _project} -> :ok
      _ -> :ok
    end
  end

  defp mark_project_clearing(_project_id, _clearing), do: :ok
end
