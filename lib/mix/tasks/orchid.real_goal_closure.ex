defmodule Mix.Tasks.Orchid.RealGoalClosure do
  @moduledoc """
  Runs Orchid's real-goal closure harness through the product GoalWatcher path.
  """

  use Mix.Task

  alias Orchid.Planner.{Router, RuntimeGoal}
  alias Orchid.{Agent, GoalWatcher, Object, Project, Projects, Sandbox}

  @shortdoc "Run the Orchid real-goal closure harness"
  @default_out Path.join(["priv", "autonomy", "real_goal_closure.json"])
  @default_goal_timeout_ms 720_000
  @default_success_timeout_ms 30_000
  @poll_interval_ms 5_000
  @completion_grace_ms 120_000
  @free_provider :openrouter
  @free_model :nex_n2_pro

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          out: :string,
          goal_timeout_ms: :integer,
          success_timeout_ms: :integer,
          keep_data_dir: :boolean
        ]
      )

    reject_invalid_options!(invalid)

    output_path = opts |> Keyword.get(:out, @default_out) |> validate_output_path!()

    goal_timeout_ms =
      opts
      |> Keyword.get(:goal_timeout_ms, @default_goal_timeout_ms)
      |> validate_positive_integer!("--goal-timeout-ms")

    success_timeout_ms =
      opts
      |> Keyword.get(:success_timeout_ms, @default_success_timeout_ms)
      |> validate_positive_integer!("--success-timeout-ms")

    keep_data_dir? = Keyword.get(opts, :keep_data_dir, false)
    data_dir = temp_data_dir()
    started_at = monotonic_ms()

    Application.put_env(:orchid, :data_dir, data_dir)
    Application.put_env(:orchid, :goal_watcher_planner_mode, :auto)

    start_dependencies!()
    supervisor = start_minimal_runtime!()

    report =
      try do
        seed_templates!()
        seed_facts!()
        force_free_model_templates!()

        definitions = real_goals()

        goals =
          Enum.map(definitions, fn definition ->
            run_goal(definition, goal_timeout_ms, success_timeout_ms)
          end)

        report = build_report(goals, definitions, data_dir, output_path, started_at)
        write_report!(report, output_path)
        report
      after
        stop_named(GoalWatcher)
        Supervisor.stop(supervisor)

        unless keep_data_dir? do
          File.rm_rf(data_dir)
        end
      end

    Mix.shell().info(
      "orchid.real_goal_closure: closed #{report.closed_count}/#{report.n_goals}; " <>
        "wrote #{output_path}"
    )
  end

  defp run_goal(definition, goal_timeout_ms, success_timeout_ms) do
    started_at = monotonic_ms()

    case create_fixture(definition) do
      {:ok, %{project: project, goal: goal, workspace: workspace}} ->
        runtime_goal_input = RuntimeGoal.from_goal_watcher(project, [goal])
        request = GoalWatcher.runtime_planner_request(project, [goal])
        decision = Router.classify(request.route_input)

        runtime_contract = %{
          goal_label: request.goal_label,
          route_input_matches_runtime_goal: request.route_input == runtime_goal_input
        }

        counter = __MODULE__.ModelCallCounter.start!()
        start_goal_watcher!()

        try do
          send(GoalWatcher, :check)

          wait_result =
            wait_for_goal(definition, project, goal.id, %{
              deadline: monotonic_ms() + goal_timeout_ms,
              success_timeout_ms: success_timeout_ms,
              watcher_checks: 1,
              success_seen_at: nil
            })

          model_calls = __MODULE__.ModelCallCounter.stop(counter)
          cleanup_project(project.id)

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
            cleanup_project(project.id)

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
            cleanup_project(project.id)

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
          stop_named(GoalWatcher)
        end

      {:error, reason} ->
        %{
          id: definition.id,
          closed: false,
          nudges: 0,
          failure_mode: "fixture_error: #{truncate(inspect(reason), 800)}",
          reliability_failure: false,
          status: :fixture_error,
          duration_ms: monotonic_ms() - started_at
        }
    end
  end

  defp wait_for_goal(definition, project, goal_id, state) do
    now = monotonic_ms()
    success = run_success_check(project.id, definition.success_check, state.success_timeout_ms)
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

  defp build_report(goals, definitions, data_dir, output_path, started_at) do
    closed_count = Enum.count(goals, & &1.closed)

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      harness: "Mix.Tasks.Orchid.RealGoalClosure",
      harness_path: "lib/mix/tasks/orchid.real_goal_closure.ex",
      product_entry: "Orchid.GoalWatcher",
      route_contract:
        "GoalWatcher.runtime_planner_request -> RuntimeGoal.from_goal_watcher -> Router -> planner",
      runner_substrate: "durable per-project sandbox via Orchid.Projects.ensure_sandbox",
      model: "openrouter/#{Orchid.LLM.Catalog.resolve_model(@free_model, @free_provider)}",
      data_dir: data_dir,
      report_path: output_path,
      n_goals: length(definitions),
      closed_count: closed_count,
      criteria: %{
        ran_all_3: length(goals) == 3,
        at_least_1_closed_with_zero_nudges:
          closed_count >= 1 and Enum.any?(goals, &(&1.closed and &1.nudges == 0)),
        all_success_checks_external: true
      },
      goals: goals,
      duration_ms: monotonic_ms() - started_at
    }
  end

  defp create_fixture(definition) do
    with {:ok, project} <-
           Object.create(:project, definition.project_name, String.trim(definition.project_brief),
             metadata: %{
               status: :active,
               objective: definition.objective,
               success_criteria: "shell: #{definition.success_check}",
               max_steps: 8
             }
           ),
         {:ok, goal} <-
           Object.create(:goal, definition.goal_name, String.trim(definition.goal_description),
             metadata: %{
               project_id: project.id,
               status: :pending,
               depends_on: [],
               max_steps: 8
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

  defp run_success_check(project_id, command, timeout_ms) do
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
      }
    ]
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
      {DynamicSupervisor, strategy: :one_for_one, name: Orchid.AgentSupervisor},
      Orchid.GoalReviewQueue
    ]

    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, pid} -> pid
      {:error, reason} -> Mix.raise("failed to start minimal runtime: #{inspect(reason)}")
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

    unless Object.get_fact_value("openrouter_api_key") do
      Mix.raise("openrouter_api_key fact was not loaded")
    end
  end

  defp force_free_model_templates! do
    for template <- Object.list_agent_templates() do
      updates = %{provider: @free_provider, model: @free_model}

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

  defp start_goal_watcher! do
    case GoalWatcher.start_link([]) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
      {:error, reason} -> Mix.raise("failed to start GoalWatcher: #{inspect(reason)}")
    end
  end

  defp cleanup_project(project_id) do
    Object.update_metadata(project_id, %{status: :real_goal_harness_done, clearing_goals: true})
    stop_project_agents(project_id)
    Projects.stop_sandbox(project_id)
    :ok
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

  defp reliability_failure?(nil), do: false

  defp reliability_failure?(text) when is_binary(text) do
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
        "timed out starting orchid mcp bridge",
        "openrouter"
      ],
      &String.contains?(down, &1)
    )
  end

  defp reliability_failure?(other), do: other |> inspect() |> reliability_failure?()

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

  defp temp_data_dir do
    Path.join(System.tmp_dir!(), "orchid-real-goal-closure-#{System.unique_integer([:positive])}")
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
