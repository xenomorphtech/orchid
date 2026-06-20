defmodule Orchid.GoalWatcher do
  @moduledoc """
  Periodically checks for projects that have pending goals but no running agents.
  Spawns a Planner agent per project to orchestrate goals.
  Also detects dead agents (assigned to goals but no longer running) and
  re-kicks idle agents that still have unfinished work.
  """
  use GenServer
  require Logger
  alias Orchid.LLM
  alias Orchid.Planner.{Router, RuntimeGoal}

  @interval :timer.seconds(10)
  @log_file "priv/data/goal_watcher.log"
  @critic_config %{
    provider: :codex,
    model: :gpt54,
    model_reasoning_effort: "medium",
    max_turns: 8,
    max_tokens: 500,
    disable_tools: true
  }
  @default_output_retry_attempts 6

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # Don't re-kick an agent more than once per cooldown period
  @re_kick_cooldown :timer.minutes(5)

  @impl true
  def init(:ok) do
    File.mkdir_p!(Path.dirname(@log_file))
    log("started, checking every #{div(@interval, 1000)}s")
    schedule()
    # kicked_agents: %{agent_id => last_kick_time}
    {:ok, %{kicked_agents: %{}}}
  end

  @impl true
  def handle_info(:check, state) do
    state =
      try do
        check_projects(state)
      rescue
        e ->
          log(
            "CRASH in check_projects: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
          )

          state
      catch
        kind, reason ->
          log("CRASH in check_projects: #{inspect(kind)} #{inspect(reason)}")
          state
      end

    schedule()
    {:noreply, state}
  end

  defp schedule do
    Process.send_after(self(), :check, @interval)
  end

  defp check_projects(state) do
    projects = Orchid.Object.list_projects()
    running_agent_ids = MapSet.new(Orchid.Agent.list())

    # Build map of running agent states keyed by project_id
    agent_states =
      running_agent_ids
      |> Enum.reduce(%{}, fn id, acc ->
        case Orchid.Agent.get_state(id, 2000) do
          {:ok, agent_state} when not is_nil(agent_state.project_id) ->
            Map.update(acc, agent_state.project_id, [agent_state], &[agent_state | &1])

          _ ->
            acc
        end
      end)

    Enum.reduce(projects, state, fn project, acc_state ->
      if project.metadata[:status] in [nil, :active] and project.metadata[:clearing_goals] != true do
        goals = Orchid.Object.list_goals_for_project(project.id)
        pending = Enum.filter(goals, fn g -> Orchid.Goals.open_status?(g.metadata[:status]) end)

        if pending != [] do
          project_agents = Map.get(agent_states, project.id, [])
          handle_project(project, pending, project_agents, running_agent_ids, acc_state)
        else
          acc_state
        end
      else
        acc_state
      end
    end)
  end

  defp handle_project(project, pending_goals, project_agents, running_agent_ids, state) do
    # 1. Clean up goals assigned to dead agents
    orphaned =
      Enum.filter(pending_goals, fn g ->
        aid = g.metadata[:agent_id]
        aid != nil and aid not in running_agent_ids
      end)

    if orphaned != [] do
      log(
        "project \"#{project.name}\": #{length(orphaned)} goal(s) assigned to dead agents — clearing assignments",
        project_id: project.id
      )

      for goal <- orphaned do
        Orchid.Object.update_metadata(goal.id, %{agent_id: nil})

        log("  cleared dead agent from goal \"#{goal.name}\" [#{goal.id}]",
          project_id: project.id,
          metadata: %{goal_id: goal.id}
        )
      end
    end

    # Clean dead agents from kicked tracking
    state = %{
      state
      | kicked_agents:
          Map.reject(state.kicked_agents, fn {id, _} -> id not in running_agent_ids end)
    }

    # 2. No agents at all → spawn planner
    if project_agents == [] do
      # Re-fetch pending goals with cleared assignments
      pending =
        if orphaned != [] do
          Orchid.Object.list_goals_for_project(project.id)
          |> Enum.filter(fn g -> Orchid.Goals.open_status?(g.metadata[:status]) end)
        else
          pending_goals
        end

      log(
        "project \"#{project.name}\" has #{length(pending)} pending goal(s), 0 agents — spawning planner",
        project_id: project.id
      )

      spawn_planner(project, pending)
      state
    else
      # 3. Has idle agents with pending assigned goals → re-kick (with cooldown)
      re_kick_idle_agents(project, project_agents, state)
    end
  end

  defp re_kick_idle_agents(project, project_agents, state) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(project_agents, state, fn agent_state, acc_state ->
      if agent_state.status != :idle do
        acc_state
      else
        last_kick = Map.get(acc_state.kicked_agents, agent_state.id)

        if last_kick && now - last_kick < @re_kick_cooldown do
          acc_state
        else
          goals = Orchid.Object.list_goals_for_project(project.id)

          assigned_pending =
            Enum.filter(goals, fn g ->
              g.metadata[:agent_id] == agent_state.id and
                Orchid.Goals.open_status?(g.metadata[:status])
            end)

          re_kickable_goals = Enum.reject(assigned_pending, &goal_blocked?/1)

          if re_kickable_goals != [] do
            goal_names = Enum.map_join(re_kickable_goals, ", ", & &1.name)
            tag = agent_tag(agent_state)
            last_role = List.last(agent_state.messages) && List.last(agent_state.messages).role

            if last_role in [:user, :tool] do
              log(
                "agent #{agent_state.id} (#{tag}) idle, last msg=#{last_role}, goals: #{goal_names} — retrying",
                project_id: project.id,
                agent_id: agent_state.id
              )

              Task.start(fn ->
                case Orchid.Agent.retry(agent_state.id) do
                  {:ok, response} ->
                    preview = response |> String.slice(0, 200) |> String.replace("\n", " ")

                    log("agent #{agent_state.id} (#{tag}) retry responded: #{preview}",
                      project_id: project.id,
                      agent_id: agent_state.id
                    )

                  {:error, reason} ->
                    log(
                      "ERROR: agent #{agent_state.id} (#{tag}) retry failed: #{inspect(reason)}",
                      project_id: project.id,
                      agent_id: agent_state.id
                    )
                end
              end)
            else
              log("agent #{agent_state.id} (#{tag}) idle, goals: #{goal_names} — re-kicking",
                project_id: project.id,
                agent_id: agent_state.id
              )

              Task.start(fn ->
                message = build_rekick_message(agent_state, re_kickable_goals)

                case Orchid.Agent.stream(agent_state.id, message, fn _chunk -> :ok end) do
                  {:ok, response} ->
                    preview = response |> String.slice(0, 200) |> String.replace("\n", " ")

                    log("agent #{agent_state.id} (#{tag}) re-kick responded: #{preview}",
                      project_id: project.id,
                      agent_id: agent_state.id
                    )

                  {:error, reason} ->
                    log(
                      "ERROR: agent #{agent_state.id} (#{tag}) re-kick failed: #{inspect(reason)}",
                      project_id: project.id,
                      agent_id: agent_state.id
                    )
                end
              end)
            end

            %{acc_state | kicked_agents: Map.put(acc_state.kicked_agents, agent_state.id, now)}
          else
            acc_state
          end
        end
      end
    end)
  end

  @doc false
  def runtime_planner_request(project, pending_goals) do
    goals = List.wrap(pending_goals)
    goal_summary = format_goal_summary(goals)

    %{
      route_input: RuntimeGoal.from_goal_watcher(project, goals),
      goal_label: RuntimeGoal.goal_label(goals, project.id),
      planner_objective: planner_kickoff_message(project.name, project.content, goal_summary),
      goal_summary: goal_summary
    }
  end

  @doc false
  def plan_runtime_goals(project, pending_goals, opts \\ []) when is_list(opts) do
    request = runtime_planner_request(project, pending_goals)
    decision = route_runtime_request(request, opts)

    plan_routed_request(project, request, decision, opts)
  end

  @doc false
  def run_flat_planner_message(config, message, opts \\ [])
      when is_map(config) and is_binary(message) and is_list(opts) do
    agent_module = Keyword.get(opts, :agent_module, Orchid.Agent)
    label = Keyword.get(opts, :label, "kickoff")
    on_agent_created = Keyword.get(opts, :on_agent_created, fn _agent_id -> :ok end)
    response_validator = Keyword.get(opts, :response_validator, &usable_planner_response/1)
    max_attempts = output_retry_attempts(opts)

    run_flat_planner_message_with_output_retry(
      agent_module,
      config,
      String.trim(message),
      label,
      on_agent_created,
      response_validator,
      1,
      max_attempts
    )
  end

  defp spawn_planner(project, pending_goals) do
    request = runtime_planner_request(project, pending_goals)
    decision = route_runtime_request(request, [])

    case decision.mode do
      :flat -> spawn_flat_planner(project, pending_goals, request)
      :gvr -> spawn_gvr_planner(project, pending_goals, request, decision)
    end
  end

  defp spawn_flat_planner(project, pending_goals, request) do
    case find_planner_template() do
      nil ->
        log("ERROR: no Planner template found, skipping project \"#{project.name}\"",
          project_id: project.id
        )

      planner ->
        ensure_planner_sandbox(project)
        config = planner_agent_config(planner, project, :flat)

        Task.start(fn ->
          case run_flat_planner_message(config, request.planner_objective,
                 label: "kickoff",
                 on_agent_created: fn agent_id ->
                   log("spawned flat planner #{agent_id} for project \"#{project.name}\"",
                     project_id: project.id,
                     agent_id: agent_id
                   )

                   assign_unassigned_goals(pending_goals, agent_id)
                 end
               ) do
            {:ok, %{agent_id: agent_id}} ->
              log("sent kickoff message to #{agent_id}",
                project_id: project.id,
                agent_id: agent_id
              )

            {:error, reason} ->
              log(
                "ERROR: flat planner for \"#{project.name}\" failed to produce output: #{inspect(reason)}",
                project_id: project.id
              )
          end
        end)
    end
  end

  defp run_flat_planner_message_with_output_retry(
         agent_module,
         config,
         message,
         label,
         on_agent_created,
         response_validator,
         attempt,
         max_attempts
       ) do
    case run_flat_planner_message_once(
           agent_module,
           config,
           message,
           label,
           on_agent_created,
           response_validator
         ) do
      {:ok, result} ->
        {:ok, Map.put(result, :attempts, attempt)}

      {:retry, %{agent_id: agent_id, reason: reason}} when attempt < max_attempts ->
        log_output_retry(attempt, max_attempts, reason)
        stop_retry_agent(agent_module, agent_id)

        run_flat_planner_message_with_output_retry(
          agent_module,
          config,
          message,
          label,
          on_agent_created,
          response_validator,
          attempt + 1,
          max_attempts
        )

      {:retry, %{agent_id: agent_id, reason: reason}} ->
        log_output_retry(attempt, max_attempts, reason)
        stop_retry_agent(agent_module, agent_id)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_flat_planner_message_once(
         agent_module,
         config,
         message,
         label,
         on_agent_created,
         response_validator
       ) do
    case agent_module.create(config) do
      {:ok, agent_id} ->
        on_agent_created.(agent_id)

        log("streaming #{label} to planner #{agent_id}...")

        case agent_module.stream(agent_id, message, fn _chunk -> :ok end) do
          {:ok, response} ->
            case response_validator.(response) do
              {:ok, trimmed} ->
                preview = trimmed |> String.slice(0, 200) |> String.replace("\n", " ")
                log("planner #{agent_id} responded: #{preview}")
                {:ok, %{agent_id: agent_id, response: trimmed}}

              {:retry, reason} ->
                {:retry, %{agent_id: agent_id, reason: reason}}
            end

          {:error, reason} ->
            log("ERROR: planner #{agent_id} stream failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp usable_planner_response(response) when is_binary(response) do
    case String.trim(response) do
      "" -> {:retry, "Planner returned empty output"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp usable_planner_response(response) do
    {:retry, "Planner returned no decodable output: #{inspect(response)}"}
  end

  defp log_output_retry(attempt, max_attempts, reason) do
    log("flat planner output retry #{attempt}/#{max_attempts}: #{truncate(reason, 2_000)}")
  end

  defp stop_retry_agent(agent_module, agent_id) do
    case agent_module.stop(agent_id, :empty_output_retry) do
      :ok -> :ok
      {:error, _reason} -> :ok
      _other -> :ok
    end
  end

  defp output_retry_attempts(opts) do
    opts
    |> Keyword.get(:flat_output_retry_attempts, @default_output_retry_attempts)
    |> bounded_int(@default_output_retry_attempts, 1, 8)
  end

  defp bounded_int(value, _default, min, max) when is_integer(value) do
    value |> max(min) |> min(max)
  end

  defp bounded_int(_value, default, _min, _max), do: default

  defp spawn_gvr_planner(project, pending_goals, request, decision) do
    case find_planner_template() do
      nil ->
        log("ERROR: no Planner template found, skipping project \"#{project.name}\"",
          project_id: project.id
        )

      planner ->
        ensure_planner_sandbox(project)

        case Orchid.Agent.create(planner_agent_config(planner, project, :gvr)) do
          {:ok, agent_id} ->
            log("spawned G-V-R planner #{agent_id} for project \"#{project.name}\"",
              project_id: project.id,
              agent_id: agent_id
            )

            assign_unassigned_goals(pending_goals, agent_id)

            Task.start(fn ->
              log("running G-V-R planner for #{agent_id}...",
                project_id: project.id,
                agent_id: agent_id
              )

              opts = [
                base_sandbox: Orchid.Sandbox.status(project.id),
                allowed_tools: planner_allowed_tools(planner)
              ]

              case plan_routed_request(project, request, decision, opts) do
                {:ok, %{plan: plan}} ->
                  stream_planner_message(
                    agent_id,
                    gvr_kickoff_message(request.planner_objective, plan),
                    "G-V-R kickoff"
                  )

                {:error, {:gvr_planner_failed, reason, _context}} ->
                  handle_gvr_planner_failure(agent_id, pending_goals, reason, request)
              end
            end)

            log("started G-V-R planner task for #{agent_id}",
              project_id: project.id,
              agent_id: agent_id
            )

          {:error, reason} ->
            log(
              "ERROR: failed to spawn G-V-R planner for \"#{project.name}\": #{inspect(reason)}",
              project_id: project.id
            )
        end
    end
  end

  defp route_runtime_request(request, opts) do
    case configured_planner_mode(opts) do
      :auto ->
        Router.route(request.route_input, request.goal_label)

      mode when mode in [:flat, :gvr] ->
        decision = Router.classify(request.route_input)
        signal = "#{decision.signal}; selected_mode=#{mode}"
        decision = %{decision | mode: mode, signal: signal}
        Router.log_decision(request.goal_label, decision)
        decision
    end
  end

  defp plan_routed_request(_project, request, %{mode: :flat} = decision, _opts) do
    {:ok,
     %{
       mode: :flat,
       decision: decision,
       route_input: request.route_input,
       planner_objective: request.planner_objective,
       plan: nil
     }}
  end

  defp plan_routed_request(project, request, %{mode: :gvr} = decision, opts) do
    planner_opts = gvr_planner_opts(project, opts)
    planner_fun = Keyword.get(opts, :planner_fun, &Orchid.Planner.plan/3)

    case planner_fun.(request.planner_objective, Keyword.get(opts, :base_sandbox), planner_opts) do
      {:ok, plan} ->
        {:ok,
         %{
           mode: :gvr,
           decision: decision,
           route_input: request.route_input,
           planner_objective: request.planner_objective,
           planner_opts: planner_opts,
           plan: plan
         }}

      {:error, reason} ->
        {:error,
         {:gvr_planner_failed, reason,
          %{mode: :gvr, decision: decision, route_input: request.route_input}}}
    end
  end

  defp configured_planner_mode(opts) do
    opts
    |> Keyword.get_lazy(:mode, fn ->
      Application.get_env(:orchid, :goal_watcher_planner_mode) ||
        System.get_env("ORCHID_GOAL_WATCHER_PLANNER_MODE") ||
        :auto
    end)
    |> normalize_planner_mode()
  end

  defp normalize_planner_mode(mode) when mode in [:auto, :flat, :gvr], do: mode

  defp normalize_planner_mode(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "auto" -> :auto
      "flat" -> :flat
      "gvr" -> :gvr
      _ -> :auto
    end
  end

  defp normalize_planner_mode(_mode), do: :auto

  defp ensure_planner_sandbox(project) do
    case Orchid.Projects.ensure_sandbox(project.id) do
      {:ok, _} ->
        log("sandbox ready for project \"#{project.name}\"")

      {:error, reason} ->
        log("WARNING: sandbox failed for project \"#{project.name}\": #{inspect(reason)}")
    end
  end

  defp planner_agent_config(planner, project, mode) do
    config = %{
      provider: planner.metadata[:provider] || :cli,
      system_prompt: planner_system_prompt(planner.content, project.name),
      template_id: planner.id,
      project_id: project.id,
      planner_mode: mode
    }

    config =
      if planner.metadata[:model],
        do: Map.put(config, :model, planner.metadata[:model]),
        else: config

    config =
      if is_list(planner.metadata[:allowed_tools]),
        do: Map.put(config, :allowed_tools, planner.metadata[:allowed_tools]),
        else: config

    config =
      if planner.metadata[:use_orchid_tools],
        do: Map.put(config, :use_orchid_tools, true),
        else: config

    if mode == :gvr do
      config
      |> Map.put(:provider, :openrouter)
      |> Map.put(:model, :nex_n2_pro)
    else
      config
    end
  end

  defp planner_allowed_tools(planner) do
    case planner.metadata[:allowed_tools] do
      tools when is_list(tools) and tools != [] -> tools
      _ -> nil
    end
  end

  defp assign_unassigned_goals(pending_goals, agent_id) do
    for goal <- pending_goals, is_nil(goal.metadata[:agent_id]) do
      Orchid.Object.update_metadata(goal.id, %{agent_id: agent_id})
      log("  assigned goal \"#{goal.name}\" [#{goal.id}] -> #{agent_id}")
    end
  end

  defp stream_planner_message(agent_id, message, label) do
    Task.start(fn ->
      log("streaming #{label} to planner #{agent_id}...")

      result =
        Orchid.Agent.stream(agent_id, String.trim(message), fn _chunk -> :ok end)

      case result do
        {:ok, response} ->
          preview = response |> String.slice(0, 200) |> String.replace("\n", " ")
          log("planner #{agent_id} responded: #{preview}")

        {:error, reason} ->
          log("ERROR: planner #{agent_id} stream failed: #{inspect(reason)}")
      end
    end)
  end

  defp gvr_kickoff_message(runtime_snapshot, plan) do
    """
    G-V-R approved task array:

    #{plan}

    Use this approved plan to drive the current objectives. First call `goal_list`
    to confirm live state, then execute the plan with the available Orchid tools.

    Runtime snapshot used for planning:
    #{runtime_snapshot}
    """
    |> String.trim()
  end

  defp handle_gvr_planner_failure(agent_id, pending_goals, reason, request) do
    log("ERROR: G-V-R planner #{agent_id} failed: #{inspect(reason)}")

    if gvr_flat_fallback?() do
      fallback =
        """
        G-V-R planning failed before producing an approved task array:
        #{inspect(reason)}

        Continue in flat planner mode using the runtime snapshot below.

        #{request.planner_objective}
        """

      stream_planner_message(agent_id, fallback, "G-V-R failure fallback")
    else
      for goal <- pending_goals do
        Orchid.Object.update_metadata(goal.id, %{
          agent_id: nil,
          last_error: "G-V-R planner failed: #{inspect(reason)}"
        })
      end

      Orchid.Agent.stop(agent_id)
    end
  end

  defp gvr_flat_fallback? do
    truthy?(
      Application.get_env(:orchid, :goal_watcher_gvr_flat_fallback) ||
        System.get_env("ORCHID_GOAL_WATCHER_GVR_FLAT_FALLBACK")
    )
  end

  defp truthy?(value) when value in [true, "true", "1", 1, true], do: true
  defp truthy?(_value), do: false

  defp gvr_planner_opts(project, opts) do
    [
      num_paths: Keyword.get(opts, :gvr_num_paths, Keyword.get(opts, :num_paths, 1)),
      max_iterations:
        Keyword.get(opts, :gvr_max_iterations, Keyword.get(opts, :max_iterations, 1)),
      max_concurrency:
        Keyword.get(opts, :gvr_max_concurrency, Keyword.get(opts, :max_concurrency, 1)),
      llm_memoize: Keyword.get(opts, :llm_memoize, true),
      project_id: project.id,
      completed_tasks: Keyword.get(opts, :completed_tasks, []),
      workspace_context:
        Keyword.get_lazy(opts, :workspace_context, fn -> planner_workspace_context(project.id) end),
      llm_config:
        Keyword.get(opts, :llm_config, %{
          provider: :openrouter,
          model: :nex_n2_pro
        })
    ]
    |> maybe_put_option(:allowed_tools, Keyword.get(opts, :allowed_tools))
    |> maybe_put_option(:llm_module, Keyword.get(opts, :llm_module))
  end

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp planner_workspace_context(project_id) do
    root = Orchid.Project.files_path(project_id)

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

  defp find_planner_template do
    Orchid.Object.list_agent_templates()
    |> Enum.find(fn t -> t.name == "Planner" end)
  end

  defp format_goal_summary([]), do: "(none)"

  defp format_goal_summary(goals) do
    goals
    |> Enum.map(fn g ->
      deps = g.metadata[:depends_on] || []
      dep_str = if deps == [], do: "", else: " (depends on: #{Enum.join(deps, ", ")})"
      desc_str = if g.content != "", do: "\n  #{g.content}", else: ""
      "- #{g.name} [#{g.id}]#{dep_str}#{desc_str}"
    end)
    |> Enum.join("\n")
  end

  defp planner_system_prompt(prompt, project_name) do
    prompt
    |> String.replace("{project name}", project_name)
    |> String.replace(~r/\n## Context\nCurrent objectives:\n\{goals list\}\s*\z/s, "")
    |> String.replace("{goals list}", "")
    |> String.trim()
  end

  @doc false
  def planner_kickoff_message(project_name, project_brief, goal_summary) do
    brief_section =
      case String.trim(project_brief || "") do
        "" -> []
        brief -> ["Saved project brief:", brief, ""]
      end

    [
      "Project: #{project_name}",
      "",
      brief_section,
      "Current objectives:",
      goal_summary,
      "",
      "Use this as an initial snapshot only. First call `goal_list` to confirm the live state, then inspect the workspace and continue with the next actionable work."
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> String.trim()
  end

  # Short tag for log lines: "TemplateName/provider"
  defp agent_tag(agent_state) do
    provider = agent_state.config[:provider] || "?"
    model = agent_state.config[:model]

    tname =
      case agent_state.config[:template_id] do
        nil ->
          nil

        tid ->
          case Orchid.Object.get(tid) do
            {:ok, t} -> t.name
            _ -> nil
          end
      end

    tname || "#{provider}#{if model, do: "/#{model}", else: ""}"
  end

  defp log(msg, opts \\ []) do
    File.mkdir_p!(Path.dirname(@log_file))
    ts = DateTime.utc_now() |> DateTime.to_string()
    line = "[#{ts}] GoalWatcher: #{msg}\n"
    File.write!(@log_file, line, [:append])
    rendered = "GoalWatcher: #{msg}"
    Logger.info(rendered)

    Orchid.EventLog.info(:goal_watcher, rendered,
      project_id: Keyword.get(opts, :project_id),
      agent_id: Keyword.get(opts, :agent_id),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp build_rekick_message(agent_state, assigned_pending) do
    goal_names = Enum.map_join(assigned_pending, ", ", & &1.name)
    assistant_msg = last_assistant_message(agent_state)

    completion_instruction =
      if agent_state.config[:use_orchid_tools] do
        "If work is complete, call `task_report_result` with `outcome: \"success\"` and include a concise report."
      else
        "If work is complete, return a concise completion report directly. Do not mention unavailable tools."
      end

    case summarize_last_update(assistant_msg, assigned_pending) do
      {:ok, %{status: status, summary: summary, error: error}} ->
        """
        Review of your last update:
        - Status: #{status}
        - Summary: #{summary}
        #{if(error, do: "- Error: #{error}", else: "")}

        Pending goals: #{goal_names}

        #{completion_instruction}
        If blocked, continue execution and report the exact failing command/output.
        """
        |> String.trim()

      _ ->
        "Pending goals: #{goal_names}. Continue execution and report exact command/output for progress or blockers."
    end
  end

  defp summarize_last_update(last_msg, goals) do
    goal_text =
      goals
      |> Enum.map(fn g -> "- #{g.name}: #{g.content || ""}" end)
      |> Enum.join("\n")

    system = """
    You summarize worker status for orchestration.
    Judge progress against the actual goals and acceptance criteria in the text provided.
    Do not assume source edits, builds, or tests are required unless the goals explicitly require them.
    If the worker provided meaningful execution evidence, commands, or artifact paths for a non-code goal,
    count that as real progress instead of treating it as missing implementation work.
    Return exactly one JSON object in a single response. Do not call tools.
    Return strict JSON only with keys:
    - status: one of "completed", "error", "in_progress", "unknown"
    - summary: short string (<= 220 chars)
    - error: string or null
    Be concise and evidence-based.
    """

    user = """
    Goals:
    #{goal_text}

    Last assistant message:
    #{truncate(last_msg || "(none)", 6000)}
    """

    context = %{
      system: system,
      messages: [%{role: :user, content: String.trim(user)}],
      objects: "",
      memory: %{}
    }

    with {:ok, %{content: raw}} <- LLM.chat(@critic_config, context),
         {:ok, parsed} <- parse_summary_json(raw) do
      {:ok, parsed}
    end
  end

  defp parse_summary_json(raw) when is_binary(raw) do
    parsed =
      case Jason.decode(raw) do
        {:ok, v} ->
          v

        _ ->
          case Regex.run(~r/\{.*\}/s, raw) do
            [json] ->
              case Jason.decode(json) do
                {:ok, v} -> v
                _ -> nil
              end

            _ ->
              nil
          end
      end

    case parsed do
      %{"status" => status, "summary" => summary} when is_binary(status) and is_binary(summary) ->
        normalized =
          case status do
            "completed" -> "completed"
            "error" -> "error"
            "in_progress" -> "in_progress"
            _ -> "unknown"
          end

        err =
          case Map.get(parsed, "error") do
            e when is_binary(e) and e != "" -> e
            _ -> nil
          end

        {:ok, %{status: normalized, summary: truncate(summary, 220), error: err}}

      _ ->
        {:error, :invalid_summary}
    end
  end

  defp last_assistant_message(agent_state) do
    agent_state.messages
    |> Enum.reverse()
    |> Enum.find(fn msg -> msg.role == :assistant end)
    |> case do
      nil -> nil
      msg -> msg.content
    end
  end

  defp truncate(text, max) when is_binary(text) and is_integer(max) and max > 0 do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end

  defp goal_blocked?(goal) do
    normalize_task_outcome(goal.metadata[:task_outcome]) == :blocked
  end

  defp normalize_task_outcome(outcome)
       when outcome in [:success, :failure, :blocked, :in_progress],
       do: outcome

  defp normalize_task_outcome(outcome) when is_binary(outcome) do
    case String.downcase(String.trim(outcome)) do
      "success" -> :success
      "failure" -> :failure
      "blocked" -> :blocked
      "in_progress" -> :in_progress
      _ -> nil
    end
  end

  defp normalize_task_outcome(_), do: nil
end
