defmodule Orchid.ProductPathSmoke do
  alias Orchid.Object
  alias Orchid.Planner.RuntimeGoal
  alias Orchid.Planner.Router

  @model_config %{
    provider: :openrouter,
    model: :nex_n2_pro,
    disable_tools: true,
    max_turns: 1,
    max_tokens: 1_200
  }

  def run do
    Logger.configure(level: :info)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "orchid-product-path-smoke-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:orchid, :data_dir, data_dir)

    start_dependencies!()
    supervisor = start_minimal_runtime!()

    try do
      seed_facts!()

      {project, goal} = smoke_objects()
      runtime_goal = RuntimeGoal.from_goal_watcher(project, [goal])
      request = Orchid.GoalWatcher.runtime_planner_request(project, [goal])

      unless request.route_input == runtime_goal do
        raise "GoalWatcher runtime route_input diverged from RuntimeGoal.from_goal_watcher/2"
      end

      IO.puts("ORCHID_PRODUCT_PATH_SMOKE")
      IO.puts("ROUTE_INPUT_JSON=#{Jason.encode!(request.route_input)}")

      decision = Router.route(request.route_input, request.goal_label)
      IO.puts("[ROUTER] -> #{inspect(decision.mode)} signal=#{decision.signal}")
      IO.puts("MODEL=openrouter/#{Orchid.LLM.Catalog.resolve_model(:nex_n2_pro, :openrouter)}")

      case decision.mode do
        :flat ->
          run_flat_planner!(request)

        :gvr ->
          run_gvr_planner!(request)
      end
    after
      Supervisor.stop(supervisor)
      File.rm_rf(data_dir)
    end
  end

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
      {DynamicSupervisor, strategy: :one_for_one, name: Orchid.AgentSupervisor}
    ]

    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, pid} -> pid
      {:error, reason} -> raise "failed to start minimal runtime: #{inspect(reason)}"
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

  defp smoke_objects do
    now = DateTime.utc_now()

    project = %Object{
      id: "product-smoke-project",
      type: :project,
      name: "Product Path Smoke",
      content: "",
      metadata: %{
        status: :active,
        objective: "Write a one-line shell script that prints hello.",
        success_criteria: "The returned plan includes a runnable hello-printing shell script."
      },
      created_at: now,
      updated_at: now
    }

    goal = %Object{
      id: "product-smoke-goal",
      type: :goal,
      name: "Write hello script",
      content: "Write a one-line shell script that prints hello.",
      metadata: %{
        project_id: project.id,
        status: :pending,
        depends_on: []
      },
      created_at: now,
      updated_at: now
    }

    {project, goal}
  end

  defp run_flat_planner!(request) do
    IO.puts("RESOLVED_ENTRY=Orchid.GoalWatcher.run_flat_planner_message/3")
    prompt = flat_smoke_user_prompt(request.planner_objective)

    case Orchid.GoalWatcher.run_flat_planner_message(
           flat_planner_config(),
           prompt,
           label: "product-path smoke",
           response_validator: &validate_task_array/1,
           on_agent_created: fn agent_id ->
             IO.puts("FLAT_ATTEMPT_AGENT=#{agent_id}")
           end
         ) do
      {:ok, response} ->
        IO.puts("MODEL_CALLS_OBSERVED=#{response.attempts}")
        print_plan(response.response)

      {:error, reason} ->
        raise "flat planner failed: #{reason}"
    end
  end

  defp flat_planner_config do
    %{
      provider: :openrouter,
      model: :nex_n2_pro,
      system_prompt: flat_smoke_system_prompt(),
      disable_tools: true,
      max_turns: 1,
      max_tokens: 1_200
    }
  end

  defp run_gvr_planner!(request) do
    IO.puts("RESOLVED_ENTRY=Orchid.Planner.plan/3")

    opts = [
      num_paths: 1,
      max_iterations: 1,
      max_concurrency: 1,
      llm_memoize: false,
      workspace_context: "(smoke test empty workspace)",
      llm_config: @model_config
    ]

    case Orchid.Planner.plan(request.planner_objective, nil, opts) do
      {:ok, plan} ->
        IO.puts("MODEL_CALLS_OBSERVED=2")
        print_plan(plan)

      {:error, reason} ->
        raise "gvr planner failed: #{inspect(reason)}"
    end
  end

  defp flat_smoke_system_prompt do
    """
    You are the Orchid flat planner entrypoint in a product-path smoke test.
    Treat the user message as the real planner kickoff. Do not call tools.
    Return only a JSON array with one or two task objects.
    Each task object must include id, type, objective, tool, and args.
    Prefer one concrete shell task for this trivial goal.
    """
    |> String.trim()
  end

  defp flat_smoke_user_prompt(planner_objective) do
    """
    #{planner_objective}

    Smoke-test response contract:
    Return a JSON task array only. Do not include markdown or prose.
    """
    |> String.trim()
  end

  defp print_plan(response) when is_binary(response) do
    trimmed = String.trim(response)
    IO.puts("PLAN_RAW_BEGIN")
    IO.puts(trimmed)
    IO.puts("PLAN_RAW_END")

    case Jason.decode(trimmed) do
      {:ok, decoded} ->
        IO.puts("TASK_ARRAY_JSON_BEGIN")
        IO.puts(Jason.encode!(decoded, pretty: true))
        IO.puts("TASK_ARRAY_JSON_END")

      {:error, reason} ->
        IO.puts("TASK_ARRAY_JSON_PARSE_ERROR=#{inspect(reason)}")
    end
  end

  defp validate_task_array(response) when is_binary(response) do
    trimmed = String.trim(response)

    cond do
      trimmed == "" ->
        {:retry, "empty_response"}

      true ->
        case Jason.decode(trimmed) do
          {:ok, decoded} when is_list(decoded) and decoded != [] ->
            {:ok, trimmed}

          {:ok, _decoded} ->
            {:retry, "json_not_nonempty_array"}

          {:error, reason} ->
            {:retry, "invalid_json: #{Exception.message(reason)}"}
        end
    end
  end

  defp validate_task_array(response), do: {:retry, "no_decodable_json: #{inspect(response)}"}
end

Orchid.ProductPathSmoke.run()
