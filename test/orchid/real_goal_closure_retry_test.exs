defmodule Mix.Tasks.Orchid.RealGoalClosure.ReliabilityRetryTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Orchid.RealGoalClosure.ReliabilityRetry

  test "classifier marks reliability flakes but not genuine goal failures" do
    assert ReliabilityRetry.reliability_failure?(
             "reliability_flake: OpenRouter API error 429 quota exceeded"
           )

    assert ReliabilityRetry.reliability_failure?("empty response from model")
    assert ReliabilityRetry.reliability_failure?("no such container: orchid-worker")
    assert ReliabilityRetry.reliability_failure?("timed out starting orchid mcp bridge")

    refute ReliabilityRetry.reliability_failure?(nil)
    refute ReliabilityRetry.reliability_failure?("goal_not_closed: wrote the wrong marker file")

    refute ReliabilityRetry.reliability_failure?(
             "timeout_no_external_success: child goal completed but success check still failed"
           )
  end

  test "retry predicate is gated by open reliability failures" do
    assert ReliabilityRetry.should_retry?(%{closed: false, reliability_failure: true}, 1)

    refute ReliabilityRetry.should_retry?(%{closed: true, reliability_failure: true}, 1)
    refute ReliabilityRetry.should_retry?(%{closed: false, reliability_failure: true}, 0)

    refute ReliabilityRetry.should_retry?(%{closed: false, reliability_failure: false}, 2)
  end

  test "transient reliability flakes are absorbed within max retries" do
    result =
      run_sequence(
        [
          reliability_flake("not_found"),
          reliability_flake("timeout"),
          closed_result()
        ],
        2
      )

    assert result.closed
    assert result.attempts_used == 3
    assert result.reliability_retry_limit == 2
    assert result.retried
    assert Enum.map(result.attempts, & &1.attempt) == [1, 2, 3]
    assert Enum.map(result.attempts, & &1.closed) == [false, false, true]
    assert Enum.map(result.attempts, & &1.reliability_failure) == [true, true, false]
  end

  test "persistent reliability flakes stop at the retry bound" do
    result =
      run_sequence(
        [
          reliability_flake("first"),
          reliability_flake("second"),
          reliability_flake("persistent")
        ],
        2
      )

    refute result.closed
    assert result.attempts_used == 3
    assert result.reliability_retry_limit == 2
    assert result.retried
    assert result.reliability_failure
    assert result.failure_mode == "reliability_flake: persistent"
  end

  test "genuine failures are not retried" do
    result = run_sequence([genuine_failure(), closed_result()], 2)

    refute result.closed
    refute result.reliability_failure
    assert result.attempts_used == 1
    assert result.reliability_retry_limit == 2
    refute result.retried
    assert [%{attempt: 1, closed: false, reliability_failure: false}] = result.attempts
    assert result.failure_mode == "goal_not_closed: wrong file contents"
  end

  defp run_sequence(results, max_retries) do
    {:ok, agent} = Agent.start_link(fn -> results end)

    try do
      ReliabilityRetry.run(
        fn ->
          Agent.get_and_update(agent, fn
            [result | remaining] -> {result, remaining}
            [] -> raise "retry runner requested more attempts than the test provided"
          end)
        end,
        max_retries,
        &attempt_summary/1
      )
    after
      Agent.stop(agent)
    end
  end

  defp reliability_flake(label) do
    result(%{
      closed: false,
      failure_mode: "reliability_flake: #{label}",
      reliability_failure: true,
      status: :timeout
    })
  end

  defp genuine_failure do
    result(%{
      closed: false,
      failure_mode: "goal_not_closed: wrong file contents",
      reliability_failure: false,
      status: :timeout
    })
  end

  defp closed_result do
    result(%{
      closed: true,
      failure_mode: nil,
      reliability_failure: false,
      status: :ok
    })
  end

  defp result(attrs) do
    Map.merge(
      %{
        id: "retry-unit-test",
        route_mode: :auto,
        nudges: 0,
        project_id: "project-1",
        goal_id: "goal-1",
        workspace: "/tmp/retry-unit-test",
        model_calls: 0,
        watcher_checks: 1,
        duration_ms: 1
      },
      attrs
    )
  end

  defp attempt_summary(result) do
    Map.take(result, [
      :closed,
      :nudges,
      :failure_mode,
      :reliability_failure,
      :route_mode,
      :status,
      :attempts_used,
      :reliability_retry_limit,
      :retried,
      :project_id,
      :goal_id,
      :workspace,
      :model_calls,
      :watcher_checks,
      :duration_ms
    ])
  end
end
