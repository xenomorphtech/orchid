defmodule Orchid.Autonomy.Runner do
  @moduledoc """
  Unattended benchmark runner for the autonomy metric suite.

  The runner owns the future end-to-end flow:

    * create or reset a sandboxed project for a benchmark
    * create an agent with interventions disabled
    * drive the benchmark objective until closure, stall, or `max_steps`
    * return a deterministic run result for the scorer
  """

  alias Orchid.Autonomy.{Benchmark, Runtime, Scorer}
  alias Orchid.{Agent, Goals, Object, Projects, Sandbox}

  @type step :: %{
          optional(:index) => non_neg_integer(),
          optional(:status) => atom(),
          optional(:tool) => String.t(),
          optional(:args) => map(),
          optional(:summary) => String.t(),
          optional(:timestamp) => String.t()
        }

  @type recovery_event :: %{
          optional(:step) => non_neg_integer(),
          optional(:status) => atom(),
          optional(:reason) => term(),
          optional(:recovered) => boolean()
        }

  @type run_result :: %{
          required(:benchmark) => Benchmark.t(),
          required(:project_id) => String.t() | nil,
          required(:depth) => non_neg_integer(),
          required(:closed) => boolean(),
          required(:recovered) => [recovery_event()],
          required(:steps) => [step()],
          optional(:agent_id) => String.t(),
          optional(:goal_id) => String.t(),
          optional(:status) => atom(),
          optional(:turn_result) => :ok | :error | :timeout,
          optional(:last_assistant_message) => String.t() | nil,
          optional(:error) => term()
        }

  @type option ::
          {:project_id, String.t()}
          | {:agent_config, map()}
          | {:max_steps, pos_integer()}
          | {:wall_clock_timeout_ms, pos_integer()}
          | {:success_timeout_ms, pos_integer()}

  @default_wall_clock_timeout_ms 360_000
  @default_success_timeout_ms 120_000
  @agent_tools ~w(shell read edit list grep task_report_result)

  @doc """
  Run a benchmark unattended.
  """
  @spec run(Benchmark.t(), [option()]) :: {:ok, run_result()} | {:error, term()}
  def run(%Benchmark{} = benchmark, opts \\ []) when is_list(opts) do
    max_steps = Keyword.get(opts, :max_steps, benchmark.max_steps)

    with :ok <- validate_max_steps(max_steps),
         :ok <- Runtime.ensure_started(),
         {:ok, project} <- ensure_project(benchmark, opts),
         :ok <- ensure_sandbox(project.id),
         {:ok, agent_id} <- Agent.create(agent_config(benchmark, project.id, opts)),
         {:ok, goal} <- create_goal(benchmark, project.id),
         {:ok, result} <-
           run_assigned_goal(benchmark, project.id, goal, agent_id, max_steps, opts) do
      {:ok, result}
    end
  end

  @doc """
  Stop runtime resources associated with a run result.
  """
  @spec cleanup(run_result()) :: :ok
  def cleanup(%{project_id: project_id}) when is_binary(project_id) do
    Projects.stop_sandbox(project_id)
    :ok
  end

  def cleanup(_run_result), do: :ok

  defp validate_max_steps(max_steps) when is_integer(max_steps) and max_steps > 0, do: :ok
  defp validate_max_steps(max_steps), do: {:error, {:invalid_max_steps, max_steps}}

  defp ensure_project(%Benchmark{} = benchmark, opts) do
    case Keyword.get(opts, :project_id) do
      project_id when is_binary(project_id) ->
        Object.get(project_id)

      _ ->
        Projects.create(%{
          name: "Autonomy benchmark: #{benchmark.id} #{timestamp_id()}",
          objective: benchmark.objective,
          success_criteria: success_check_text(benchmark.success_check),
          constraints: "Run unattended in the sandbox. Do not ask for human help.",
          background: "Autonomy metric benchmark #{benchmark.id}.",
          relevant_paths: [],
          kickoff_goal: "",
          default_execution_mode: :vm
        })
    end
  end

  defp ensure_sandbox(project_id) do
    with {:ok, _} <- Projects.ensure_sandbox(project_id) do
      wait_for_sandbox(project_id, 120_000)
    end
  end

  defp wait_for_sandbox(project_id, timeout_ms) do
    deadline = monotonic_ms() + timeout_ms
    do_wait_for_sandbox(project_id, deadline)
  end

  defp do_wait_for_sandbox(project_id, deadline) do
    cond do
      Sandbox.healthy?(project_id) ->
        :ok

      monotonic_ms() >= deadline ->
        {:error, {:sandbox_not_ready, Sandbox.status(project_id)}}

      true ->
        Process.sleep(1_000)
        do_wait_for_sandbox(project_id, deadline)
    end
  end

  defp agent_config(benchmark, project_id, opts) do
    %{
      project_id: project_id,
      execution_mode: :vm,
      provider: :openrouter,
      model: :nex_n2_pro,
      intervention: :disabled,
      allowed_tools: @agent_tools,
      system_prompt: system_prompt(benchmark)
    }
    |> maybe_put_openrouter_api_key()
    |> Map.merge(Keyword.get(opts, :agent_config, %{}))
  end

  defp maybe_put_openrouter_api_key(config) do
    case System.get_env("OPENROUTER_API_KEY") do
      key when is_binary(key) and key != "" -> Map.put_new(config, :api_key, key)
      _ -> config
    end
  end

  defp create_goal(benchmark, project_id) do
    Goals.create("Autonomy benchmark: #{benchmark.id}", goal_description(benchmark), project_id)
  end

  defp run_assigned_goal(benchmark, project_id, goal, agent_id, max_steps, opts) do
    started_at = monotonic_ms()

    try do
      with :ok <- assign_goal(goal.id, agent_id) do
        turn_result = run_agent_turn(agent_id, goal_message(goal), opts)
        agent_state = fetch_agent_state(agent_id)

        result =
          build_result(
            benchmark,
            project_id,
            goal.id,
            agent_id,
            agent_state,
            turn_result,
            max_steps,
            opts,
            started_at
          )

        finalize_goal(goal.id, result)
        {:ok, result}
      end
    after
      stop_agent(agent_id)
    end
  end

  defp assign_goal(goal_id, agent_id) do
    case Object.update_metadata(goal_id, %{agent_id: agent_id}) do
      {:ok, _goal} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_agent_turn(agent_id, message, opts) do
    timeout = Keyword.get(opts, :wall_clock_timeout_ms, @default_wall_clock_timeout_ms)

    task =
      Task.async(fn ->
        Agent.stream(agent_id, message, fn _chunk -> :ok end)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, _response} = ok} -> ok
      {:ok, {:error, _reason} = error} -> error
      {:exit, reason} -> {:error, {:agent_task_exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp fetch_agent_state(agent_id) do
    case Agent.get_state(agent_id, 2_000) do
      {:ok, state} -> state
      {:error, _reason} -> nil
    end
  end

  defp build_result(
         benchmark,
         project_id,
         goal_id,
         agent_id,
         agent_state,
         turn_result,
         max_steps,
         opts,
         started_at
       ) do
    steps =
      agent_state
      |> tool_history()
      |> Enum.with_index(1)
      |> Enum.map(fn {record, index} -> encode_step(record, index) end)

    depth = steps |> Enum.count(&(&1.status == :ok)) |> min(max_steps)

    base_result = %{
      benchmark: benchmark,
      project_id: project_id,
      goal_id: goal_id,
      agent_id: agent_id,
      depth: depth,
      closed: false,
      recovered: [],
      steps: steps,
      turn_result: turn_result_status(turn_result),
      last_assistant_message: last_assistant_message(agent_state),
      duration_ms: monotonic_ms() - started_at
    }

    closed =
      Scorer.success_check_passed?(benchmark.success_check, base_result,
        success_timeout_ms: Keyword.get(opts, :success_timeout_ms, @default_success_timeout_ms)
      )

    base_result
    |> Map.put(:closed, closed)
    |> Map.put(:status, run_status(closed, depth, max_steps, turn_result))
    |> maybe_put_error(turn_result)
  end

  defp tool_history(nil), do: []
  defp tool_history(%{tool_history: history}) when is_list(history), do: history
  defp tool_history(_state), do: []

  defp encode_step(record, index) when is_map(record) do
    %{
      index: index,
      tool: to_string(Map.get(record, :tool, "")),
      args: sanitize_args(Map.get(record, :args, %{})),
      status: tool_status(Map.get(record, :result)),
      summary: summarize_tool_result(Map.get(record, :result)),
      timestamp: encode_timestamp(Map.get(record, :timestamp))
    }
  end

  defp encode_step(record, index), do: %{index: index, status: :unknown, summary: inspect(record)}

  defp sanitize_args(args) when is_map(args) do
    Map.new(args, fn {key, value} -> {to_string(key), sanitize_value(value)} end)
  end

  defp sanitize_args(_args), do: %{}

  defp sanitize_value(value) when is_binary(value), do: truncate(value, 2_000)

  defp sanitize_value(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  defp sanitize_value(value), do: inspect(value)

  defp tool_status({:ok, _value}), do: :ok
  defp tool_status({:error, _reason}), do: :error
  defp tool_status(_result), do: :unknown

  defp summarize_tool_result({:ok, value}) when is_binary(value), do: truncate(value, 1_000)
  defp summarize_tool_result({:ok, value}), do: value |> inspect() |> truncate(1_000)
  defp summarize_tool_result({:error, reason}), do: reason |> inspect() |> truncate(1_000)
  defp summarize_tool_result(result), do: result |> inspect() |> truncate(1_000)

  defp encode_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp encode_timestamp(_timestamp), do: nil

  defp turn_result_status({:ok, _response}), do: :ok
  defp turn_result_status({:error, :timeout}), do: :timeout
  defp turn_result_status({:error, _reason}), do: :error

  defp run_status(true, _depth, _max_steps, _turn_result), do: :closed
  defp run_status(false, depth, max_steps, _turn_result) when depth >= max_steps, do: :max_steps
  defp run_status(false, _depth, _max_steps, {:error, :timeout}), do: :timeout
  defp run_status(false, _depth, _max_steps, {:error, _reason}), do: :agent_error
  defp run_status(false, _depth, _max_steps, _turn_result), do: :stalled

  defp maybe_put_error(result, {:error, reason}), do: Map.put(result, :error, reason)
  defp maybe_put_error(result, _turn_result), do: result

  defp finalize_goal(goal_id, %{closed: true} = result) do
    Goals.set_status(goal_id, :completed)

    Object.update_metadata(goal_id, %{
      report: result.last_assistant_message,
      completion_summary: "Benchmark success_check passed.",
      last_error: nil
    })

    :ok
  end

  defp finalize_goal(goal_id, result) do
    Object.update_metadata(goal_id, %{
      status: :pending,
      report: result.last_assistant_message,
      completion_summary: "Benchmark stopped with status #{result.status}.",
      last_error: inspect(Map.get(result, :error))
    })

    :ok
  end

  defp stop_agent(agent_id) do
    case Agent.stop(agent_id) do
      :ok -> :ok
      _other -> :ok
    end
  end

  defp last_assistant_message(nil), do: nil

  defp last_assistant_message(%{messages: messages}) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn message -> Map.get(message, :role) == :assistant end)
    |> case do
      nil -> nil
      message -> message |> Map.get(:content) |> blank_to_nil()
    end
  end

  defp last_assistant_message(_state), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: truncate(value, 4_000)
  end

  defp blank_to_nil(_value), do: nil

  defp goal_message(goal) do
    description =
      if goal.content && goal.content != "" do
        "\n\n#{goal.content}"
      else
        ""
      end

    "Work on goal: #{goal.name}\nGoal ID: #{goal.id}#{description}"
  end

  defp goal_description(benchmark) do
    """
    #{benchmark.objective}

    Acceptance check:
    #{success_check_text(benchmark.success_check)}

    Work entirely in /workspace. Do not ask for human input. Use tools to inspect,
    create, edit, and test the implementation. Before finishing, run the
    acceptance check or an equivalent verification command and report the result.
    """
    |> String.trim()
  end

  defp system_prompt(benchmark) do
    """
    You are running an Orchid autonomy benchmark.

    Complete the assigned goal without human input. Do not ask clarifying
    questions. Work only in the sandbox workspace at /workspace. You may use
    shell, read, edit, list, and grep tools. Create any files needed for the
    benchmark objective.

    Deterministic success check:
    #{success_check_text(benchmark.success_check)}

    Stop only after the check passes or you are blocked by a concrete technical
    error. Keep the final report concise and include files changed and commands
    run.
    """
    |> String.trim()
  end

  defp success_check_text({:shell, command}), do: "shell: #{command}"
  defp success_check_text({:file_exists, path}), do: "file exists: #{path}"

  defp success_check_text({:file_contains, path, %Regex{} = pattern}) do
    "file #{path} matches #{Regex.source(pattern)}"
  end

  defp success_check_text({:file_contains, path, needle}) do
    "file #{path} contains #{inspect(needle)}"
  end

  defp success_check_text({:predicate, _predicate}), do: "pure Elixir predicate"
  defp success_check_text(other), do: inspect(other)

  defp timestamp_id do
    DateTime.utc_now()
    |> DateTime.to_unix(:millisecond)
    |> Integer.to_string()
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    binary_part(text, 0, max) <> "..."
  end

  defp truncate(text, _max), do: text
end
