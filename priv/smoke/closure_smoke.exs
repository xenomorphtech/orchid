defmodule Orchid.ClosureSmoke do
  alias Orchid.Autonomy.{Benchmark, Runner, Scorer}

  @executed_command "mix run --no-start priv/smoke/closure_smoke.exs"
  @success_command "test -x /workspace/hello.sh && [ \"$(/workspace/hello.sh)\" = \"hello\" ]"

  def run do
    Logger.configure(level: :info)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "orchid-closure-smoke-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:orchid, :data_dir, data_dir)

    benchmark = benchmark()

    IO.puts("ORCHID_CLOSURE_SMOKE")
    IO.puts("EXECUTED_COMMAND=#{@executed_command}")
    IO.puts("RAN_UNDER_MIX_RUN_NO_START=#{not app_started?(:orchid)}")
    IO.puts("RUNNER_MODE=flat")
    IO.puts("BENCHMARK_ID=#{benchmark.id}")
    IO.puts("SUCCESS_CHECK=#{@success_command}")

    try do
      run_benchmark!(benchmark)
    after
      File.rm_rf(data_dir)
    end
  end

  defp benchmark do
    Benchmark.new!(
      id: "closure_smoke_hello_script",
      category: :development,
      max_steps: 3,
      objective: """
      Create /workspace/hello.sh as a POSIX shell script that prints exactly hello
      followed by a newline. Make it executable, run it, and stop only after it
      produces exactly hello.
      """,
      success_check: {:shell, @success_command}
    )
  end

  defp run_benchmark!(benchmark) do
    runner_opts = [
      mode: :flat,
      max_steps: benchmark.max_steps,
      wall_clock_timeout_ms: 240_000,
      success_timeout_ms: 30_000
    ]

    case Runner.run(benchmark, runner_opts) do
      {:ok, result} ->
        print_result!(result)

      {:error, reason} ->
        IO.puts("RUNNER_RESULT=error")
        IO.puts("GOAL_CLOSURE=false")
        IO.puts("SUCCESS_CHECK_PASSED=false")
        IO.puts("MODEL_CALLS_OBSERVED=0")
        IO.puts("BLOCKER=#{inspect(reason)}")
        System.halt(2)
    end
  end

  defp print_result!(result) do
    post_run_score = Scorer.score(result, success_timeout_ms: 30_000)
    closed = Map.get(result, :closed, false)
    steps = Map.get(result, :steps, [])

    IO.puts("RUNNER_RESULT=ok")
    IO.puts("PROJECT_ID=#{Map.get(result, :project_id)}")
    IO.puts("AGENT_ID=#{Map.get(result, :agent_id)}")
    IO.puts("STATUS=#{Map.get(result, :status)}")
    IO.puts("TURN_RESULT=#{Map.get(result, :turn_result)}")
    IO.puts("GOAL_CLOSURE=#{closed}")
    IO.puts("SUCCESS_CHECK_PASSED_IN_RUNNER=#{closed}")
    IO.puts("POST_RUN_SCORER_GOAL_CLOSURE=#{post_run_score.goal_closure}")
    IO.puts("UNATTENDED_DEPTH=#{Map.get(result, :depth, 0)}")
    IO.puts("MODEL_CALLS_OBSERVED=#{estimate_model_calls(result)}")

    IO.puts(
      "MODEL_CALLS_NOTE=estimated from recorded tool loop; count OpenRouter streaming log lines for exact retries"
    )

    if closed and not post_run_score.goal_closure do
      IO.puts(
        "PRODUCT_BUG=Runner.run/2 cleans up the sandbox before caller-side Scorer.score/2 can rerun the success_check"
      )
    end

    IO.puts("STEPS_JSON_BEGIN")
    IO.puts(Jason.encode!(steps, pretty: true))
    IO.puts("STEPS_JSON_END")

    case Map.get(result, :last_assistant_message) do
      message when is_binary(message) and message != "" ->
        IO.puts("LAST_ASSISTANT_MESSAGE_BEGIN")
        IO.puts(message)
        IO.puts("LAST_ASSISTANT_MESSAGE_END")

      _ ->
        :ok
    end
  end

  defp estimate_model_calls(result) do
    steps = Map.get(result, :steps, [])

    cond do
      steps == [] -> 1
      true -> length(steps) + 1
    end
  end

  defp app_started?(app) do
    Application.started_applications()
    |> Enum.any?(fn {started_app, _description, _version} -> started_app == app end)
  end
end

Orchid.ClosureSmoke.run()
