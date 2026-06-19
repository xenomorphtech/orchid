defmodule Orchid.Planner.RuntimeGoal do
  @moduledoc false

  alias Orchid.Object

  @type route_input :: %{
          required(:source) => :goal_watcher,
          required(:objective) => String.t(),
          required(:success_check_text) => String.t(),
          required(:goal_count) => non_neg_integer(),
          required(:goal_ids) => [String.t()],
          optional(:max_steps) => pos_integer()
        }

  @doc false
  @spec from_goal_watcher(Object.t(), [Object.t()]) :: route_input()
  def from_goal_watcher(%Object{} = project, goals) when is_list(goals) do
    route_input = %{
      source: :goal_watcher,
      objective: routing_objective(project, goals),
      success_check_text: text_metadata(project, :success_criteria),
      goal_count: length(goals),
      goal_ids: Enum.map(goals, & &1.id)
    }

    case runtime_step_budget(project, goals) do
      nil -> route_input
      budget -> Map.put(route_input, :max_steps, budget)
    end
  end

  @doc false
  @spec goal_label([Object.t()], String.t() | nil) :: String.t()
  def goal_label([goal], _project_id), do: goal.id
  def goal_label([], project_id), do: project_id || "unknown"
  def goal_label(goals, project_id), do: "#{project_id || "unknown"}:#{length(goals)}-goals"

  defp routing_objective(project, goals) do
    [
      text_metadata(project, :objective),
      text_metadata(project, :success_criteria),
      text_metadata(project, :background),
      text_metadata(project, :constraints),
      goal_text(goals)
    ]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp goal_text(goals) do
    goals
    |> Enum.map(fn goal ->
      deps = metadata(goal, :depends_on) || []
      dep_text = if deps == [], do: "", else: " depends on #{Enum.join(deps, ", ")}"
      content = String.trim(goal.content || "")
      body = if content == "", do: "", else: ": #{content}"

      "#{goal.name}#{dep_text}#{body}"
    end)
    |> Enum.join("\n")
  end

  defp runtime_step_budget(project, goals) do
    [
      metadata(project, :max_steps),
      metadata(project, :step_budget),
      metadata(project, :max_turns)
    ]
    |> Kernel.++(Enum.flat_map(goals, &goal_budget_values/1))
    |> Enum.find_value(&normalize_budget/1)
  end

  defp goal_budget_values(goal) do
    [metadata(goal, :max_steps), metadata(goal, :step_budget), metadata(goal, :max_turns)]
  end

  defp normalize_budget(value) when is_integer(value) and value > 0, do: value

  defp normalize_budget(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_budget(_value), do: nil

  defp text_metadata(object, key) do
    case metadata(object, key) do
      value when is_binary(value) -> value
      nil -> ""
      value -> to_string(value)
    end
  end

  defp metadata(%Object{metadata: metadata}, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata(_object, _key), do: nil
end
