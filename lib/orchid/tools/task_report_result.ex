defmodule Orchid.Tools.TaskReportResult do
  @moduledoc "Report task outcome for the agent's assigned goal with structured metadata"
  @behaviour Orchid.Tool

  alias Orchid.{Object, Goals}
  alias Orchid.Tools.GoalHelpers

  @impl true
  def name, do: "task_report_result"

  @impl true
  def description do
    "Report success/failure/in-progress for a goal with summary, error, and optional completion"
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        goal_id: %{
          type: "string",
          description: "Goal ID or name (optional, defaults to this agent's assigned goal)"
        },
        outcome: %{
          type: "string",
          enum: ["success", "failure", "blocked", "in_progress"],
          description: "Task outcome"
        },
        summary: %{
          type: "string",
          description: "Concise progress or completion summary"
        },
        report: %{
          type: "string",
          description: "Detailed report with commands and outputs"
        },
        error: %{
          type: "string",
          description: "Error details (required when outcome is failure/blocked)"
        },
        mark_completed: %{
          type: "boolean",
          description: "When outcome=success, mark goal completed (default: true)"
        }
      },
      required: ["outcome", "summary"]
    }
  end

  @impl true
  def execute(args, %{agent_state: state}) do
    with {:ok, goal} <- resolve_target_goal(args["goal_id"], state),
         :ok <- validate_args(args),
         :ok <- validate_subgoals_complete(goal, state.project_id, args),
         {:ok, _} <- persist_report(goal, args) do
      {:ok, "Reported #{args["outcome"]} for goal \"#{goal.name}\" [#{goal.id}]"}
    end
  end

  def execute(_args, _context) do
    {:error, "task_report_result requires agent_state context"}
  end

  defp resolve_target_goal(goal_ref, state) do
    project_id = state.project_id
    goals = Object.list_goals_for_project(project_id)

    goal =
      cond do
        is_binary(goal_ref) and goal_ref != "" ->
          id = GoalHelpers.resolve_goal_ref(goal_ref, project_id) || goal_ref

          case Object.get(id) do
            {:ok, %{type: :goal} = g} -> g
            _ -> nil
          end

        true ->
          Enum.find(goals, fn g ->
            g.metadata[:agent_id] == state.id and Goals.open_status?(g.metadata[:status])
          end)
      end

    if goal do
      {:ok, goal}
    else
      {:error, "No target goal found for task_report_result"}
    end
  end

  defp validate_args(%{"outcome" => outcome} = args) do
    if outcome in ["failure", "blocked"] and blank?(args["error"]) do
      {:error, "error is required when outcome is failure or blocked"}
    else
      :ok
    end
  end

  defp persist_report(goal, args) do
    outcome = args["outcome"]
    summary = truncate(args["summary"] || "", 400)
    report = truncate(args["report"] || summary, 20_000)
    error_text = truncate(args["error"] || "", 2000)

    metadata = %{
      completion_summary: summary,
      report: report,
      last_error:
        if(outcome in ["failure", "blocked"], do: nonempty(error_text, summary), else: nil),
      task_outcome: outcome,
      reported_by_tool: true,
      reported_at: DateTime.utc_now()
    }

    with {:ok, _} <- Object.update_metadata(goal.id, metadata),
         :ok <- maybe_update_status(goal.id, args) do
      {:ok, :reported}
    end
  end

  defp validate_subgoals_complete(goal, project_id, %{"outcome" => "success"} = args) do
    if Map.get(args, "mark_completed", true) do
      goals = Object.list_goals_for_project(project_id)

      pending_children =
        Enum.filter(goals, fn g ->
          g.metadata[:parent_goal_id] == goal.id and Goals.open_status?(g.metadata[:status])
        end)

      if pending_children == [] do
        :ok
      else
        names = Enum.map_join(pending_children, ", ", fn g -> "#{g.name} [#{g.id}]" end)
        {:error, "Cannot mark goal completed while subgoals are pending: #{names}"}
      end
    else
      :ok
    end
  end

  defp validate_subgoals_complete(_goal, _project_id, _args), do: :ok

  defp maybe_update_status(goal_id, %{"outcome" => "success"} = args) do
    if Map.get(args, "mark_completed", true) do
      case Goals.set_status(goal_id, :completed) do
        {:ok, _} -> :ok
        other -> other
      end
    else
      case Goals.set_status(goal_id, :pending) do
        {:ok, _} -> :ok
        other -> other
      end
    end
  end

  defp maybe_update_status(goal_id, _args) do
    case Goals.set_status(goal_id, :pending) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: false

  defp nonempty(v, fallback) do
    if blank?(v), do: fallback, else: v
  end

  defp truncate(text, max) when is_binary(text) and max > 0 do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end
end
