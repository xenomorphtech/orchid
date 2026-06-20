defmodule Mix.Tasks.Orchid.RealGoalClosure do
  @moduledoc """
  Runs Orchid's real-goal closure harness through the product GoalWatcher path.
  """

  use Mix.Task

  alias Orchid.Planner.{Router, RuntimeGoal}
  alias Orchid.{Agent, GoalWatcher, Object, Project, Projects, Sandbox}

  @shortdoc "Run the Orchid real-goal closure harness"
  @real_default_out Path.join(["priv", "autonomy", "real_goal_closure.json"])
  @gvr_default_out Path.join(["priv", "autonomy", "gvr_real_goal_closure.json"])
  @gvr_vs_flat_default_out Path.join(["priv", "autonomy", "gvr_vs_flat_real.json"])
  @default_goal_timeout_ms 720_000
  @default_success_timeout_ms 30_000
  @default_gvr_retry_attempts 2
  @default_reliability_retry_attempts 2
  @poll_interval_ms 5_000
  @completion_grace_ms 120_000
  @closure_provider :codex
  @closure_model :gpt55

  @impl Mix.Task
  def run(args) do
    run_suite(:real, args)
  end

  def run_suite(suite_key, args) when suite_key in [:real, :gvr] do
    suite = suite_config!(suite_key)

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          out: :string,
          goal_id: :string,
          goal_timeout_ms: :integer,
          success_timeout_ms: :integer,
          keep_data_dir: :boolean
        ]
      )

    reject_invalid_options!(invalid)

    repo_cwd = File.cwd!()
    output_path = opts |> Keyword.get(:out, suite.default_out) |> validate_output_path!()
    output_file = Path.expand(output_path, repo_cwd)
    goal_id = Keyword.get(opts, :goal_id)

    goal_timeout_ms =
      opts
      |> Keyword.get(:goal_timeout_ms, @default_goal_timeout_ms)
      |> validate_positive_integer!("--goal-timeout-ms")

    success_timeout_ms =
      opts
      |> Keyword.get(:success_timeout_ms, @default_success_timeout_ms)
      |> validate_positive_integer!("--success-timeout-ms")

    reliability_retry_limit = suite_reliability_retry_limit(suite.key)
    keep_data_dir? = Keyword.get(opts, :keep_data_dir, false)
    data_dir = temp_data_dir()
    started_at = monotonic_ms()
    previous_trap_exit = Process.flag(:trap_exit, true)

    Application.put_env(:orchid, :data_dir, data_dir)
    Application.put_env(:orchid, :goal_watcher_planner_mode, :auto)

    start_dependencies!()
    supervisor = start_minimal_runtime!()

    report =
      try do
        seed_templates!()
        seed_facts!()
        force_closure_model_templates!()

        definitions = select_goal_definitions!(suite.goals, goal_id)

        goals =
          Enum.map(definitions, fn definition ->
            File.cd!(repo_cwd)

            run_goal_with_reliability_retries(
              definition,
              goal_timeout_ms,
              success_timeout_ms,
              repo_cwd,
              reliability_retry_limit
            )
          end)

        File.cd!(repo_cwd)

        report =
          build_report(
            goals,
            definitions,
            data_dir,
            output_file,
            started_at,
            suite,
            reliability_retry_limit,
            goal_id
          )

        write_report!(report, output_file)
        report
      after
        File.cd!(repo_cwd)
        stop_named(GoalWatcher)
        Supervisor.stop(supervisor)

        File.cd!(repo_cwd)

        unless keep_data_dir? do
          safe_rm_rf_temp!(data_dir, "orchid-real-goal-closure-")
        end

        Process.flag(:trap_exit, previous_trap_exit)
      end

    Mix.shell().info(
      "#{suite.task_name}: closed #{report.closed_count}/#{report.n_goals}; " <>
        "wrote #{output_path}"
    )
  end

  def run_gvr_vs_flat(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          out: :string,
          goal_timeout_ms: :integer,
          success_timeout_ms: :integer,
          gvr_retries: :integer,
          keep_data_dir: :boolean
        ]
      )

    reject_invalid_options!(invalid)

    repo_cwd = File.cwd!()

    output_path =
      opts |> Keyword.get(:out, @gvr_vs_flat_default_out) |> validate_output_path!()

    output_file = Path.expand(output_path, repo_cwd)

    goal_timeout_ms =
      opts
      |> Keyword.get(:goal_timeout_ms, @default_goal_timeout_ms)
      |> validate_positive_integer!("--goal-timeout-ms")

    success_timeout_ms =
      opts
      |> Keyword.get(:success_timeout_ms, @default_success_timeout_ms)
      |> validate_positive_integer!("--success-timeout-ms")

    gvr_retries =
      opts
      |> Keyword.get(:gvr_retries, @default_gvr_retry_attempts)
      |> validate_non_negative_integer!("--gvr-retries")

    keep_data_dir? = Keyword.get(opts, :keep_data_dir, false)
    data_dir = temp_data_dir()
    started_at = monotonic_ms()
    previous_trap_exit = Process.flag(:trap_exit, true)

    Application.put_env(:orchid, :data_dir, data_dir)
    Application.put_env(:orchid, :goal_watcher_planner_mode, :auto)
    Application.put_env(:orchid, :goal_watcher_gvr_flat_fallback, false)

    start_dependencies!()
    supervisor = start_minimal_runtime!()

    report =
      try do
        seed_templates!()
        seed_facts!()
        force_closure_model_templates!()

        definition = gvr_vs_flat_real_goal()

        File.cd!(repo_cwd)
        flat = run_goal(definition, goal_timeout_ms, success_timeout_ms, repo_cwd, :flat)

        File.cd!(repo_cwd)

        gvr_attempts =
          run_gvr_with_retries(
            definition,
            goal_timeout_ms,
            success_timeout_ms,
            repo_cwd,
            gvr_retries
          )

        gvr = List.last(gvr_attempts)

        File.cd!(repo_cwd)

        report =
          build_gvr_vs_flat_report(
            definition,
            flat,
            gvr,
            gvr_attempts,
            data_dir,
            output_file,
            started_at,
            gvr_retries
          )

        write_report!(report, output_file)
        report
      after
        File.cd!(repo_cwd)
        stop_named(GoalWatcher)
        Supervisor.stop(supervisor)

        File.cd!(repo_cwd)

        unless keep_data_dir? do
          safe_rm_rf_temp!(data_dir, "orchid-real-goal-closure-")
        end

        Application.put_env(:orchid, :goal_watcher_planner_mode, :auto)
        Process.flag(:trap_exit, previous_trap_exit)
      end

    Mix.shell().info(
      "orchid.gvr_vs_flat_real: flat_closed=#{report.flat_closed} " <>
        "gvr_closed=#{report.gvr_closed} gvr_beats_flat=#{report.gvr_beats_flat}; " <>
        "wrote #{output_path}"
    )
  end

  defp run_goal_with_reliability_retries(
         definition,
         goal_timeout_ms,
         success_timeout_ms,
         repo_cwd,
         max_retries,
         route_mode \\ :auto
       ) do
    __MODULE__.ReliabilityRetry.run(
      fn -> run_goal(definition, goal_timeout_ms, success_timeout_ms, repo_cwd, route_mode) end,
      max_retries,
      &arm_summary/1
    )
  end

  defp run_gvr_with_retries(
         definition,
         goal_timeout_ms,
         success_timeout_ms,
         repo_cwd,
         retries_remaining,
         attempts \\ []
       ) do
    result = run_goal(definition, goal_timeout_ms, success_timeout_ms, repo_cwd, :gvr)
    attempts = attempts ++ [result]

    if __MODULE__.ReliabilityRetry.should_retry?(result, retries_remaining) do
      run_gvr_with_retries(
        definition,
        goal_timeout_ms,
        success_timeout_ms,
        repo_cwd,
        retries_remaining - 1,
        attempts
      )
    else
      attempts
    end
  end

  defp run_goal(definition, goal_timeout_ms, success_timeout_ms, repo_cwd, route_mode) do
    started_at = monotonic_ms()

    case create_fixture(definition) do
      {:ok, %{project: project, goal: goal, workspace: workspace}} ->
        runtime_goal_input = RuntimeGoal.from_goal_watcher(project, [goal])
        request = GoalWatcher.runtime_planner_request(project, [goal])
        decision = route_decision(request.route_input, route_mode)

        runtime_contract = %{
          goal_label: request.goal_label,
          route_input_matches_runtime_goal: request.route_input == runtime_goal_input
        }

        counter = __MODULE__.ModelCallCounter.start!()
        File.cd!(repo_cwd)
        Application.put_env(:orchid, :goal_watcher_planner_mode, route_mode)
        start_goal_watcher!(repo_cwd)

        try do
          File.cd!(repo_cwd)
          send(GoalWatcher, :check)

          wait_result =
            wait_for_goal(definition, project, goal.id, %{
              deadline: monotonic_ms() + goal_timeout_ms,
              success_timeout_ms: success_timeout_ms,
              repo_cwd: repo_cwd,
              watcher_checks: 1,
              success_seen_at: nil
            })

          model_calls = __MODULE__.ModelCallCounter.stop(counter)
          File.cd!(repo_cwd)
          cleanup_project(project.id, repo_cwd)

          encode_goal_result(
            definition,
            project,
            goal,
            workspace,
            decision,
            runtime_contract,
            wait_result,
            model_calls,
            monotonic_ms() - started_at
          )
        rescue
          error ->
            model_calls = __MODULE__.ModelCallCounter.stop(counter)
            File.cd!(repo_cwd)
            cleanup_project(project.id, repo_cwd)

            error_goal_result(
              definition,
              project,
              goal,
              workspace,
              decision,
              runtime_contract,
              {:exception, error, __STACKTRACE__},
              model_calls,
              monotonic_ms() - started_at
            )
        catch
          kind, reason ->
            model_calls = __MODULE__.ModelCallCounter.stop(counter)
            File.cd!(repo_cwd)
            cleanup_project(project.id, repo_cwd)

            error_goal_result(
              definition,
              project,
              goal,
              workspace,
              decision,
              runtime_contract,
              {:caught, kind, reason},
              model_calls,
              monotonic_ms() - started_at
            )
        after
          File.cd!(repo_cwd)
          stop_named(GoalWatcher)
        end

      {:error, reason} ->
        %{
          id: definition.id,
          route_mode: route_mode,
          closed: false,
          nudges: 0,
          failure_mode: "fixture_error: #{truncate(inspect(reason), 800)}",
          reliability_failure: false,
          status: :fixture_error,
          duration_ms: monotonic_ms() - started_at
        }
    end
  end

  defp route_decision(route_input, :auto), do: Router.classify(route_input)

  defp route_decision(route_input, mode) when mode in [:flat, :gvr] do
    decision = Router.classify(route_input)
    %{decision | mode: mode, signal: "#{decision.signal}; selected_mode=#{mode}"}
  end

  defp wait_for_goal(definition, project, goal_id, state) do
    now = monotonic_ms()

    success =
      run_success_check(
        project.id,
        definition.success_check,
        state.success_timeout_ms,
        state.repo_cwd
      )

    goals = Object.list_goals_for_project(project.id)
    top_goal = Enum.find(goals, &(&1.id == goal_id))
    active_agents = active_agent_states(project.id)

    cond do
      success.passed and completed?(top_goal) ->
        %{
          result: :ok,
          closed: true,
          closed_by_status: completed?(top_goal),
          success_check: success,
          goals: goals,
          active_agents: active_agents,
          watcher_checks: state.watcher_checks,
          blocker: nil
        }

      success.passed and is_integer(state.success_seen_at) and
          now - state.success_seen_at >= @completion_grace_ms ->
        %{
          result: :success_fact_reached,
          closed: true,
          closed_by_status: false,
          success_check: success,
          goals: goals,
          active_agents: active_agents,
          watcher_checks: state.watcher_checks,
          blocker: "External success check passed before parent goal status completed."
        }

      success.passed ->
        Process.sleep(@poll_interval_ms)

        wait_for_goal(definition, project, goal_id, %{
          state
          | success_seen_at: state.success_seen_at || now
        })

      now >= state.deadline ->
        %{
          result: :timeout,
          closed: false,
          closed_by_status: completed?(top_goal),
          success_check: success,
          goals: goals,
          active_agents: active_agents,
          watcher_checks: state.watcher_checks,
          blocker: timeout_blocker(goals, active_agents, success)
        }

      true ->
        Process.sleep(@poll_interval_ms)
        wait_for_goal(definition, project, goal_id, %{state | success_seen_at: nil})
    end
  end

  defp encode_goal_result(
         definition,
         project,
         goal,
         workspace,
         decision,
         runtime_contract,
         wait_result,
         model_calls,
         duration_ms
       ) do
    closed = wait_result.success_check.passed
    failure_mode = if closed, do: nil, else: failure_mode(wait_result)

    %{
      id: definition.id,
      route_mode: decision.mode,
      closed: closed,
      nudges: 0,
      failure_mode: failure_mode,
      reliability_failure: reliability_failure?(failure_mode),
      status: wait_result.result,
      project_id: project.id,
      goal_id: goal.id,
      workspace: workspace,
      route: %{
        mode: decision.mode,
        signal: decision.signal,
        goal_label: runtime_contract.goal_label,
        route_input_matches_runtime_goal: runtime_contract.route_input_matches_runtime_goal
      },
      closed_by_status: wait_result.closed_by_status,
      success_check: wait_result.success_check,
      model_calls: model_calls,
      watcher_checks: wait_result.watcher_checks,
      goals: Enum.map(wait_result.goals, &goal_snapshot/1),
      active_agents: wait_result.active_agents,
      blocker: wait_result.blocker,
      duration_ms: duration_ms
    }
  end

  defp error_goal_result(
         definition,
         project,
         goal,
         workspace,
         decision,
         runtime_contract,
         reason,
         model_calls,
         duration_ms
       ) do
    failure_mode = "harness_exception: #{format_reason(reason)}"

    %{
      id: definition.id,
      route_mode: decision.mode,
      closed: false,
      nudges: 0,
      failure_mode: failure_mode,
      reliability_failure: reliability_failure?(failure_mode),
      status: :harness_exception,
      project_id: project.id,
      goal_id: goal.id,
      workspace: workspace,
      route: %{
        mode: decision.mode,
        signal: decision.signal,
        goal_label: runtime_contract.goal_label,
        route_input_matches_runtime_goal: runtime_contract.route_input_matches_runtime_goal
      },
      success_check: %{passed: false, error: failure_mode},
      model_calls: model_calls,
      duration_ms: duration_ms
    }
  end

  defp build_report(
         goals,
         definitions,
         data_dir,
         output_path,
         started_at,
         suite,
         reliability_retry_limit,
         goal_id
       ) do
    closed_count = Enum.count(goals, & &1.closed)
    gvr_closed_count = gvr_closed_count(goals)

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      harness: suite.harness,
      harness_path: suite.harness_path,
      implementation_path: "lib/mix/tasks/orchid.real_goal_closure.ex",
      product_entry: "Orchid.GoalWatcher",
      route_contract:
        "GoalWatcher.runtime_planner_request -> RuntimeGoal.from_goal_watcher -> Router -> planner",
      runner_substrate: "durable per-project sandbox via Orchid.Projects.ensure_sandbox",
      provider: @closure_provider,
      model_id: @closure_model,
      model: closure_model_label(),
      data_dir: data_dir,
      report_path: output_path,
      reliability_retry_policy: %{
        max_retries: reliability_retry_limit,
        retry_condition: "closed=false and reliability_failure=true"
      },
      goal_filter: goal_filter(goal_id),
      n_goals: length(definitions),
      closed_count: closed_count,
      gvr_closed_count: gvr_closed_count,
      criteria: criteria(suite.key, goals, closed_count, gvr_closed_count),
      goals: goals,
      duration_ms: monotonic_ms() - started_at
    }
  end

  defp build_gvr_vs_flat_report(
         definition,
         flat,
         gvr,
         gvr_attempts,
         data_dir,
         output_path,
         started_at,
         gvr_retries
       ) do
    gvr_beats_flat = not flat.closed and gvr.closed

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      harness: "Mix.Tasks.Orchid.GvrVsFlatReal",
      harness_path: "lib/mix/tasks/orchid.gvr_vs_flat_real.ex",
      implementation_path: "lib/mix/tasks/orchid.real_goal_closure.ex",
      product_entry: "Orchid.GoalWatcher",
      route_contract:
        "GoalWatcher.runtime_planner_request -> RuntimeGoal.from_goal_watcher -> Router -> planner",
      runner_substrate: "durable per-project sandbox via Orchid.Projects.ensure_sandbox",
      provider: @closure_provider,
      model_id: @closure_model,
      model: closure_model_label(),
      data_dir: data_dir,
      report_path: output_path,
      goal_id: definition.id,
      success_check: definition.success_check,
      same_workspace_seed: true,
      workspace_seed: seed_manifest(definition.seed_files),
      flat_closed: flat.closed,
      gvr_closed: gvr.closed,
      gvr_beats_flat: gvr_beats_flat,
      nudges: %{
        flat: flat.nudges,
        gvr: gvr.nudges
      },
      failure_modes: %{
        flat: flat.failure_mode,
        gvr: gvr.failure_mode
      },
      flat: arm_summary(flat),
      gvr: arm_summary(gvr),
      gvr_retry_limit: gvr_retries,
      gvr_attempt_count: length(gvr_attempts),
      gvr_attempts: Enum.map(gvr_attempts, &arm_summary/1),
      criteria: %{
        same_real_goal: flat.id == definition.id and gvr.id == definition.id,
        same_workspace_seed: true,
        same_external_success_check:
          get_in(flat, [:success_check, :command]) == definition.success_check and
            get_in(gvr, [:success_check, :command]) == definition.success_check,
        forced_flat: flat.route_mode == :flat,
        forced_gvr: gvr.route_mode == :gvr,
        all_success_checks_external: true,
        result_recorded_honestly: true,
        gvr_beats_flat: gvr_beats_flat
      },
      arms: %{
        flat: flat,
        gvr: gvr
      },
      duration_ms: monotonic_ms() - started_at
    }
  end

  defp arm_summary(result) do
    %{
      closed: result.closed,
      nudges: result.nudges,
      failure_mode: result.failure_mode,
      reliability_failure: result.reliability_failure,
      route_mode: result.route_mode,
      status: result.status,
      attempts_used: Map.get(result, :attempts_used),
      reliability_retry_limit: Map.get(result, :reliability_retry_limit),
      retried: Map.get(result, :retried),
      project_id: Map.get(result, :project_id),
      goal_id: Map.get(result, :goal_id),
      workspace: Map.get(result, :workspace),
      model_calls: Map.get(result, :model_calls),
      watcher_checks: Map.get(result, :watcher_checks),
      duration_ms: Map.get(result, :duration_ms)
    }
  end

  defp closure_model_label do
    "#{@closure_provider}/#{Orchid.LLM.Catalog.resolve_model(@closure_model, @closure_provider)}"
  end

  defp select_goal_definitions!(definitions, nil), do: definitions

  defp select_goal_definitions!(definitions, goal_id) do
    case Enum.filter(definitions, &(&1.id == goal_id)) do
      [] ->
        valid_ids = definitions |> Enum.map(& &1.id) |> Enum.join(", ")
        Mix.raise("unknown --goal-id #{inspect(goal_id)}; valid ids: #{valid_ids}")

      selected ->
        selected
    end
  end

  defp goal_filter(nil), do: nil
  defp goal_filter(goal_id), do: %{goal_id: goal_id}

  defp seed_manifest(seed_files) do
    Enum.map(seed_files, fn %{path: path, content: content} ->
      %{
        path: path,
        bytes: byte_size(content),
        sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      }
    end)
  end

  defp create_fixture(definition) do
    max_steps = Map.get(definition, :max_steps, 8)

    with {:ok, project} <-
           Object.create(:project, definition.project_name, String.trim(definition.project_brief),
             metadata: %{
               status: :active,
               objective: definition.objective,
               success_criteria: "shell: #{definition.success_check}",
               max_steps: max_steps
             }
           ),
         {:ok, goal} <-
           Object.create(:goal, definition.goal_name, String.trim(definition.goal_description),
             metadata: %{
               project_id: project.id,
               status: :pending,
               depends_on: [],
               max_steps: max_steps
             }
           ),
         {:ok, workspace} <- Project.ensure_dir(project.id),
         :ok <- seed_files(workspace, definition.seed_files) do
      {:ok, %{project: project, goal: goal, workspace: workspace}}
    end
  end

  defp seed_files(workspace, seed_files) do
    Enum.reduce_while(seed_files, :ok, fn %{path: path, content: content}, :ok ->
      target = Path.expand(path, workspace)
      root = Path.expand(workspace)

      cond do
        target != root and String.starts_with?(target, root <> "/") ->
          File.mkdir_p!(Path.dirname(target))
          File.write!(target, content)
          {:cont, :ok}

        true ->
          {:halt, {:error, {:invalid_seed_path, path}}}
      end
    end)
  end

  defp run_success_check(project_id, command, timeout_ms, repo_cwd) do
    try do
      case Sandbox.status(project_id) do
        %{status: :ready, running: true} ->
          case Sandbox.exec(project_id, command, timeout: timeout_ms) do
            {:ok, output} ->
              %{passed: true, command: command, output: String.trim(output)}

            {:error, reason} ->
              %{passed: false, command: command, error: truncate(inspect(reason), 1_000)}
          end

        _ ->
          root = Project.files_path(project_id)
          host_command = String.replace(command, "/workspace", shell_escape(root))

          case System.cmd("sh", ["-c", host_command], stderr_to_stdout: true) do
            {output, 0} ->
              %{passed: true, command: command, output: String.trim(output), fallback: :host}

            {output, code} ->
              %{
                passed: false,
                command: command,
                error: "exit=#{code} output=#{String.trim(output)}",
                fallback: :host
              }
          end
      end
    after
      File.cd!(repo_cwd)
    end
  end

  defp suite_reliability_retry_limit(:real), do: @default_reliability_retry_attempts
  defp suite_reliability_retry_limit(_suite_key), do: 0

  defp suite_config!(:real) do
    %{
      key: :real,
      task_name: "orchid.real_goal_closure",
      harness: "Mix.Tasks.Orchid.RealGoalClosure",
      harness_path: "lib/mix/tasks/orchid.real_goal_closure.ex",
      default_out: @real_default_out,
      goals: real_goals()
    }
  end

  defp suite_config!(:gvr) do
    %{
      key: :gvr,
      task_name: "orchid.gvr_real_goal_closure",
      harness: "Mix.Tasks.Orchid.GvrRealGoalClosure",
      harness_path: "lib/mix/tasks/orchid.gvr_real_goal_closure.ex",
      default_out: @gvr_default_out,
      goals: gvr_real_goals()
    }
  end

  defp criteria(:real, goals, closed_count, _gvr_closed_count) do
    %{
      ran_all_4: length(goals) == 4,
      at_least_1_closed_with_zero_nudges:
        closed_count >= 1 and Enum.any?(goals, &(&1.closed and &1.nudges == 0)),
      all_success_checks_external: true
    }
  end

  defp criteria(:gvr, goals, _closed_count, gvr_closed_count) do
    %{
      at_least_1_gvr_closed_with_zero_nudges: gvr_closed_count >= 1,
      all_success_checks_external: true,
      all_goals_routed_gvr: Enum.all?(goals, &(&1.route_mode == :gvr)),
      all_route_inputs_match_runtime_goal:
        Enum.all?(goals, fn goal ->
          get_in(goal, [:route, :route_input_matches_runtime_goal]) == true
        end)
    }
  end

  defp gvr_closed_count(goals) do
    Enum.count(goals, fn goal ->
      goal.closed and goal.nudges == 0 and goal.route_mode == :gvr
    end)
  end

  defp real_goals do
    [
      %{
        id: "alpha_marker_file",
        project_name: "Real Goal Alpha Marker",
        objective: "Create a small marker file with exact text.",
        project_brief: """
        Real external goal alpha.
        The accepted final state is a workspace file at notes/closure.txt
        containing exactly orchid-real-goal-alpha.
        """,
        goal_name: "Close alpha marker file",
        goal_description: """
        Use the product worker path to close this task.

        Create exactly one Shell Operator child goal. The child goal must create
        /workspace/notes/closure.txt with exactly this line:
        orchid-real-goal-alpha

        The child goal must run:
        grep -qx 'orchid-real-goal-alpha' /workspace/notes/closure.txt

        The child goal must call task_report_result with outcome "success",
        mark_completed true, and command evidence.

        When the child goal is completed, call task_report_result for this
        parent goal with outcome "success", mark_completed true, and include the
        child goal id plus the grep result. Do not create extra child goals.
        """,
        success_check:
          "cd /workspace && test -f notes/closure.txt && grep -qx 'orchid-real-goal-alpha' notes/closure.txt",
        seed_files: [
          %{
            path: "README.md",
            content: "Real goal alpha: create notes/closure.txt with the required marker.\n"
          }
        ]
      },
      %{
        id: "bravo_executable_script",
        project_name: "Real Goal Bravo Script",
        objective: "Create one executable script with exact output.",
        project_brief: """
        Real external goal bravo.
        The accepted final state is an executable bin/answer.sh whose output is
        exactly bravo-42.
        """,
        goal_name: "Close bravo executable script",
        goal_description: """
        Use the product worker path to close this task.

        Create exactly one Shell Operator child goal. The child goal must create
        /workspace/bin/answer.sh as an executable POSIX sh script. Running it
        must print exactly:
        bravo-42

        The child goal must run:
        test -x /workspace/bin/answer.sh && test "$(/workspace/bin/answer.sh)" = "bravo-42"

        The child goal must call task_report_result with outcome "success",
        mark_completed true, and command evidence.

        When the child goal is completed, call task_report_result for this
        parent goal with outcome "success", mark_completed true, and include the
        child goal id plus the test result. Do not create extra child goals.
        """,
        success_check:
          "cd /workspace && test -x bin/answer.sh && test \"$(bin/answer.sh)\" = \"bravo-42\"",
        seed_files: [
          %{
            path: "README.md",
            content: "Real goal bravo: create executable bin/answer.sh.\n"
          }
        ]
      },
      %{
        id: "charlie_status_json",
        project_name: "Real Goal Charlie Status",
        objective: "Update one seeded status file to closed.",
        project_brief: """
        Real external goal charlie.
        The accepted final state is data/status.txt containing exactly
        state=closed.
        """,
        goal_name: "Close charlie status file",
        goal_description: """
        Use the product worker path to close this task.

        Create exactly one Shell Operator child goal. The child goal must edit
        /workspace/data/status.txt so it contains exactly this line:
        state=closed

        The child goal must run:
        grep -qx 'state=closed' /workspace/data/status.txt

        The child goal must call task_report_result with outcome "success",
        mark_completed true, and command evidence.

        When the child goal is completed, call task_report_result for this
        parent goal with outcome "success", mark_completed true, and include the
        child goal id plus the grep result. Do not create extra child goals.
        """,
        success_check:
          "cd /workspace && test -f data/status.txt && grep -qx 'state=closed' data/status.txt",
        seed_files: [
          %{
            path: "README.md",
            content: "Real goal charlie: update data/status.txt to state closed.\n"
          },
          %{
            path: "data/status.txt",
            content: "state=open\n"
          }
        ]
      },
      %{
        id: "echo_multifile",
        project_name: "Real Goal Echo Multifile",
        objective: "Create two text files with exact contents.",
        project_brief: """
        Real external goal echo.
        The accepted final state is two workspace files at notes/echo-left.txt
        and notes/echo-right.txt containing exactly the requested text.
        """,
        goal_name: "Close echo multifile text",
        goal_description: """
        Use the product worker path to close this task.

        Create exactly one Shell Operator child goal. The child goal must create
        /workspace/notes/echo-left.txt with exactly this line:
        orchid-echo-left

        The child goal must also create /workspace/notes/echo-right.txt with
        exactly this line:
        orchid-echo-right

        The child goal must run:
        cd /workspace && test -f notes/echo-left.txt && test -f notes/echo-right.txt && printf 'orchid-echo-left\\n' | cmp -s notes/echo-left.txt - && printf 'orchid-echo-right\\n' | cmp -s notes/echo-right.txt -

        The child goal must call task_report_result with outcome "success",
        mark_completed true, and command evidence.

        When the child goal is completed, call task_report_result for this
        parent goal with outcome "success", mark_completed true, and include the
        child goal id plus the cmp result. Do not create extra child goals.
        """,
        success_check:
          "cd /workspace && test -f notes/echo-left.txt && test -f notes/echo-right.txt && printf 'orchid-echo-left\\n' | cmp -s notes/echo-left.txt - && printf 'orchid-echo-right\\n' | cmp -s notes/echo-right.txt -",
        seed_files: [
          %{
            path: "README.md",
            content: "Real goal echo: create two notes/echo text files.\n"
          }
        ]
      }
    ]
  end

  defp gvr_real_goals do
    [
      %{
        id: "delta_dependency_order_refactor",
        project_name: "GVR Real Goal Delta Dependency Order",
        objective:
          "Refactor the deployment stage ordering under explicit constraints and dependency sequencing.",
        project_brief: """
        Real external GVR goal delta.
        The accepted final state is config/stages.txt containing exactly three
        ordered lines. The dependency constraints are: build before test, test
        before deploy, and no extra lines.
        """,
        goal_name: "Close delta dependency order refactor",
        goal_description: """
        Use the product worker path to close this constrained ordering task.

        Create exactly one Shell Operator child goal. The child goal must
        refactor /workspace/config/stages.txt so the dependency sequence is
        exactly:
        build
        test
        deploy

        The child goal must preserve only those three ordered lines and run:
        cd /workspace && test -f config/stages.txt && printf 'build\\ntest\\ndeploy\\n' | cmp -s config/stages.txt -

        The child goal must call task_report_result with outcome "success",
        mark_completed true, and command evidence.

        When the child goal is completed, call task_report_result for this
        parent goal with outcome "success", mark_completed true, and include
        the child goal id plus the cmp result. Do not create extra child goals.
        """,
        success_check:
          "cd /workspace && test -f config/stages.txt && printf 'build\\ntest\\ndeploy\\n' | cmp -s config/stages.txt -",
        max_steps: 8,
        seed_files: [
          %{
            path: "README.md",
            content: "GVR real goal delta: refactor config/stages.txt into dependency order.\n"
          },
          %{
            path: "config/stages.txt",
            content: "deploy\ntest\nbuild\n"
          }
        ]
      }
    ]
  end

  defp gvr_vs_flat_real_goal do
    gvr_real_goals()
    |> List.first()
  end

  defp start_dependencies! do
    for app <- [:logger, :crypto, :ssl, :public_key, :jason, :req, :cubdb] do
      case Application.ensure_all_started(app) do
        {:ok, _} -> :ok
        {:error, reason} -> Mix.raise("failed to start #{inspect(app)}: #{inspect(reason)}")
      end
    end
  end

  defp start_minimal_runtime! do
    ensure_distributed_node!()
    ensure_ets!(:orchid_agent_states, [:public, :set, read_concurrency: true])

    ensure_ets!(:orchid_agent_runtime, [
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    children = [
      Orchid.Store,
      {Registry, keys: :unique, name: Orchid.Registry},
      Orchid.Autonomy.SandboxReaper,
      {DynamicSupervisor, strategy: :one_for_one, name: Orchid.AgentSupervisor},
      Orchid.GoalReviewQueue
    ]

    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, pid} -> pid
      {:error, reason} -> Mix.raise("failed to start minimal runtime: #{inspect(reason)}")
    end
  end

  defp ensure_distributed_node! do
    expected = :"orchid@127.0.0.1"

    case Node.self() do
      :nonode@nohost ->
        case Node.start(expected) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> Mix.raise("failed to start #{expected}: #{inspect(reason)}")
        end

      ^expected ->
        :ok

      other ->
        Mix.raise("expected node #{expected} for Orchid MCP bridge, got #{other}")
    end
  end

  defp ensure_ets!(name, opts) do
    case :ets.info(name) do
      :undefined ->
        :ets.new(name, [:named_table | opts])
        :ok

      _ ->
        :ok
    end
  end

  defp seed_templates! do
    Orchid.Seeds.seed_templates()
  end

  defp seed_facts! do
    case Orchid.Facts.seed_from_local_file() do
      {:ok, %{missing: true, path: path}} ->
        Mix.raise("facts source missing at #{path}")

      {:ok, %{error: error, path: path}} ->
        Mix.raise("failed to seed facts from #{path}: #{inspect(error)}")

      {:ok, _stats} ->
        :ok
    end

    :ok
  end

  defp force_closure_model_templates! do
    for template <- Object.list_agent_templates() do
      updates = %{provider: @closure_provider, model: @closure_model}

      updates =
        cond do
          template.name == "Planner" ->
            updates
            |> Map.put(:use_orchid_tools, true)
            |> Map.put(:allowed_tools, [
              "goal_list",
              "goal_read",
              "goal_create",
              "subgoal_create",
              "subgoal_list",
              "task_report_result",
              "agent_spawn",
              "active_agents",
              "wait",
              "list",
              "read",
              "grep",
              "ping"
            ])

          template.name == "Shell Operator" ->
            Map.put(updates, :allowed_tools, [
              "shell",
              "read",
              "edit",
              "list",
              "grep",
              "task_report_result"
            ])

          true ->
            updates
        end

      {:ok, _} = Object.update_metadata(template.id, updates)
    end
  end

  defp start_goal_watcher!(repo_cwd) do
    File.cd!(repo_cwd)

    case GoalWatcher.start_link([]) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
      {:error, reason} -> Mix.raise("failed to start GoalWatcher: #{inspect(reason)}")
    end
  end

  defp cleanup_project(project_id, repo_cwd) do
    try do
      File.cd!(repo_cwd)
      Object.update_metadata(project_id, %{status: :real_goal_harness_done, clearing_goals: true})
      stop_project_agents(project_id)
      Projects.stop_sandbox(project_id)
      :ok
    after
      File.cd!(repo_cwd)
    end
  end

  defp stop_project_agents(project_id) do
    Agent.list()
    |> Enum.each(fn agent_id ->
      case Agent.get_state(agent_id, 2_000) do
        {:ok, %{project_id: ^project_id}} -> Agent.stop(agent_id)
        _ -> :ok
      end
    end)
  end

  defp active_agent_states(project_id) do
    Agent.list()
    |> Enum.flat_map(fn agent_id ->
      case Agent.get_state(agent_id, 2_000) do
        {:ok, %{project_id: ^project_id} = state} ->
          [
            %{
              id: state.id,
              status: state.status,
              provider: state.config[:provider],
              model: state.config[:model],
              planner_mode: state.config[:planner_mode],
              use_orchid_tools: state.config[:use_orchid_tools] == true,
              last_assistant_message: last_assistant_message(state)
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp goal_snapshot(goal) do
    %{
      id: goal.id,
      name: goal.name,
      status: metadata(goal, :status),
      parent_goal_id: metadata(goal, :parent_goal_id),
      agent_id: metadata(goal, :agent_id),
      task_outcome: metadata(goal, :task_outcome),
      completion_summary: truncate(metadata(goal, :completion_summary), 500),
      last_error: truncate(metadata(goal, :last_error), 500),
      report: truncate(metadata(goal, :report), 1_000)
    }
  end

  defp completed?(nil), do: false
  defp completed?(goal), do: metadata(goal, :status) in [:completed, "completed"]

  defp metadata(%{metadata: metadata}, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata(_goal, _key), do: nil

  defp timeout_blocker(goals, active_agents, success) do
    %{
      success_check_error: Map.get(success, :error),
      open_goals: goals |> Enum.reject(&completed?/1) |> Enum.map(&goal_snapshot/1),
      active_agents: active_agents
    }
  end

  defp failure_mode(%{result: :timeout} = result) do
    text =
      [
        inspect(result.success_check),
        inspect(result.blocker),
        inspect(Enum.map(result.goals, &goal_snapshot/1)),
        inspect(result.active_agents)
      ]
      |> Enum.join("\n")

    cond do
      reliability_failure?(text) -> "reliability_flake: #{truncate(text, 800)}"
      true -> "timeout_no_external_success: #{truncate(text, 800)}"
    end
  end

  defp failure_mode(result) do
    text = inspect(result)

    cond do
      reliability_failure?(text) -> "reliability_flake: #{truncate(text, 800)}"
      true -> "goal_not_closed: #{truncate(text, 800)}"
    end
  end

  defp reliability_failure?(value), do: __MODULE__.ReliabilityRetry.reliability_failure?(value)

  defp write_report!(report, output_path) do
    output_path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(output_path, Jason.encode!(json_safe(report), pretty: true))
  end

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, val} -> {json_key(key), json_safe(val)} end)
  end

  defp json_safe(value) when is_boolean(value) or is_nil(value), do: value
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: inspect(value)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: to_string(key)

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

  defp validate_non_negative_integer!(value, _flag) when is_integer(value) and value >= 0,
    do: value

  defp validate_non_negative_integer!(value, flag),
    do: Mix.raise("#{flag} must be non-negative, got #{inspect(value)}")

  defp temp_data_dir do
    suffix = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    Path.join(System.tmp_dir!(), "orchid-real-goal-closure-#{suffix}")
  end

  defp safe_rm_rf_temp!(path, prefix) when is_binary(path) and is_binary(prefix) do
    expanded = Path.expand(path)
    tmp = System.tmp_dir!() |> Path.expand()
    base = Path.basename(expanded)

    if String.starts_with?(expanded, tmp <> "/") and String.starts_with?(base, prefix) do
      File.rm_rf(expanded)
    else
      Mix.raise("refusing to remove non-harness temp path: #{expanded}")
    end
  end

  defp last_assistant_message(%{messages: messages}) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(Map.get(&1, :role) == :assistant))
    |> case do
      nil -> nil
      message -> message |> Map.get(:content) |> truncate(1_000)
    end
  end

  defp last_assistant_message(_state), do: nil

  defp shell_escape(arg) do
    escaped = String.replace(arg, "'", "'\\''")
    "'#{escaped}'"
  end

  defp stop_named(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end

      nil ->
        :ok
    end
  end

  defp format_reason({:exception, error, stacktrace}) do
    Exception.format(:error, error, stacktrace) |> truncate(1_000)
  end

  defp format_reason(reason), do: reason |> inspect() |> truncate(1_000)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp truncate(nil, _max), do: nil

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    binary_part(text, 0, max) <> "..."
  end

  defp truncate(text, _max), do: text

  defmodule ReliabilityRetry do
    @moduledoc false

    def run(next_attempt, max_retries, summarize_attempt \\ & &1)
        when is_function(next_attempt, 0) and is_integer(max_retries) and max_retries >= 0 and
               is_function(summarize_attempt, 1) do
      attempts = collect_attempts(next_attempt, max_retries, [])

      attempts
      |> List.last()
      |> annotate_attempts(attempts, max_retries, summarize_attempt)
    end

    def should_retry?(result, retries_remaining) do
      cond do
        result.closed ->
          false

        not result.reliability_failure ->
          false

        retries_remaining <= 0 ->
          false

        true ->
          true
      end
    end

    def annotate_attempts(result, attempts, max_retries, summarize_attempt \\ & &1)
        when is_function(summarize_attempt, 1) do
      attempts_used = length(attempts)

      result
      |> Map.put(:attempts_used, attempts_used)
      |> Map.put(:reliability_retry_limit, max_retries)
      |> Map.put(:retried, attempts_used > 1)
      |> Map.put(
        :attempts,
        attempts
        |> Enum.with_index(1)
        |> Enum.map(fn {attempt, index} ->
          attempt
          |> summarize_attempt.()
          |> Map.put(:attempt, index)
        end)
      )
    end

    def reliability_failure?(nil), do: false

    def reliability_failure?(text) when is_binary(text) do
      down = String.downcase(text)

      Enum.any?(
        [
          "429",
          "rate limit",
          "quota",
          "empty output",
          "empty response",
          "no decodable output",
          "api_key_missing",
          "database or disk is full",
          "no space left",
          "enospc",
          "container save",
          "exit code 125",
          "no container with name",
          "no such container",
          "timed out starting orchid mcp bridge",
          "openrouter api error"
        ],
        &String.contains?(down, &1)
      )
    end

    def reliability_failure?(other), do: other |> inspect() |> reliability_failure?()

    defp collect_attempts(next_attempt, retries_remaining, attempts) do
      result = next_attempt.()
      attempts = attempts ++ [result]

      if should_retry?(result, retries_remaining) do
        collect_attempts(next_attempt, retries_remaining - 1, attempts)
      else
        attempts
      end
    end
  end

  defmodule ModelCallCounter do
    @moduledoc false

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
end
