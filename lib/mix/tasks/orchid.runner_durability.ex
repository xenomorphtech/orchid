defmodule Mix.Tasks.Orchid.RunnerDurability do
  @moduledoc """
  Runs a deterministic Runner durability regression.

  The harness intentionally uses the real `Orchid.Autonomy.Runner` while keeping
  the benchmark no-AI-in-loop: `:gvr` mode checks deterministic closure before
  planning, and zero planner rounds prevent fallback LLM calls after injected
  transient shell failures.
  """

  use Mix.Task

  alias Orchid.Autonomy.{Benchmark, Runner, Runtime, Scorer}
  alias Orchid.Sandbox

  @shortdoc "Run the Orchid Runner durability regression"
  @default_runs 20
  @default_faults 3
  @default_out Path.join(["priv", "autonomy", "runner_durability.json"])
  @default_run_timeout_ms 180_000

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          runs: :integer,
          faults: :integer,
          out: :string,
          run_timeout_ms: :integer
        ]
      )

    reject_invalid_options!(invalid)

    runs = opts |> Keyword.get(:runs, @default_runs) |> validate_positive_integer!("--runs")

    faults =
      opts |> Keyword.get(:faults, @default_faults) |> validate_non_negative_integer!("--faults")

    run_timeout_ms =
      opts
      |> Keyword.get(:run_timeout_ms, @default_run_timeout_ms)
      |> validate_positive_integer!("--run-timeout-ms")

    output_path = opts |> Keyword.get(:out, @default_out) |> validate_output_path!()
    fault_indices = fault_indices(runs, faults)

    ensure_runtime_started!()

    baseline_orphans = list_orphaned_containers()

    samples =
      1..runs
      |> Enum.map(fn run_index ->
        inject_fault? = MapSet.member?(fault_indices, run_index)
        run_sample(run_index, inject_fault?, run_timeout_ms)
      end)

    final_orphans = list_orphaned_containers()
    report = build_report(samples, baseline_orphans, final_orphans, runs, faults)

    write_report!(report, output_path)

    Mix.shell().info(
      "orchid.runner_durability: ran #{runs} goal(s), " <>
        "#{report.recovery_injected_count} injected recovery fault(s), " <>
        "recovery_rate=#{Float.round(report.recovery_rate, 3)}, " <>
        "orphaned_count=#{report.orphaned_count}; wrote #{output_path}"
    )
  end

  defp run_sample(run_index, inject_fault?, timeout_ms) do
    benchmark = benchmark(run_index, inject_fault?)
    started_at = monotonic_ms()

    task =
      Task.async(fn ->
        try do
          {:runner,
           Runner.run(benchmark,
             mode: :gvr,
             max_steps: 1,
             gvr_max_rounds: 0,
             gvr_max_delegate_depth: 0,
             wall_clock_timeout_ms: 5_000,
             success_timeout_ms: 10_000
           )}
        rescue
          error ->
            {:exception, :error, error, __STACKTRACE__}
        catch
          kind, reason ->
            {:exception, kind, reason, __STACKTRACE__}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:runner, {:ok, result}}} ->
        score = Scorer.score(result)

        %{
          run: run_index,
          benchmark_id: benchmark.id,
          injected: inject_fault?,
          status: :ok,
          runner_status: Map.get(result, :status),
          runner_mode: Map.get(result, :runner_mode),
          project_id: Map.get(result, :project_id),
          container_name: container_name(Map.get(result, :project_id)),
          closed: Map.get(result, :closed, false),
          depth: Map.get(result, :depth, 0),
          score: score,
          recovery_events: encode_recovery_events(Map.get(result, :recovered, [])),
          duration_ms: monotonic_ms() - started_at
        }

      {:ok, {:runner, {:error, reason}}} ->
        error_sample(run_index, benchmark.id, inject_fault?, :runner_error, reason, started_at)

      {:ok, {:exception, kind, reason, stacktrace}} ->
        error_sample(
          run_index,
          benchmark.id,
          inject_fault?,
          :runner_exception,
          format_exception(kind, reason, stacktrace),
          started_at
        )

      {:exit, reason} ->
        error_sample(run_index, benchmark.id, inject_fault?, :task_exit, reason, started_at)

      nil ->
        error_sample(
          run_index,
          benchmark.id,
          inject_fault?,
          :timeout,
          {:timeout_ms, timeout_ms},
          started_at
        )
    end
  end

  defp benchmark(run_index, inject_fault?) do
    Benchmark.new!(
      id: "runner_durability_#{run_index}",
      category: :operation,
      max_steps: 1,
      objective: """
      Confirm the seeded durability sentinel in /workspace without planner or
      model assistance. The deterministic checks simulate transient shell/exec
      faults on selected runs and must pass on retry.
      """,
      success_check: closure_check(),
      seed_files: seed_files(inject_fault?),
      recovery_checks: recovery_checks(inject_fault?)
    )
  end

  defp seed_files(inject_fault?) do
    base = [
      %{
        path: "ready.txt",
        content: "status=ready\n"
      },
      %{
        path: "README.md",
        content: """
        Runner durability sentinel.
        The harness verifies sandbox lifecycle cleanup and deterministic
        transient shell-fault recovery without using an LLM.
        """
      }
    ]

    if inject_fault? do
      base ++
        [
          %{path: "faults/closure", content: "fail the first closure exec\n"},
          %{path: "faults/recovery", content: "fail the first recovery exec\n"}
        ]
    else
      base
    end
  end

  defp closure_check do
    {:shell,
     """
     cd /workspace &&
     test -f ready.txt &&
     if test -f faults/closure; then rm -f faults/closure; exit 1; fi &&
     grep -q '^status=ready$' ready.txt
     """}
  end

  defp recovery_checks(false), do: []

  defp recovery_checks(true) do
    [
      %{
        id: "transient_exec_fault",
        description:
          "A seeded shell marker makes the first recovery check fail, then retry cleanly.",
        check: recovery_check()
      }
    ]
  end

  defp recovery_check do
    {:shell,
     """
     cd /workspace &&
     if test -f faults/recovery; then rm -f faults/recovery; exit 1; fi &&
     test -f ready.txt &&
     grep -q '^status=ready$' ready.txt
     """}
  end

  defp build_report(samples, baseline_orphans, final_orphans, runs, requested_faults) do
    recovery_events = Enum.flat_map(samples, &Map.get(&1, :recovery_events, []))
    injected_events = Enum.filter(recovery_events, &Map.get(&1, :injected, true))
    recovered_count = Enum.count(injected_events, &Map.get(&1, :recovered, false))
    injected_count = length(injected_events)
    recovery_rate = rate(recovered_count, injected_count)
    project_ids = samples |> Enum.map(&Map.get(&1, :project_id)) |> Enum.reject(&is_nil/1)
    harness_orphans = harness_orphan_names(project_ids, final_orphans.names)
    closed_count = Enum.count(samples, &Map.get(&1, :closed, false))
    ok_count = Enum.count(samples, &(Map.get(&1, :status) == :ok))

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      harness: "Mix.Tasks.Orchid.RunnerDurability",
      container_prefix: container_prefix(),
      n_goals: runs,
      requested_faults: requested_faults,
      successful_runs: ok_count,
      closed_count: closed_count,
      recovery_injected_count: injected_count,
      recovery_recovered_count: recovered_count,
      recovery_rate: recovery_rate,
      orphaned_count: final_orphans.count,
      orphaned_containers: final_orphans.names,
      baseline_orphaned_count: baseline_orphans.count,
      baseline_orphaned_containers: baseline_orphans.names,
      harness_created_orphaned_count: length(harness_orphans),
      harness_created_orphaned_containers: harness_orphans,
      score: %{
        unattended_depth: median(Enum.map(samples, &Map.get(&1, :depth, 0))),
        goal_closure: closed_count == runs,
        recovery_rate: recovery_rate
      },
      criteria: %{
        n_goals_at_least_20: runs >= 20,
        recovery_faults_at_least_3: injected_count >= 3,
        recovery_rate_at_least_0_9: recovery_rate >= 0.9,
        global_orphaned_count_zero: final_orphans.count == 0,
        harness_created_orphaned_count_zero: harness_orphans == []
      },
      samples: samples
    }
  end

  defp list_orphaned_containers do
    case System.cmd(
           "podman",
           ["ps", "-a", "--filter", "name=#{container_prefix()}", "--format", "{{.Names}}"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        names =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.starts_with?(&1, container_prefix()))
          |> Enum.sort()

        %{count: length(names), names: names, error: nil}

      {output, code} ->
        %{count: 0, names: [], error: "podman ps failed with #{code}: #{String.trim(output)}"}
    end
  end

  defp harness_orphan_names(project_ids, orphan_names) do
    project_ids
    |> Enum.map(&container_name/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
    |> then(fn created -> Enum.filter(orphan_names, &MapSet.member?(created, &1)) end)
  end

  defp encode_recovery_events(events) do
    Enum.map(events, fn event ->
      %{
        id: Map.get(event, :id),
        description: Map.get(event, :description),
        check: Map.get(event, :check),
        injected: Map.get(event, :injected, true),
        initial_passed: Map.get(event, :initial_passed),
        final_passed: Map.get(event, :final_passed),
        recovered: Map.get(event, :recovered, false),
        status: Map.get(event, :status)
      }
    end)
  end

  defp error_sample(run_index, benchmark_id, inject_fault?, status, reason, started_at) do
    %{
      run: run_index,
      benchmark_id: benchmark_id,
      injected: inject_fault?,
      status: status,
      closed: false,
      depth: 0,
      score: %{unattended_depth: 0, goal_closure: false, recovery_rate: 0.0},
      recovery_events: [],
      error: inspect(reason),
      duration_ms: monotonic_ms() - started_at
    }
  end

  defp fault_indices(_runs, 0), do: MapSet.new()

  defp fault_indices(runs, faults) do
    1..min(runs, faults)
    |> MapSet.new()
  end

  defp ensure_runtime_started! do
    case Runtime.ensure_started() do
      :ok -> :ok
      {:error, reason} -> Mix.raise("failed to start Orchid autonomy runtime: #{inspect(reason)}")
    end
  end

  defp format_exception(kind, reason, stacktrace) do
    kind
    |> Exception.format(reason, stacktrace)
    |> truncate(4_000)
  end

  defp reject_invalid_options!([]), do: :ok

  defp reject_invalid_options!(invalid) do
    options = invalid |> Enum.map_join(", ", fn {option, _value} -> option end)
    Mix.raise("Invalid orchid.runner_durability option(s): #{options}")
  end

  defp validate_positive_integer!(value, _flag) when is_integer(value) and value > 0, do: value

  defp validate_positive_integer!(value, flag),
    do: Mix.raise("#{flag} must be a positive integer, got: #{inspect(value)}")

  defp validate_non_negative_integer!(value, _flag) when is_integer(value) and value >= 0,
    do: value

  defp validate_non_negative_integer!(value, flag),
    do: Mix.raise("#{flag} must be a non-negative integer, got: #{inspect(value)}")

  defp validate_output_path!(path) when is_binary(path) do
    if String.trim(path) == "" do
      Mix.raise("--out must be a non-empty path")
    end

    path
  end

  defp validate_output_path!(path), do: Mix.raise("--out must be a path, got: #{inspect(path)}")

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    binary_part(text, 0, max) <> "..."
  end

  defp truncate(text, _max), do: text

  defp write_report!(report, output_path) do
    output_path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(output_path, Jason.encode!(report, pretty: true))
  end

  defp rate(_numerator, 0), do: 0.0
  defp rate(numerator, denominator), do: numerator / denominator

  defp median([]), do: 0

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

  defp container_prefix, do: Sandbox.container_name("")

  defp container_name(project_id) when is_binary(project_id),
    do: Sandbox.container_name(project_id)

  defp container_name(_project_id), do: nil
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
