defmodule Mix.Tasks.Orchid.Autonomy do
  @moduledoc """
  Runs the Orchid autonomy benchmark suite and writes the latest report.
  """

  use Mix.Task

  alias Orchid.Autonomy.{Benchmark, Runner, Scorer}

  @shortdoc "Run the Orchid autonomy benchmark suite"
  @benchmark_glob Path.join(["test", "autonomy", "benchmarks", "*.exs"])
  @report_path Path.join(["priv", "autonomy", "last_report.json"])

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          runs: :integer,
          mode: :string,
          max_rounds: :integer,
          max_delegate_depth: :integer,
          gvr_memoize: :boolean
        ]
      )

    reject_invalid_options!(invalid)

    runs = Keyword.get(opts, :runs, 3)
    validate_runs!(runs)
    mode = opts |> Keyword.get(:mode, "auto") |> parse_mode!()
    runner_opts = build_runner_opts(opts)

    benchmarks = load_benchmarks()
    report = build_report(benchmarks, runs, mode, runner_opts)

    write_report!(report)

    Mix.shell().info(
      "orchid.autonomy: loaded #{length(benchmarks)} benchmark(s), #{runs} #{mode} run(s) each; wrote #{@report_path}"
    )
  end

  # Translate CLI bounding flags into Runner opts. Only includes a key when the
  # flag was passed, so the Runner's own defaults (gvr_max_rounds 6,
  # gvr_max_delegate_depth 3) still apply when unset. Bounding these makes the
  # G-V-R recursive delegate*revise call count tractable on a slow free model.
  defp build_runner_opts(opts) do
    []
    |> maybe_put_opt(:gvr_max_rounds, Keyword.get(opts, :max_rounds))
    |> maybe_put_opt(:gvr_max_delegate_depth, Keyword.get(opts, :max_delegate_depth))
    |> maybe_put_opt(:gvr_llm_memoize, Keyword.get(opts, :gvr_memoize))
  end

  defp maybe_put_opt(kw, _key, nil), do: kw
  defp maybe_put_opt(kw, key, value), do: Keyword.put(kw, key, value)

  @doc """
  Load benchmark structs from `test/autonomy/benchmarks/*.exs`.
  """
  @spec load_benchmarks(String.t()) :: [Benchmark.t()]
  def load_benchmarks(glob \\ @benchmark_glob) do
    glob
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&load_benchmark!/1)
  end

  defp reject_invalid_options!([]), do: :ok

  defp reject_invalid_options!(invalid) do
    options = invalid |> Enum.map_join(", ", fn {option, _value} -> option end)
    Mix.raise("Invalid orchid.autonomy option(s): #{options}")
  end

  defp validate_runs!(runs) when is_integer(runs) and runs >= 3, do: :ok

  defp validate_runs!(runs) do
    Mix.raise("--runs must be an integer >= 3, got: #{inspect(runs)}")
  end

  defp parse_mode!("flat"), do: :flat
  defp parse_mode!("gvr"), do: :gvr
  defp parse_mode!("auto"), do: :auto

  defp parse_mode!(mode) do
    Mix.raise("--mode must be flat, gvr, or auto, got: #{inspect(mode)}")
  end

  defp load_benchmark!(path) do
    case Code.eval_file(path) do
      {%Benchmark{} = benchmark, _binding} ->
        benchmark

      {attrs, _binding} when is_map(attrs) or is_list(attrs) ->
        Benchmark.new!(attrs)

      {other, _binding} ->
        Mix.raise("Benchmark #{path} returned #{inspect(other)}, expected #{inspect(Benchmark)}")
    end
  end

  defp build_report(benchmarks, runs, mode, runner_opts) do
    benchmark_reports = Enum.map(benchmarks, &benchmark_report(&1, runs, mode, runner_opts))

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: suite_status(benchmark_reports),
      runner_mode: mode,
      runs_per_benchmark: runs,
      benchmark_count: length(benchmarks),
      benchmarks: benchmark_reports,
      categories: category_summaries(benchmark_reports),
      summary: summarize(benchmark_reports)
    }
  end

  defp benchmark_report(%Benchmark{} = benchmark, runs, mode, runner_opts) do
    samples =
      1..runs
      |> Enum.map(fn run_index ->
        case Runner.run(benchmark, [mode: mode] ++ runner_opts) do
          {:ok, result} ->
            try do
              score = Scorer.score(result)
              runner_mode = Map.get(result, :runner_mode, mode)

              %{
                run: run_index,
                runner_mode: runner_mode,
                status: Map.get(result, :status, :unknown),
                result: encode_run_result(result),
                score: score
              }
            after
              Runner.cleanup(result)
            end

          {:error, reason} ->
            %{
              run: run_index,
              runner_mode: mode,
              status: :error,
              error: inspect(reason),
              score: %{unattended_depth: 0, goal_closure: false, recovery_rate: 0.0}
            }
        end
      end)

    %{
      id: benchmark.id,
      category: benchmark.category,
      runner_mode: mode,
      objective: benchmark.objective,
      max_steps: benchmark.max_steps,
      success_check: encode_success_check(benchmark.success_check),
      seed_files: Enum.map(benchmark.seed_files, & &1.path),
      recovery_checks: encode_recovery_checks(benchmark.recovery_checks),
      samples: samples,
      median_score: median_score(samples),
      goal_closure_rate: goal_closure_rate(samples)
    }
  end

  defp encode_run_result(result) do
    %{
      project_id: Map.get(result, :project_id),
      agent_id: Map.get(result, :agent_id),
      runner_mode: Map.get(result, :runner_mode),
      depth: Map.get(result, :depth, 0),
      closed: Map.get(result, :closed, false),
      recovered: Map.get(result, :recovered, []),
      steps: Map.get(result, :steps, []),
      status: Map.get(result, :status)
    }
    |> maybe_put(:goal_id, Map.get(result, :goal_id))
    |> maybe_put(:turn_result, Map.get(result, :turn_result))
    |> maybe_put(:duration_ms, Map.get(result, :duration_ms))
    |> maybe_put(:last_assistant_message, Map.get(result, :last_assistant_message))
    |> maybe_put(:error, error_text(Map.get(result, :error)))
  end

  defp encode_success_check({:shell, command}), do: %{type: :shell, command: command}
  defp encode_success_check({:file_exists, path}), do: %{type: :file_exists, path: path}

  defp encode_success_check({:file_contains, path, %Regex{} = pattern}) do
    %{type: :file_contains, path: path, pattern: Regex.source(pattern)}
  end

  defp encode_success_check({:file_contains, path, needle}) do
    %{type: :file_contains, path: path, needle: needle}
  end

  defp encode_success_check({:predicate, _predicate}), do: %{type: :predicate}

  defp encode_recovery_checks(recovery_checks) do
    Enum.map(recovery_checks, fn recovery_check ->
      %{
        id: recovery_check.id,
        description: Map.get(recovery_check, :description),
        check: encode_success_check(recovery_check.check)
      }
    end)
  end

  defp median_score(samples) do
    %{
      unattended_depth: median(Enum.map(samples, &get_in(&1, [:score, :unattended_depth]))),
      recovery_rate: median(Enum.map(samples, &get_in(&1, [:score, :recovery_rate])))
    }
  end

  defp goal_closure_rate([]), do: 0.0

  defp goal_closure_rate(samples) do
    closed = Enum.count(samples, &get_in(&1, [:score, :goal_closure]))
    closed / length(samples)
  end

  defp summarize([]) do
    %{unattended_depth: 0, goal_closure_rate: 0.0, recovery_rate: 0.0}
  end

  defp summarize(benchmark_reports) do
    %{
      unattended_depth:
        median(Enum.map(benchmark_reports, &get_in(&1, [:median_score, :unattended_depth]))),
      goal_closure_rate:
        average(Enum.map(benchmark_reports, &Map.fetch!(&1, :goal_closure_rate))),
      recovery_rate: aggregate_recovery_rate(benchmark_reports),
      recovery_injected_count: recovery_injected_count(benchmark_reports),
      recovery_recovered_count: recovery_recovered_count(benchmark_reports)
    }
  end

  defp category_summaries(benchmark_reports) do
    benchmark_reports
    |> Enum.group_by(& &1.category)
    |> Enum.map(fn {category, reports} ->
      {category,
       %{
         benchmark_count: length(reports),
         goal_closure_rate: average(Enum.map(reports, &Map.fetch!(&1, :goal_closure_rate))),
         unattended_depth:
           median(Enum.map(reports, &get_in(&1, [:median_score, :unattended_depth]))),
         recovery_rate: aggregate_recovery_rate(reports),
         recovery_injected_count: recovery_injected_count(reports),
         recovery_recovered_count: recovery_recovered_count(reports)
       }}
    end)
    |> Map.new()
  end

  defp aggregate_recovery_rate(benchmark_reports) do
    injected = recovery_injected_count(benchmark_reports)

    if injected == 0 do
      0.0
    else
      recovery_recovered_count(benchmark_reports) / injected
    end
  end

  defp recovery_injected_count(benchmark_reports) do
    benchmark_reports
    |> recovery_events()
    |> Enum.count(&Map.get(&1, :injected, true))
  end

  defp recovery_recovered_count(benchmark_reports) do
    benchmark_reports
    |> recovery_events()
    |> Enum.count(&(Map.get(&1, :injected, true) and Map.get(&1, :recovered, false)))
  end

  defp recovery_events(benchmark_reports) do
    benchmark_reports
    |> Enum.flat_map(&Map.fetch!(&1, :samples))
    |> Enum.flat_map(fn sample -> get_in(sample, [:result, :recovered]) || [] end)
  end

  defp suite_status(benchmark_reports) do
    if Enum.any?(benchmark_reports, &benchmark_error?/1), do: :error, else: :complete
  end

  defp benchmark_error?(%{samples: samples}) do
    Enum.any?(samples, fn sample -> sample.status == :error end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp error_text(nil), do: nil
  defp error_text(error), do: inspect(error)

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, middle)
    else
      (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
    end
  end

  defp average([]), do: 0.0

  defp average(values) do
    Enum.sum(values) / length(values)
  end

  defp write_report!(report) do
    @report_path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(@report_path, Jason.encode!(report, pretty: true))
  end
end
