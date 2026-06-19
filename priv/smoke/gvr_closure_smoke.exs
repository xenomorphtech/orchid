defmodule Orchid.GVRClosureSmoke do
  alias Orchid.Autonomy.{Benchmark, Runner, Scorer}

  @benchmark_path Path.join(["test", "autonomy", "benchmarks", "garden_path_diagnosis.exs"])
  @executed_command "mix run --no-start priv/smoke/gvr_closure_smoke.exs"
  @gvr_max_rounds 1
  @gvr_max_delegate_depth 1
  @success_timeout_ms 30_000

  defmodule ModelCallCounter do
    @patterns [
      {Orchid.LLM, :chat, 2},
      {Orchid.LLM, :chat_stream, 3}
    ]

    def start! do
      pid = spawn_link(fn -> loop(0) end)

      for pattern <- @patterns do
        pattern |> elem(0) |> Code.ensure_loaded!()
        :erlang.trace_pattern(pattern, true, [:global])
      end

      :erlang.trace(:all, true, [:call, {:tracer, pid}])
      :erlang.trace(:new, true, [:call, {:tracer, pid}])
      pid
    end

    def stop(pid) when is_pid(pid) do
      :erlang.trace(:all, false, [:call])
      :erlang.trace(:new, false, [:call])

      for pattern <- @patterns do
        :erlang.trace_pattern(pattern, false, [:global])
      end

      count = count(pid)
      send(pid, :stop)
      count
    end

    defp count(pid) do
      ref = make_ref()
      send(pid, {:count, self(), ref})

      receive do
        {:count, ^ref, count} -> count
      after
        1_000 -> :unknown
      end
    end

    defp loop(count) do
      receive do
        {:trace, _pid, :call, {Orchid.LLM, :chat, _args}} ->
          loop(count + 1)

        {:trace, _pid, :call, {Orchid.LLM, :chat_stream, _args}} ->
          loop(count + 1)

        {:count, from, ref} ->
          send(from, {:count, ref, count})
          loop(count)

        :stop ->
          :ok

        _other ->
          loop(count)
      end
    end
  end

  def run do
    Logger.configure(level: :info)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "orchid-gvr-closure-smoke-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:orchid, :data_dir, data_dir)
    benchmark = benchmark!()

    IO.puts("ORCHID_GVR_CLOSURE_SMOKE")
    IO.puts("EXECUTED_COMMAND=#{@executed_command}")
    IO.puts("RAN_UNDER_MIX_RUN_NO_START=#{not app_started?(:orchid)}")
    IO.puts("RUNNER_MODE=gvr")
    IO.puts("BENCHMARK_ID=#{benchmark.id}")
    IO.puts("GVR_MAX_ROUNDS=#{@gvr_max_rounds}")
    IO.puts("GVR_MAX_DELEGATE_DEPTH=#{@gvr_max_delegate_depth}")
    IO.puts("SUCCESS_CHECK=#{success_check_text(benchmark.success_check)}")

    try do
      run_benchmark!(benchmark)
    after
      File.rm_rf(data_dir)
    end
  end

  defp benchmark! do
    case Code.eval_file(@benchmark_path) do
      {%Benchmark{} = benchmark, _binding} ->
        benchmark

      {attrs, _binding} when is_map(attrs) or is_list(attrs) ->
        Benchmark.new!(attrs)

      {other, _binding} ->
        raise "benchmark #{@benchmark_path} returned #{inspect(other)}, expected #{inspect(Benchmark)}"
    end
  end

  defp run_benchmark!(benchmark) do
    ensure_runtime!()
    ensure_facts!()
    counter = ModelCallCounter.start!()

    runner_opts = [
      mode: :gvr,
      max_steps: benchmark.max_steps,
      wall_clock_timeout_ms: 420_000,
      success_timeout_ms: @success_timeout_ms,
      gvr_num_paths: 1,
      gvr_max_rounds: @gvr_max_rounds,
      gvr_max_delegate_depth: @gvr_max_delegate_depth
    ]

    runner_result =
      try do
        Runner.run(benchmark, runner_opts)
      after
        Process.put(:orchid_gvr_model_calls, ModelCallCounter.stop(counter))
      end

    model_calls = Process.get(:orchid_gvr_model_calls, :unknown)

    case runner_result do
      {:ok, result} ->
        print_result!(result, model_calls)

      {:error, reason} ->
        IO.puts("RUNNER_RESULT=error")
        IO.puts("GOAL_CLOSURE=false")
        IO.puts("SUCCESS_CHECK_PASSED=false")
        IO.puts("MODEL_CALLS_OBSERVED=#{model_calls}")
        IO.puts("BLOCKER=#{inspect(reason)}")
        System.halt(2)
    end
  end

  defp ensure_runtime! do
    case Orchid.Autonomy.Runtime.ensure_started() do
      :ok -> :ok
      {:error, reason} -> raise "failed to start autonomy runtime: #{inspect(reason)}"
    end
  end

  defp ensure_facts! do
    case Orchid.Facts.seed_from_local_file() do
      {:ok, %{missing: true, path: path}} ->
        raise "facts source missing at #{path}"

      {:ok, %{error: error, path: path}} ->
        raise "failed to seed facts from #{path}: #{inspect(error)}"

      {:ok, stats} ->
        IO.puts(
          "FACTS_SEEDED path=#{stats.path} created=#{stats.created} updated=#{stats.updated} skipped=#{stats.skipped}"
        )
    end
  end

  defp print_result!(result, model_calls) do
    post_run_score = Scorer.score(result, success_timeout_ms: @success_timeout_ms)
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
    IO.puts("MODEL_CALLS_OBSERVED=#{model_calls}")
    IO.puts("TOOL_STEPS_OBSERVED=#{length(steps)}")

    IO.puts("MODEL_CALLS_NOTE=observed via runtime trace of Orchid.LLM chat/chat_stream calls")

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

  defp success_check_text({:shell, command}),
    do: command |> String.trim() |> String.replace("\n", "\\n")

  defp success_check_text(other), do: inspect(other)

  defp app_started?(app) do
    Application.started_applications()
    |> Enum.any?(fn {started_app, _description, _version} -> started_app == app end)
  end
end

Orchid.GVRClosureSmoke.run()
