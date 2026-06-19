defmodule Orchid.GptOssPlanfixDiagnosis.CapturingLLM do
  @moduledoc false

  def chat(config, context) do
    timed(:chat, config, context, fn clean_config ->
      Orchid.LLM.chat(clean_config, context)
    end)
  end

  def chat_stream(config, context, callback) do
    timed(:chat_stream, config, context, fn clean_config ->
      Orchid.LLM.chat_stream(clean_config, context, callback)
    end)
  end

  defp timed(kind, config, context, fun) do
    started_at = System.monotonic_time(:millisecond)
    result = fun.(clean_config(config))
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    record = %{
      "kind" => Atom.to_string(kind),
      "node" => planner_node(context),
      "model" => resolved_model(config),
      "elapsed_ms" => elapsed_ms,
      "elapsed_s" => Float.round(elapsed_ms / 1000, 3),
      "status" => call_status(result),
      "raw_output" => raw_output(result)
    }

    case Map.get(config, :diagnosis_owner) do
      owner when is_pid(owner) -> send(owner, {:orchid_gptoss_planfix_call, record})
      _ -> :ok
    end

    result
  end

  defp clean_config(config) do
    Map.drop(config, [:llm_module, :diagnosis_owner])
  end

  defp planner_node(%{system: system}) when is_binary(system) do
    cond do
      String.contains?(system, "Generator node") -> "generator"
      String.contains?(system, "Verifier node") -> "verifier"
      true -> "unknown"
    end
  end

  defp planner_node(_context), do: "unknown"

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

  defp raw_output({:ok, %{content: content}}) when is_binary(content), do: content
  defp raw_output({:error, reason}), do: inspect(reason, limit: 50)
  defp raw_output(other), do: inspect(other, limit: 50)
end

defmodule Orchid.GptOssPlanfixDiagnosis do
  @moduledoc false

  alias Orchid.Planner.{Generator, Verifier}

  @executed_command "mix run --no-start priv/smoke/gptoss_planfix_diagnosis.exs"
  @model "openai/gpt-oss-20b:free"

  @objective """
  Create /workspace/hello.sh as a POSIX shell script that prints exactly hello
  followed by a newline. Make it executable, run it, and stop only after it
  produces exactly hello.
  """

  def run do
    Logger.configure(level: :info)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "orchid-gptoss-planfix-diagnosis-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:orchid, :data_dir, data_dir)

    try do
      ensure_runtime!()
      ensure_facts!()

      IO.puts("ORCHID_GPTOSS_PLANFIX_DIAGNOSIS")
      IO.puts("EXECUTED_COMMAND=#{@executed_command}")
      IO.puts("RAN_UNDER_MIX_RUN_NO_START=#{not app_started?(:orchid)}")
      IO.puts("MODEL=#{@model}")
      IO.puts("PLAN_PROBE=num_paths=1 max_iterations=1 max_concurrency=1")

      result = run_plan_probe()
      calls = drain_calls()

      print_result(result, calls)
    after
      File.rm_rf(data_dir)
    end
  end

  defp run_plan_probe do
    opts = [
      num_paths: 1,
      max_iterations: 1,
      max_concurrency: 1,
      llm_memoize: false,
      llm_module: Orchid.GptOssPlanfixDiagnosis.CapturingLLM,
      generator_output_retry_attempts: 3,
      verifier_output_retry_attempts: 3,
      allowed_tools: ~w(shell read edit list grep task_report_result),
      workspace_context: "(workspace initially empty)",
      llm_config: %{
        provider: :openrouter,
        model: @model,
        disable_tools: true,
        max_turns: 1,
        max_tokens: 1_800,
        diagnosis_owner: self()
      }
    ]

    case Orchid.Planner.plan_tasks(@objective, nil, opts) do
      {:ok, tasks} ->
        %{valid?: true, task_count: length(tasks), tasks: tasks, error: nil}

      {:error, reason} ->
        %{valid?: false, task_count: 0, tasks: [], error: reason}
    end
  end

  defp print_result(result, calls) do
    generator_calls = Enum.filter(calls, &(&1["node"] == "generator"))
    verifier_calls = Enum.filter(calls, &(&1["node"] == "verifier"))

    IO.puts("PLAN_VALID=#{yes_no(result.valid?)}")
    IO.puts("PLAN_TASK_COUNT=#{result.task_count}")
    IO.puts("PLAN_ERROR=#{result.error || ""}")
    IO.puts("CALLS_OBSERVED=#{length(calls)}")
    IO.puts("AVG_S_PER_CALL=#{format_seconds(avg_seconds(calls))}")

    IO.puts("GENERATOR_RAW_OUTPUTS_JSON_BEGIN")
    IO.puts(Jason.encode!(Enum.map(generator_calls, &raw_call_json/1), pretty: true))
    IO.puts("GENERATOR_RAW_OUTPUTS_JSON_END")

    IO.puts("GENERATOR_PARSE_JSON_BEGIN")
    IO.puts(Jason.encode!(parse_generator_outputs(generator_calls), pretty: true))
    IO.puts("GENERATOR_PARSE_JSON_END")

    IO.puts("VERIFIER_RAW_OUTPUTS_JSON_BEGIN")
    IO.puts(Jason.encode!(Enum.map(verifier_calls, &raw_call_json/1), pretty: true))
    IO.puts("VERIFIER_RAW_OUTPUTS_JSON_END")

    IO.puts("VERIFIER_DECISIONS_JSON_BEGIN")
    IO.puts(Jason.encode!(parse_verifier_outputs(verifier_calls), pretty: true))
    IO.puts("VERIFIER_DECISIONS_JSON_END")
  end

  defp raw_call_json(call) do
    Map.take(call, ["elapsed_ms", "elapsed_s", "model", "node", "raw_output", "status"])
  end

  defp parse_generator_outputs(calls) do
    Enum.map(calls, fn call ->
      raw = Map.get(call, "raw_output", "")

      case Generator.parse_task_array(raw) do
        {:ok, tasks} ->
          %{
            "status" => "ok",
            "task_count" => length(tasks),
            "tasks" => Enum.map(tasks, &task_to_json/1)
          }

        {:error, reason} ->
          %{"status" => "error", "reason" => reason}
      end
    end)
  end

  defp parse_verifier_outputs(calls) do
    Enum.map(calls, fn call ->
      raw = Map.get(call, "raw_output", "")

      case Verifier.parse_decision(raw) do
        {:approved, reason} -> %{"status" => "approved", "reason" => reason}
        {:flawed, critique} -> %{"status" => "flawed", "critique" => critique}
        {:retry, reason} -> %{"status" => "retry", "reason" => reason}
      end
    end)
  end

  defp task_to_json(task) do
    base = %{
      "id" => Map.fetch!(task, :id),
      "type" => task |> Map.fetch!(:type) |> Atom.to_string(),
      "objective" => Map.fetch!(task, :objective)
    }

    if task[:type] == :tool do
      base
      |> Map.put("tool", Map.get(task, :tool))
      |> Map.put("args", Map.get(task, :args, %{}))
    else
      base
    end
  end

  defp ensure_runtime! do
    case Orchid.Autonomy.Runtime.ensure_started() do
      :ok -> :ok
      {:error, reason} -> raise "failed to start minimal runtime: #{inspect(reason)}"
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

  defp drain_calls(acc \\ []) do
    receive do
      {:orchid_gptoss_planfix_call, call} -> drain_calls([call | acc])
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

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"

  defp app_started?(app) do
    Application.started_applications()
    |> Enum.any?(fn {started_app, _description, _version} -> started_app == app end)
  end
end

Orchid.GptOssPlanfixDiagnosis.run()
