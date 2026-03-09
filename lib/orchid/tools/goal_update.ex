defmodule Orchid.Tools.GoalUpdate do
  @moduledoc "Update an existing goal"
  @behaviour Orchid.Tool

  alias Orchid.Object
  alias Orchid.Tools.GoalHelpers

  @impl true
  def name, do: "goal_update"

  @impl true
  def description, do: "Update an existing goal's status, dependencies, or name"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        id: %{
          type: "string",
          description: "Goal ID or name of the goal to update"
        },
        status: %{
          type: "string",
          enum: ["pending", "completed", "superseded"],
          description: "New status for the goal"
        },
        depends_on: %{
          type: "array",
          items: %{type: "string"},
          description: "New list of goal IDs or names this goal depends on"
        },
        name: %{
          type: "string",
          description: "New name for the goal"
        },
        report: %{
          type: "string",
          description: "Optional status report or completion/supersession rationale"
        }
      },
      required: ["id"]
    }
  end

  @impl true
  def execute(%{"id" => id_ref} = args, %{agent_state: %{project_id: project_id}}) do
    id = GoalHelpers.resolve_goal_ref(id_ref, project_id) || id_ref

    case Object.get(id) do
      {:ok, obj} when obj.type == :goal ->
        resolved_deps =
          if args["depends_on"] do
            GoalHelpers.resolve_goal_refs(
              args["depends_on"],
              project_id || obj.metadata[:project_id]
            )
          else
            nil
          end

        metadata_updates =
          %{}
          |> maybe_put(:status, normalize_status(args["status"], args["report"]))
          |> maybe_put(:depends_on, resolved_deps)
          |> maybe_put(:report, args["report"])

        # Update metadata if there are changes
        if metadata_updates != %{} do
          {:ok, _} = Object.update_metadata(id, metadata_updates)
        end

        # Update name via content update if provided
        if args["name"] do
          {:ok, updated} = Object.get(id)

          :ok =
            Orchid.Store.put_object(%{
              updated
              | name: args["name"],
                updated_at: DateTime.utc_now()
            })
        end

        # Notify orchestrator when a goal is completed
        if normalize_status(args["status"], args["report"]) == :completed do
          Orchid.Goals.notify_orchestrator(id)
        end

        {:ok, "Updated goal: #{args["name"] || obj.name} (ID: #{id})"}

      {:ok, _obj} ->
        {:error, "Object #{id} is not a goal"}

      {:error, :not_found} ->
        {:error, "Goal not found: #{id_ref}"}
    end
  end

  def execute(%{"id" => id_ref} = args, _context) do
    # Fallback for calls without agent_state (shouldn't normally happen)
    case Object.get(id_ref) do
      {:ok, obj} when obj.type == :goal ->
        project_id = obj.metadata[:project_id]

        resolved_deps =
          if args["depends_on"] do
            GoalHelpers.resolve_goal_refs(args["depends_on"], project_id)
          else
            nil
          end

        metadata_updates =
          %{}
          |> maybe_put(:status, normalize_status(args["status"], args["report"]))
          |> maybe_put(:depends_on, resolved_deps)
          |> maybe_put(:report, args["report"])

        if metadata_updates != %{} do
          {:ok, _} = Object.update_metadata(id_ref, metadata_updates)
        end

        if args["name"] do
          {:ok, updated} = Object.get(id_ref)

          :ok =
            Orchid.Store.put_object(%{
              updated
              | name: args["name"],
                updated_at: DateTime.utc_now()
            })
        end

        {:ok, "Updated goal: #{args["name"] || obj.name} (ID: #{id_ref})"}

      {:ok, _obj} ->
        {:error, "Object #{id_ref} is not a goal"}

      {:error, :not_found} ->
        {:error, "Goal not found: #{id_ref}"}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_status(nil, _report), do: nil

  defp normalize_status(status, report) when is_binary(status) do
    normalized =
      status
      |> String.trim()
      |> String.downcase()

    cond do
      normalized == "completed" and superseded_report?(report) -> :superseded
      normalized == "pending" -> :pending
      normalized == "completed" -> :completed
      normalized == "superseded" -> :superseded
      true -> nil
    end
  end

  defp normalize_status(_status, _report), do: nil

  defp superseded_report?(report) when is_binary(report) do
    String.contains?(String.downcase(report), "superseded")
  end

  defp superseded_report?(_), do: false
end
