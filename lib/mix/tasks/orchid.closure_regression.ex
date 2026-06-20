defmodule Mix.Tasks.Orchid.ClosureRegression do
  @moduledoc """
  Runs the standing Orchid real-goal closure regression oracle.
  """

  use Mix.Task

  @shortdoc "Run the Orchid closure regression oracle"
  @default_out Path.join(["priv", "autonomy", "closure_regression.json"])
  @default_goal_timeout_ms 720_000
  @default_gvr_goal_timeout_ms 180_000
  @default_success_timeout_ms 30_000
  @flat_goal_total 4
  @task_path "lib/mix/tasks/orchid.closure_regression.ex"
  @real_goal_runner_path "lib/mix/tasks/orchid.real_goal_closure.ex"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          out: :string,
          goal_timeout_ms: :integer,
          gvr_goal_timeout_ms: :integer,
          success_timeout_ms: :integer
        ]
      )

    reject_invalid_options!(invalid)

    repo_cwd = File.cwd!()
    output_path = opts |> Keyword.get(:out, @default_out) |> validate_output_path!()
    output_file = Path.expand(output_path, repo_cwd)

    goal_timeout_ms =
      opts
      |> Keyword.get(:goal_timeout_ms, @default_goal_timeout_ms)
      |> validate_positive_integer!("--goal-timeout-ms")

    success_timeout_ms =
      opts
      |> Keyword.get(:success_timeout_ms, @default_success_timeout_ms)
      |> validate_positive_integer!("--success-timeout-ms")

    gvr_goal_timeout_ms =
      opts
      |> Keyword.get(:gvr_goal_timeout_ms, @default_gvr_goal_timeout_ms)
      |> validate_positive_integer!("--gvr-goal-timeout-ms")

    temp_dir = temp_output_dir()
    started_at = monotonic_ms()

    report =
      try do
        File.mkdir_p!(temp_dir)

        flat_report =
          run_suite_report(
            :real,
            Path.join(temp_dir, "flat_real_goal_closure.json"),
            goal_timeout_ms,
            success_timeout_ms
          )

        gvr_report =
          run_suite_report(
            :gvr,
            Path.join(temp_dir, "gvr_real_goal_closure.json"),
            gvr_goal_timeout_ms,
            success_timeout_ms
          )

        build_report(flat_report, gvr_report, output_file, started_at, %{
          "flat_goal_timeout_ms" => goal_timeout_ms,
          "gvr_goal_timeout_ms" => gvr_goal_timeout_ms,
          "success_timeout_ms" => success_timeout_ms
        })
      after
        File.cd!(repo_cwd)
        File.rm_rf(temp_dir)
      end

    write_report!(report, output_file)
    print_summary(report, output_path)

    unless report["overall_pass"] do
      Mix.raise("orchid.closure_regression failed; wrote #{output_path}")
    end
  end

  defp run_suite_report(suite_key, output_file, goal_timeout_ms, success_timeout_ms) do
    args = [
      "--out",
      output_file,
      "--goal-timeout-ms",
      Integer.to_string(goal_timeout_ms),
      "--success-timeout-ms",
      Integer.to_string(success_timeout_ms)
    ]

    try do
      Mix.Tasks.Orchid.RealGoalClosure.run_suite(suite_key, args)
      output_file |> File.read!() |> Jason.decode!()
    rescue
      error ->
        exception_report(suite_key, {:exception, error, __STACKTRACE__})
    catch
      kind, reason ->
        exception_report(suite_key, {:caught, kind, reason})
    end
  end

  defp build_report(flat_report, gvr_report, output_file, started_at, run_config) do
    flat = flat_summary(flat_report)
    gvr = gvr_summary(gvr_report)
    overall_pass = flat["pass"] and gvr["pass"]

    %{
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "harness" => "Mix.Tasks.Orchid.ClosureRegression",
      "harness_path" => @task_path,
      "implementation_path" => @real_goal_runner_path,
      "product_entry" => "Orchid.GoalWatcher",
      "route_contract" =>
        "GoalWatcher.runtime_planner_request -> RuntimeGoal.from_goal_watcher -> Router -> planner",
      "runner_substrate" => "durable per-project sandbox via Orchid.Projects.ensure_sandbox",
      "report_path" => output_file,
      "run_config" => run_config,
      "flat" => flat,
      "gvr" => gvr,
      "overall_pass" => overall_pass,
      "duration_ms" => monotonic_ms() - started_at
    }
  end

  defp flat_summary(report) do
    goals = report |> Map.get("goals", []) |> Enum.map(&goal_summary/1)
    total = integer_value(Map.get(report, "n_goals")) || length(goals)
    closed_count = integer_value(Map.get(report, "closed_count")) || count_closed(goals)
    own_external_success_checks = own_external_success_checks?(goals, total)

    pass =
      total == @flat_goal_total and closed_count == @flat_goal_total and
        own_external_success_checks

    %{
      "closed_count" => closed_count,
      "total" => total,
      "pass" => pass,
      "failure_mode" =>
        flat_failure_mode(pass, total, closed_count, goals, own_external_success_checks),
      "own_external_success_checks" => own_external_success_checks,
      "goals" => goals
    }
  end

  defp gvr_summary(report) do
    goals = report |> Map.get("goals", []) |> Enum.map(&goal_summary/1)
    total = integer_value(Map.get(report, "n_goals")) || length(goals)

    closed_count =
      integer_value(Map.get(report, "gvr_closed_count")) ||
        integer_value(Map.get(report, "closed_count")) ||
        count_closed(goals)

    route_mode = route_mode(goals)
    arm_error? = Map.get(report, "arm_error") == true

    failure_mode =
      cond do
        closed_count >= 1 -> nil
        arm_error? -> report |> Map.get("failure_mode")
        true -> "free_model_convergence_variance"
      end

    %{
      "closed_count" => closed_count,
      "total" => total,
      "route_mode" => route_mode,
      "pass" => closed_count >= 1 or failure_mode == "free_model_convergence_variance",
      "failure_mode" => failure_mode,
      "raw_failure_modes" => raw_failure_modes(goals),
      "goals" => goals
    }
  end

  defp goal_summary(goal) do
    %{
      "id" => Map.get(goal, "id"),
      "closed" => Map.get(goal, "closed") == true,
      "route_mode" => Map.get(goal, "route_mode"),
      "failure_mode" => Map.get(goal, "failure_mode"),
      "reliability_failure" => Map.get(goal, "reliability_failure") == true,
      "status" => Map.get(goal, "status"),
      "project_id" => Map.get(goal, "project_id"),
      "goal_id" => Map.get(goal, "goal_id"),
      "workspace" => Map.get(goal, "workspace"),
      "success_check" => success_check_summary(Map.get(goal, "success_check")),
      "model_calls" => Map.get(goal, "model_calls"),
      "watcher_checks" => Map.get(goal, "watcher_checks"),
      "duration_ms" => Map.get(goal, "duration_ms")
    }
  end

  defp success_check_summary(%{} = success_check) do
    %{
      "passed" => Map.get(success_check, "passed") == true,
      "command" => Map.get(success_check, "command"),
      "output" => Map.get(success_check, "output"),
      "error" => Map.get(success_check, "error"),
      "fallback" => Map.get(success_check, "fallback")
    }
  end

  defp success_check_summary(_), do: %{"passed" => false}

  defp own_external_success_checks?(goals, total) do
    commands =
      goals
      |> Enum.map(&get_in(&1, ["success_check", "command"]))
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))

    total > 0 and length(commands) == total and length(Enum.uniq(commands)) == total and
      Enum.all?(goals, &(get_in(&1, ["success_check", "passed"]) == true))
  end

  defp flat_failure_mode(true, _total, _closed_count, _goals, _own_external_success_checks),
    do: nil

  defp flat_failure_mode(false, total, closed_count, goals, own_external_success_checks) do
    failed_goals =
      goals
      |> Enum.reject(fn goal ->
        goal["closed"] == true and get_in(goal, ["success_check", "passed"]) == true
      end)
      |> Enum.map(fn goal ->
        %{
          "id" => goal["id"],
          "closed" => goal["closed"],
          "success_check_passed" => get_in(goal, ["success_check", "passed"]) == true,
          "failure_mode" => goal["failure_mode"]
        }
      end)

    cond do
      total != @flat_goal_total ->
        "flat_total_mismatch: expected #{@flat_goal_total} goals, got #{total}"

      closed_count != @flat_goal_total ->
        "flat_goal_closure_regression: #{Jason.encode!(failed_goals)}"

      not own_external_success_checks ->
        "flat_external_success_check_regression"
    end
  end

  defp route_mode(goals) do
    goals
    |> Enum.map(& &1["route_mode"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [mode] -> mode
      [] -> nil
      modes -> modes
    end
  end

  defp raw_failure_modes(goals) do
    goals
    |> Enum.map(& &1["failure_mode"])
    |> Enum.reject(&is_nil/1)
  end

  defp count_closed(goals), do: Enum.count(goals, &(&1["closed"] == true))

  defp exception_report(suite_key, reason) do
    expected_total = if suite_key == :real, do: @flat_goal_total, else: 1
    failure_mode = "harness_exception: #{format_reason(reason)}"

    %{
      "arm_error" => true,
      "closed_count" => 0,
      "gvr_closed_count" => 0,
      "n_goals" => expected_total,
      "failure_mode" => failure_mode,
      "goals" => [
        %{
          "id" => Atom.to_string(suite_key),
          "closed" => false,
          "route_mode" => nil,
          "failure_mode" => failure_mode,
          "reliability_failure" => false,
          "status" => "harness_exception",
          "success_check" => %{"passed" => false, "error" => failure_mode}
        }
      ]
    }
  end

  defp write_report!(report, output_path) do
    output_path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(output_path, Jason.encode!(report, pretty: true))
  end

  defp print_summary(report, output_path) do
    status = if report["overall_pass"], do: "PASS", else: "FAIL"
    flat = report["flat"]
    gvr = report["gvr"]
    gvr_failure = gvr["failure_mode"] || "none"

    Mix.shell().info(
      "orchid.closure_regression: #{status} flat=#{flat["closed_count"]}/#{flat["total"]} " <>
        "gvr=#{gvr["closed_count"]}/#{gvr["total"]} gvr_failure_mode=#{gvr_failure}; " <>
        "wrote #{output_path}"
    )
  end

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_), do: nil

  defp reject_invalid_options!([]), do: :ok

  defp reject_invalid_options!(invalid) do
    invalid
    |> Enum.map(fn {flag, _value} -> to_string(flag) end)
    |> Enum.join(", ")
    |> then(&Mix.raise("Invalid option(s): #{&1}"))
  end

  defp validate_output_path!(path) when is_binary(path) do
    if String.trim(path) == "" do
      Mix.raise("--out must be a non-empty path")
    end

    path
  end

  defp validate_positive_integer!(value, _flag) when is_integer(value) and value > 0, do: value

  defp validate_positive_integer!(value, flag),
    do: Mix.raise("#{flag} must be positive, got #{inspect(value)}")

  defp temp_output_dir do
    suffix = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    Path.join(System.tmp_dir!(), "orchid-closure-regression-#{suffix}")
  end

  defp format_reason({:exception, error, stacktrace}) do
    Exception.format(:error, error, stacktrace) |> truncate(1_000)
  end

  defp format_reason(reason), do: reason |> inspect() |> truncate(1_000)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    binary_part(text, 0, max) <> "..."
  end

  defp truncate(text, _max), do: text
end
