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
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [runs: :integer])
    reject_invalid_options!(invalid)

    runs = Keyword.get(opts, :runs, 3)
    validate_runs!(runs)

    benchmarks = load_benchmarks()
    report = build_report(benchmarks, runs)

    write_report!(report)

    Mix.shell().info(
      "orchid.autonomy: loaded #{length(benchmarks)} benchmark(s), #{runs} run(s) each; wrote #{@report_path}"
    )
  end

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

  defp build_report(benchmarks, runs) do
    benchmark_reports = Enum.map(benchmarks, &benchmark_report(&1, runs))

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: :scaffold,
      runs_per_benchmark: runs,
      benchmark_count: length(benchmarks),
      benchmarks: benchmark_reports,
      summary: summarize(benchmark_reports)
    }
  end

  defp benchmark_report(%Benchmark{} = benchmark, runs) do
    samples =
      1..runs
      |> Enum.map(fn run_index ->
        case Runner.run(benchmark) do
          {:ok, result} ->
            score = Scorer.score(result)

            %{
              run: run_index,
              status: :scaffold,
              result: encode_run_result(result),
              score: score
            }

          {:error, reason} ->
            %{
              run: run_index,
              status: :error,
              error: inspect(reason),
              score: %{unattended_depth: 0, goal_closure: false, recovery_rate: 0.0}
            }
        end
      end)

    %{
      id: benchmark.id,
      category: benchmark.category,
      objective: benchmark.objective,
      max_steps: benchmark.max_steps,
      success_check: encode_success_check(benchmark.success_check),
      samples: samples,
      median_score: median_score(samples),
      goal_closure_rate: goal_closure_rate(samples)
    }
  end

  defp encode_run_result(result) do
    %{
      project_id: Map.get(result, :project_id),
      agent_id: Map.get(result, :agent_id),
      depth: Map.get(result, :depth, 0),
      closed: Map.get(result, :closed, false),
      recovered: Map.get(result, :recovered, []),
      steps: Map.get(result, :steps, []),
      status: Map.get(result, :status)
    }
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
      recovery_rate:
        median(Enum.map(benchmark_reports, &get_in(&1, [:median_score, :recovery_rate])))
    }
  end

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
