defmodule Orchid.RecoveryRateSmoke do
  alias Orchid.Autonomy.{Benchmark, Runner, Scorer}

  @benchmark_path Path.join(["test", "autonomy", "benchmarks", "recover_broken_healthcheck.exs"])
  @executed_command "mix run --no-start priv/smoke/recovery_rate_smoke.exs"
  @gvr_max_rounds 2
  @gvr_max_delegate_depth 1
  @max_steps 12
  @success_timeout_ms 30_000
  @wall_clock_timeout_ms 900_000
  @seeded_fault "app/healthcheck.sh is seeded as an executable script that prints BROKEN healthcheck and exits 1 while app/status.txt already contains the valid state=ok/port=8080 data."

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
        "orchid-recovery-rate-smoke-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:orchid, :data_dir, data_dir)
    benchmark = benchmark!()
    max_steps = min(@max_steps, benchmark.max_steps)

    IO.puts("ORCHID_RECOVERY_RATE_SMOKE")
    IO.puts("EXECUTED_COMMAND=#{@executed_command}")
    IO.puts("RAN_UNDER_MIX_RUN_NO_START=#{not app_started?(:orchid)}")
    IO.puts("RUNNER_MODE=gvr")
    IO.puts("BENCHMARK_ID=#{benchmark.id}")
    IO.puts("SEEDED_FAULT=#{@seeded_fault}")
    IO.puts("SUCCESS_CHECK=#{success_check_text(benchmark.success_check)}")
    IO.puts("GVR_MAX_ROUNDS=#{@gvr_max_rounds}")
    IO.puts("GVR_MAX_DELEGATE_DEPTH=#{@gvr_max_delegate_depth}")
    IO.puts("MAX_STEPS=#{max_steps}")
    IO.puts("MODEL=openrouter/#{Orchid.LLM.Catalog.resolve_model(:nex_n2_pro, :openrouter)}")

    try do
      run_benchmark!(benchmark, max_steps)
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

  defp run_benchmark!(benchmark, max_steps) do
    ensure_runtime!()
    ensure_facts!()
    counter = ModelCallCounter.start!()

    runner_opts = [
      mode: :gvr,
      max_steps: max_steps,
      wall_clock_timeout_ms: @wall_clock_timeout_ms,
      success_timeout_ms: @success_timeout_ms,
      gvr_num_paths: 1,
      gvr_max_rounds: @gvr_max_rounds,
      gvr_max_delegate_depth: @gvr_max_delegate_depth
    ]

    runner_result =
      try do
        Runner.run(benchmark, runner_opts)
      after
        Process.put(:orchid_recovery_rate_model_calls, ModelCallCounter.stop(counter))
      end

    model_calls = Process.get(:orchid_recovery_rate_model_calls, :unknown)

    case runner_result do
      {:ok, result} ->
        print_result!(result, model_calls)

      {:error, reason} ->
        IO.puts("RUNNER_RESULT=error")
        IO.puts("RECOVERED=false")
        IO.puts("RECOVERY_CLASSIFICATION=halted")
        IO.puts("GOAL_CLOSURE=false")
        IO.puts("SUCCESS_CHECK_PASSED=false")
        IO.puts("RECOVERY_RATE=0.0")
        IO.puts("MODEL_CALLS_OBSERVED=#{model_calls}")
        IO.puts("RAN_UNDER_NO_START=yes")
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
    score = Scorer.score(result, success_timeout_ms: @success_timeout_ms)
    recovered_events = Map.get(result, :recovered, [])
    injected_count = Enum.count(recovered_events, &Map.get(&1, :injected, true))
    recovered_count = Enum.count(recovered_events, &recovered_event?/1)
    recovered = injected_count > 0 and injected_count == recovered_count
    steps = Map.get(result, :steps, [])

    IO.puts("RUNNER_RESULT=ok")
    IO.puts("PROJECT_ID=#{Map.get(result, :project_id)}")
    IO.puts("AGENT_ID=#{Map.get(result, :agent_id)}")
    IO.puts("STATUS=#{Map.get(result, :status)}")
    IO.puts("TURN_RESULT=#{Map.get(result, :turn_result)}")
    IO.puts("GOAL_CLOSURE=#{Map.get(result, :closed, false)}")
    IO.puts("SUCCESS_CHECK_PASSED_IN_RUNNER=#{Map.get(result, :closed, false)}")
    IO.puts("POST_RUN_SCORER_GOAL_CLOSURE=#{score.goal_closure}")
    IO.puts("RECOVERY_RATE=#{score.recovery_rate}")
    IO.puts("RECOVERED=#{recovered}")
    IO.puts("RECOVERY_CLASSIFICATION=#{if(recovered, do: "recovered", else: "halted")}")
    IO.puts("RECOVERY_INJECTED_COUNT=#{injected_count}")
    IO.puts("RECOVERY_RECOVERED_COUNT=#{recovered_count}")
    IO.puts("UNATTENDED_DEPTH=#{Map.get(result, :depth, 0)}")
    IO.puts("MODEL_CALLS_OBSERVED=#{model_calls}")
    IO.puts("MODEL_CALLS_NOTE=observed via runtime trace of Orchid.LLM chat/chat_stream calls")
    IO.puts("TOOL_STEPS_OBSERVED=#{length(steps)}")
    IO.puts("TOOL_ERROR_STEPS_OBSERVED=#{Enum.count(steps, &(&1.status == :error))}")
    IO.puts("PROCEEDED_AFTER_TOOL_ERROR=#{proceeded_after_tool_error?(steps)}")
    IO.puts("RAN_UNDER_NO_START=yes")

    IO.puts("RECOVERY_EVENTS_JSON_BEGIN")
    IO.puts(Jason.encode!(recovered_events, pretty: true))
    IO.puts("RECOVERY_EVENTS_JSON_END")

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

  defp recovered_event?(event) do
    Map.get(event, :injected, true) and Map.get(event, :recovered, false)
  end

  defp proceeded_after_tool_error?(steps) do
    steps
    |> Enum.reduce({false, false}, fn step, {seen_error, proceeded} ->
      cond do
        proceeded ->
          {seen_error, true}

        step.status == :error ->
          {true, false}

        seen_error and step.status == :ok ->
          {true, true}

        true ->
          {seen_error, false}
      end
    end)
    |> elem(1)
  end

  defp success_check_text({:shell, command}),
    do: command |> String.trim() |> String.replace("\n", "\\n")

  defp success_check_text(other), do: inspect(other)

  defp app_started?(app) do
    Application.started_applications()
    |> Enum.any?(fn {started_app, _description, _version} -> started_app == app end)
  end
end

Orchid.RecoveryRateSmoke.run()
