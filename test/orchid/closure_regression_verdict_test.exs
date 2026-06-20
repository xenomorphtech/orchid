defmodule Mix.Tasks.Orchid.ClosureRegressionVerdictTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Orchid.ClosureRegression

  test "flat summary requires exactly four closed goals with own external success checks" do
    passing = ClosureRegression.flat_summary(flat_report())

    assert passing["pass"]
    assert passing["closed_count"] == 4
    assert passing["total"] == 4
    assert passing["own_external_success_checks"]
    assert passing["failure_mode"] == nil

    one_open = ClosureRegression.flat_summary(flat_report(closed_count: 3))

    refute one_open["pass"]
    assert one_open["closed_count"] == 3
    assert one_open["total"] == 4
    assert one_open["own_external_success_checks"]
    assert one_open["failure_mode"] =~ "flat_goal_closure_regression"

    bad_external_check =
      ClosureRegression.flat_summary(flat_report(bad_external_success_check?: true))

    refute bad_external_check["pass"]
    assert bad_external_check["closed_count"] == 4
    assert bad_external_check["total"] == 4
    refute bad_external_check["own_external_success_checks"]
    assert bad_external_check["failure_mode"] == "flat_external_success_check_regression"

    wrong_total = ClosureRegression.flat_summary(flat_report(total: 3, closed_count: 3))

    refute wrong_total["pass"]
    assert wrong_total["closed_count"] == 3
    assert wrong_total["total"] == 3
    assert wrong_total["own_external_success_checks"]
    assert wrong_total["failure_mode"] == "flat_total_mismatch: expected 4 goals, got 3"
  end

  test "gvr summary tolerates convergence variance but not genuine arm errors" do
    convergence_variance =
      ClosureRegression.gvr_summary(
        gvr_report(closed_count: 0, failure_mode: "free_model_convergence_variance")
      )

    assert convergence_variance["pass"]
    assert convergence_variance["closed_count"] == 0
    assert convergence_variance["failure_mode"] == "free_model_convergence_variance"

    closed = ClosureRegression.gvr_summary(gvr_report(closed_count: 1))

    assert closed["pass"]
    assert closed["closed_count"] == 1
    assert closed["failure_mode"] == nil

    arm_error =
      ClosureRegression.gvr_summary(
        gvr_report(
          closed_count: 0,
          arm_error: true,
          failure_mode: "harness_exception: planner crashed"
        )
      )

    refute arm_error["pass"]
    assert arm_error["closed_count"] == 0
    assert arm_error["failure_mode"] == "harness_exception: planner crashed"
  end

  test "overall pass is the flat and gvr verdict conjunction" do
    assert overall_pass?(flat_report(), gvr_report(closed_count: 1))

    refute overall_pass?(flat_report(closed_count: 3), gvr_report(closed_count: 1))

    refute overall_pass?(
             flat_report(),
             gvr_report(
               closed_count: 0,
               arm_error: true,
               failure_mode: "harness_exception: planner crashed"
             )
           )
  end

  defp overall_pass?(flat_report, gvr_report) do
    report =
      ClosureRegression.build_report(
        flat_report,
        gvr_report,
        "/tmp/orchid-closure-regression-verdict-test.json",
        System.monotonic_time(:millisecond),
        %{
          "flat_goal_timeout_ms" => 1,
          "gvr_goal_timeout_ms" => 1,
          "success_timeout_ms" => 1
        }
      )

    report["overall_pass"]
  end

  defp flat_report(opts \\ []) do
    total = Keyword.get(opts, :total, 4)
    closed_count = Keyword.get(opts, :closed_count, total)
    bad_external_success_check? = Keyword.get(opts, :bad_external_success_check?, false)

    goals =
      Enum.map(1..total, fn index ->
        closed? = index <= closed_count
        success_check_passed? = not (bad_external_success_check? and index == 1)

        goal("flat-#{index}", closed?, "external-check-#{index}", success_check_passed?)
      end)

    %{
      "n_goals" => total,
      "closed_count" => closed_count,
      "reliability_retry_policy" => %{"max_retries" => 2},
      "goals" => goals
    }
  end

  defp gvr_report(opts) do
    closed_count = Keyword.get(opts, :closed_count, 0)
    arm_error? = Keyword.get(opts, :arm_error, false)
    failure_mode = Keyword.get(opts, :failure_mode)

    %{
      "n_goals" => 1,
      "closed_count" => closed_count,
      "gvr_closed_count" => closed_count,
      "arm_error" => arm_error?,
      "failure_mode" => failure_mode,
      "goals" => [
        goal(
          "gvr-1",
          closed_count >= 1,
          "gvr-external-check",
          closed_count >= 1,
          "gvr",
          failure_mode
        )
      ]
    }
  end

  defp goal(
         id,
         closed?,
         success_check_command,
         success_check_passed?,
         route_mode \\ "flat",
         failure_mode \\ nil
       ) do
    %{
      "id" => id,
      "closed" => closed?,
      "route_mode" => route_mode,
      "failure_mode" => failure_mode,
      "reliability_failure" => false,
      "status" => if(closed?, do: "closed", else: "open"),
      "attempts_used" => 1,
      "reliability_retry_limit" => 2,
      "retried" => false,
      "attempts" => [],
      "project_id" => "project-#{id}",
      "goal_id" => "goal-#{id}",
      "workspace" => "/tmp/#{id}",
      "success_check" => %{
        "passed" => success_check_passed?,
        "command" => success_check_command,
        "output" => if(success_check_passed?, do: "ok", else: nil),
        "error" => if(success_check_passed?, do: nil, else: "missing expected marker")
      },
      "model_calls" => 0,
      "watcher_checks" => 1,
      "duration_ms" => 1
    }
  end
end
