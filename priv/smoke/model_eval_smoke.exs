defmodule Orchid.ModelEvalSmoke.TimedLLM do
  @moduledoc false

  def chat(config, context) do
    timed(:chat, config, fn clean_config ->
      Orchid.LLM.chat(clean_config, context)
    end)
  end

  def chat_stream(config, context, callback) do
    timed(:chat_stream, config, fn clean_config ->
      Orchid.LLM.chat_stream(clean_config, context, callback)
    end)
  end

  defp timed(kind, config, fun) do
    started_at = System.monotonic_time(:millisecond)
    result = fun.(clean_config(config))
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    record = %{
      "kind" => Atom.to_string(kind),
      "phase" => config |> Map.get(:model_eval_phase, :unknown) |> to_string(),
      "model" => resolved_model(config),
      "elapsed_ms" => elapsed_ms,
      "elapsed_s" => Float.round(elapsed_ms / 1000, 3),
      "status" => call_status(result)
    }

    case Map.get(config, :model_eval_owner) do
      owner when is_pid(owner) -> send(owner, {:orchid_model_eval_call, record})
      _ -> :ok
    end

    result
  end

  defp clean_config(config) do
    Map.drop(config, [:llm_module, :model_eval_owner, :model_eval_phase])
  end

  defp resolved_model(config) do
    provider = Map.get(config, :provider, :openrouter)
    model = Map.get(config, :model)

    case Orchid.LLM.Catalog.resolve_model(model, provider) do
      nil -> inspect(model)
      resolved -> resolved
    end
  end

  defp call_status({:ok, %{content: content}}) when is_binary(content) do
    if String.trim(content) == "", do: "ok_empty", else: "ok"
  end

  defp call_status({:ok, _}), do: "ok"
  defp call_status({:error, {:api_error, status, _body}}), do: "error_api_#{status}"
  defp call_status({:error, reason}), do: "error_#{inspect(reason, limit: 10)}"
  defp call_status(other), do: inspect(other, limit: 10)
end

defmodule Orchid.ModelEvalSmoke do
  @moduledoc false

  alias Orchid.Autonomy.{Benchmark, Runner}

  @executed_command "mix run --no-start priv/smoke/model_eval_smoke.exs"
  @baseline_model "nex-agi/nex-n2-pro:free"
  @baseline_avg_s 95.0
  @success_command "test -x /workspace/hello.sh && [ \"$(/workspace/hello.sh)\" = \"hello\" ]"
  @candidates [
    "openai/gpt-oss-20b:free",
    "qwen/qwen3-next-80b-a3b-instruct:free"
  ]

  def run do
    Logger.configure(level: :info)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "orchid-model-eval-smoke-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:orchid, :data_dir, data_dir)

    try do
      ensure_runtime!()

      IO.puts("ORCHID_MODEL_EVAL_SMOKE")
      IO.puts("EXECUTED_COMMAND=#{@executed_command}")
      IO.puts("RAN_UNDER_MIX_RUN_NO_START=#{not app_started?(:orchid)}")
      IO.puts("RUNNER_MODE=flat")
      IO.puts("BASELINE_MODEL=#{@baseline_model}")
      IO.puts("BASELINE_AVG_S_PER_CALL=#{format_seconds(@baseline_avg_s)}")
      IO.puts("SUCCESS_CHECK=#{@success_command}")
      IO.puts("PLAN_PROBE=num_paths=1 max_iterations=1 max_concurrency=1")
      IO.puts("CANDIDATES=#{Enum.join(@candidates, ",")}")

      results = Enum.map(@candidates, &run_candidate/1)

      IO.puts("SUMMARY_JSON_BEGIN")
      IO.puts(Jason.encode!(results, pretty: true))
      IO.puts("SUMMARY_JSON_END")
      IO.puts("RECOMMENDATION=#{recommendation(results)}")
    after
      File.rm_rf(data_dir)
    end
  end

  defp run_candidate(model) do
    drain_calls()
    IO.puts("CANDIDATE_BEGIN=#{model}")

    {plan_result, plan_duration_ms} = timed(fn -> run_plan_probe(model) end)
    plan_calls = drain_calls()

    {closure_result, closure_duration_ms} = timed(fn -> run_closure(model) end)
    closure_calls = drain_calls()

    calls = plan_calls ++ closure_calls
    avg_s = avg_seconds(calls)
    plan_avg_s = avg_seconds(plan_calls)
    closure_avg_s = avg_seconds(closure_calls)

    result = %{
      "model" => model,
      "avg_s_per_call" => avg_s,
      "plan_avg_s_per_call" => plan_avg_s,
      "closure_avg_s_per_call" => closure_avg_s,
      "calls_observed" => length(calls),
      "plan_calls_observed" => length(plan_calls),
      "closure_calls_observed" => length(closure_calls),
      "plan_valid" => plan_result.valid?,
      "plan_task_count" => plan_result.task_count,
      "plan_error" => plan_result.error,
      "plan_duration_s" => Float.round(plan_duration_ms / 1000, 3),
      "closed" => closure_result.closed?,
      "success_check_passed" => closure_result.success_check_passed?,
      "closure_status" => closure_result.status,
      "closure_turn_result" => closure_result.turn_result,
      "closure_error" => closure_result.error,
      "closure_duration_s" => Float.round(closure_duration_ms / 1000, 3),
      "llm_calls" => calls
    }

    print_candidate_result(result)
    IO.puts("CANDIDATE_END=#{model}")
    result
  end

  defp run_plan_probe(model) do
    objective = """
    Create /workspace/hello.sh as a POSIX shell script that prints exactly hello
    followed by a newline. Make it executable, run it, and stop only after it
    produces exactly hello.
    """

    opts = [
      num_paths: 1,
      max_iterations: 1,
      max_concurrency: 1,
      llm_memoize: false,
      llm_module: Orchid.ModelEvalSmoke.TimedLLM,
      generator_output_retry_attempts: 3,
      verifier_output_retry_attempts: 3,
      allowed_tools: ~w(shell read edit list grep task_report_result),
      workspace_context: "(workspace initially empty)",
      llm_config: %{
        provider: :openrouter,
        model: model,
        disable_tools: true,
        max_turns: 1,
        max_tokens: 1_800,
        model_eval_owner: self(),
        model_eval_phase: :plan
      }
    ]

    case Orchid.Planner.plan_tasks(objective, nil, opts) do
      {:ok, tasks} ->
        %{valid?: true, task_count: length(tasks), error: nil}

      {:error, reason} ->
        %{valid?: false, task_count: 0, error: inspect(reason, limit: 20)}
    end
  end

  defp run_closure(model) do
    runner_opts = [
      mode: :flat,
      max_steps: benchmark().max_steps,
      wall_clock_timeout_ms: 240_000,
      success_timeout_ms: 30_000,
      agent_config: %{
        provider: :openrouter,
        model: model,
        llm_module: Orchid.ModelEvalSmoke.TimedLLM,
        model_eval_owner: self(),
        model_eval_phase: :closure
      }
    ]

    case Runner.run(benchmark(), runner_opts) do
      {:ok, result} ->
        %{
          closed?: Map.get(result, :closed, false),
          success_check_passed?: Map.get(result, :closed, false),
          status: result |> Map.get(:status) |> inspect(),
          turn_result: result |> Map.get(:turn_result) |> inspect(),
          error: result |> Map.get(:error) |> maybe_inspect()
        }

      {:error, reason} ->
        %{
          closed?: false,
          success_check_passed?: false,
          status: "error",
          turn_result: "error",
          error: inspect(reason, limit: 20)
        }
    end
  end

  defp benchmark do
    Benchmark.new!(
      id: "model_eval_hello_script",
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

  defp print_candidate_result(result) do
    IO.puts("MODEL=#{result["model"]}")
    IO.puts("AVG_S_PER_CALL=#{format_seconds(result["avg_s_per_call"])}")
    IO.puts("PLAN_AVG_S_PER_CALL=#{format_seconds(result["plan_avg_s_per_call"])}")
    IO.puts("CLOSURE_AVG_S_PER_CALL=#{format_seconds(result["closure_avg_s_per_call"])}")
    IO.puts("CALLS_OBSERVED=#{result["calls_observed"]}")
    IO.puts("PLAN_VALID=#{yes_no(result["plan_valid"])}")
    IO.puts("PLAN_TASK_COUNT=#{result["plan_task_count"]}")
    IO.puts("PLAN_ERROR=#{result["plan_error"] || ""}")
    IO.puts("CLOSED=#{yes_no(result["closed"])}")
    IO.puts("SUCCESS_CHECK_PASSED=#{yes_no(result["success_check_passed"])}")
    IO.puts("CLOSURE_STATUS=#{result["closure_status"]}")
    IO.puts("CLOSURE_TURN_RESULT=#{result["closure_turn_result"]}")
    IO.puts("CLOSURE_ERROR=#{result["closure_error"] || ""}")
  end

  defp recommendation(results) do
    winners =
      results
      |> Enum.filter(fn result ->
        result["plan_valid"] and result["closed"] and
          is_number(result["avg_s_per_call"]) and result["avg_s_per_call"] < @baseline_avg_s
      end)
      |> Enum.sort_by(& &1["avg_s_per_call"])

    case winners do
      [winner | _] ->
        "#{winner["model"]} unlocks free-tier at-scale; avg #{format_seconds(winner["avg_s_per_call"])}s/call vs #{@baseline_model} ~#{format_seconds(@baseline_avg_s)}s"

      [] ->
        "none faster-and-valid; paid model remains the gate"
    end
  end

  defp ensure_runtime! do
    case Orchid.Autonomy.Runtime.ensure_started() do
      :ok -> :ok
      {:error, reason} -> raise "failed to start minimal runtime: #{inspect(reason)}"
    end
  end

  defp timed(fun) when is_function(fun, 0) do
    started_at = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started_at}
  end

  defp drain_calls(acc \\ []) do
    receive do
      {:orchid_model_eval_call, call} -> drain_calls([call | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp avg_seconds([]), do: nil

  defp avg_seconds(calls) do
    total_ms = Enum.reduce(calls, 0, &(&1["elapsed_ms"] + &2))
    Float.round(total_ms / length(calls) / 1000, 3)
  end

  defp format_seconds(nil), do: "n/a"

  defp format_seconds(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)

  defp maybe_inspect(nil), do: nil
  defp maybe_inspect(value), do: inspect(value, limit: 20)

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"

  defp app_started?(app) do
    Application.started_applications()
    |> Enum.any?(fn {started_app, _description, _version} -> started_app == app end)
  end
end

Orchid.ModelEvalSmoke.run()
