defmodule Orchid.Agent do
  @moduledoc """
  GenServer representing a single LLM coding agent.
  Maintains conversation history, attached objects, tool history, and memory.
  """
  use GenServer
  require Logger

  alias Orchid.{Store, Object, LLM}

  @critic_config %{
    provider: :codex,
    model: :gpt54,
    model_reasoning_effort: "medium",
    max_tokens: 700,
    max_turns: 8,
    disable_tools: true
  }

  defmodule State do
    @moduledoc false
    defstruct [
      :id,
      :config,
      :project_id,
      :execution_mode,
      :sandbox,
      lifecycle: :running,
      messages: [],
      objects: [],
      tool_history: [],
      memory: %{},
      notifications: [],
      status: :idle
    ]
  end

  # Client API

  @doc """
  Create a new agent with the given configuration.

  ## Config options
  - `:provider` - :anthropic (default) or :openai
  - `:model` - model name (default: "claude-sonnet-4-20250514")
  - `:system_prompt` - system instructions
  - `:api_key` - API key (or reads from env)
  """
  def create(config \\ %{}) do
    id = generate_id()

    # Default to OAuth (uses subscription via .claude_tokens.json)
    config =
      Map.merge(
        %{
          # Default to OpenRouter on the free Nex N2 Pro model — fully autonomous at zero token cost.
          provider: :openrouter,
          model: :nex_n2_pro,
          system_prompt: default_system_prompt()
        },
        config
      )
      |> then(fn cfg ->
        default_mode = if cfg[:project_id], do: :vm, else: :host
        Map.put_new(cfg, :execution_mode, default_mode)
      end)

    case DynamicSupervisor.start_child(
           Orchid.AgentSupervisor,
           {__MODULE__, {id, config}}
         ) do
      {:ok, _pid} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Attach objects to the agent's context.
  """
  def attach(agent_id, object_ids) when is_list(object_ids) do
    call(agent_id, {:attach, object_ids})
  end

  def attach(agent_id, object_id) do
    attach(agent_id, [object_id])
  end

  @doc """
  Run the agent with a user message.
  Executes the agent loop: LLM call -> tool calls -> repeat until done.
  Returns immediately; caller is notified via callback or can poll get_state.
  """
  def run(agent_id, message) do
    cast(agent_id, {:run, message, nil})
  end

  @doc """
  Stream a response from the agent.
  Callback receives chunks as they arrive.
  The caller_pid receives {:agent_done, agent_id, result} when complete.
  """
  def stream(agent_id, message, callback) when is_function(callback, 1) do
    caller = self()

    case cast(agent_id, {:run, message, {callback, caller}}) do
      :ok ->
        await_agent_done(agent_id, 660_000)

      error ->
        error
    end
  end

  @doc """
  Execute completion review for assigned goals.
  Called by GoalReviewQueue to serialize reviewer LLM traffic.
  """
  def run_completion_review(agent_id, project_id, report)
      when is_binary(agent_id) and is_binary(project_id) and is_binary(report) do
    review_and_finalize_goals(agent_id, project_id, report)
  end

  @doc """
  Retry the last LLM call without adding a new message.
  Use when the agent failed mid-turn and the last message is already in history.
  """
  def retry(agent_id, callback \\ fn _chunk -> :ok end) do
    caller = self()

    case cast(agent_id, {:retry, {callback, caller}}) do
      :ok ->
        await_agent_done(agent_id, 660_000)

      error ->
        error
    end
  end

  @doc """
  Get the current state of an agent.
  Reads from ETS — lock-free, never blocks.
  Optional timeout kept for API compat but ignored.
  """
  def get_state(agent_id, _timeout \\ :infinity) do
    case :ets.lookup(:orchid_agent_states, agent_id) do
      [{^agent_id, state}] -> {:ok, state}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Publish agent state to ETS. Can be called from any process (including Tasks).
  """
  def publish_state(state) do
    if agent_runtime_lifecycle(state.id) == :running do
      :ets.insert(:orchid_agent_states, {state.id, state})
    end
  end

  @doc """
  List all active agents.
  """
  def list do
    Registry.select(Orchid.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  Reset the sandbox for an agent.
  """
  def reset_sandbox(agent_id) do
    call(agent_id, :reset_sandbox)
  end

  @doc """
  Stop an agent.
  """
  def stop(agent_id, reason \\ :manual_stop) do
    case call(agent_id, {:stop_agent, reason}, 5_000) do
      :ok ->
        wait_until_stopped(agent_id, 50)
        :ok

      other ->
        other
    end
  end

  @doc """
  Push a notification to an agent. Non-blocking.
  The agent can drain these later (e.g. via the wait tool).
  """
  def notify(agent_id, message) do
    cast(agent_id, {:notify, message})
  end

  @doc """
  Drain all pending notifications from an agent. Returns the list and clears it.
  """
  def drain_notifications(agent_id) do
    call(agent_id, :drain_notifications)
  end

  @doc """
  Add a message to agent memory.
  """
  def remember(agent_id, key, value) do
    call(agent_id, {:remember, key, value})
  end

  @doc """
  Recall from agent memory.
  """
  def recall(agent_id, key) do
    call(agent_id, {:recall, key})
  end

  # GenServer callbacks

  def start_link({id, config}) do
    GenServer.start_link(__MODULE__, {id, config}, name: via(id))
  end

  def child_spec({id, config}) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [{id, config}]},
      restart: :temporary
    }
  end

  @impl true
  def init({id, config}) do
    execution_mode = normalize_execution_mode(config[:execution_mode], config[:project_id])

    state = %State{
      id: id,
      config: config,
      project_id: config[:project_id],
      execution_mode: execution_mode
    }

    state =
      if state.project_id && state.execution_mode == :vm do
        case Orchid.Projects.ensure_sandbox(state.project_id) do
          {:ok, _} ->
            sandbox_status = Orchid.Sandbox.status(state.project_id)
            %{state | sandbox: sandbox_status}

          {:error, reason} ->
            Logger.warning("Agent #{id}: sandbox failed to start: #{inspect(reason)}")
            state
        end
      else
        state
      end

    Logger.info(
      "Agent #{id} started, project=#{inspect(state.project_id)}, mode=#{state.execution_mode}, provider=#{config[:provider]}, model=#{config[:model]}"
    )

    put_runtime(id, %{lifecycle: :running, worker_pid: nil})
    publish_state(state)
    Store.put_agent_state(id, state)
    {:ok, state}
  end

  @impl true
  def handle_call({:attach, object_ids}, _from, state) do
    # Verify all objects exist
    valid_ids =
      Enum.filter(object_ids, fn id ->
        case Object.get(id) do
          {:ok, _} -> true
          _ -> false
        end
      end)

    new_objects = Enum.uniq(state.objects ++ valid_ids)
    state = %{state | objects: new_objects}
    publish_state(state)
    Store.put_agent_state(state.id, state)
    {:reply, :ok, state}
  end

  def handle_call(:reset_sandbox, _from, state) do
    if state.execution_mode == :host do
      {:reply, {:error, :host_mode}, state}
    else
      if state.project_id do
        case Orchid.Sandbox.reset(state.project_id) do
          {:ok, status} ->
            new_state = %{state | sandbox: status}
            publish_state(new_state)
            Store.put_agent_state(state.id, new_state)
            {:reply, {:ok, status}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      else
        {:reply, {:error, :no_sandbox}, state}
      end
    end
  end

  def handle_call({:remember, key, value}, _from, state) do
    state = %{state | memory: Map.put(state.memory, key, value)}
    publish_state(state)
    Store.put_agent_state(state.id, state)
    {:reply, :ok, state}
  end

  def handle_call({:recall, key}, _from, state) do
    {:reply, Map.get(state.memory, key), state}
  end

  def handle_call(:drain_notifications, _from, state) do
    new_state = %{state | notifications: []}
    publish_state(new_state)
    Store.put_agent_state(new_state.id, new_state)
    {:reply, {:ok, state.notifications}, new_state}
  end

  def handle_call({:stop_agent, reason}, _from, state) do
    stopping_state = %{state | lifecycle: :stopping}
    put_runtime(state.id, %{lifecycle: :stopping})
    stop_worker(state.id)
    stop_reason = if reason == :manual_stop, do: {:shutdown, :manual_stop}, else: reason
    {:stop, stop_reason, :ok, stopping_state}
  end

  @impl true
  def handle_cast({:notify, _message}, %{lifecycle: lifecycle} = state)
      when lifecycle != :running do
    {:noreply, state}
  end

  def handle_cast({:notify, message}, state) do
    state =
      state
      |> add_message(:notification, message)
      |> then(fn s -> %{s | notifications: s.notifications ++ [message]} end)

    publish_state(state)
    Store.put_agent_state(state.id, state)
    {:noreply, state}
  end

  def handle_cast({:retry, notify}, %{lifecycle: lifecycle} = state) when lifecycle != :running do
    maybe_notify_waiter(state.id, notify, {:error, :stopped})
    {:noreply, state}
  end

  def handle_cast({:retry, notify}, state) do
    # Re-run the LLM without adding a new message (last message already in history)
    state = %{state | status: :thinking}
    state = %{state | memory: Map.put(state.memory, :task_report_result_used_in_turn, false)}
    publish_state(state)
    start_worker(state, notify)
    {:noreply, state}
  end

  def handle_cast({:run, _message, notify}, %{lifecycle: lifecycle} = state)
      when lifecycle != :running do
    maybe_notify_waiter(state.id, notify, {:error, :stopped})
    {:noreply, state}
  end

  def handle_cast({:run, message, notify}, state) do
    state = %{state | status: :thinking}
    state = %{state | memory: Map.put(state.memory, :task_report_result_used_in_turn, false)}
    state = add_message(state, :user, message)
    publish_state(state)
    start_worker(state, notify)
    {:noreply, state}
  end

  @impl true
  def handle_info({:update_status, _status}, %{lifecycle: lifecycle} = state)
      when lifecycle != :running do
    {:noreply, state}
  end

  def handle_info({:update_status, status}, state) do
    state = %{state | status: status}
    publish_state(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %{lifecycle: lifecycle} = state)
      when lifecycle != :running do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    runtime = agent_runtime(state.id)

    cond do
      runtime[:worker_ref] != ref or runtime[:worker_pid] != pid ->
        {:noreply, state}

      true ->
        put_runtime(state.id, %{worker_pid: nil, worker_ref: nil})

        new_state =
          if state.status == :idle do
            state
          else
            %{state | status: :idle}
          end

        if reason not in [:normal, :shutdown] and not match?({:shutdown, _}, reason) do
          Logger.error(
            "Agent #{state.id} worker died before completion: #{truncate(inspect(reason), 800)}"
          )
        end

        publish_state(new_state)
        Store.put_agent_state(new_state.id, new_state)
        {:noreply, new_state}
    end
  end

  def handle_info({:work_done, _new_state, _result}, %{lifecycle: lifecycle} = state)
      when lifecycle != :running do
    {:noreply, state}
  end

  def handle_info({:work_done, new_state, result}, state) do
    clear_worker_runtime(state.id)
    # Preserve notifications that arrived during the Task's execution
    new_state = %{new_state | status: :idle, notifications: state.notifications}

    agent_tag = agent_log_tag(new_state)

    case result do
      {:ok, response} ->
        preview = (response || "") |> String.slice(0, 150) |> String.replace("\n", " ")
        Logger.info("Agent #{new_state.id} (#{agent_tag}) done: #{preview}")

      {:error, reason} ->
        Logger.error("Agent #{new_state.id} (#{agent_tag}) failed: #{inspect(reason)}")
    end

    publish_state(new_state)
    Store.put_agent_state(new_state.id, new_state)

    assigned_pending = assigned_pending_goals(new_state)
    tool_delta = tool_history_delta(state, new_state)
    # Auto-complete assigned goals for worker CLI/Codex agents (not orchestrators, not on error).
    # If the worker already used task_report_result in this turn, skip reviewer auto-finalization.
    impl_retry_triggered =
      if new_state.config[:provider] in [:cli, :codex] &&
           new_state.project_id &&
           !new_state.config[:use_orchid_tools] &&
           match?({:ok, _}, result) do
        response =
          case result do
            {:ok, content} -> content
            other -> other
          end

        impl_retry_triggered =
          if task_report_result_used_in_turn?(state, new_state) do
            false
          else
            maybe_retry_for_missing_impl_evidence(new_state, assigned_pending, tool_delta)
          end

        unless task_report_result_used_in_turn?(state, new_state) or impl_retry_triggered do
          Orchid.GoalReviewQueue.enqueue(
            new_state.id,
            new_state.project_id,
            normalize_report(response)
          )
        end

        impl_retry_triggered
      else
        false
      end

    # Worker agents: always stop when done (success or failure).
    # GoalWatcher can clear/reassign orphaned pending goals if any remain.
    if new_state.project_id && !new_state.config[:use_orchid_tools] do
      case result do
        {:error, reason} ->
          annotate_assigned_goals_error(new_state, reason)
          notify_orchestrator_of_failures(new_state, reason)

          Logger.info(
            "Agent #{new_state.id} (#{agent_tag}) stopping after error: #{inspect(reason)}"
          )

          {:stop, {:shutdown, {:worker_error, truncate(inspect(reason), 800)}}, new_state}

        {:ok, _} ->
          cond do
            impl_retry_triggered ->
              {:noreply, new_state}

            assigned_pending != [] ->
              {:noreply, new_state}

            true ->
              Logger.info("Agent #{new_state.id} (#{agent_tag}) stopping after successful run")
              {:stop, :normal, new_state}
          end
      end
    else
      {:noreply, new_state}
    end
  end

  defp start_worker(state, notify) do
    agent_pid = self()
    agent_id = state.id

    {callback, caller} =
      case notify do
        {cb, caller_pid} -> {cb, caller_pid}
        nil -> {fn _chunk -> :ok end, nil}
      end

    {:ok, worker_pid} =
      Task.start(fn ->
        result =
          try do
            case run_agent_loop_streaming(state, callback, 10, agent_pid) do
              {:ok, response, new_state} ->
                send(agent_pid, {:work_done, new_state, {:ok, response}})
                {:ok, response}

              {:error, reason, new_state} ->
                send(agent_pid, {:work_done, new_state, {:error, reason}})
                {:error, reason}
            end
          rescue
            e ->
              Logger.error("Agent #{agent_id} run loop crashed: #{Exception.message(e)}")
              send(agent_pid, {:work_done, state, {:error, Exception.message(e)}})
              {:error, Exception.message(e)}
          end

        if caller, do: send(caller, {:agent_done, agent_id, result})
      end)

    worker_ref = Process.monitor(worker_pid)
    put_runtime(agent_id, %{worker_pid: worker_pid, worker_ref: worker_ref})
    :ok
  end

  defp notify_orchestrator_of_failures(state, reason) do
    goals =
      Orchid.Object.list_goals_for_project(state.project_id)
      |> Enum.filter(fn g ->
        g.metadata[:agent_id] == state.id and Orchid.Goals.open_status?(g.metadata[:status])
      end)

    for goal <- goals do
      with parent_id when not is_nil(parent_id) <- goal.metadata[:parent_goal_id],
           {:ok, parent} <- Orchid.Object.get(parent_id),
           orchestrator_id when not is_nil(orchestrator_id) <- parent.metadata[:agent_id] do
        message =
          """
          Goal failed: "#{goal.name}" [#{goal.id}]
          Worker agent: #{state.id}
          Error: #{inspect(reason)}

          Check `goal_read` for context, fix the blocker, and reassign.
          """
          |> String.trim()

        Orchid.Agent.notify(orchestrator_id, message)
      else
        _ -> :ok
      end
    end
  end

  @impl true
  def terminate(reason, state) do
    stop_worker(state.id)
    put_runtime(state.id, %{lifecycle: :stopped, worker_pid: nil})
    maybe_notify_creator_on_terminate(reason, state)
    :ets.delete(:orchid_agent_states, state.id)
    Store.delete_agent_state(state.id)
    :ok
  end

  # Build a short tag for log lines: "provider/model, goal: name"
  defp agent_log_tag(state) do
    provider = state.config[:provider] || "?"
    model = state.config[:model]
    template = state.config[:template_id]

    # Look up template name
    tname =
      if template do
        case Orchid.Object.get(template) do
          {:ok, t} -> t.name
          _ -> nil
        end
      end

    # Look up assigned goal
    gname =
      if state.project_id do
        Orchid.Object.list_goals_for_project(state.project_id)
        |> Enum.find(fn g -> g.metadata[:agent_id] == state.id end)
        |> case do
          nil -> nil
          g -> g.name
        end
      end

    parts = [tname || "#{provider}#{if model, do: "/#{model}", else: ""}"]
    parts = if gname, do: parts ++ ["goal: #{gname}"], else: parts
    Enum.join(parts, ", ")
  end

  # Worker agents cannot be trusted to self-certify completion.
  # Route final reports through a lightweight completion reviewer model.
  defp review_and_finalize_goals(agent_id, project_id, report) do
    goals = Orchid.Object.list_goals_for_project(project_id)

    assigned_pending =
      Enum.filter(goals, fn g ->
        g.metadata[:agent_id] == agent_id and Orchid.Goals.open_status?(g.metadata[:status])
      end)

    for goal <- assigned_pending do
      case review_goal_completion(goal, project_id, report) do
        {:ok, %{completed: true, summary: summary}} ->
          Logger.info(
            "Agent #{agent_id}: reviewer approved completion for \"#{goal.name}\" [#{goal.id}]"
          )

          Orchid.Goals.set_status(goal.id, :completed)

          Orchid.Object.update_metadata(goal.id, %{
            report: report,
            completion_summary: summary,
            last_error: nil,
            reviewed_by: "sonnet"
          })

        {:ok, %{completed: false, summary: summary, error: error}} ->
          Logger.warning(
            "Agent #{agent_id}: reviewer kept goal pending \"#{goal.name}\" [#{goal.id}]"
          )

          Orchid.Object.update_metadata(goal.id, %{
            status: :pending,
            report: report,
            completion_summary: summary,
            last_error: error || "Reviewer marked incomplete",
            reviewed_by: "sonnet"
          })

          maybe_retry_after_incomplete_review(agent_id, goal, summary, error)

        {:error, reason} ->
          Logger.error(
            "Agent #{agent_id}: completion review failed for \"#{goal.name}\" [#{goal.id}]: #{inspect(reason)}"
          )

          Orchid.Object.update_metadata(goal.id, %{
            status: :pending,
            report: report,
            completion_summary: nil,
            last_error: "Completion review failed: #{inspect(reason)}",
            reviewed_by: "sonnet"
          })
      end
    end
  end

  defp task_report_result_used_in_turn?(old_state, new_state) do
    old_len = length(old_state.tool_history)

    new_state.tool_history
    |> Enum.drop(old_len)
    |> Enum.any?(fn tr -> tr.tool in ["task_report_result", "task_report"] end)
  end

  defp assigned_pending_goals(state) do
    Orchid.Object.list_goals_for_project(state.project_id)
    |> Enum.filter(fn g ->
      g.metadata[:agent_id] == state.id and Orchid.Goals.open_status?(g.metadata[:status])
    end)
  end

  defp tool_history_delta(old_state, new_state) do
    old_len = length(old_state.tool_history)
    Enum.drop(new_state.tool_history, old_len)
  end

  defp maybe_retry_for_missing_impl_evidence(state, goals, tool_delta) do
    target_goals =
      Enum.filter(goals, fn g ->
        implementation_goal?(g) and (g.metadata[:impl_enforcement_retry_count] || 0) < 1
      end)

    missing = missing_impl_evidence(tool_delta)

    if target_goals != [] and missing != [] do
      critique = impl_retry_critique(target_goals, missing)

      for goal <- target_goals do
        current = goal.metadata[:impl_enforcement_retry_count] || 0

        Orchid.Object.update_metadata(goal.id, %{
          impl_enforcement_retry_count: current + 1,
          completion_summary: critique.summary,
          last_error: critique.error
        })
      end

      goal_names = Enum.map_join(target_goals, ", ", &"\"#{&1.name}\" [#{&1.id}]")

      corrective =
        """
        Critic summary: #{critique.summary}
        Critic detail: #{critique.error}

        Affected goals: #{goal_names}

        Retry in the same run and provide the missing evidence for these code-change goals:
        #{Enum.map_join(missing_impl_evidence_instructions(missing), "\n", &"- #{&1}")}
        Include only the concrete evidence needed to close the gap.
        """
        |> String.trim()

      Task.start(fn -> Orchid.Agent.stream(state.id, corrective, fn _chunk -> :ok end) end)
      true
    else
      false
    end
  end

  defp maybe_retry_after_incomplete_review(agent_id, goal, summary, error) do
    retry_count = goal.metadata[:auto_retry_count] || 0

    if retry_count < 1 and agent_alive?(agent_id) do
      Orchid.Object.update_metadata(goal.id, %{auto_retry_count: retry_count + 1})

      corrective =
        """
        Reviewer marked your previous attempt incomplete for goal "#{goal.name}" [#{goal.id}].

        Reviewer summary: #{summary}
        #{if(error, do: "Reviewer error: #{error}", else: "Reviewer error: (none provided)")}

        Retry now by addressing the reviewer feedback against the goal's actual requirements:
        - provide the concrete evidence or outputs the reviewer says are still missing
        - if the goal requires code changes, include exact changed paths and build/verification outputs
        - if the goal is execution, investigation, or evidence capture, include the exact commands, artifact paths, and key output markers
        - if blocked, provide exact failing command and output
        - do not add boilerplate about unavailable tools
        """
        |> String.trim()

      Task.start(fn -> Orchid.Agent.stream(agent_id, corrective, fn _chunk -> :ok end) end)
    end
  end

  defp agent_alive?(agent_id) when is_binary(agent_id) do
    case Registry.lookup(Orchid.Registry, agent_id) do
      [{pid, _}] -> Process.alive?(pid)
      [] -> false
    end
  end

  defp agent_alive?(_), do: false

  defp implementation_goal?(goal) do
    text = "#{goal.name}\n#{goal.content || ""}" |> String.downcase()

    cond do
      Regex.match?(
        ~r/\b(without editing source files|without editing source|no source edits|do not edit source(?: files)?)\b/,
        text
      ) ->
        false

      Regex.match?(~r/\b(implement|create|add|refactor|fix|update|modify|write|edit)\b/, text) ->
        true

      String.contains?(text, "cmakelists") ->
        true

      Regex.match?(~r/src\/|\.c\b|\.h\b|\.cpp\b|\.rs\b|\.go\b|\.ex\b|\.js\b/, text) ->
        true

      true ->
        false
    end
  end

  defp missing_impl_evidence(tool_delta) do
    has_edit =
      Enum.any?(tool_delta, fn tr ->
        tr.tool == "edit"
      end)

    has_build =
      Enum.any?(tool_delta, fn tr ->
        tr.tool == "shell" and shell_build_command?(tr.args)
      end)

    []
    |> maybe_add_missing_evidence(:file_edits, has_edit)
    |> maybe_add_missing_evidence(:build_verification, has_build)
  end

  defp maybe_add_missing_evidence(missing, _kind, true), do: missing
  defp maybe_add_missing_evidence(missing, kind, false), do: missing ++ [kind]

  defp impl_retry_critique(goals, missing) do
    goal_names = Enum.map_join(goals, ", ", &"\"#{&1.name}\"")
    missing_text = Enum.map_join(missing, " and ", &missing_impl_evidence_label/1)

    %{
      summary: "In progress: #{goal_names} is still missing #{missing_text} from the same run.",
      error: "Missing evidence: #{Enum.map_join(missing, "; ", &missing_impl_evidence_error/1)}."
    }
  end

  defp missing_impl_evidence_instructions(missing) do
    Enum.map(missing, &missing_impl_evidence_instruction/1)
  end

  defp missing_impl_evidence_label(:file_edits), do: "file edit evidence"
  defp missing_impl_evidence_label(:build_verification), do: "build or verification output"

  defp missing_impl_evidence_error(:file_edits),
    do: "no file edit activity was recorded"

  defp missing_impl_evidence_error(:build_verification),
    do: "no build or verification command result was recorded"

  defp missing_impl_evidence_instruction(:file_edits),
    do: "make the required source changes and report the exact file paths changed"

  defp missing_impl_evidence_instruction(:build_verification),
    do: "run at least one build or verification command and report the command plus the result"

  defp shell_build_command?(%{"command" => cmd}) when is_binary(cmd) do
    lc = String.downcase(cmd)

    String.contains?(lc, "cmake") or
      String.contains?(lc, "ninja") or
      String.contains?(lc, "make") or
      String.contains?(lc, "mix compile") or
      String.contains?(lc, "mix test") or
      String.contains?(lc, "cargo build") or
      String.contains?(lc, "go test") or
      String.contains?(lc, "pytest") or
      String.contains?(lc, "npm run build")
  end

  defp shell_build_command?(_), do: false

  defp annotate_assigned_goals_error(state, reason) do
    goals = Orchid.Object.list_goals_for_project(state.project_id)

    assigned_pending =
      Enum.filter(goals, fn g ->
        g.metadata[:agent_id] == state.id and Orchid.Goals.open_status?(g.metadata[:status])
      end)

    if assigned_pending != [] do
      report = normalize_report(last_assistant_message(state))
      error_summary = truncate("Worker failed: #{inspect(reason)}", 1_000)

      for goal <- assigned_pending do
        Orchid.Object.update_metadata(goal.id, %{
          status: :pending,
          report: report,
          completion_summary: "Worker exited with error before completion.",
          last_error: error_summary
        })
      end
    end
  end

  defp review_goal_completion(goal, project_id, report) do
    files = collect_project_artifacts(project_id, 60)
    files_text = if files == [], do: "(none)", else: Enum.join(files, "\n")

    system = """
    You are a practical goal completion reviewer.
    Decide whether the submitted work completes the goal as written.
    Judge against the goal's actual acceptance criteria and requested evidence.
    Do not require source edits, builds, or tests unless the goal explicitly asks for them
    or they are necessary to prove the requested outcome.
    If the goal is about execution evidence, logs, commands, artifacts, or investigation,
    evaluate those directly instead of demanding implementation work.
    Return exactly one JSON object in a single response. Do not call tools.
    Return JSON only with keys:
    - completed (boolean)
    - summary (string, <= 240 chars)
    - error (string or null). If completed=true, set error to null.
    Be concise and evidence-based. If evidence is weak or missing, completed must be false,
    and error should explain the most important missing proof or unmet criterion.
    """

    user = """
    Goal: #{goal.name}
    Goal Description:
    #{goal.content || "(none)"}

    Worker Report:
    #{truncate(report, 10_000)}

    Workspace Artifacts:
    #{truncate(files_text, 4_000)}
    """

    context = %{
      system: system,
      messages: [%{role: :user, content: String.trim(user)}],
      objects: "",
      memory: %{}
    }

    with {:ok, %{content: raw}} <- LLM.chat(@critic_config, context),
         {:ok, decision} <- decode_reviewer_json(raw) do
      {:ok, decision}
    end
  end

  defp last_assistant_message(state) do
    state.messages
    |> Enum.reverse()
    |> Enum.find(fn msg -> msg.role == :assistant end)
    |> case do
      nil -> "(no response)"
      msg -> msg.content || "(empty)"
    end
  end

  defp decode_reviewer_json(raw) when is_binary(raw) do
    candidate =
      case Jason.decode(raw) do
        {:ok, parsed} ->
          parsed

        _ ->
          case Regex.run(~r/\{.*\}/s, raw) do
            [json] ->
              case Jason.decode(json) do
                {:ok, parsed} -> parsed
                _ -> nil
              end

            _ ->
              nil
          end
      end

    case candidate do
      %{"completed" => completed, "summary" => summary}
      when is_boolean(completed) and is_binary(summary) ->
        error =
          case Map.get(candidate, "error") do
            nil -> nil
            e when is_binary(e) and e != "" -> e
            _ -> nil
          end

        {:ok, %{completed: completed, summary: truncate(summary, 240), error: error}}

      _ ->
        {:error, {:invalid_reviewer_output, truncate(raw, 600)}}
    end
  end

  defp collect_project_artifacts(nil, _limit), do: []

  defp collect_project_artifacts(project_id, limit) do
    files_root = Orchid.Project.files_path(project_id)
    upper_root = Path.join([Orchid.Project.data_dir(), "sandboxes", project_id, "upper"])

    files =
      list_regular_files(files_root)
      |> Enum.map(&Path.relative_to(&1, files_root))

    upper =
      list_regular_files(upper_root)
      |> Enum.map(&Path.relative_to(&1, upper_root))

    (files ++ upper)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(limit)
  end

  defp list_regular_files(root) do
    if File.dir?(root) do
      root
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
    else
      []
    end
  end

  defp normalize_report({:ok, report}), do: normalize_report(report)
  defp normalize_report({:error, reason}), do: normalize_report("Error: #{inspect(reason)}")
  defp normalize_report(report), do: truncate(to_string(report || ""), 20_000)

  defp maybe_notify_creator_on_terminate(reason, state) do
    case termination_notice(reason, state) do
      nil ->
        :ok

      notice ->
        case resolve_creator_agent_id(state) do
          creator_id when is_binary(creator_id) and creator_id != state.id ->
            Orchid.Agent.notify(creator_id, notice)

          _ ->
            :ok
        end
    end
  end

  defp termination_notice(:manual_stop, state) do
    "Agent #{state.id} was stopped manually."
  end

  defp termination_notice({:shutdown, :manual_stop}, state),
    do: termination_notice(:manual_stop, state)

  defp termination_notice({:shutdown, {:worker_error, reason}}, state),
    do: termination_notice({:worker_error, reason}, state)

  defp termination_notice({:worker_error, reason}, state) do
    """
    Agent #{state.id} stopped after an error.
    Error: #{reason}
    """
    |> String.trim()
  end

  defp termination_notice(:normal, _state), do: nil
  defp termination_notice(:shutdown, _state), do: nil

  defp termination_notice(reason, state) do
    """
    Agent #{state.id} crashed/stopped unexpectedly.
    Reason: #{truncate(inspect(reason), 800)}
    """
    |> String.trim()
  end

  defp resolve_creator_agent_id(state) do
    case state.config[:creator_agent_id] do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        infer_creator_from_goal_hierarchy(state)
    end
  end

  defp infer_creator_from_goal_hierarchy(%{project_id: nil}), do: nil

  defp infer_creator_from_goal_hierarchy(state) do
    goals = Orchid.Object.list_goals_for_project(state.project_id)

    with %{metadata: meta} <- Enum.find(goals, fn g -> g.metadata[:agent_id] == state.id end),
         parent_id when is_binary(parent_id) <- meta[:parent_goal_id],
         {:ok, parent_goal} <- Orchid.Object.get(parent_id),
         creator_id when is_binary(creator_id) <- parent_goal.metadata[:agent_id] do
      creator_id
    else
      _ -> nil
    end
  end

  defp truncate(text, max) when is_binary(text) and is_integer(max) and max > 0 do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end

  # Private functions

  defp via(id), do: {:via, Registry, {Orchid.Registry, id}}

  defp call(agent_id, msg, timeout \\ :infinity) do
    case Registry.lookup(Orchid.Registry, agent_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, msg, timeout)
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
          :exit, {:noproc, _} -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp cast(agent_id, msg) do
    case Registry.lookup(Orchid.Registry, agent_id) do
      [{pid, _}] -> GenServer.cast(pid, msg)
      [] -> {:error, :not_found}
    end
  end

  defp maybe_notify_waiter(agent_id, {_, caller}, result) when is_pid(caller) do
    send(caller, {:agent_done, agent_id, result})
  end

  defp maybe_notify_waiter(_agent_id, _notify, _result), do: :ok

  defp agent_runtime(agent_id) do
    case :ets.lookup(:orchid_agent_runtime, agent_id) do
      [{^agent_id, runtime}] -> runtime
      [] -> %{lifecycle: :stopped, worker_pid: nil, worker_ref: nil}
    end
  end

  defp agent_runtime_lifecycle(agent_id) do
    agent_id
    |> agent_runtime()
    |> Map.get(:lifecycle, :stopped)
  end

  defp put_runtime(agent_id, attrs) when is_map(attrs) do
    runtime =
      agent_id
      |> agent_runtime()
      |> Map.merge(attrs)

    :ets.insert(:orchid_agent_runtime, {agent_id, runtime})
  end

  defp stop_worker(agent_id) do
    runtime = agent_runtime(agent_id)

    if is_reference(runtime[:worker_ref]) do
      Process.demonitor(runtime[:worker_ref], [:flush])
    end

    case runtime[:worker_pid] do
      pid when is_pid(pid) and pid != self() ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)

      _ ->
        :ok
    end

    put_runtime(agent_id, %{worker_pid: nil, worker_ref: nil})
    :ok
  end

  defp clear_worker_runtime(agent_id) do
    runtime = agent_runtime(agent_id)

    if is_reference(runtime[:worker_ref]) do
      Process.demonitor(runtime[:worker_ref], [:flush])
    end

    put_runtime(agent_id, %{worker_pid: nil, worker_ref: nil})
  end

  defp wait_until_stopped(_agent_id, attempts_left) when attempts_left <= 0, do: :ok

  defp wait_until_stopped(agent_id, attempts_left) do
    case Registry.lookup(Orchid.Registry, agent_id) do
      [] ->
        :ok

      _ ->
        Process.sleep(20)
        wait_until_stopped(agent_id, attempts_left - 1)
    end
  end

  defp await_agent_done(_agent_id, timeout_ms) when timeout_ms <= 0, do: {:error, :timeout}

  defp await_agent_done(agent_id, timeout_ms) do
    wait_ms = min(timeout_ms, 1_000)

    receive do
      {:agent_done, ^agent_id, result} ->
        result
    after
      wait_ms ->
        case Registry.lookup(Orchid.Registry, agent_id) do
          [] -> {:error, :not_found}
          _ -> await_agent_done(agent_id, timeout_ms - wait_ms)
        end
    end
  end

  defp agent_running?(agent_id), do: agent_runtime_lifecycle(agent_id) == :running

  defp ensure_agent_running(state) do
    if agent_running?(state.id) do
      :ok
    else
      {:error, :stopped, state}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp add_message(state, role, content) do
    message = %{role: role, content: content, timestamp: DateTime.utc_now()}
    %{state | messages: state.messages ++ [message]}
  end

  defp add_assistant_message(state, content, tool_calls \\ nil) do
    message = %{
      role: :assistant,
      content: content,
      tool_calls: tool_calls,
      timestamp: DateTime.utc_now()
    }

    %{state | messages: state.messages ++ [message]}
  end

  @max_retries 10
  @initial_backoff 2_000

  defp run_agent_loop_streaming(state, callback, max_iterations, agent_pid) do
    do_run_loop_streaming(state, callback, max_iterations, nil, agent_pid)
  end

  defp do_run_loop_streaming(state, _callback, 0, last_response, _agent_pid) do
    {:ok, last_response || "Max iterations reached", state}
  end

  defp do_run_loop_streaming(state, callback, iterations_left, _last_response, agent_pid) do
    with :ok <- ensure_agent_running(state) do
      context = build_context(state)
      config = build_llm_config(state)

      case llm_call_with_retry(config, context, callback, agent_pid) do
        {:ok, %{content: content, tool_calls: nil}} ->
          state = add_assistant_message(state, content)
          publish_state(state)
          {:ok, content, state}

        {:ok, %{content: content, tool_calls: tool_calls}} when is_list(tool_calls) ->
          state = add_assistant_message(state, content, tool_calls)
          tool_names = Enum.map_join(tool_calls, ", ", & &1.name)
          state = %{state | status: {:executing_tool, tool_names}}
          publish_state(state)

          case execute_tool_calls(state, tool_calls) do
            {:ok, state, tool_results} ->
              {notifications, tool_results} =
                Enum.reduce(tool_results, {[], []}, fn result, {notifs, results} ->
                  case result do
                    {:notifications, msgs, formatted} -> {notifs ++ msgs, results ++ [formatted]}
                    _ -> {notifs, results ++ [result]}
                  end
                end)

              state =
                Enum.reduce(tool_results, state, fn result, acc ->
                  add_message(acc, :tool, result)
                end)

              state =
                if notifications != [] do
                  notif_text = Enum.join(notifications, "\n\n---\n\n")
                  add_message(state, :user, notif_text)
                else
                  state
                end

              publish_state(state)
              do_run_loop_streaming(state, callback, iterations_left - 1, content, agent_pid)

            {:error, :stopped, state} ->
              {:error, :stopped, state}
          end

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  defp llm_call_with_retry(config, context, callback, agent_pid) do
    do_llm_retry(config, context, callback, 0, agent_pid)
  end

  defp do_llm_retry(config, context, callback, attempt, _agent_pid)
       when attempt >= @max_retries do
    if agent_running?(config[:agent_id]) do
      llm_module(config).chat_stream(config, context, callback)
    else
      {:error, :stopped}
    end
  end

  defp do_llm_retry(config, context, callback, attempt, agent_pid) do
    if not agent_running?(config[:agent_id]) do
      {:error, :stopped}
    else
      case llm_module(config).chat_stream(config, context, callback) do
        {:ok, _} = success ->
          success

        {:error, "Codex returned empty response"} ->
          backoff = min((@initial_backoff * :math.pow(2, attempt)) |> round(), 30_000)

          Logger.warning(
            "Agent LLM call returned empty response, retry #{attempt + 1}/#{@max_retries} in #{backoff}ms"
          )

          if agent_pid,
            do:
              send(
                agent_pid,
                {:update_status, {:retrying, attempt + 1, @max_retries, :empty_response}}
              )

          Process.sleep(backoff)

          if agent_running?(config[:agent_id]) do
            if agent_pid, do: send(agent_pid, {:update_status, :thinking})
            do_llm_retry(config, context, callback, attempt + 1, agent_pid)
          else
            {:error, :stopped}
          end

        {:error, {:api_error, status, _}} when status in [429, 500, 502, 503, 504] ->
          backoff = min((@initial_backoff * :math.pow(2, attempt)) |> round(), 30_000)

          Logger.warning(
            "Agent LLM call failed (#{status}), retry #{attempt + 1}/#{@max_retries} in #{backoff}ms"
          )

          if agent_pid,
            do: send(agent_pid, {:update_status, {:retrying, attempt + 1, @max_retries, status}})

          Process.sleep(backoff)

          if agent_running?(config[:agent_id]) do
            if agent_pid, do: send(agent_pid, {:update_status, :thinking})
            do_llm_retry(config, context, callback, attempt + 1, agent_pid)
          else
            {:error, :stopped}
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp llm_module(config) do
    Map.get(config, :llm_module, LLM)
  end

  defp build_context(state) do
    # Build context with attached objects
    object_context =
      state.objects
      |> Enum.map(&Object.get/1)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, obj} ->
        "[Object: #{obj.name} (#{obj.type})]\n#{obj.content}"
      end)
      |> Enum.join("\n\n")

    %{
      system: state.config.system_prompt,
      objects: object_context,
      messages: state.messages,
      memory: state.memory
    }
  end

  defp build_llm_config(state) do
    Map.put(state.config, :agent_id, state.id)
  end

  defp execute_tool_calls(state, tool_calls) do
    Enum.reduce_while(tool_calls, {:ok, state, []}, fn tool_call, {:ok, acc_state, results} ->
      if agent_running?(acc_state.id) do
        {new_state, result} = execute_tool(acc_state, tool_call)
        {:cont, {:ok, new_state, results ++ [result]}}
      else
        {:halt, {:error, :stopped, acc_state}}
      end
    end)
  end

  defp execute_tool(state, %{name: name, arguments: args, id: tool_id}) do
    args_preview = args |> inspect() |> String.slice(0, 200)
    Logger.info("Agent #{state.id}: tool #{name}(#{args_preview})")

    result =
      try do
        Orchid.Tool.execute(name, args || %{}, %{agent_state: state})
      rescue
        e ->
          Logger.error("Tool #{name} crashed: #{Exception.message(e)}")
          {:error, "Tool error: #{Exception.message(e)}"}
      end

    # Handle wait tool's special notification return
    case result do
      {:notifications, messages, _tool_result} ->
        tool_record = %{
          id: tool_id,
          tool: name,
          args: args,
          result: {:ok, "notifications"},
          timestamp: DateTime.utc_now()
        }

        state = %{state | tool_history: state.tool_history ++ [tool_record]}

        formatted = %{
          tool_use_id: tool_id,
          tool_name: name,
          content: "Received #{length(messages)} notification(s)."
        }

        {state, {:notifications, messages, formatted}}

      _ ->
        tool_record = %{
          id: tool_id,
          tool: name,
          args: args,
          result: result,
          timestamp: DateTime.utc_now()
        }

        state = %{state | tool_history: state.tool_history ++ [tool_record]}

        formatted = %{
          tool_use_id: tool_id,
          tool_name: name,
          content: format_tool_result(result)
        }

        {state, formatted}
    end
  end

  defp format_tool_result({:ok, value}) when is_binary(value), do: sanitize_utf8(value)
  defp format_tool_result({:ok, value}), do: inspect(value)
  defp format_tool_result({:error, reason}), do: "Error: #{inspect(reason)}"

  defp sanitize_utf8(str) do
    if String.valid?(str) do
      str
    else
      "(binary data, #{byte_size(str)} bytes — not valid UTF-8)"
    end
  end

  defp normalize_execution_mode(mode, project_id) do
    case mode do
      :host -> :host
      "host" -> :host
      :root_vm -> :host
      "root_vm" -> :host
      :vm -> :vm
      "vm" -> :vm
      :sandbox -> :vm
      "sandbox" -> :vm
      _ -> if(project_id, do: :vm, else: :host)
    end
  end

  defp default_system_prompt do
    """
    You are an expert coding assistant. You help users by reading, understanding, and modifying code.

    You have access to objects (files, artifacts, functions) that you can read and modify.
    Use the available tools to accomplish tasks.

    Be concise and focus on solving the user's problem efficiently.
    """
  end
end
