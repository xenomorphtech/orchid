defmodule Orchid.Planner.Router do
  @moduledoc """
  Cheap runtime classifier for choosing the autonomy runner mode.

  The classifier only inspects fields available on the runtime goal contract:
  objective text, success check shape, and max-step budget. It deliberately does
  not use benchmark ids or categories.
  """

  require Logger

  @type mode :: :flat | :gvr
  @type route_input :: map() | String.t()
  @type decision :: %{
          required(:mode) => mode(),
          required(:signal) => String.t()
        }

  @hard_planning_markers [
    {"oscillation", ~r/\boscillat\w*/i},
    {"constraint", ~r/\bconstraints?\b/i},
    {"refactor", ~r/\brefactor\w*/i},
    {"flip", ~r/\bflip(?:s|ped|ping)?\b/i}
  ]

  @context_planning_markers [
    {"boundary", ~r/\bboundar(?:y|ies)\b/i},
    {"shared", ~r/\bshared\b/i},
    {"contract", ~r/\bcontract\b/i},
    {"together", ~r/\btogether\b/i},
    {"both", ~r/\bboth\b/i},
    {"ordering", ~r/\border(?:ing|ed)?\b/i},
    {"sequence", ~r/\bsequence(?:d|s)?\b/i},
    {"dependency", ~r/\bdepend(?:ency|encies|s|ing)?\b/i},
    {"before-after", ~r/\b(?:before|after)\b/i},
    {"budget", ~r/\bbudget(?:ed|s)?\b/i},
    {"coordinate", ~r/\bcoordinat\w*/i},
    {"simultaneous", ~r/\bsimultaneous\w*/i}
  ]

  @doc """
  Classify a goal into the resolved runner mode.

  Accepts the benchmark struct used by the autonomy harness, a runtime goal
  routing map, or a bare objective string. Runtime maps are expected to carry
  only product-available signals such as objective text, optional step budget,
  and optional success-check text/shape.
  """
  @spec classify(route_input()) :: decision()
  def classify(objective) when is_binary(objective) do
    classify(%{objective: objective})
  end

  def classify(goal) when is_map(goal) do
    objective = objective_text(goal)
    max_steps = step_budget(goal)
    success_check = input_success_check_kind(goal)

    hard_markers = matching_markers(objective, @hard_planning_markers)
    context_markers = matching_markers(objective, @context_planning_markers)
    objective_words = word_count(objective)

    mode =
      if planning_goal?(
           hard_markers,
           context_markers,
           objective_words,
           max_steps,
           success_check
         ) do
        :gvr
      else
        :flat
      end

    %{
      mode: mode,
      signal:
        signal_text(
          hard_markers,
          context_markers,
          objective_words,
          max_steps,
          success_check
        )
    }
  end

  @doc """
  Classify and log the per-goal routing decision when a goal id is available.
  """
  @spec route(route_input(), term()) :: decision()
  def route(goal, goal_id \\ nil) do
    decision = classify(goal)
    log_decision(goal_id, decision)
    decision
  end

  @spec log_decision(term(), decision()) :: :ok
  def log_decision(goal_id, %{mode: mode, signal: signal}) do
    Logger.info("[ROUTER] goal=#{goal_label(goal_id)} -> #{inspect(mode)} signal=#{signal}")
    :ok
  end

  defp planning_goal?(hard_markers, context_markers, objective_words, max_steps, success_check) do
    hard_markers != [] or
      length(context_markers) >= 3 or
      (length(context_markers) >= 2 and high_step_budget?(max_steps)) or
      (length(context_markers) >= 2 and objective_words >= 60 and success_check == "shell")
  end

  defp high_step_budget?(max_steps) when is_integer(max_steps), do: max_steps >= 20
  defp high_step_budget?(_max_steps), do: false

  defp objective_text(goal) do
    goal
    |> get_any([:objective, "objective", :content, "content", :name, "name"])
    |> to_text()
  end

  defp step_budget(goal) do
    goal
    |> get_any([
      :max_steps,
      "max_steps",
      :step_budget,
      "step_budget",
      :max_turns,
      "max_turns"
    ])
    |> normalize_step_budget()
  end

  defp normalize_step_budget(value) when is_integer(value), do: value

  defp normalize_step_budget(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_step_budget(_value), do: nil

  defp input_success_check_kind(goal) do
    explicit_kind =
      goal
      |> get_any([:success_check_kind, "success_check_kind"])
      |> normalize_kind()

    cond do
      explicit_kind != nil ->
        explicit_kind

      true ->
        case get_any(goal, [:success_check, "success_check"]) do
          nil ->
            case get_any(goal, [:success_check_text, "success_check_text"]) do
              nil -> "unknown"
              success_check_text -> success_check_kind(success_check_text)
            end

          success_check ->
            success_check_kind(success_check)
        end
    end
  end

  defp matching_markers(text, markers) when is_binary(text) do
    markers
    |> Enum.flat_map(fn {label, pattern} ->
      if Regex.match?(pattern, text), do: [label], else: []
    end)
  end

  defp matching_markers(_text, _markers), do: []

  defp word_count(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp word_count(_text), do: 0

  defp success_check_kind({:shell, _command}), do: "shell"
  defp success_check_kind({:file_exists, _path}), do: "file_exists"
  defp success_check_kind({:file_contains, _path, _needle}), do: "file_contains"
  defp success_check_kind({:predicate, _predicate}), do: "predicate"
  defp success_check_kind(text) when is_binary(text), do: text_success_check_kind(text)
  defp success_check_kind(_success_check), do: "unknown"

  defp text_success_check_kind(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" ->
        "unknown"

      Regex.match?(~r/^\s*(shell|command)\s*:/i, trimmed) ->
        "shell"

      Regex.match?(~r/\b(file exists|exists at|path exists)\b/i, trimmed) ->
        "file_exists"

      Regex.match?(~r/\b(file contains|contains text|matches regex)\b/i, trimmed) ->
        "file_contains"

      Regex.match?(~r/\b(run|execute|passes?|check|verify)\b/i, trimmed) and
          Regex.match?(~r/\b(mix|npm|pnpm|yarn|pytest|cargo|go test|make|curl)\b/i, trimmed) ->
        "shell"

      true ->
        "text"
    end
  end

  defp normalize_kind(nil), do: nil
  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)

  defp normalize_kind(kind) when is_binary(kind) do
    case String.trim(kind) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_kind(_kind), do: nil

  defp get_any(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp to_text(value) when is_binary(value), do: value
  defp to_text(nil), do: ""
  defp to_text(value), do: to_string(value)

  defp signal_text(hard_markers, context_markers, objective_words, max_steps, success_check) do
    markers = hard_markers ++ context_markers
    marker_text = if markers == [], do: "none", else: Enum.join(markers, ",")
    max_steps_text = if is_nil(max_steps), do: "unknown", else: max_steps

    "objective_markers=#{marker_text}; objective_words=#{objective_words}; max_steps=#{max_steps_text}; success_check=#{success_check}"
  end

  defp goal_label(nil), do: "unknown"
  defp goal_label(goal_id) when is_binary(goal_id), do: goal_id
  defp goal_label(goal_id), do: inspect(goal_id)
end
