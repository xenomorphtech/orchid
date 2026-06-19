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
  alias Orchid.{Agent, Goals, Object, Planner, Project, Projects, Sandbox, Tool}

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
          optional(:id) => String.t(),
          optional(:description) => String.t(),
          optional(:check) => String.t(),
          optional(:injected) => boolean(),
          optional(:initial_passed) => boolean(),
          optional(:final_passed) => boolean(),
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
          optional(:runner_mode) => :flat | :gvr,
          optional(:status) => atom(),
          optional(:turn_result) => :ok | :error | :timeout,
          optional(:last_assistant_message) => String.t() | nil,
          optional(:error) => term()
        }

  @type option ::
          {:project_id, String.t()}
          | {:mode, :flat | :gvr | String.t()}
          | {:agent_config, map()}
          | {:max_steps, pos_integer()}
          | {:wall_clock_timeout_ms, pos_integer()}
          | {:success_timeout_ms, pos_integer()}
          | {:gvr_num_paths, pos_integer()}
          | {:gvr_max_rounds, pos_integer()}
          | {:gvr_max_delegate_depth, non_neg_integer()}

  @default_wall_clock_timeout_ms 360_000
  @default_success_timeout_ms 120_000
  @default_gvr_max_rounds 6
  @default_gvr_max_delegate_depth 3
  @agent_tools ~w(shell read edit list grep task_report_result)

  @doc """
  Run a benchmark unattended.
  """
  @spec run(Benchmark.t(), [option()]) :: {:ok, run_result()} | {:error, term()}
  def run(%Benchmark{} = benchmark, opts \\ []) when is_list(opts) do
    max_steps = Keyword.get(opts, :max_steps, benchmark.max_steps)
    mode = runner_mode(opts)

    with :ok <- validate_max_steps(max_steps),
         {:ok, mode} <- validate_mode(mode),
         :ok <- Runtime.ensure_started(),
         {:ok, project} <- ensure_project(benchmark, opts) do
      project_id = project.id

      try do
        with :ok <- seed_project_files(benchmark, project_id),
             :ok <- ensure_sandbox(project_id),
             initial_recovery <- detect_initial_recovery(benchmark, project_id, opts),
             {:ok, goal} <- create_goal(benchmark, project_id),
             {:ok, result} <-
               run_goal(mode, benchmark, project_id, goal, max_steps, initial_recovery, opts) do
          {:ok, result}
        end
      after
        cleanup(%{project_id: project_id})
      end
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

  defp validate_mode(mode) when mode in [:flat, :gvr], do: {:ok, mode}
  defp validate_mode(mode), do: {:error, {:invalid_runner_mode, mode}}

  defp runner_mode(opts) do
    opts
    |> Keyword.get(:mode, :flat)
    |> normalize_mode()
  end

  defp normalize_mode(:flat), do: :flat
  defp normalize_mode(:gvr), do: :gvr
  defp normalize_mode("flat"), do: :flat
  defp normalize_mode("gvr"), do: :gvr
  defp normalize_mode(other), do: other

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

  defp seed_project_files(%Benchmark{seed_files: []}, _project_id), do: :ok

  defp seed_project_files(%Benchmark{seed_files: seed_files}, project_id) do
    root = Project.files_path(project_id) |> Path.expand()
    File.mkdir_p!(root)

    Enum.reduce_while(seed_files, :ok, fn seed_file, :ok ->
      case write_seed_file(root, seed_file) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp write_seed_file(root, %{path: path, content: content} = seed_file) do
    with {:ok, target} <- seed_target(root, path),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(target, content),
         :ok <- maybe_chmod(target, Map.get(seed_file, :mode)) do
      :ok
    end
  end

  defp seed_target(root, path) when is_binary(path) do
    target = Path.expand(path, root)

    if target == root or String.starts_with?(target, root <> "/") do
      {:ok, target}
    else
      {:error, {:invalid_seed_path, path}}
    end
  end

  defp seed_target(_root, path), do: {:error, {:invalid_seed_path, path}}

  defp maybe_chmod(_target, nil), do: :ok
  defp maybe_chmod(target, mode), do: File.chmod(target, mode)

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

  defp detect_initial_recovery(%Benchmark{recovery_checks: []}, _project_id, _opts), do: []

  defp detect_initial_recovery(%Benchmark{recovery_checks: recovery_checks}, project_id, opts) do
    Enum.map(recovery_checks, fn recovery_check ->
      check = Map.fetch!(recovery_check, :check)
      initial_passed = Scorer.success_check_passed?(check, %{project_id: project_id}, opts)

      %{
        id: Map.fetch!(recovery_check, :id),
        description: Map.get(recovery_check, :description),
        check: check,
        check_label: success_check_text(check),
        injected: not initial_passed,
        initial_passed: initial_passed
      }
    end)
  end

  defp run_goal(:flat, benchmark, project_id, goal, max_steps, initial_recovery, opts) do
    with {:ok, agent_id} <- Agent.create(agent_config(benchmark, project_id, opts)),
         {:ok, result} <-
           run_assigned_goal(
             benchmark,
             project_id,
             goal,
             agent_id,
             max_steps,
             initial_recovery,
             opts
           ) do
      {:ok, Map.put(result, :runner_mode, :flat)}
    end
  end

  defp run_goal(:gvr, benchmark, project_id, goal, max_steps, initial_recovery, opts) do
    run_gvr_goal(benchmark, project_id, goal, max_steps, initial_recovery, opts)
  end

  defp run_assigned_goal(
         benchmark,
         project_id,
         goal,
         agent_id,
         max_steps,
         initial_recovery,
         opts
       ) do
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
            initial_recovery,
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

  defp run_gvr_goal(benchmark, project_id, goal, max_steps, initial_recovery, opts) do
    started_at = monotonic_ms()
    gvr_id = "gvr-" <> goal.id

    with :ok <- assign_goal(goal.id, gvr_id) do
      state = gvr_agent_state(gvr_id, project_id)
      context = gvr_context(benchmark)
      rounds = Keyword.get(opts, :gvr_max_rounds, @default_gvr_max_rounds)

      {turn_result, final_state} =
        run_gvr_loop(
          benchmark,
          project_id,
          state,
          context,
          max_steps,
          rounds,
          0,
          opts
        )

      result =
        build_result(
          benchmark,
          project_id,
          goal.id,
          gvr_id,
          final_state,
          turn_result,
          max_steps,
          initial_recovery,
          opts,
          started_at
        )
        |> Map.put(:runner_mode, :gvr)

      finalize_goal(goal.id, result)
      {:ok, result}
    end
  end

  defp gvr_agent_state(gvr_id, project_id) do
    %{
      id: gvr_id,
      project_id: project_id,
      sandbox: Sandbox.status(project_id),
      config: %{allowed_tools: @agent_tools},
      messages: [],
      tool_history: [],
      memory: %{}
    }
  end

  defp gvr_context(benchmark) do
    %{
      objective: goal_description(benchmark),
      completed_tasks: [],
      failures: []
    }
  end

  defp run_gvr_loop(
         benchmark,
         project_id,
         state,
         context,
         max_steps,
         rounds_left,
         delegate_depth,
         opts
       ) do
    cond do
      Scorer.success_check_passed?(benchmark.success_check, %{project_id: project_id}, opts) ->
        {{:ok, "G-V-R success check passed."},
         add_gvr_message(state, "G-V-R success check passed.")}

      gvr_depth(state) >= max_steps ->
        {{:ok, "G-V-R reached max_steps."}, add_gvr_message(state, "G-V-R reached max_steps.")}

      rounds_left <= 0 ->
        {{:ok, "G-V-R planner rounds exhausted."},
         add_gvr_message(state, "G-V-R planner rounds exhausted before closure.")}

      true ->
        objective = gvr_planning_objective(context)
        planner_opts = gvr_planner_opts(project_id, context, opts)

        case Planner.plan_tasks(objective, Sandbox.status(project_id), planner_opts) do
          {:ok, tasks} ->
            case execute_gvr_tasks(
                   tasks,
                   benchmark,
                   project_id,
                   state,
                   context,
                   max_steps,
                   rounds_left,
                   delegate_depth,
                   opts
                 ) do
              {:closed, next_state, next_context} ->
                run_gvr_loop(
                  benchmark,
                  project_id,
                  next_state,
                  next_context,
                  max_steps,
                  rounds_left - 1,
                  delegate_depth,
                  opts
                )

              {:continue, next_state, next_context} ->
                run_gvr_loop(
                  benchmark,
                  project_id,
                  next_state,
                  next_context,
                  max_steps,
                  rounds_left - 1,
                  delegate_depth,
                  opts
                )

              {:failed, next_state, next_context} ->
                run_gvr_loop(
                  benchmark,
                  project_id,
                  next_state,
                  next_context,
                  max_steps,
                  rounds_left - 1,
                  delegate_depth,
                  opts
                )
            end

          {:error, reason} ->
            {{:error, {:gvr_planner_failed, reason}},
             add_gvr_message(state, "G-V-R planner failed: #{reason}")}
        end
    end
  end

  defp execute_gvr_tasks(
         tasks,
         benchmark,
         project_id,
         state,
         context,
         max_steps,
         rounds_left,
         delegate_depth,
         opts
       ) do
    Enum.reduce_while(tasks, {:continue, state, context}, fn task,
                                                             {_status, acc_state, acc_context} ->
      cond do
        Scorer.success_check_passed?(benchmark.success_check, %{project_id: project_id}, opts) ->
          {:halt, {:closed, acc_state, acc_context}}

        gvr_depth(acc_state) >= max_steps ->
          {:halt, {:continue, acc_state, add_gvr_failure(acc_context, task, "max_steps reached")}}

        true ->
          case execute_gvr_task(
                 task,
                 benchmark,
                 project_id,
                 acc_state,
                 acc_context,
                 max_steps,
                 rounds_left,
                 delegate_depth,
                 opts
               ) do
            {:ok, next_state, next_context} -> {:cont, {:continue, next_state, next_context}}
            {:closed, next_state, next_context} -> {:halt, {:closed, next_state, next_context}}
            {:error, next_state, next_context} -> {:halt, {:failed, next_state, next_context}}
          end
      end
    end)
  end

  defp execute_gvr_task(
         %{type: :delegate} = task,
         benchmark,
         project_id,
         state,
         context,
         max_steps,
         rounds_left,
         delegate_depth,
         opts
       ) do
    max_delegate_depth =
      Keyword.get(opts, :gvr_max_delegate_depth, @default_gvr_max_delegate_depth)

    if delegate_depth >= max_delegate_depth do
      {:error, state, add_gvr_failure(context, task, "delegate depth limit reached")}
    else
      delegate_context = %{
        context
        | objective: gvr_delegate_objective(task, context),
          failures: context.failures
      }

      {turn_result, next_state} =
        run_gvr_loop(
          benchmark,
          project_id,
          state,
          delegate_context,
          max_steps,
          max(1, rounds_left - 1),
          delegate_depth + 1,
          opts
        )

      next_context =
        case turn_result do
          {:error, reason} -> add_gvr_failure(context, task, inspect(reason))
          _ -> add_gvr_completed(context, task, "delegate completed")
        end

      if Scorer.success_check_passed?(benchmark.success_check, %{project_id: project_id}, opts) do
        {:closed, next_state, next_context}
      else
        {:ok, next_state, next_context}
      end
    end
  end

  defp execute_gvr_task(
         %{type: :tool} = task,
         benchmark,
         project_id,
         state,
         context,
         _max_steps,
         _rounds_left,
         _delegate_depth,
         opts
       ) do
    result =
      try do
        Tool.execute(task.tool, task.args || %{}, %{agent_state: state})
      rescue
        error ->
          {:error, "Tool #{task.tool} crashed: #{Exception.message(error)}"}
      end

    next_state = record_gvr_tool(state, task, result)

    case result do
      {:ok, summary} ->
        next_context = add_gvr_completed(context, task, summary)

        if Scorer.success_check_passed?(benchmark.success_check, %{project_id: project_id}, opts) do
          {:closed, next_state, next_context}
        else
          {:ok, next_state, next_context}
        end

      {:error, reason} ->
        {:error, next_state, add_gvr_failure(context, task, inspect(reason))}
    end
  end

  defp execute_gvr_task(
         task,
         _benchmark,
         _project_id,
         state,
         context,
         _max_steps,
         _rounds_left,
         _delegate_depth,
         _opts
       ) do
    {:error, state, add_gvr_failure(context, task, "invalid G-V-R task")}
  end

  defp gvr_planner_opts(project_id, context, opts) do
    [
      num_paths: Keyword.get(opts, :gvr_num_paths, 1),
      max_iterations: 1,
      max_concurrency: Keyword.get(opts, :gvr_num_paths, 1),
      project_id: project_id,
      completed_tasks: context.completed_tasks,
      allowed_tools: @agent_tools,
      workspace_context: gvr_workspace_context(project_id),
      llm_config: gvr_llm_config(opts)
    ]
  end

  defp gvr_llm_config(opts) do
    %{provider: :openrouter, model: :nex_n2_pro}
    |> maybe_put_openrouter_api_key()
    |> Map.merge(Keyword.get(opts, :gvr_llm_config, %{}))
  end

  defp gvr_planning_objective(context) do
    """
    #{context.objective}

    Completed G-V-R tasks:
    #{inspect(context.completed_tasks, limit: 40)}

    Explicit failures to avoid:
    #{inspect(context.failures, limit: 20)}
    """
    |> String.trim()
  end

  defp gvr_delegate_objective(task, context) do
    """
    Delegated subtask:
    #{task.objective}

    Original/root objective:
    #{context.objective}

    Completed parent tasks:
    #{inspect(context.completed_tasks, limit: 40)}

    Known failures:
    #{inspect(context.failures, limit: 20)}
    """
    |> String.trim()
  end

  defp gvr_workspace_context(project_id) do
    root = Project.files_path(project_id)

    files =
      if File.dir?(root) do
        root
        |> Path.join("**/*")
        |> Path.wildcard(match_dot: true)
        |> Enum.filter(&File.regular?/1)
        |> Enum.take(80)
        |> Enum.map(&Path.relative_to(&1, root))
      else
        []
      end

    if files == [] do
      "(workspace appears empty)"
    else
      Enum.join(files, "\n")
    end
  end

  defp record_gvr_tool(state, task, result) do
    tool_record = %{
      id: Map.get(task, :id),
      tool: Map.get(task, :tool),
      args: Map.get(task, :args, %{}),
      result: result,
      timestamp: DateTime.utc_now()
    }

    %{state | tool_history: state.tool_history ++ [tool_record]}
  end

  defp add_gvr_completed(context, task, summary) do
    completed = %{
      id: Map.get(task, :id),
      type: Map.get(task, :type),
      objective: Map.get(task, :objective),
      result: truncate(to_string(summary), 500)
    }

    %{context | completed_tasks: context.completed_tasks ++ [completed]}
  end

  defp add_gvr_failure(context, task, reason) do
    failure = %{
      id: Map.get(task, :id),
      type: Map.get(task, :type),
      objective: Map.get(task, :objective),
      reason: truncate(to_string(reason), 500)
    }

    %{context | failures: context.failures ++ [failure]}
  end

  defp add_gvr_message(state, content) do
    message = %{role: :assistant, content: content, timestamp: DateTime.utc_now()}
    %{state | messages: state.messages ++ [message]}
  end

  defp gvr_depth(state) do
    state
    |> tool_history()
    |> Enum.count(fn record -> tool_status(Map.get(record, :result)) == :ok end)
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
         initial_recovery,
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
    |> Map.put(:recovered, recovery_events(initial_recovery, project_id, opts))
    |> Map.put(:status, run_status(closed, depth, max_steps, turn_result))
    |> maybe_put_error(turn_result)
  end

  defp recovery_events([], _project_id, _opts), do: []

  defp recovery_events(initial_recovery, project_id, opts) do
    Enum.map(initial_recovery, fn initial ->
      final_passed = Scorer.success_check_passed?(initial.check, %{project_id: project_id}, opts)
      recovered = initial.injected and final_passed

      %{
        id: initial.id,
        description: initial.description,
        check: initial.check_label,
        injected: initial.injected,
        initial_passed: initial.initial_passed,
        final_passed: final_passed,
        recovered: recovered,
        status: recovery_status(initial.injected, final_passed)
      }
    end)
  end

  defp recovery_status(true, true), do: :recovered
  defp recovery_status(true, false), do: :unrecovered
  defp recovery_status(false, true), do: :not_injected
  defp recovery_status(false, false), do: :invalid

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

    #{seed_files_text(benchmark)}
    #{recovery_text(benchmark)}

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

    #{seed_files_text(benchmark)}
    #{recovery_text(benchmark)}

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

  defp seed_files_text(%Benchmark{seed_files: []}), do: ""

  defp seed_files_text(%Benchmark{seed_files: seed_files}) do
    paths = seed_files |> Enum.map(& &1.path) |> Enum.join(", ")
    "Seeded workspace files: #{paths}"
  end

  defp recovery_text(%Benchmark{recovery_checks: []}), do: ""

  defp recovery_text(%Benchmark{recovery_checks: recovery_checks}) do
    labels =
      recovery_checks
      |> Enum.map(fn check -> "#{check.id}: #{success_check_text(check.check)}" end)
      |> Enum.join("; ")

    "Recovery checks start failing by design. Repair the seeded fault so they pass: #{labels}"
  end

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
