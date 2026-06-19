defmodule Orchid.ProductClosureSmoke do
  alias Orchid.Object

  @executed_command "mix run --no-start priv/smoke/product_closure_smoke.exs"
  @success_command "test -x /workspace/hello.sh && [ \"$(/workspace/hello.sh)\" = \"hello\" ]"
  @wall_clock_timeout_ms 720_000
  @poll_interval_ms 5_000
  @manual_check_interval_ms 20_000
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
        "orchid-product-closure-smoke-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:orchid, :data_dir, data_dir)
    Application.put_env(:orchid, :goal_watcher_planner_mode, :flat)

    start_dependencies!()
    supervisor = start_minimal_runtime!()

    try do
      seed_templates!()
      seed_facts!()
      force_free_model_templates!()

      {project, goal, workspace} = create_fixture!()

      IO.puts("ORCHID_PRODUCT_CLOSURE_SMOKE")
      IO.puts("EXECUTED_COMMAND=#{@executed_command}")
      IO.puts("RAN_UNDER_MIX_RUN_NO_START=#{not app_started?(:orchid)}")
      IO.puts("PRODUCT_ENTRY=Orchid.GoalWatcher")
      IO.puts("PLANNER_MODE=flat")
      IO.puts("MODEL=openrouter/#{Orchid.LLM.Catalog.resolve_model(:nex_n2_pro, :openrouter)}")
      IO.puts("PROJECT_ID=#{project.id}")
      IO.puts("TOP_GOAL_ID=#{goal.id}")
      IO.puts("WORKSPACE=#{workspace}")
      IO.puts("SUCCESS_CHECK=#{@success_command}")

      result = run_product_path!(project, goal)
      print_result!(result)

      if result.result == :error do
        System.halt(2)
      end
    after
      stop_named(Orchid.GoalWatcher)
      Supervisor.stop(supervisor)
      File.rm_rf(data_dir)
    end
  end

  defp run_product_path!(project, goal) do
    counter = ModelCallCounter.start!()

    try do
      start_goal_watcher!()
      send(Orchid.GoalWatcher, :check)

      result =
        wait_for_goal(project, goal.id, %{
          deadline: System.monotonic_time(:millisecond) + @wall_clock_timeout_ms,
          next_check: System.monotonic_time(:millisecond) + @manual_check_interval_ms
        })

      Map.put(result, :model_calls, :pending)
    after
      Process.put(:orchid_product_closure_model_calls, ModelCallCounter.stop(counter))
    end
    |> Map.put(:model_calls, Process.get(:orchid_product_closure_model_calls, :unknown))
  end

  defp wait_for_goal(project, goal_id, state) do
    now = System.monotonic_time(:millisecond)
    maybe_trigger_check(now, state.next_check)

    case Object.get(goal_id) do
      {:ok, goal} ->
        goals = Object.list_goals_for_project(project.id)
        closed_by_status = completed?(goal)

        if closed_by_status do
          success = run_success_check(project.id)

          %{
            result: :ok,
            closed_by_status: true,
            success_check: success,
            goals: goals,
            active_agents: active_agent_states(),
            blocker: nil
          }
        else
          if now >= state.deadline do
            %{
              result: :timeout,
              closed_by_status: false,
              success_check: run_success_check(project.id),
              goals: goals,
              active_agents: active_agent_states(),
              blocker: timeout_blocker(goals)
            }
          else
            Process.sleep(@poll_interval_ms)

            wait_for_goal(project, goal_id, %{
              state
              | next_check:
                  if(now >= state.next_check,
                    do: now + @manual_check_interval_ms,
                    else: state.next_check
                  )
            })
          end
        end

      {:error, reason} ->
        %{
          result: :error,
          closed_by_status: false,
          success_check: {:error, "top goal lookup failed: #{inspect(reason)}"},
          goals: Object.list_goals_for_project(project.id),
          active_agents: active_agent_states(),
          blocker: "Orchid.Object.get/1 failed for top goal #{goal_id}: #{inspect(reason)}"
        }
    end
  end

  defp maybe_trigger_check(now, next_check) when now >= next_check do
    if Process.whereis(Orchid.GoalWatcher) do
      send(Orchid.GoalWatcher, :check)
    end
  end

  defp maybe_trigger_check(_now, _next_check), do: :ok

  defp start_dependencies! do
    for app <- [:logger, :crypto, :ssl, :public_key, :jason, :req, :cubdb] do
      case Application.ensure_all_started(app) do
        {:ok, _} -> :ok
        {:error, reason} -> raise "failed to start #{inspect(app)}: #{inspect(reason)}"
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
      {:error, reason} -> raise "failed to start minimal runtime: #{inspect(reason)}"
    end
  end

  defp start_goal_watcher! do
    case Orchid.GoalWatcher.start_link([]) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
      {:error, reason} -> raise "failed to start GoalWatcher: #{inspect(reason)}"
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
        raise "facts source missing at #{path}"

      {:ok, %{error: error, path: path}} ->
        raise "failed to seed facts from #{path}: #{inspect(error)}"

      {:ok, stats} ->
        IO.puts(
          "FACTS_SEEDED path=#{stats.path} created=#{stats.created} updated=#{stats.updated} skipped=#{stats.skipped}"
        )
    end

    unless Object.get_fact_value("openrouter_api_key") do
      raise "openrouter_api_key fact was not loaded"
    end
  end

  defp force_free_model_templates! do
    for template <- Object.list_agent_templates() do
      updates = %{provider: :openrouter, model: :nex_n2_pro}

      updates =
        if template.name == "Planner",
          do: Map.put(updates, :use_orchid_tools, true),
          else: updates

      {:ok, _} = Object.update_metadata(template.id, updates)
    end
  end

  defp create_fixture! do
    objective =
      "Create /workspace/hello.sh as an executable POSIX shell script that prints exactly hello."

    project_brief = """
    Product closure smoke fixture. Use the existing Orchid planner/worker tools to close the goal.
    The only accepted final state is an executable /workspace/hello.sh whose output is exactly hello.
    """

    {:ok, project} =
      Object.create(:project, "Product Closure Smoke", String.trim(project_brief),
        metadata: %{
          status: :active,
          objective: objective,
          success_criteria: @success_command,
          max_steps: 6
        }
      )

    goal_description = """
    Orchestrate one bounded operational task through the product path.

    Create exactly one Shell Operator child goal. That child goal must:
    - create /workspace/hello.sh with POSIX sh content that prints exactly hello followed by a newline
    - make /workspace/hello.sh executable
    - run /workspace/hello.sh and report the exact output
    - call task_report_result with outcome "success", mark_completed true, and include the command evidence

    After that child goal is completed, call task_report_result for this parent goal with outcome "success",
    mark_completed true, and include the child goal ID plus the observed hello output. Do not create extra child goals.
    """

    {:ok, goal} =
      Object.create(
        :goal,
        "Close hello script through product GoalWatcher",
        String.trim(goal_description),
        metadata: %{
          project_id: project.id,
          status: :pending,
          depends_on: [],
          max_steps: 6
        }
      )

    {:ok, workspace} = Orchid.Project.ensure_dir(project.id)
    {project, goal, workspace}
  end

  defp run_success_check(project_id) do
    case Orchid.Sandbox.status(project_id) do
      %{status: :ready, running: true} ->
        case Orchid.Sandbox.exec(project_id, @success_command, timeout: @success_timeout_ms) do
          {:ok, output} -> {:ok, String.trim(output)}
          {:error, reason} -> {:error, inspect(reason)}
        end

      _ ->
        root = Orchid.Project.files_path(project_id)
        command = String.replace(@success_command, "/workspace", shell_escape(root))

        case System.cmd("sh", ["-c", command], stderr_to_stdout: true) do
          {output, 0} -> {:ok, String.trim(output)}
          {output, code} -> {:error, "exit=#{code} output=#{String.trim(output)}"}
        end
    end
  end

  defp print_result!(result) do
    success_check_passed = match?({:ok, _}, result.success_check)
    goal_closure = result.closed_by_status and success_check_passed

    IO.puts("PRODUCT_PATH_RESULT=#{result.result}")
    IO.puts("TOP_GOAL_STATUS_COMPLETED=#{result.closed_by_status}")
    IO.puts("SUCCESS_CHECK_PASSED=#{success_check_passed}")
    IO.puts("GOAL_CLOSURE=#{goal_closure}")
    IO.puts("MODEL_CALLS_OBSERVED=#{result.model_calls}")
    IO.puts("MODEL_CALLS_NOTE=observed via runtime trace of Orchid.LLM chat/chat_stream calls")
    IO.puts("RAN_UNDER_NO_START=yes")

    case result.success_check do
      {:ok, output} -> IO.puts("SUCCESS_CHECK_OUTPUT=#{inspect(output)}")
      {:error, reason} -> IO.puts("SUCCESS_CHECK_ERROR=#{reason}")
    end

    if result.blocker do
      IO.puts("BLOCKER=#{result.blocker}")
    end

    IO.puts("GOALS_JSON_BEGIN")
    IO.puts(Jason.encode!(Enum.map(result.goals, &goal_snapshot/1), pretty: true))
    IO.puts("GOALS_JSON_END")

    IO.puts("ACTIVE_AGENTS_JSON_BEGIN")
    IO.puts(Jason.encode!(result.active_agents, pretty: true))
    IO.puts("ACTIVE_AGENTS_JSON_END")
  end

  defp goal_snapshot(goal) do
    %{
      id: goal.id,
      name: goal.name,
      status: metadata(goal, :status),
      agent_id: metadata(goal, :agent_id),
      parent_goal_id: metadata(goal, :parent_goal_id),
      task_outcome: metadata(goal, :task_outcome),
      last_error: metadata(goal, :last_error),
      completion_summary: metadata(goal, :completion_summary),
      report: truncate(metadata(goal, :report), 2_000)
    }
  end

  defp active_agent_states do
    Orchid.Agent.list()
    |> Enum.map(fn agent_id ->
      case Orchid.Agent.get_state(agent_id, 2_000) do
        {:ok, state} ->
          %{
            id: state.id,
            project_id: state.project_id,
            status: inspect(state.status),
            provider: state.config[:provider],
            model: state.config[:model],
            template_id: state.config[:template_id],
            use_orchid_tools: state.config[:use_orchid_tools],
            message_count: length(state.messages),
            tool_count: length(state.tool_history)
          }

        {:error, reason} ->
          %{id: agent_id, error: inspect(reason)}
      end
    end)
  end

  defp timeout_blocker(goals) do
    summary =
      goals
      |> Enum.map(fn goal ->
        "#{goal.name}[#{goal.id}] status=#{inspect(metadata(goal, :status))} agent=#{inspect(metadata(goal, :agent_id))} outcome=#{inspect(metadata(goal, :task_outcome))} error=#{inspect(metadata(goal, :last_error))}"
      end)
      |> Enum.join("; ")

    "Timed out after #{div(@wall_clock_timeout_ms, 1000)}s waiting for product GoalWatcher closure; #{summary}"
  end

  defp completed?(goal), do: metadata(goal, :status) in [:completed, "completed"]

  defp metadata(%{metadata: metadata}, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata(_goal, _key), do: nil

  defp truncate(nil, _max), do: nil

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end

  defp truncate(other, _max), do: other

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

  defp app_started?(app) do
    Application.started_applications()
    |> Enum.any?(fn {started_app, _description, _version} -> started_app == app end)
  end
end

Orchid.ProductClosureSmoke.run()
