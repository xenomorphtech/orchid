defmodule Orchid.Planner.Router do
  @moduledoc """
  Cheap runtime classifier for choosing the autonomy runner mode.

  The classifier only inspects fields available on the runtime goal contract:
  objective text, success check shape, and max-step budget. It deliberately does
  not use benchmark ids or categories.
  """

  require Logger

  alias Orchid.Autonomy.Benchmark

  @type mode :: :flat | :gvr
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
  Classify a benchmark goal into the resolved runner mode.
  """
  @spec classify(Benchmark.t()) :: decision()
  def classify(%Benchmark{} = benchmark) do
    hard_markers = matching_markers(benchmark.objective, @hard_planning_markers)
    context_markers = matching_markers(benchmark.objective, @context_planning_markers)
    objective_words = word_count(benchmark.objective)
    success_check = success_check_kind(benchmark.success_check)

    mode =
      if planning_goal?(
           hard_markers,
           context_markers,
           objective_words,
           benchmark.max_steps,
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
          benchmark.max_steps,
          success_check
        )
    }
  end

  @doc """
  Classify and log the per-goal routing decision when a goal id is available.
  """
  @spec route(Benchmark.t(), term()) :: decision()
  def route(%Benchmark{} = benchmark, goal_id \\ nil) do
    decision = classify(benchmark)
    log_decision(goal_id, decision)
    decision
  end

  @spec log_decision(term(), decision()) :: :ok
  def log_decision(goal_id, %{mode: mode, signal: signal}) do
    Logger.info("[ROUTER] goal=#{goal_label(goal_id)} signal=#{signal} -> #{inspect(mode)}")
    :ok
  end

  defp planning_goal?(hard_markers, context_markers, objective_words, max_steps, success_check) do
    hard_markers != [] or
      length(context_markers) >= 3 or
      (length(context_markers) >= 2 and max_steps >= 20) or
      (length(context_markers) >= 2 and objective_words >= 60 and success_check == "shell")
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
  defp success_check_kind(_success_check), do: "unknown"

  defp signal_text(hard_markers, context_markers, objective_words, max_steps, success_check) do
    markers = hard_markers ++ context_markers
    marker_text = if markers == [], do: "none", else: Enum.join(markers, ",")

    "objective_markers=#{marker_text}; objective_words=#{objective_words}; max_steps=#{max_steps}; success_check=#{success_check}"
  end

  defp goal_label(nil), do: "unknown"
  defp goal_label(goal_id) when is_binary(goal_id), do: goal_id
  defp goal_label(goal_id), do: inspect(goal_id)
end
