defmodule OrchidWeb.AgentLive do
  use Phoenix.LiveView

  @diagnostics_tail_lines 120
  @diagnostics_max_chars 12_000

  @impl true
  def mount(params, _session, socket) do
    agent_id = params["id"]

    socket =
      socket
      |> assign(:agents, list_agents_with_info())
      |> assign(:current_agent, agent_id)
      |> assign(:messages, [])
      |> assign(:input, "")
      |> assign(:streaming, false)
      |> assign(:stream_content, "")
      |> assign(:pending_message, nil)
      |> assign(:model, :opus)
      |> assign(:provider, :cli)
      |> assign(:agent_execution_mode, :vm)
      |> assign(:projects, Orchid.Object.list_projects())
      |> assign(:project_query, "")
      |> assign(:current_project, nil)
      |> assign(:creating_project, false)
      |> assign(:new_project_name, "")
      |> assign(:goals, [])
      |> assign(:creating_goal, false)
      |> assign(:new_goal_name, "")
      |> assign(:new_goal_description, "")
      |> assign(:new_goal_parent, nil)
      |> assign(:editing_goal, nil)
      |> assign(:expanded_goal, nil)
      |> assign(:adding_dependency_to, nil)
      |> assign(:assigning_goal, nil)
      |> assign(:goals_view_mode, :list)
      |> assign(:hide_completed_goals, false)
      |> assign(:project_tab, :goals)
      |> assign(:decomp_goal_text, "")
      |> assign(:decomp_num_paths, 3)
      |> assign(:decomp_max_iterations, 3)
      |> assign(:decomp_model, :sonnet)
      |> assign(:decomp_reasoning_effort, :medium)
      |> assign(:decomp_running, false)
      |> assign(:decomp_result, nil)
      |> assign(:decomp_error, nil)
      |> assign(:project_notes, [])
      |> assign(:project_facts, [])
      |> assign(:creating_project_note, false)
      |> assign(:project_note_name, "")
      |> assign(:project_note_content, "")
      |> assign(:creating_project_fact, false)
      |> assign(:project_fact_name, "")
      |> assign(:project_fact_value, "")
      |> assign(:diagnostics_log_path, diagnostics_log_path())
      |> assign(:diagnostics_log_excerpt, nil)
      |> assign(:diagnostics_summary, nil)
      |> assign(:diagnostics_running, false)
      |> assign(:diagnostics_error, nil)
      |> assign(:diagnostics_updated_at, nil)
      |> assign(:templates, Orchid.Object.list_agent_templates())
      |> then(fn s ->
        templates = s.assigns.templates
        first_template = List.first(templates)
        assign(s, :selected_template, first_template && first_template.id)
      end)
      |> assign(:current_agent_template, nil)
      |> assign(:creating_template, false)
      |> assign(:template_name, "")
      |> assign(:template_model, :opus)
      |> assign(:template_provider, :cli)
      |> assign(:template_system_prompt, "")
      |> assign(:template_category, "General")
      |> assign(:template_use_orchid_tools, false)
      |> assign(:sandbox_statuses, %{})
      |> assign(:agent_status, :idle)
      |> assign(:agent_wait_status, nil)
      |> assign(:system_prompt, nil)
      |> assign(:show_system_prompt, false)
      |> assign(:mcp_calls, [])

    socket =
      if agent_id do
        case Orchid.Agent.get_state(agent_id, 2000) do
          {:ok, state} ->
            template_info = get_template_info(state.config[:template_id])

            socket
            |> assign(:messages, format_messages(state.messages))
            |> assign(:agent_status, state.status)
            |> assign(:agent_wait_status, wait_status_from_memory(state.memory))
            |> assign(:system_prompt, state.config[:system_prompt])
            |> assign(:current_agent_template, template_info)
            |> then(fn s ->
              if state.project_id do
                s
                |> assign(:current_project, state.project_id)
                |> assign(:goals, Orchid.Goals.list_for_project(state.project_id))
              else
                s
              end
            end)

          _ ->
            socket
        end
      else
        socket
      end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Orchid.PubSub, "mcp_calls")
      Process.send_after(self(), :poll_agent_status, 2000)
    end

    {:ok, socket}
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{role: msg.role, content: msg.content, tool_calls: msg[:tool_calls]}
    end)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    agent_id = params["id"]

    socket =
      socket
      |> assign(:current_agent, agent_id)
      |> assign(:agents, list_agents_with_info())

    socket =
      if agent_id do
        case Orchid.Agent.get_state(agent_id, 2000) do
          {:ok, state} ->
            template_info = get_template_info(state.config[:template_id])

            socket
            |> assign(:messages, format_messages(state.messages))
            |> assign(:agent_status, state.status)
            |> assign(:agent_wait_status, wait_status_from_memory(state.memory))
            |> assign(:current_agent_template, template_info)
            |> assign(:system_prompt, state.config[:system_prompt])
            |> assign(:show_system_prompt, false)
            |> then(fn s ->
              if state.project_id do
                s
                |> assign(:current_project, state.project_id)
                |> assign(:goals, Orchid.Goals.list_for_project(state.project_id))
              else
                s
              end
            end)

          _ ->
            socket
            |> assign(:messages, [])
            |> assign(:agent_status, :idle)
            |> assign(:agent_wait_status, nil)
            |> assign(:current_agent_template, nil)
            |> assign(:system_prompt, nil)
            |> assign(:show_system_prompt, false)
        end
      else
        socket
        |> assign(:messages, [])
        |> assign(:agent_status, :idle)
        |> assign(:agent_wait_status, nil)
        |> assign(:current_agent_template, nil)
        |> assign(:system_prompt, nil)
        |> assign(:show_system_prompt, false)
      end

    {:noreply, socket}
  end

  defp get_template_info(nil), do: nil

  defp get_template_info(template_id) do
    case Orchid.Object.get(template_id) do
      {:ok, template} ->
        %{
          id: template.id,
          name: template.name,
          model: template.metadata[:model],
          provider: template.metadata[:provider],
          category: template.metadata[:category] || "General",
          use_orchid_tools: template.metadata[:use_orchid_tools] || false
        }

      _ ->
        nil
    end
  end

  @impl true
  def handle_event("create_agent", _params, socket) do
    template_id = socket.assigns.selected_template

    # Template is required
    config =
      case Orchid.Object.get(template_id) do
        {:ok, template} ->
          config = %{
            provider: template.metadata[:provider] || :cli,
            system_prompt: template.content,
            template_id: template_id
          }

          config =
            if template.metadata[:model],
              do: Map.put(config, :model, template.metadata[:model]),
              else: config

          config =
            if template.metadata[:reasoning_effort],
              do: Map.put(config, :reasoning_effort, template.metadata[:reasoning_effort]),
              else: config

          config =
            if is_list(template.metadata[:allowed_tools]),
              do: Map.put(config, :allowed_tools, template.metadata[:allowed_tools]),
              else: config

          if template.metadata[:use_orchid_tools],
            do: Map.put(config, :use_orchid_tools, true),
            else: config

        _ ->
          # Fallback (shouldn't happen with UI validation)
          %{model: :opus, provider: :cli}
      end

    config =
      if socket.assigns.current_project do
        Map.put(config, :project_id, socket.assigns.current_project)
      else
        config
      end

    config = Map.put(config, :execution_mode, socket.assigns.agent_execution_mode)

    {:ok, agent_id} = Orchid.Agent.create(config)
    {:noreply, push_patch(socket, to: "/agent/#{agent_id}")}
  end

  def handle_event("select_agent", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: "/agent/#{id}")}
  end

  def handle_event("go_home", _params, socket) do
    {:noreply, push_patch(socket, to: "/")}
  end

  def handle_event("stop_agent", %{"id" => id}, socket) do
    Orchid.Agent.stop(id)
    # Refresh after a short delay to let Registry update
    Process.send_after(self(), {:refresh_after_stop, id}, 100)
    {:noreply, socket}
  end

  def handle_event("update_input", %{"input" => value}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  def handle_event("update_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, :model, String.to_existing_atom(model))}
  end

  def handle_event("update_provider", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, :provider, String.to_existing_atom(provider))}
  end

  def handle_event("update_agent_execution_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :agent_execution_mode, parse_agent_execution_mode(mode))}
  end

  # Template events
  def handle_event("select_template", %{"id" => id}, socket) do
    socket =
      case Orchid.Object.get(id) do
        {:ok, template} ->
          socket
          |> assign(:selected_template, id)
          |> assign(:model, template.metadata[:model])
          |> assign(:provider, template.metadata[:provider] || :cli)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("show_create_template", _params, socket) do
    # If a template is selected, use its values as starting point
    {model, provider, prompt, use_orchid_tools} =
      case socket.assigns.selected_template do
        nil ->
          {socket.assigns.model, socket.assigns.provider, "", false}

        template_id ->
          case Orchid.Object.get(template_id) do
            {:ok, template} ->
              {
                template.metadata[:model],
                template.metadata[:provider] || :cli,
                template.content || "",
                template.metadata[:use_orchid_tools] || false
              }

            _ ->
              {socket.assigns.model, socket.assigns.provider, "", false}
          end
      end

    {:noreply,
     assign(socket,
       creating_template: true,
       template_name: "",
       template_model: model,
       template_provider: provider,
       template_system_prompt: prompt,
       template_category: "General",
       template_use_orchid_tools: use_orchid_tools
     )}
  end

  def handle_event("cancel_create_template", _params, socket) do
    {:noreply, assign(socket, creating_template: false)}
  end

  def handle_event("update_template_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :template_name, name)}
  end

  def handle_event("update_template_model", %{"model" => ""}, socket) do
    {:noreply, assign(socket, :template_model, nil)}
  end

  def handle_event("update_template_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, :template_model, String.to_existing_atom(model))}
  end

  def handle_event("update_template_provider", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, :template_provider, String.to_existing_atom(provider))}
  end

  def handle_event("update_template_system_prompt", %{"prompt" => prompt}, socket) do
    {:noreply, assign(socket, :template_system_prompt, prompt)}
  end

  def handle_event("update_template_category", %{"category" => category}, socket) do
    {:noreply, assign(socket, :template_category, category)}
  end

  def handle_event("update_template_orchid_tools", %{"value" => _}, socket) do
    {:noreply,
     assign(socket, :template_use_orchid_tools, !socket.assigns.template_use_orchid_tools)}
  end

  def handle_event("create_template", _params, socket) do
    name = String.trim(socket.assigns.template_name)
    prompt = socket.assigns.template_system_prompt

    if name != "" do
      metadata = %{
        model: socket.assigns.template_model,
        provider: socket.assigns.template_provider,
        category: socket.assigns.template_category
      }

      metadata =
        if socket.assigns.template_use_orchid_tools,
          do: Map.put(metadata, :use_orchid_tools, true),
          else: metadata

      {:ok, template} =
        Orchid.Object.create(:agent_template, name, prompt, metadata: metadata)

      {:noreply,
       assign(socket,
         templates: Orchid.Object.list_agent_templates(),
         selected_template: template.id,
         creating_template: false,
         template_name: "",
         template_system_prompt: ""
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_template", %{"id" => id}, socket) do
    Orchid.Object.delete(id)

    socket =
      socket
      |> assign(:templates, Orchid.Object.list_agent_templates())
      |> then(fn s ->
        if s.assigns.selected_template == id do
          assign(s, :selected_template, nil)
        else
          s
        end
      end)

    {:noreply, socket}
  end

  def handle_event("search_projects", %{"query" => query}, socket) do
    {:noreply, assign(socket, :project_query, query)}
  end

  def handle_event("select_project", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:current_project, id)
     |> assign(:project_tab, :goals)
     |> assign(:goals, Orchid.Goals.list_for_project(id))
     |> assign(:mcp_calls, recent_mcp_calls(id, 40))
     |> assign(:decomp_result, nil)
     |> assign(:decomp_error, nil)
     |> refresh_project_knowledge()
     |> refresh_sandbox_statuses()}
  end

  def handle_event("clear_project", _params, socket) do
    {:noreply,
     socket
     |> assign(:current_project, nil)
      |> assign(:goals, [])
     |> assign(:mcp_calls, recent_mcp_calls(nil, 40))
     |> assign(:project_notes, [])
     |> assign(:project_facts, [])
     |> assign(:creating_project_note, false)
     |> assign(:project_note_name, "")
     |> assign(:project_note_content, "")
     |> assign(:creating_project_fact, false)
     |> assign(:project_fact_name, "")
     |> assign(:project_fact_value, "")}
  end

  def handle_event("show_new_project", _params, socket) do
    {:noreply, assign(socket, creating_project: true, new_project_name: "")}
  end

  def handle_event("cancel_new_project", _params, socket) do
    {:noreply, assign(socket, creating_project: false)}
  end

  def handle_event("update_new_project_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :new_project_name, name)}
  end

  def handle_event("create_project", _params, socket) do
    name = String.trim(socket.assigns.new_project_name)

    if name != "" do
      {:ok, project} = Orchid.Projects.create(name)

      {:noreply,
       socket
       |> assign(
         projects: Orchid.Object.list_projects(),
         creating_project: false,
         new_project_name: "",
         current_project: project.id,
         project_tab: :goals,
         goals: [],
         mcp_calls: recent_mcp_calls(project.id, 40)
       )
       |> refresh_project_knowledge()
       |> refresh_sandbox_statuses()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_project", %{"id" => id}, socket) do
    Orchid.Projects.delete(id)

    socket =
      socket
      |> assign(:projects, Orchid.Object.list_projects())
      |> then(fn s ->
        if s.assigns.current_project == id do
          assign(s, :current_project, nil)
        else
          s
        end
      end)

    {:noreply, socket}
  end

  # Project status events
  def handle_event("pause_project", %{"id" => id}, socket) do
    Orchid.Projects.pause(id)
    {:noreply, assign(socket, :projects, Orchid.Object.list_projects())}
  end

  def handle_event("resume_project", %{"id" => id}, socket) do
    Orchid.Projects.resume(id)
    {:noreply, assign(socket, :projects, Orchid.Object.list_projects())}
  end

  def handle_event("archive_project", %{"id" => id}, socket) do
    Orchid.Projects.archive(id)
    {:noreply, assign(socket, :projects, Orchid.Object.list_projects())}
  end

  def handle_event("restore_project", %{"id" => id}, socket) do
    Orchid.Projects.restore(id)
    {:noreply, assign(socket, :projects, Orchid.Object.list_projects())}
  end

  # Goal events
  def handle_event("show_new_goal", _params, socket) do
    {:noreply,
     assign(socket,
       creating_goal: true,
       new_goal_name: "",
       new_goal_description: "",
       new_goal_parent: nil
     )}
  end

  def handle_event("cancel_new_goal", _params, socket) do
    {:noreply,
     assign(socket,
       creating_goal: false,
       new_goal_name: "",
       new_goal_description: "",
       new_goal_parent: nil
     )}
  end

  def handle_event("update_new_goal_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :new_goal_name, name)}
  end

  def handle_event("update_new_goal_description", %{"description" => desc}, socket) do
    {:noreply, assign(socket, :new_goal_description, desc)}
  end

  def handle_event("update_new_goal_parent", %{"parent" => ""}, socket) do
    {:noreply, assign(socket, :new_goal_parent, nil)}
  end

  def handle_event("update_new_goal_parent", %{"parent" => parent_id}, socket) do
    {:noreply, assign(socket, :new_goal_parent, parent_id)}
  end

  def handle_event("create_goal", _params, socket) do
    name = String.trim(socket.assigns.new_goal_name)
    project_id = socket.assigns.current_project

    if name != "" and project_id do
      description = String.trim(socket.assigns.new_goal_description)

      Orchid.Goals.create(name, description, project_id,
        parent_goal_id: socket.assigns.new_goal_parent
      )

      {:noreply,
       socket
       |> refresh_goals()
       |> assign(
         creating_goal: false,
         new_goal_name: "",
         new_goal_description: "",
         new_goal_parent: nil
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_goal_status", %{"id" => id, "status" => status}, socket) do
    Orchid.Goals.set_status(id, String.to_existing_atom(status))
    {:noreply, refresh_goals(socket)}
  end

  def handle_event("toggle_goal_status", %{"id" => id}, socket) do
    Orchid.Goals.toggle_status(id)
    {:noreply, refresh_goals(socket)}
  end

  def handle_event("toggle_goal_details", %{"id" => id}, socket) do
    expanded = if socket.assigns.expanded_goal == id, do: nil, else: id
    {:noreply, assign(socket, :expanded_goal, expanded)}
  end

  def handle_event("delete_goal", %{"id" => id}, socket) do
    Orchid.Goals.delete(id)
    {:noreply, refresh_goals(socket)}
  end

  def handle_event("clear_all_goals", _params, socket) do
    if socket.assigns.current_project do
      Orchid.Goals.clear_project(socket.assigns.current_project)
    end

    {:noreply, refresh_goals(socket)}
  end

  def handle_event("start_add_dependency", %{"id" => id}, socket) do
    {:noreply, assign(socket, :adding_dependency_to, id)}
  end

  def handle_event("cancel_add_dependency", _params, socket) do
    {:noreply, assign(socket, :adding_dependency_to, nil)}
  end

  def handle_event(
        "add_dependency",
        %{"goal-id" => goal_id, "depends-on" => depends_on_id},
        socket
      ) do
    Orchid.Goals.add_dependency(goal_id, depends_on_id)

    {:noreply,
     socket
     |> refresh_goals()
     |> assign(:adding_dependency_to, nil)}
  end

  def handle_event(
        "remove_dependency",
        %{"goal-id" => goal_id, "depends-on" => depends_on_id},
        socket
      ) do
    Orchid.Goals.remove_dependency(goal_id, depends_on_id)
    {:noreply, refresh_goals(socket)}
  end

  def handle_event("toggle_goals_view", _params, socket) do
    mode = if socket.assigns.goals_view_mode == :list, do: :graph, else: :list
    {:noreply, assign(socket, :goals_view_mode, mode)}
  end

  def handle_event("toggle_hide_completed_goals", _params, socket) do
    {:noreply, assign(socket, :hide_completed_goals, !socket.assigns.hide_completed_goals)}
  end

  def handle_event("set_project_tab", %{"tab" => tab}, socket) do
    project_tab =
      case tab do
        "decomposition" -> :decomposition
        "knowledge" -> :knowledge
        "diagnostics" -> :diagnostics
        _ -> :goals
      end

    socket =
      socket
      |> assign(:project_tab, project_tab)
      |> maybe_load_diagnostics(project_tab)
      |> maybe_load_project_knowledge(project_tab)

    {:noreply, socket}
  end

  def handle_event("update_decomp_goal", %{"goal" => goal}, socket) do
    {:noreply, assign(socket, :decomp_goal_text, goal)}
  end

  def handle_event("update_decomp_num_paths", %{"num_paths" => raw}, socket) do
    {:noreply, assign(socket, :decomp_num_paths, clamp_int(raw, 3, 1, 8))}
  end

  def handle_event("update_decomp_max_iterations", %{"max_iterations" => raw}, socket) do
    {:noreply, assign(socket, :decomp_max_iterations, clamp_int(raw, 3, 0, 6))}
  end

  def handle_event("update_decomp_model", %{"model" => model}, socket) do
    model = parse_decomp_model(model)

    socket =
      socket
      |> assign(:decomp_model, model)
      |> maybe_reset_decomp_reasoning_effort(model)

    {:noreply, socket}
  end

  def handle_event("update_decomp_reasoning_effort", %{"reasoning_effort" => effort}, socket) do
    {:noreply, assign(socket, :decomp_reasoning_effort, parse_decomp_reasoning_effort(effort))}
  end

  def handle_event("refresh_diagnostics", _params, socket) do
    {:noreply, refresh_diagnostics(socket)}
  end

  def handle_event("show_new_project_note", _params, socket) do
    {:noreply, assign(socket, creating_project_note: true, project_note_name: "", project_note_content: "")}
  end

  def handle_event("cancel_new_project_note", _params, socket) do
    {:noreply, assign(socket, creating_project_note: false, project_note_name: "", project_note_content: "")}
  end

  def handle_event("update_project_note_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :project_note_name, name)}
  end

  def handle_event("update_project_note_content", %{"content" => content}, socket) do
    {:noreply, assign(socket, :project_note_content, content)}
  end

  def handle_event("create_project_note", _params, socket) do
    project_id = socket.assigns.current_project
    name = String.trim(socket.assigns.project_note_name)
    content = String.trim(socket.assigns.project_note_content)

    cond do
      is_nil(project_id) ->
        {:noreply, socket}

      name == "" ->
        {:noreply, socket}

      true ->
        {:ok, _note} =
          Orchid.Object.create(:markdown, name, content,
            metadata: %{project_id: project_id, category: "Project Notes"}
          )

        {:noreply,
         socket
         |> assign(:creating_project_note, false)
         |> assign(:project_note_name, "")
         |> assign(:project_note_content, "")
         |> refresh_project_knowledge()}
    end
  end

  def handle_event("delete_project_note", %{"id" => id}, socket) do
    Orchid.Object.delete(id)
    {:noreply, refresh_project_knowledge(socket)}
  end

  def handle_event("show_new_project_fact", _params, socket) do
    {:noreply, assign(socket, creating_project_fact: true, project_fact_name: "", project_fact_value: "")}
  end

  def handle_event("cancel_new_project_fact", _params, socket) do
    {:noreply, assign(socket, creating_project_fact: false, project_fact_name: "", project_fact_value: "")}
  end

  def handle_event("update_project_fact_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :project_fact_name, name)}
  end

  def handle_event("update_project_fact_value", %{"value" => value}, socket) do
    {:noreply, assign(socket, :project_fact_value, value)}
  end

  def handle_event("create_project_fact", _params, socket) do
    project_id = socket.assigns.current_project
    name = String.trim(socket.assigns.project_fact_name)
    value = String.trim(socket.assigns.project_fact_value)

    cond do
      is_nil(project_id) ->
        {:noreply, socket}

      name == "" or value == "" ->
        {:noreply, socket}

      true ->
        {:ok, _fact} =
          Orchid.Object.create(:fact, name, value,
            metadata: %{project_id: project_id, category: "Project Facts", scope: :project}
          )

        {:noreply,
         socket
         |> assign(:creating_project_fact, false)
         |> assign(:project_fact_name, "")
         |> assign(:project_fact_value, "")
         |> refresh_project_knowledge()}
    end
  end

  def handle_event("delete_project_fact", %{"id" => id}, socket) do
    Orchid.Object.delete(id)
    {:noreply, refresh_project_knowledge(socket)}
  end

  def handle_event("run_decomposition_test", params, socket) do
    project_id = socket.assigns.current_project
    objective = String.trim(params["goal"] || socket.assigns.decomp_goal_text || "")
    model = parse_decomp_model(params["model"] || Atom.to_string(socket.assigns.decomp_model))
    reasoning_effort =
      parse_decomp_reasoning_effort(
        params["reasoning_effort"] || Atom.to_string(socket.assigns.decomp_reasoning_effort)
      )
    num_paths = clamp_int(params["num_paths"], socket.assigns.decomp_num_paths, 1, 8)
    max_iterations = clamp_int(params["max_iterations"], socket.assigns.decomp_max_iterations, 0, 6)

    cond do
      socket.assigns.decomp_running ->
        {:noreply, socket}

      is_nil(project_id) ->
        {:noreply, assign(socket, :decomp_error, "Select a project first.")}

      objective == "" ->
        {:noreply, assign(socket, :decomp_error, "Enter a goal/objective to decompose.")}

      true ->
        started_ms = System.monotonic_time(:millisecond)
        pid = self()

        socket =
          socket
          |> assign(:decomp_goal_text, objective)
          |> assign(:decomp_model, model)
          |> assign(:decomp_reasoning_effort, reasoning_effort)
          |> assign(:decomp_num_paths, num_paths)
          |> assign(:decomp_max_iterations, max_iterations)
          |> assign(:decomp_running, true)
          |> assign(:decomp_error, nil)
          |> assign(:decomp_result, nil)

        Task.start(fn ->
          llm_config = decomp_llm_config(model, reasoning_effort)

          raw_output =
            case Orchid.LLM.Aletheia.generate_paths(objective, num_paths, llm_config) do
              {:ok, [raw | _]} when is_binary(raw) -> raw
              {:ok, plans} when is_list(plans) -> Enum.join(plans, "\n\n---\n\n")
              {:error, reason} -> "Raw generation failed: #{inspect(reason)}"
            end

          opts = [
            num_paths: num_paths,
            max_iterations: max_iterations,
            project_id: project_id,
            llm_config: llm_config
          ]

          result =
            case Orchid.Planner.plan(objective, Orchid.Sandbox.status(project_id), opts) do
              {:ok, best_plan} ->
                {:ok, best_plan}

              {:error, reason} ->
                {:error, reason}
            end

          duration_ms = System.monotonic_time(:millisecond) - started_ms
          send(
            pid,
            {:decomposition_test_done, result, raw_output, duration_ms, model, reasoning_effort,
             num_paths, max_iterations}
          )
        end)

        {:noreply, socket}
    end
  end

  def handle_event("start_assign_goal", %{"id" => id}, socket) do
    {:noreply, assign(socket, :assigning_goal, id)}
  end

  def handle_event("cancel_assign_goal", _params, socket) do
    {:noreply, assign(socket, :assigning_goal, nil)}
  end

  def handle_event(
        "assign_goal_to_agent",
        %{"goal-id" => goal_id, "agent-id" => agent_id},
        socket
      ) do
    Orchid.Goals.assign_to_agent(goal_id, agent_id)

    {:noreply,
     socket
     |> refresh_goals()
     |> assign(:assigning_goal, nil)}
  end

  def handle_event("toggle_system_prompt", _params, socket) do
    {:noreply, assign(socket, :show_system_prompt, !socket.assigns.show_system_prompt)}
  end

  def handle_event("start_sandbox", %{"id" => project_id}, socket) do
    Orchid.Projects.ensure_sandbox(project_id)
    {:noreply, refresh_sandbox_statuses(socket)}
  end

  def handle_event("stop_sandbox", %{"id" => project_id}, socket) do
    Orchid.Projects.stop_sandbox(project_id)
    {:noreply, refresh_sandbox_statuses(socket)}
  end

  def handle_event("reset_sandbox", %{"id" => project_id}, socket) do
    case Orchid.Sandbox.reset(project_id) do
      {:ok, _status} -> :ok
      {:error, _reason} -> :ok
    end

    {:noreply, refresh_sandbox_statuses(socket)}
  end

  def handle_event("reset_sandbox", _params, socket) do
    # Legacy: reset sandbox from agent chat view using current project
    case socket.assigns.current_project do
      nil ->
        {:noreply, socket}

      project_id ->
        Orchid.Sandbox.reset(project_id)
        {:noreply, refresh_sandbox_statuses(socket)}
    end
  end

  def handle_event("send_message", _params, socket) do
    input = String.trim(socket.assigns.input)

    if input == "" or socket.assigns.streaming do
      {:noreply, socket}
    else
      agent_id = socket.assigns.current_agent

      # Add user message to list immediately so it shows in chat
      messages = socket.assigns.messages ++ [%{role: :user, content: input, tool_calls: nil}]

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:pending_message, input)
        |> assign(:input, "")
        |> assign(:streaming, true)
        |> assign(:stream_content, "")
        |> assign(:retry_count, 0)

      start_stream(socket, agent_id, input)
      {:noreply, socket}
    end
  end

  defp start_stream(_socket, agent_id, input) do
    pid = self()

    Task.start(fn ->
      callback = fn chunk ->
        send(pid, {:stream_chunk, chunk})
      end

      case Orchid.Agent.stream(agent_id, input, callback) do
        {:ok, _} -> send(pid, :stream_done)
        {:error, reason} -> send(pid, {:stream_error, reason})
      end
    end)
  end

  @impl true
  def handle_info({:stream_chunk, chunk}, socket) do
    content = socket.assigns.stream_content <> chunk
    {:noreply, assign(socket, :stream_content, content)}
  end

  def handle_info(:stream_done, socket) do
    # Add assistant response (user message was already added when sent)
    assistant_msg = %{role: :assistant, content: socket.assigns.stream_content, tool_calls: nil}
    messages = socket.assigns.messages ++ [assistant_msg]

    socket =
      socket
      |> assign(:messages, messages)
      |> assign(:streaming, false)
      |> assign(:stream_content, "")
      |> assign(:pending_message, nil)

    {:noreply, socket}
  end

  def handle_info({:stream_error, reason}, socket) do
    retry_count = socket.assigns[:retry_count] || 0

    if retry_count < 3 do
      # Show retry message and schedule retry
      error_msg = format_error(reason)

      messages =
        socket.assigns.messages ++
          [
            %{
              role: :error,
              content: "#{error_msg} - Retrying in 10s (#{retry_count + 1}/3)...",
              tool_calls: nil
            }
          ]

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:retry_count, retry_count + 1)
        |> assign(:stream_content, "")

      # Schedule retry
      Process.send_after(self(), :retry_stream, 10_000)
      {:noreply, socket}
    else
      # Max retries reached - restore pending message to input for editing
      error_msg = format_error(reason)
      pending = socket.assigns[:pending_message] || ""

      messages =
        socket.assigns.messages ++
          [%{role: :error, content: "#{error_msg} - Max retries reached.", tool_calls: nil}]

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:streaming, false)
        |> assign(:stream_content, "")
        |> assign(:input, pending)
        |> assign(:pending_message, nil)

      {:noreply, socket}
    end
  end

  def handle_info(:retry_stream, socket) do
    agent_id = socket.assigns.current_agent
    input = socket.assigns[:pending_message] || ""
    start_stream(socket, agent_id, input)
    {:noreply, socket}
  end

  def handle_info({:refresh_after_stop, id}, socket) do
    socket =
      socket
      |> assign(:agents, list_agents_with_info())
      |> then(fn s ->
        if s.assigns.current_agent == id do
          push_patch(s, to: "/")
        else
          s
        end
      end)

    {:noreply, socket}
  end

  def handle_info({:mcp_call, event}, socket) do
    relevant =
      is_nil(socket.assigns.current_project) or event.project_id == socket.assigns.current_project

    socket =
      if relevant do
        calls = [event | socket.assigns.mcp_calls] |> Enum.take(40)
        assign(socket, :mcp_calls, calls)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(
        {:decomposition_test_done, result, raw_output, duration_ms, model, reasoning_effort,
         num_paths, max_iterations},
        socket
      ) do
    socket =
      case result do
        {:ok, best_plan} ->
          assign(socket,
            decomp_running: false,
            decomp_error: nil,
            decomp_result: %{
              raw_output: raw_output,
              best_plan: best_plan,
              duration_ms: duration_ms,
              model: model,
              reasoning_effort: reasoning_effort,
              num_paths: num_paths,
              max_iterations: max_iterations,
              ran_at: DateTime.utc_now()
            }
          )

        {:error, reason} ->
          assign(socket,
            decomp_running: false,
            decomp_result: %{
              raw_output: raw_output,
              best_plan: nil,
              duration_ms: duration_ms,
              model: model,
              num_paths: num_paths,
              max_iterations: max_iterations,
              ran_at: DateTime.utc_now(),
              planner_error: inspect(reason)
            },
            decomp_error: "Planner failed: #{inspect(reason)}"
          )
      end

    {:noreply, socket}
  end

  def handle_info({:diagnostics_summary_done, excerpt, {:ok, summary}, fetched_at}, socket) do
    {:noreply,
     assign(socket,
       diagnostics_running: false,
       diagnostics_log_excerpt: excerpt,
       diagnostics_summary: summary,
       diagnostics_error: nil,
       diagnostics_updated_at: fetched_at
     )}
  end

  def handle_info({:diagnostics_summary_done, excerpt, {:error, reason}, fetched_at}, socket) do
    {:noreply,
     assign(socket,
       diagnostics_running: false,
       diagnostics_log_excerpt: excerpt,
       diagnostics_summary: nil,
       diagnostics_error: format_diagnostics_error(reason),
       diagnostics_updated_at: fetched_at
     )}
  end

  def handle_info(:poll_agent_status, socket) do
    socket =
      case socket.assigns.current_agent do
        nil ->
          socket

        agent_id ->
          case Orchid.Agent.get_state(agent_id, 2000) do
            {:ok, state} ->
              socket
              |> assign(:agent_status, state.status)
              |> assign(:agent_wait_status, wait_status_from_memory(state.memory))
              |> assign(:messages, format_messages(state.messages))

            _ ->
              socket
          end
      end

    socket =
      socket
      |> assign(:agents, list_agents_with_info())
      |> refresh_sandbox_statuses()
      |> refresh_goals()

    Process.send_after(self(), :poll_agent_status, 2000)
    {:noreply, socket}
  end

  defp format_error({:api_error, status, body}) do
    "API Error #{status}: #{inspect(body)}"
  end

  defp format_error(reason), do: "Error: #{inspect(reason)}"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="app-layout">
      <div class="sidebar">
        <div class="sidebar-header">
          <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 0.5rem;">
            <h2 style="margin: 0;">Projects</h2>
            <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="show_new_project">+ New</button>
          </div>
          <form phx-change="search_projects">
            <input
              type="text"
              name="query"
              class="sidebar-search"
              placeholder="Search projects..."
              value={@project_query}
              phx-debounce="150"
            />
          </form>
        </div>
        <div class="sidebar-content">
          <%= if @creating_project do %>
            <form phx-submit="create_project" phx-change="update_new_project_name" style="padding: 0.5rem;">
              <input
                type="text"
                name="name"
                value={@new_project_name}
                placeholder="Project name"
                class="sidebar-search"
                style="margin-bottom: 0.5rem;"
                autofocus
              />
              <div style="display: flex; gap: 0.25rem;">
                <button type="submit" class="btn btn-sm">Create</button>
                <button type="button" class="btn btn-secondary btn-sm" phx-click="cancel_new_project">Cancel</button>
              </div>
            </form>
          <% else %>
            <%= if @current_project do %>
              <div class="project-item active" style="margin-bottom: 0.5rem;">
                <span class="project-icon"></span>
                <span style="flex: 1;"><%= get_project_name(@projects, @current_project) %></span>
                <button
                  class="btn btn-secondary btn-sm"
                  style="padding: 0.15rem 0.4rem; font-size: 0.7rem;"
                  phx-click="clear_project"
                >×</button>
              </div>
            <% end %>
            <%= for project <- filter_projects(@projects, @project_query, @current_project) do %>
              <% p_status = project.metadata[:status] %>
              <div
                class="project-item"
                phx-click="select_project"
                phx-value-id={project.id}
                style={if p_status in [:paused, :archived], do: "opacity: 0.5;", else: ""}
              >
                <span class="project-icon"></span>
                <span style="flex: 1;"><%= project.name %></span>
                <%= if p_status == :paused do %>
                  <span style="font-size: 0.65rem; color: #d29922; background: #2d2000; padding: 0.05rem 0.3rem; border-radius: 3px;">paused</span>
                <% end %>
                <%= if p_status == :archived do %>
                  <span style="font-size: 0.65rem; color: #8b949e; background: #21262d; padding: 0.05rem 0.3rem; border-radius: 3px;">archived</span>
                <% end %>
              </div>
            <% end %>
            <%= if @projects == [] and not @creating_project do %>
              <div class="no-projects">No projects yet</div>
            <% end %>
          <% end %>
        </div>
        <div class="sidebar-footer">
        </div>
      </div>

      <div class="main-content">
        <div class="container">
          <div class="header">
            <div style="display: flex; align-items: center; gap: 1rem;">
              <%= if @current_agent do %>
                <button class="btn btn-secondary" style="padding: 0.4rem 0.6rem;" phx-click="go_home">&larr;</button>
              <% end %>
              <h1>Orchid</h1>
            </div>
            <div style="display: flex; gap: 0.5rem; align-items: center;">
              <%= if @templates != [] do %>
                <form phx-change="select_template" style="display: inline;">
                  <select class="model-select" name="id" title="Template">
                    <%= for {category, templates} <- group_templates_by_category(@templates) do %>
                      <optgroup label={category}>
                        <%= for template <- templates do %>
                          <option value={template.id} selected={@selected_template == template.id}>
                            <%= template.name %>
                          </option>
                        <% end %>
                      </optgroup>
                    <% end %>
                  </select>
                </form>
              <% end %>
              <form phx-change="update_agent_execution_mode" style="display: inline;">
                <select class="model-select" name="mode" title="Execution Mode">
                  <option value="vm" selected={@agent_execution_mode == :vm}>VM</option>
                  <option value="host" selected={@agent_execution_mode == :host}>Host</option>
                </select>
              </form>
              <a href="/prompts" class="btn btn-secondary" style="padding: 0.4rem 0.6rem;">Prompts</a>
              <a href="/settings" class="btn btn-secondary" style="padding: 0.4rem 0.6rem;">Settings</a>
              <button class="btn btn-secondary" phx-click="show_create_template" title="New Template" style="padding: 0.4rem 0.6rem;">+T</button>
              <%= if @selected_template do %>
                <button class="btn" phx-click="create_agent">New Agent</button>
              <% else %>
                <span style="color: #8b949e; font-size: 0.85rem;">Create a template first</span>
              <% end %>
            </div>
          </div>

          <%= if @creating_template do %>
            <div class="template-form" style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
              <h3 style="color: #c9d1d9; margin: 0 0 1rem 0;">Create Agent Template</h3>
              <form phx-submit="create_template">
                <div style="margin-bottom: 0.75rem;">
                  <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">Name</label>
                  <input
                    type="text"
                    name="name"
                    value={@template_name}
                    phx-change="update_template_name"
                    placeholder="Template name"
                    class="sidebar-search"
                    style="width: 100%;"
                    autofocus
                  />
                </div>
                <div style="display: flex; gap: 0.75rem; margin-bottom: 0.75rem;">
                  <div style="flex: 1;">
                    <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">Category</label>
                    <input
                      type="text"
                      name="category"
                      value={@template_category}
                      phx-change="update_template_category"
                      placeholder="Category"
                      class="sidebar-search"
                      style="width: 100%;"
                      list="category-suggestions"
                    />
                    <datalist id="category-suggestions">
                      <option value="General" />
                      <option value="Coding" />
                      <option value="Writing" />
                      <option value="Analysis" />
                      <option value="Research" />
                    </datalist>
                  </div>
                  <div style="flex: 1;">
                    <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">Provider</label>
                    <select class="sidebar-search" style="width: 100%;" phx-change="update_template_provider" name="provider">
                      <option value="cli" selected={@template_provider == :cli}>CLI</option>
                      <option value="codex" selected={@template_provider == :codex}>Codex</option>
                      <option value="oauth" selected={@template_provider == :oauth}>API</option>
                      <option value="gemini" selected={@template_provider == :gemini}>Gemini</option>
                      <option value="cerebras" selected={@template_provider == :cerebras}>Cerebras</option>
                      <option value="openrouter" selected={@template_provider == :openrouter}>OpenRouter</option>
                    </select>
                  </div>
                  <div style="flex: 1;">
                    <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">Model</label>
                    <select class="sidebar-search" style="width: 100%;" phx-change="update_template_model" name="model">
                      <option value="" selected={@template_model == nil}>Default</option>
                      <option value="opus" selected={@template_model == :opus}>Opus</option>
                      <option value="sonnet" selected={@template_model == :sonnet}>Sonnet</option>
                      <option value="haiku" selected={@template_model == :haiku}>Haiku</option>
                      <option value="gpt53" selected={@template_model == :gpt53}>GPT 5.3</option>
                      <option value="gemini_pro" selected={@template_model == :gemini_pro}>Gemini Pro</option>
                      <option value="gemini_flash" selected={@template_model == :gemini_flash}>Gemini Flash</option>
                      <option value="gemini_flash_image" selected={@template_model == :gemini_flash_image}>Gemini Flash Image</option>
                      <option value="gemini_3_flash" selected={@template_model == :gemini_3_flash}>Gemini 3 Flash</option>
                      <option value="llama_3_1_8b" selected={@template_model == :llama_3_1_8b}>Llama 3.1 8B</option>
                      <option value="llama_3_3_70b" selected={@template_model == :llama_3_3_70b}>Llama 3.3 70B</option>
                      <option value="gpt_oss_120b" selected={@template_model == :gpt_oss_120b}>GPT OSS 120B</option>
                      <option value="qwen_3_32b" selected={@template_model == :qwen_3_32b}>Qwen 3 32B</option>
                      <option value="qwen_3_235b" selected={@template_model == :qwen_3_235b}>Qwen 3 235B</option>
                      <option value="zai_glm_4_7" selected={@template_model == :zai_glm_4_7}>Z.ai GLM 4.7</option>
                      <option value="minimax_m2_5" selected={@template_model == :minimax_m2_5}>MiniMax M2.5</option>
                      <option value="glm_5" selected={@template_model == :glm_5}>GLM-5</option>
                    </select>
                  </div>
                </div>
                <div style="margin-bottom: 0.75rem;">
                  <label style="display: flex; align-items: center; gap: 0.5rem; color: #8b949e; font-size: 0.85rem; cursor: pointer;">
                    <input type="checkbox" phx-click="update_template_orchid_tools" name="value" value="true" checked={@template_use_orchid_tools} />
                    Orchestrator (MCP tools only)
                  </label>
                </div>
                <div style="margin-bottom: 0.75rem;">
                  <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">System Prompt</label>
                  <textarea
                    name="prompt"
                    phx-change="update_template_system_prompt"
                    placeholder="System prompt for this template..."
                    class="sidebar-search"
                    style="width: 100%; min-height: 150px; resize: vertical;"
                  ><%= @template_system_prompt %></textarea>
                </div>
                <div style="display: flex; gap: 0.5rem;">
                  <button type="submit" class="btn">Create Template</button>
                  <button type="button" class="btn btn-secondary" phx-click="cancel_create_template">Cancel</button>
                </div>
              </form>
            </div>
          <% end %>

          <%= if @current_agent do %>
            <div class="chat-container">
              <% sb = @sandbox_statuses[@current_project] %>
              <%= if sb do %>
                <div style="background: #1a2332; border-bottom: 1px solid #30363d; padding: 0.4rem 1rem; font-size: 0.8rem; display: flex; align-items: center; justify-content: space-between;">
                  <span style="color: #7ee787;">Sandbox: <%= sb[:status] %></span>
                  <button class="btn btn-secondary btn-sm" style="padding: 0.15rem 0.5rem; font-size: 0.75rem;" phx-click="reset_sandbox">Reset</button>
                </div>
              <% end %>
              <%= if @current_agent_template do %>
                <div class="template-header" style="background: #21262d; border-bottom: 1px solid #30363d; padding: 0.5rem 1rem; display: flex; align-items: center; gap: 0.5rem; font-size: 0.85rem;">
                  <span style="color: #8b949e;">Template:</span>
                  <span style="color: #58a6ff; font-weight: 500;"><%= @current_agent_template.name %></span>
                  <span style="color: #6e7681;">•</span>
                  <span style="color: #7ee787;"><%= @current_agent_template.category %></span>
                  <span style="color: #6e7681;">•</span>
                  <span style="color: #8b949e;"><%= @current_agent_template.provider %><%= if @current_agent_template.model, do: " / #{@current_agent_template.model}" %></span>
                  <%= if @current_agent_template.use_orchid_tools do %>
                    <span style="color: #6e7681;">•</span>
                    <span style="color: #d2a8ff;">Orchestrator</span>
                  <% end %>
                  <%= if @system_prompt do %>
                    <button
                      class="btn btn-secondary btn-sm"
                      style="padding: 0.1rem 0.4rem; font-size: 0.7rem; margin-left: auto;"
                      phx-click="toggle_system_prompt"
                    ><%= if @show_system_prompt, do: "Hide Prompt", else: "System Prompt" %></button>
                  <% end %>
                </div>
              <% end %>
              <%= if @agent_wait_status && @agent_wait_status != "" do %>
                <div style="background: #111b2e; border-bottom: 1px solid #30363d; padding: 0.4rem 1rem; font-size: 0.8rem; color: #58a6ff;">
                  Waiting: <%= @agent_wait_status %>
                </div>
              <% end %>
              <%= if @show_system_prompt and @system_prompt do %>
                <div style="background: #0d1117; border-bottom: 1px solid #30363d; padding: 0.75rem 1rem; max-height: 300px; overflow-y: auto; font-size: 0.8rem; color: #8b949e; white-space: pre-wrap; font-family: monospace; line-height: 1.5;"><%= @system_prompt %></div>
              <% end %>
              <div class="messages" id="messages" phx-hook="ScrollBottom">
                <%= for msg <- @messages do %>
                  <%= case msg.role do %>
                    <% :user -> %>
                      <div class="message user">
                        <div style="white-space: pre-wrap;"><%= format_content(msg.content) %></div>
                      </div>
                    <% :assistant -> %>
                      <%= if msg.content && msg.content != "" do %>
                        <div class="message assistant">
                          <div style="white-space: pre-wrap;"><%= format_content(msg.content) %></div>
                        </div>
                      <% end %>
                      <%= if msg[:tool_calls] do %>
                        <%= for tc <- msg[:tool_calls] do %>
                          <div class="message tool-call">
                            <div class="tool-name"><%= tc.name %></div>
                            <pre class="tool-args"><%= format_tool_args(tc.arguments) %></pre>
                          </div>
                        <% end %>
                      <% end %>
                    <% :tool -> %>
                      <div class="message tool-result">
                        <pre><%= format_tool_result(msg.content) %></pre>
                      </div>
                    <% :error -> %>
                      <div class="message error">
                        <div style="white-space: pre-wrap;"><%= msg.content %></div>
                      </div>
                    <% :notification -> %>
                      <div class="message" style="background: #111b2e; border: 1px solid #30363d; color: #58a6ff;">
                        <div style="font-size: 0.75rem; margin-bottom: 0.25rem; color: #8b949e;">Notification</div>
                        <div style="white-space: pre-wrap;"><%= format_content(msg.content) %></div>
                      </div>
                    <% _ -> %>
                      <div class="message">
                        <div style="white-space: pre-wrap;"><%= format_content(msg.content) %></div>
                      </div>
                  <% end %>
                <% end %>
                <%= if @streaming and @stream_content != "" do %>
                  <div class="message assistant">
                    <div style="white-space: pre-wrap;"><%= @stream_content %><span class="streaming-cursor"></span></div>
                  </div>
                <% end %>
                <%= if @agent_status != :idle do %>
                  <div class="message" style="background: #1a2332; border: 1px solid #30363d; color: #58a6ff; font-size: 0.85rem; padding: 0.5rem 1rem; display: flex; align-items: center; gap: 0.5rem;">
                    <span class="streaming-cursor"></span>
                    <%= case @agent_status do %>
                      <% :thinking -> %>
                        Thinking...
                      <% {:executing_tool, tool_names} -> %>
                        Executing <%= tool_names %>...
                      <% :executing_tool -> %>
                        Executing tool...
                      <% {:retrying, attempt, max, status_code} -> %>
                        API error (<%= status_code %>), retrying <%= attempt %>/<%= max %>...
                      <% status -> %>
                        <%= inspect(status) %>
                    <% end %>
                  </div>
                <% end %>
              </div>
              <%= if @mcp_calls != [] do %>
                <div style="border-top: 1px solid #30363d; background: #0b0f16; padding: 0.5rem 1rem; max-height: 180px; overflow-y: auto;">
                  <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.35rem;">Recent MCP Calls</div>
                  <%= for ev <- @mcp_calls do %>
                    <div style="display: flex; gap: 0.5rem; align-items: center; font-size: 0.75rem; margin-bottom: 0.2rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">
                      <span style="color: #8b949e; min-width: 56px;"><%= short_time(ev.inserted_at) %></span>
                      <span style="color: #58a6ff; font-family: monospace; min-width: 74px;"><%= short_agent_id(ev.agent_id || "none") %></span>
                      <span style="color: #c9d1d9; min-width: 90px;"><%= ev.tool %></span>
                      <span style={"min-width: 46px; color: #{if ev.outcome == "ok", do: "#7ee787", else: "#f85149"};"}><%= ev.outcome %></span>
                      <span style="color: #8b949e;"><%= if is_integer(ev.duration_ms), do: "#{ev.duration_ms}ms", else: "-" %></span>
                    </div>
                  <% end %>
                </div>
              <% end %>
              <form class="input-area" phx-submit="send_message" phx-change="update_input">
                <textarea
                  rows="2"
                  placeholder="Type a message... (Ctrl+Enter to send)"
                  id="message-input"
                  phx-hook="CtrlEnterSubmit"
                  name="input"
                  value={@input}
                ><%= @input %></textarea>
                <button class="btn" type="submit" disabled={@streaming}>
                  <%= if @streaming, do: "...", else: "Send" %>
                </button>
              </form>
            </div>
          <% else %>
            <%= if @current_project do %>
              <div class="project-detail" style="margin-bottom: 1.5rem;">
                <h2 style="color: #c9d1d9; margin-bottom: 0.5rem;">
                  Project: <%= get_project_name(@projects, @current_project) %>
                </h2>
                <div style="color: #8b949e; font-size: 0.85rem; margin-bottom: 0.5rem;">
                  Folder: <%= Orchid.Project.files_path(@current_project) %>
                </div>

                <% project_status = get_project_status(@projects, @current_project) %>
                <div style="display: flex; align-items: center; gap: 0.5rem; margin-bottom: 1rem;">
                  <span style={"font-size: 0.8rem; padding: 0.15rem 0.5rem; border-radius: 3px; #{project_status_style(project_status)}"}>
                    <%= project_status_label(project_status) %>
                  </span>
                  <%= if project_status in [nil, :active] do %>
                    <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="pause_project" phx-value-id={@current_project}>Pause</button>
                    <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="archive_project" phx-value-id={@current_project}>Archive</button>
                  <% end %>
                  <%= if project_status == :paused do %>
                    <button class="btn btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="resume_project" phx-value-id={@current_project}>Resume</button>
                    <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="archive_project" phx-value-id={@current_project}>Archive</button>
                  <% end %>
                  <%= if project_status == :archived do %>
                    <button class="btn btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="restore_project" phx-value-id={@current_project}>Restore</button>
                  <% end %>
                </div>

                <div class="sandbox-section" style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
                  <div style="display: flex; align-items: center; justify-content: space-between;">
                    <h3 style="color: #c9d1d9; margin: 0; font-size: 1rem;">Sandbox</h3>
                    <% sb = @sandbox_statuses[@current_project] %>
                    <div style="display: flex; gap: 0.5rem; align-items: center;">
                      <%= if sb do %>
                        <span style={"font-size: 0.8rem; padding: 0.15rem 0.5rem; border-radius: 3px; #{sandbox_status_style(sb[:status])}"}>
                          <%= sb[:status] %>
                        </span>
                        <span style="color: #6e7681; font-size: 0.75rem;"><%= sb[:container_name] %></span>
                        <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="reset_sandbox" phx-value-id={@current_project}>Reset</button>
                        <button class="btn btn-danger btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="stop_sandbox" phx-value-id={@current_project}>Stop</button>
                      <% else %>
                        <span style="font-size: 0.8rem; color: #8b949e;">Not running</span>
                        <button class="btn btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="start_sandbox" phx-value-id={@current_project}>Start</button>
                      <% end %>
                    </div>
                  </div>
                </div>

                <div style="display: flex; gap: 0.5rem; margin-bottom: 1rem;">
                  <button
                    class={"btn btn-secondary btn-sm"}
                    style={"padding: 0.2rem 0.6rem; font-size: 0.75rem; #{if @project_tab == :goals, do: "border-color: #58a6ff; color: #58a6ff;", else: ""}"}
                    phx-click="set_project_tab"
                    phx-value-tab="goals"
                  >Goals</button>
                  <button
                    class={"btn btn-secondary btn-sm"}
                    style={"padding: 0.2rem 0.6rem; font-size: 0.75rem; #{if @project_tab == :decomposition, do: "border-color: #58a6ff; color: #58a6ff;", else: ""}"}
                    phx-click="set_project_tab"
                    phx-value-tab="decomposition"
                  >Decomposition Lab</button>
                  <button
                    class={"btn btn-secondary btn-sm"}
                    style={"padding: 0.2rem 0.6rem; font-size: 0.75rem; #{if @project_tab == :knowledge, do: "border-color: #58a6ff; color: #58a6ff;", else: ""}"}
                    phx-click="set_project_tab"
                    phx-value-tab="knowledge"
                  >Knowledge</button>
                  <button
                    class={"btn btn-secondary btn-sm"}
                    style={"padding: 0.2rem 0.6rem; font-size: 0.75rem; #{if @project_tab == :diagnostics, do: "border-color: #58a6ff; color: #58a6ff;", else: ""}"}
                    phx-click="set_project_tab"
                    phx-value-tab="diagnostics"
                  >Diagnostics</button>
                </div>

                <%= if @project_tab == :goals do %>
                <div class="goals-section" style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
                  <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 1rem;">
                    <h3 style="color: #c9d1d9; margin: 0; font-size: 1rem;">Goals</h3>
                    <div style="display: flex; gap: 0.5rem;">
                      <%= if @goals != [] do %>
                        <button
                          class="btn btn-secondary btn-sm"
                          style="padding: 0.2rem 0.5rem; font-size: 0.75rem;"
                          phx-click="toggle_goals_view"
                        ><%= if @goals_view_mode == :list, do: "Graph", else: "List" %></button>
                        <button
                          class="btn btn-secondary btn-sm"
                          style="padding: 0.2rem 0.5rem; font-size: 0.75rem;"
                          phx-click="toggle_hide_completed_goals"
                        ><%= if @hide_completed_goals, do: "Show Done", else: "Hide Done" %></button>
                      <% end %>
                      <%= if @goals != [] do %>
                        <button
                          class="btn btn-danger btn-sm"
                          style="padding: 0.2rem 0.5rem; font-size: 0.75rem; opacity: 0.7;"
                          phx-click="clear_all_goals"
                          data-confirm="Delete all goals for this project?"
                        >Clear All</button>
                      <% end %>
                      <%= if not @creating_goal do %>
                        <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="show_new_goal">+ Add Goal</button>
                      <% end %>
                    </div>
                  </div>

                  <%= if @creating_goal do %>
                    <form phx-submit="create_goal" style="margin-bottom: 1rem;">
                      <input
                        type="text"
                        name="name"
                        value={@new_goal_name}
                        phx-change="update_new_goal_name"
                        placeholder="Goal name"
                        class="sidebar-search"
                        style="width: 100%; margin-bottom: 0.5rem;"
                        autofocus
                      />
                      <textarea
                        name="description"
                        phx-change="update_new_goal_description"
                        placeholder="Description (optional)"
                        class="sidebar-search"
                        style="width: 100%; margin-bottom: 0.5rem; min-height: 3rem; resize: vertical;"
                      ><%= @new_goal_description %></textarea>
                      <%= if @goals != [] do %>
                        <select
                          name="parent"
                          class="sidebar-search"
                          style="width: 100%; margin-bottom: 0.5rem;"
                          phx-change="update_new_goal_parent"
                        >
                          <option value="">No parent</option>
                          <%= for goal <- @goals do %>
                            <option value={goal.id} selected={@new_goal_parent == goal.id}><%= goal.name %></option>
                          <% end %>
                        </select>
                      <% end %>
                      <div style="display: flex; gap: 0.5rem;">
                        <button type="submit" class="btn btn-sm">Add</button>
                        <button type="button" class="btn btn-secondary btn-sm" phx-click="cancel_new_goal">Cancel</button>
                      </div>
                    </form>
                  <% end %>

                  <%= if @goals == [] and not @creating_goal do %>
                    <p style="color: #8b949e; margin: 0;">No goals yet.</p>
                  <% else %>
                    <% visible_goals = filter_visible_goals(@goals, @hide_completed_goals) %>
                    <%= if visible_goals == [] do %>
                      <p style="color: #8b949e; margin: 0;">No visible goals.</p>
                    <% else %>
                    <%= if @goals_view_mode == :graph do %>
                      <% graph = compute_goal_graph(visible_goals) %>
                      <div style="overflow-x: auto; margin-bottom: 1rem;">
                        <svg
                          width={graph.width}
                          height={graph.height}
                          viewBox={"0 0 #{graph.width} #{graph.height}"}
                          style="display: block;"
                        >
                          <defs>
                            <marker id="arrowhead" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
                              <polygon points="0 0, 8 3, 0 6" fill="#8b949e" />
                            </marker>
                          </defs>
                          <%= for edge <- graph.edges do %>
                            <line
                              x1={edge.x1} y1={edge.y1}
                              x2={edge.x2} y2={edge.y2}
                              stroke="#8b949e" stroke-width="1.5"
                              marker-end="url(#arrowhead)"
                              opacity="0.6"
                            />
                          <% end %>
                          <%= for node <- graph.nodes do %>
                            <rect
                              x={node.x} y={node.y}
                              width={node.w} height={node.h}
                              rx="6" ry="6"
                              fill={goal_node_fill(node.status)}
                              stroke={goal_node_stroke(node.status)}
                              stroke-width="1.5"
                            />
                            <text
                              x={node.x + node.w / 2}
                              y={node.y + node.h / 2 + 1}
                              text-anchor="middle"
                              dominant-baseline="middle"
                              fill={goal_node_text(node.status)}
                              font-size="12"
                              font-family="-apple-system, BlinkMacSystemFont, sans-serif"
                            >
                              <%= truncate_name(node.name, 30) %>
                            </text>
                            <%= if node.agent_id do %>
                              <text
                                x={node.x + node.w - 6}
                                y={node.y + 12}
                                text-anchor="end"
                                fill="#58a6ff"
                                font-size="9"
                                font-family="monospace"
                              >
                                <%= short_agent_id(node.agent_id) %>
                              </text>
                            <% end %>
                          <% end %>
                        </svg>
                      </div>
                    <% else %>
                      <div class="goals-list" style="display: flex; flex-direction: column; gap: 0.5rem; margin-bottom: 1rem;">
                        <%= for goal <- topo_sort_goals(visible_goals) do %>
                          <div class="goal-item" style="background: #0d1117; border: 1px solid #30363d; border-radius: 4px; padding: 0.75rem;">
                            <div style="display: flex; align-items: center; gap: 0.5rem;">
                              <button
                                phx-click="toggle_goal_status"
                                phx-value-id={goal.id}
                                style={"width: 1.25rem; height: 1.25rem; border-radius: 3px; border: 1px solid #30363d; background: #{if goal.metadata[:status] == :completed, do: "#238636", else: "transparent"}; cursor: pointer; display: flex; align-items: center; justify-content: center; color: white; font-size: 0.7rem;"}
                              >
                                <%= if goal.metadata[:status] == :completed, do: "✓", else: "" %>
                              </button>
                              <span
                                style={"flex: 1; cursor: pointer; color: #{if goal.metadata[:status] == :completed, do: "#8b949e", else: "#c9d1d9"}; #{if goal.metadata[:status] == :completed, do: "text-decoration: line-through;", else: ""}"}
                                phx-click="toggle_goal_details"
                                phx-value-id={goal.id}
                              >
                                <%= goal.name %>
                                <%= if is_nil(goal.metadata[:parent_goal_id]) do %>
                                  <span style="font-size: 0.65rem; color: #bc8cff; background: #1e1530; padding: 0.05rem 0.3rem; border-radius: 3px; margin-left: 0.25rem;">root</span>
                                <% else %>
                                  <span style="font-size: 0.75rem; color: #8b949e;"> (sub of: <%= get_goal_name(@goals, goal.metadata[:parent_goal_id]) %>)</span>
                                <% end %>
                              </span>
                              <%= if goal.metadata[:agent_id] do %>
                                <span style="background: #1a2332; color: #58a6ff; padding: 0.1rem 0.4rem; border-radius: 3px; font-size: 0.7rem;">
                                  <%= short_agent_id(goal.metadata[:agent_id]) %>
                                </span>
                              <% end %>
                              <%= if filter_agents(@agents, @current_project) != [] do %>
                                <button
                                  class="btn btn-secondary btn-sm"
                                  style="padding: 0.15rem 0.4rem; font-size: 0.7rem;"
                                  phx-click="start_assign_goal"
                                  phx-value-id={goal.id}
                                >Assign</button>
                              <% end %>
                              <button
                                class="btn btn-secondary btn-sm"
                                style="padding: 0.15rem 0.4rem; font-size: 0.7rem;"
                                phx-click="start_add_dependency"
                                phx-value-id={goal.id}
                              >+ dep</button>
                              <button
                                class="btn btn-danger btn-sm"
                                style="padding: 0.15rem 0.4rem; font-size: 0.7rem; opacity: 0.7;"
                                phx-click="delete_goal"
                                phx-value-id={goal.id}
                              >×</button>
                            </div>
                            <% outcome = goal_terminal_outcome(goal) %>
                            <% summary = goal_summary(goal) %>
                            <%= if outcome && summary != "" do %>
                              <div style="margin-top: 0.4rem; margin-left: 1.75rem; font-size: 0.8rem; display: flex; gap: 0.4rem; align-items: flex-start;">
                                <span style={"padding: 0.05rem 0.35rem; border-radius: 3px; font-size: 0.7rem; #{goal_outcome_style(outcome)}"}><%= goal_outcome_label(outcome) %></span>
                                <span style="color: #8b949e; white-space: pre-wrap; word-break: break-word;"><%= summary %></span>
                              </div>
                            <% end %>
                            <%= if @expanded_goal == goal.id do %>
                              <div style="margin-top: 0.5rem; margin-left: 1.75rem; padding: 0.5rem; background: #161b22; border: 1px solid #21262d; border-radius: 4px; font-size: 0.8rem;">
                                <%= if goal.content != "" do %>
                                  <div style="color: #c9d1d9; margin-bottom: 0.5rem; white-space: pre-wrap;"><%= goal.content %></div>
                                <% else %>
                                  <div style="color: #6e7681; margin-bottom: 0.5rem; font-style: italic;">No description</div>
                                <% end %>
                                <div style="color: #6e7681; font-size: 0.7rem; display: flex; flex-wrap: wrap; gap: 0.75rem;">
                                  <span>ID: <span style="color: #8b949e; font-family: monospace;"><%= goal.id %></span></span>
                                  <span>Status: <span style="color: #8b949e;"><%= goal.metadata[:status] %></span></span>
                                  <%= if goal.metadata[:parent_goal_id] do %>
                                    <span>Parent: <span style="color: #8b949e;"><%= get_goal_name(@goals, goal.metadata[:parent_goal_id]) %></span></span>
                                  <% end %>
                                  <%= if goal.metadata[:agent_id] do %>
                                    <span>Agent: <span style="color: #58a6ff; font-family: monospace;"><%= short_agent_id(goal.metadata[:agent_id]) %></span></span>
                                  <% end %>
                                  <%= if outcome do %>
                                    <span>Outcome: <span style="color: #8b949e;"><%= goal_outcome_label(outcome) %></span></span>
                                  <% end %>
                                  <span>Created: <span style="color: #8b949e;"><%= Calendar.strftime(goal.created_at, "%Y-%m-%d %H:%M") %></span></span>
                                </div>
                                <%= if outcome && summary != "" do %>
                                  <div style="margin-top: 0.5rem; color: #8b949e; white-space: pre-wrap; word-break: break-word;">
                                    <strong style="color: #c9d1d9;">Summary:</strong> <%= summary %>
                                  </div>
                                <% end %>
                              </div>
                            <% end %>
                            <%= if (goal.metadata[:depends_on] || []) != [] do %>
                              <div style="margin-top: 0.5rem; margin-left: 1.75rem; font-size: 0.85rem; color: #8b949e;">
                                depends on:
                                <%= for dep_id <- goal.metadata[:depends_on] || [] do %>
                                  <span style="display: inline-flex; align-items: center; gap: 0.25rem; background: #21262d; padding: 0.1rem 0.4rem; border-radius: 3px; margin-right: 0.25rem;">
                                    <%= get_goal_name(@goals, dep_id) %>
                                    <button
                                      phx-click="remove_dependency"
                                      phx-value-goal-id={goal.id}
                                      phx-value-depends-on={dep_id}
                                      style="background: none; border: none; color: #f85149; cursor: pointer; padding: 0; font-size: 0.7rem;"
                                    >×</button>
                                  </span>
                                <% end %>
                              </div>
                            <% end %>
                            <%= if @adding_dependency_to == goal.id do %>
                              <div style="margin-top: 0.5rem; margin-left: 1.75rem;">
                                <div style="display: flex; flex-wrap: wrap; gap: 0.25rem;">
                                  <%= for other_goal <- Enum.filter(@goals, fn g -> g.id != goal.id and g.id not in (goal.metadata[:depends_on] || []) end) do %>
                                    <button
                                      class="btn btn-secondary btn-sm"
                                      style="padding: 0.2rem 0.5rem; font-size: 0.75rem;"
                                      phx-click="add_dependency"
                                      phx-value-goal-id={goal.id}
                                      phx-value-depends-on={other_goal.id}
                                    ><%= other_goal.name %></button>
                                  <% end %>
                                  <button
                                    class="btn btn-secondary btn-sm"
                                    style="padding: 0.2rem 0.5rem; font-size: 0.75rem;"
                                    phx-click="cancel_add_dependency"
                                  >Cancel</button>
                                </div>
                              </div>
                            <% end %>
                            <%= if @assigning_goal == goal.id do %>
                              <div style="margin-top: 0.5rem; margin-left: 1.75rem;">
                                <div style="display: flex; flex-wrap: wrap; gap: 0.25rem;">
                                  <%= for agent <- filter_agents(@agents, @current_project) do %>
                                    <button
                                      class="btn btn-secondary btn-sm"
                                      style="padding: 0.2rem 0.5rem; font-size: 0.75rem;"
                                      phx-click="assign_goal_to_agent"
                                      phx-value-goal-id={goal.id}
                                      phx-value-agent-id={agent.id}
                                    ><%= short_agent_id(agent.id) %></button>
                                  <% end %>
                                  <button
                                    class="btn btn-secondary btn-sm"
                                    style="padding: 0.2rem 0.5rem; font-size: 0.75rem;"
                                    phx-click="cancel_assign_goal"
                                  >Cancel</button>
                                </div>
                              </div>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                    <% end %>
                  <% end %>
                </div>
                <% else %>
                <%= if @project_tab == :decomposition do %>
                <div class="goals-section" style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
                  <form phx-submit="run_decomposition_test">
                    <div style="display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; margin-bottom: 0.75rem;">
                      <h3 style="color: #c9d1d9; margin: 0; font-size: 1rem;">Goal -> Plan Decomposition</h3>
                      <div style="display: flex; gap: 0.5rem; align-items: center;">
                        <select
                          class="sidebar-search"
                          style="font-size: 0.8rem; padding: 0.2rem 0.5rem;"
                          phx-change="update_decomp_model"
                          name="model"
                        >
                          <option value="opus" selected={@decomp_model == :opus}>Opus</option>
                          <option value="sonnet" selected={@decomp_model == :sonnet}>Sonnet</option>
                          <option value="haiku" selected={@decomp_model == :haiku}>Haiku</option>
                          <option value="gpt54" selected={@decomp_model == :gpt54}>GPT 5.4</option>
                          <option value="gpt53" selected={@decomp_model == :gpt53}>GPT 5.3</option>
                          <option value="gpt52_codex" selected={@decomp_model == :gpt52_codex}>GPT 5.2 Codex</option>
                          <option value="gpt51_codex_max" selected={@decomp_model == :gpt51_codex_max}>GPT 5.1 Codex Max</option>
                          <option value="gpt51_codex" selected={@decomp_model == :gpt51_codex}>GPT 5.1 Codex</option>
                          <option value="gpt51_codex_mini" selected={@decomp_model == :gpt51_codex_mini}>GPT 5.1 Codex Mini</option>
                          <option value="gemini_3_pro" selected={@decomp_model == :gemini_3_pro}>Gemini 3 Pro</option>
                          <option value="minimax_m2_5" selected={@decomp_model == :minimax_m2_5}>MiniMax M2.5</option>
                          <option value="glm_5" selected={@decomp_model == :glm_5}>GLM-5</option>
                          <option value="kimi_k2_5" selected={@decomp_model == :kimi_k2_5}>Kimi K2.5</option>
                        </select>
                        <select
                          class="sidebar-search"
                          style="font-size: 0.8rem; padding: 0.2rem 0.5rem; min-width: 11rem;"
                          phx-change="update_decomp_reasoning_effort"
                          name="reasoning_effort"
                          disabled={!decomp_codex_model?(@decomp_model)}
                          title={if decomp_codex_model?(@decomp_model), do: "Codex thinking level", else: "Thinking level is only used for Codex models"}
                        >
                          <option value="low" selected={@decomp_reasoning_effort == :low}>Low</option>
                          <option value="medium" selected={@decomp_reasoning_effort == :medium}>Medium</option>
                          <option value="high" selected={@decomp_reasoning_effort == :high}>High</option>
                          <option value="xhigh" selected={@decomp_reasoning_effort == :xhigh}>Extra high</option>
                        </select>
                        <input
                          type="number"
                          min="1"
                          max="8"
                          name="num_paths"
                          value={@decomp_num_paths}
                          phx-change="update_decomp_num_paths"
                          class="sidebar-search"
                          style="width: 4.5rem; font-size: 0.8rem; padding: 0.2rem 0.4rem;"
                          title="num_paths"
                        />
                        <input
                          type="number"
                          min="0"
                          max="6"
                          name="max_iterations"
                          value={@decomp_max_iterations}
                          phx-change="update_decomp_max_iterations"
                          class="sidebar-search"
                          style="width: 4.5rem; font-size: 0.8rem; padding: 0.2rem 0.4rem;"
                          title="max_iterations"
                        />
                        <button class="btn btn-sm" type="submit" disabled={@decomp_running}>
                          <%= if @decomp_running, do: "Running...", else: "Run" %>
                        </button>
                      </div>
                    </div>
                    <%= if decomp_codex_model?(@decomp_model) do %>
                      <div style="color: #8b949e; font-size: 0.8rem; margin-bottom: 0.75rem;">
                        Thinking level: <%= decomp_reasoning_effort_label(@decomp_reasoning_effort) %>
                        <span style="margin-left: 0.35rem;">
                          <%= decomp_reasoning_effort_description(@decomp_reasoning_effort) %>
                        </span>
                      </div>
                    <% end %>

                    <textarea
                      name="goal"
                      phx-change="update_decomp_goal"
                      class="sidebar-search"
                      placeholder="Enter a goal/objective to decompose into a robust implementation plan..."
                      style="width: 100%; min-height: 5.5rem; resize: vertical; margin-bottom: 0.75rem;"
                    ><%= @decomp_goal_text %></textarea>
                  </form>

                  <%= if @decomp_error do %>
                    <div style="background: #3d1114; color: #f85149; border: 1px solid #f85149; border-radius: 4px; padding: 0.5rem; font-size: 0.85rem; margin-bottom: 0.75rem;">
                      <%= @decomp_error %>
                    </div>
                  <% end %>

                  <%= if @decomp_result do %>
                    <div style="margin-bottom: 0.6rem; color: #8b949e; font-size: 0.8rem;">
                      model=<%= @decomp_result.model %><%= if decomp_codex_model?(@decomp_result.model), do: " (" <> decomp_reasoning_effort_label(@decomp_result.reasoning_effort) <> ")" %> • paths=<%= @decomp_result.num_paths %> • iterations=<%= @decomp_result.max_iterations %> • duration=<%= @decomp_result.duration_ms %>ms • <%= short_time(@decomp_result.ran_at) %>
                    </div>
                    <div style="background: #0d1117; border: 1px solid #30363d; border-radius: 4px; padding: 0.75rem; margin-bottom: 0.75rem;">
                      <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.35rem;">Raw Model Output</div>
                      <pre style="margin: 0; white-space: pre-wrap; color: #c9d1d9; font-size: 0.85rem;"><%= @decomp_result.raw_output %></pre>
                    </div>
                    <%= if @decomp_result.best_plan do %>
                      <div style="background: #0d1117; border: 1px solid #30363d; border-radius: 4px; padding: 0.75rem;">
                        <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.35rem;">Planner Selected Plan</div>
                        <pre style="margin: 0; white-space: pre-wrap; color: #c9d1d9; font-size: 0.85rem;"><%= @decomp_result.best_plan %></pre>
                      </div>
                    <% end %>
                    <%= if @decomp_result[:planner_error] do %>
                      <div style="margin-top: 0.5rem; color: #f85149; font-size: 0.8rem;">
                        planner_error=<%= @decomp_result.planner_error %>
                      </div>
                    <% end %>
                  <% else %>
                    <div style="color: #8b949e; font-size: 0.85rem;">No run yet.</div>
                  <% end %>
                </div>
                <% else %>
                <%= if @project_tab == :knowledge do %>
                <div class="goals-section" style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
                  <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 0.75rem;">
                    <div style="background: #0d1117; border: 1px solid #30363d; border-radius: 4px; padding: 0.75rem;">
                      <div style="display: flex; align-items: center; justify-content: space-between; gap: 0.5rem; margin-bottom: 0.75rem;">
                        <div>
                          <h3 style="color: #c9d1d9; margin: 0; font-size: 1rem;">Project Notes</h3>
                          <div style="color: #8b949e; font-size: 0.8rem; margin-top: 0.2rem;">
                            Markdown notes scoped to this project.
                          </div>
                        </div>
                        <%= if not @creating_project_note do %>
                          <button class="btn btn-secondary btn-sm" type="button" phx-click="show_new_project_note">+ Note</button>
                        <% end %>
                      </div>

                      <%= if @creating_project_note do %>
                        <form phx-submit="create_project_note" style="margin-bottom: 0.75rem;">
                          <input
                            type="text"
                            name="name"
                            value={@project_note_name}
                            phx-change="update_project_note_name"
                            placeholder="Note title"
                            class="sidebar-search"
                            style="width: 100%; margin-bottom: 0.5rem;"
                          />
                          <textarea
                            name="content"
                            phx-change="update_project_note_content"
                            class="sidebar-search"
                            placeholder="What should Orchid remember about this project?"
                            style="width: 100%; min-height: 8rem; resize: vertical; margin-bottom: 0.5rem;"
                          ><%= @project_note_content %></textarea>
                          <div style="display: flex; gap: 0.5rem;">
                            <button type="submit" class="btn btn-sm">Save Note</button>
                            <button type="button" class="btn btn-secondary btn-sm" phx-click="cancel_new_project_note">Cancel</button>
                          </div>
                        </form>
                      <% end %>

                      <%= if @project_notes == [] do %>
                        <div style="color: #8b949e; font-size: 0.85rem;">No project notes yet.</div>
                      <% else %>
                        <div style="display: flex; flex-direction: column; gap: 0.5rem;">
                          <%= for note <- @project_notes do %>
                            <div style="background: #161b22; border: 1px solid #30363d; border-radius: 4px; padding: 0.65rem;">
                              <div style="display: flex; align-items: center; justify-content: space-between; gap: 0.5rem; margin-bottom: 0.35rem;">
                                <div style="color: #c9d1d9; font-weight: 500;"><%= note.name %></div>
                                <button class="btn btn-danger btn-sm" type="button" phx-click="delete_project_note" phx-value-id={note.id}>Delete</button>
                              </div>
                              <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.35rem;">
                                Updated <%= short_datetime(note.updated_at) %>
                              </div>
                              <div style="color: #c9d1d9; white-space: pre-wrap; font-size: 0.85rem;"><%= note.content %></div>
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>

                    <div style="background: #0d1117; border: 1px solid #30363d; border-radius: 4px; padding: 0.75rem;">
                      <div style="display: flex; align-items: center; justify-content: space-between; gap: 0.5rem; margin-bottom: 0.75rem;">
                        <div>
                          <h3 style="color: #c9d1d9; margin: 0; font-size: 1rem;">Project Facts</h3>
                          <div style="color: #8b949e; font-size: 0.8rem; margin-top: 0.2rem;">
                            Short structured values for this project only.
                          </div>
                        </div>
                        <%= if not @creating_project_fact do %>
                          <button class="btn btn-secondary btn-sm" type="button" phx-click="show_new_project_fact">+ Fact</button>
                        <% end %>
                      </div>

                      <%= if @creating_project_fact do %>
                        <form phx-submit="create_project_fact" style="margin-bottom: 0.75rem;">
                          <input
                            type="text"
                            name="name"
                            value={@project_fact_name}
                            phx-change="update_project_fact_name"
                            placeholder="Fact key"
                            class="sidebar-search"
                            style="width: 100%; margin-bottom: 0.5rem;"
                          />
                          <textarea
                            name="value"
                            phx-change="update_project_fact_value"
                            class="sidebar-search"
                            placeholder="Fact value"
                            style="width: 100%; min-height: 6rem; resize: vertical; margin-bottom: 0.5rem;"
                          ><%= @project_fact_value %></textarea>
                          <div style="display: flex; gap: 0.5rem;">
                            <button type="submit" class="btn btn-sm">Save Fact</button>
                            <button type="button" class="btn btn-secondary btn-sm" phx-click="cancel_new_project_fact">Cancel</button>
                          </div>
                        </form>
                      <% end %>

                      <%= if @project_facts == [] do %>
                        <div style="color: #8b949e; font-size: 0.85rem;">No project facts yet.</div>
                      <% else %>
                        <div style="display: flex; flex-direction: column; gap: 0.5rem;">
                          <%= for fact <- @project_facts do %>
                            <div style="background: #161b22; border: 1px solid #30363d; border-radius: 4px; padding: 0.65rem;">
                              <div style="display: flex; align-items: center; justify-content: space-between; gap: 0.5rem; margin-bottom: 0.35rem;">
                                <div style="color: #58a6ff; font-weight: 500;"><%= fact.name %></div>
                                <button class="btn btn-danger btn-sm" type="button" phx-click="delete_project_fact" phx-value-id={fact.id}>Delete</button>
                              </div>
                              <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.35rem;">
                                Updated <%= short_datetime(fact.updated_at) %>
                              </div>
                              <div style="color: #c9d1d9; white-space: pre-wrap; font-size: 0.85rem;"><%= fact.content %></div>
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  </div>
                </div>
                <% else %>
                <div class="goals-section" style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
                  <div style="display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; margin-bottom: 0.75rem;">
                    <div>
                      <h3 style="color: #c9d1d9; margin: 0; font-size: 1rem;">Diagnostics</h3>
                      <div style="color: #8b949e; font-size: 0.8rem; margin-top: 0.2rem;">
                        Source: <%= @diagnostics_log_path %>
                      </div>
                    </div>
                    <div style="display: flex; align-items: center; gap: 0.5rem;">
                      <%= if @diagnostics_updated_at do %>
                        <span style="color: #8b949e; font-size: 0.8rem;">
                          <%= short_time(@diagnostics_updated_at) %>
                        </span>
                      <% end %>
                      <button class="btn btn-sm" type="button" phx-click="refresh_diagnostics" disabled={@diagnostics_running}>
                        <%= if @diagnostics_running, do: "Refreshing...", else: "Refresh" %>
                      </button>
                    </div>
                  </div>

                  <%= if @diagnostics_error do %>
                    <div style="background: #3d1114; color: #f85149; border: 1px solid #f85149; border-radius: 4px; padding: 0.5rem; font-size: 0.85rem; margin-bottom: 0.75rem;">
                      <%= @diagnostics_error %>
                    </div>
                  <% end %>

                  <div style="display: grid; grid-template-columns: minmax(0, 1fr); gap: 0.75rem;">
                    <div style="background: #0d1117; border: 1px solid #30363d; border-radius: 4px; padding: 0.75rem;">
                      <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.35rem;">Haiku Summary</div>
                      <div style="color: #c9d1d9; white-space: pre-wrap; font-size: 0.85rem;">
                        <%= cond do %>
                          <% @diagnostics_running and is_nil(@diagnostics_summary) -> %>
                            Summarizing latest log tail...
                          <% is_binary(@diagnostics_summary) and String.trim(@diagnostics_summary) != "" -> %>
                            <%= @diagnostics_summary %>
                          <% @diagnostics_log_excerpt in [nil, ""] -> %>
                            No log data loaded yet.
                          <% true -> %>
                            Summary unavailable.
                        <% end %>
                      </div>
                    </div>

                    <div style="background: #0d1117; border: 1px solid #30363d; border-radius: 4px; padding: 0.75rem;">
                      <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.35rem;">Recent Log Lines</div>
                      <pre style="margin: 0; white-space: pre-wrap; color: #c9d1d9; font-size: 0.82rem; max-height: 26rem; overflow: auto;"><%= @diagnostics_log_excerpt || "No log data loaded yet." %></pre>
                    </div>
                  </div>
                </div>
                <% end %>
                <% end %>
                <% end %>

                <h3 style="color: #c9d1d9; margin-bottom: 0.5rem;">Agents</h3>
              </div>
            <% end %>

            <p style="color: #8b949e; margin-bottom: 1rem;">
              <%= if @current_project do %>
                Agents for this project:
              <% else %>
                Select an agent or create a new one to start chatting.
              <% end %>
            </p>
            <p style="color: #8b949e; font-size: 0.8rem; margin-top: -0.5rem; margin-bottom: 0.8rem;">
              New agent mode: <%= if @agent_execution_mode == :host, do: "Host", else: "VM" %>
            </p>
            <div class="agent-list">
              <%= for agent <- filter_agents(@agents, @current_project) do %>
                <div class="agent-card">
                  <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.25rem;">
                    <h3 style="margin: 0;"><%= agent.id %></h3>
                    <div style="display: flex; gap: 0.4rem; align-items: center;">
                      <div style={"padding: 0.15rem 0.5rem; border-radius: 12px; font-size: 0.75rem; #{agent_status_style(agent.status)}"}><%= agent_status_label(agent.status) %></div>
                      <span style={"font-size: 0.7rem; padding: 0.1rem 0.4rem; border-radius: 10px; #{agent_mode_style(agent.execution_mode)}"}>
                        <%= agent_mode_label(agent.execution_mode) %>
                      </span>
                    </div>
                  </div>
                  <%= if agent.template do %>
                    <div style="color: #8b949e; font-size: 0.85rem;"><%= agent.template %></div>
                  <% end %>
                  <%= if agent.goal do %>
                    <div style="color: #c9d1d9; font-size: 0.85rem; margin-top: 0.25rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;" title={agent.goal}><%= agent.goal %></div>
                  <% end %>
                  <%= if agent.wait_status do %>
                    <div style="color: #58a6ff; font-size: 0.8rem; margin-top: 0.25rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;" title={agent.wait_status}>
                      Waiting: <%= agent.wait_status %>
                    </div>
                  <% end %>
                  <%= if agent.project_id && !@current_project do %>
                    <div class="agent-project" style="margin-top: 0.25rem;">
                      <span class="project-badge"><%= get_project_name(@projects, agent.project_id) %></span>
                    </div>
                  <% end %>
                  <div class="actions" style="margin-top: 0.5rem;">
                    <button class="btn btn-secondary" phx-click="select_agent" phx-value-id={agent.id}>Open</button>
                    <button class="btn btn-danger" phx-click="stop_agent" phx-value-id={agent.id}>Stop</button>
                  </div>
                </div>
              <% end %>
              <%= if filter_agents(@agents, @current_project) == [] do %>
                <p style="color: #8b949e;">No active agents. Create one to get started.</p>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp filter_projects(projects, query, current_project) do
    projects
    |> Enum.reject(fn p -> p.id == current_project end)
    |> Enum.filter(fn p ->
      query == "" or String.contains?(String.downcase(p.name), String.downcase(query))
    end)
  end

  defp get_project_name(projects, id) do
    case Enum.find(projects, fn p -> p.id == id end) do
      nil -> "Unknown"
      project -> project.name
    end
  end

  defp get_project_status(projects, id) do
    case Enum.find(projects, fn p -> p.id == id end) do
      nil -> nil
      project -> project.metadata[:status]
    end
  end

  defp project_status_label(nil), do: "Active"
  defp project_status_label(:active), do: "Active"
  defp project_status_label(:paused), do: "Paused"
  defp project_status_label(:archived), do: "Archived"

  defp project_status_style(nil), do: "background: #0e2a15; color: #7ee787;"
  defp project_status_style(:active), do: "background: #0e2a15; color: #7ee787;"
  defp project_status_style(:paused), do: "background: #2d2000; color: #d29922;"
  defp project_status_style(:archived), do: "background: #21262d; color: #8b949e;"

  defp get_goal_name(goals, id) do
    case Enum.find(goals, fn g -> g.id == id end) do
      nil -> "Unknown"
      goal -> goal.name
    end
  end

  defp goal_terminal_outcome(goal) do
    status = normalize_status(goal.metadata[:status])
    outcome = normalize_outcome(goal.metadata[:task_outcome])

    cond do
      outcome in [:failure, :blocked] -> outcome
      status == :completed -> :success
      outcome == :success -> :success
      true -> nil
    end
  end

  defp goal_summary(goal) do
    outcome = normalize_outcome(goal.metadata[:task_outcome])

    first_nonempty([
      if(outcome in [:failure, :blocked], do: goal.metadata[:last_error], else: nil),
      goal.metadata[:completion_summary],
      goal.metadata[:report],
      if(outcome in [:failure, :blocked], do: goal.metadata[:last_error], else: nil)
    ])
  end

  defp goal_outcome_label(:success), do: "Completed"
  defp goal_outcome_label(:failure), do: "Failed"
  defp goal_outcome_label(:blocked), do: "Blocked"
  defp goal_outcome_label(_), do: "Done"

  defp goal_outcome_style(:success), do: "background: #0e2a15; color: #7ee787;"
  defp goal_outcome_style(:failure), do: "background: #3d1114; color: #f85149;"
  defp goal_outcome_style(:blocked), do: "background: #2d2000; color: #d29922;"
  defp goal_outcome_style(_), do: "background: #21262d; color: #8b949e;"

  defp normalize_status(v) when is_atom(v), do: v

  defp normalize_status(v) when is_binary(v) do
    case String.downcase(v) do
      "completed" -> :completed
      "pending" -> :pending
      _ -> nil
    end
  end

  defp normalize_status(_), do: nil

  defp normalize_outcome(v) when is_atom(v), do: v

  defp normalize_outcome(v) when is_binary(v) do
    case String.downcase(v) do
      "success" -> :success
      "failure" -> :failure
      "blocked" -> :blocked
      "in_progress" -> :in_progress
      _ -> nil
    end
  end

  defp normalize_outcome(_), do: nil

  defp first_nonempty(values) do
    values
    |> Enum.find("", fn v ->
      is_binary(v) and String.trim(v) != ""
    end)
    |> String.trim()
  end

  defp format_content(content) when is_binary(content), do: content
  defp format_content(content), do: inspect(content)

  defp format_tool_args(args) when is_map(args) do
    Jason.encode!(args, pretty: true)
  end

  defp format_tool_args(args), do: inspect(args, pretty: true)

  defp format_tool_result(%{content: content}), do: truncate(content, 500)
  defp format_tool_result(content) when is_binary(content), do: truncate(content, 500)
  defp format_tool_result(content), do: truncate(inspect(content), 500)

  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max) <> "..."
  end

  defp truncate(str, _max), do: str

  defp list_agents_with_info do
    Orchid.Agent.list()
    |> Enum.map(fn agent_id ->
      case Orchid.Agent.get_state(agent_id) do
        {:ok, state} ->
          template_name =
            case state.config[:template_id] do
              nil ->
                nil

              tid ->
                case Orchid.Object.get(tid) do
                  {:ok, obj} -> obj.name
                  _ -> nil
                end
            end

          goal_name =
            case state.project_id do
              nil ->
                nil

              pid ->
                Orchid.Object.list_goals_for_project(pid)
                |> Enum.find(fn g -> g.metadata[:agent_id] == agent_id end)
                |> case do
                  nil -> nil
                  g -> g.name
                end
            end

          status = state.status
          wait_status = wait_status_from_memory(state.memory)
          execution_mode = state.execution_mode || :vm

          %{
            id: agent_id,
            project_id: state.project_id,
            template: template_name,
            goal: goal_name,
            status: status,
            wait_status: wait_status,
            execution_mode: execution_mode
          }

        _ ->
          %{
            id: agent_id,
            project_id: nil,
            template: nil,
            goal: nil,
            status: :unknown,
            wait_status: nil,
            execution_mode: :vm
          }
      end
    end)
  end

  defp wait_status_from_memory(memory) when is_map(memory) do
    case Map.get(memory, "wait_status") || Map.get(memory, :wait_status) do
      msg when is_binary(msg) and msg != "" -> msg
      _ -> nil
    end
  end

  defp wait_status_from_memory(_), do: nil

  defp refresh_sandbox_statuses(socket) do
    case socket.assigns.current_project do
      nil ->
        assign(socket, :sandbox_statuses, %{})

      project_id ->
        statuses =
          case Orchid.Projects.sandbox_status(project_id) do
            nil -> %{}
            status -> %{project_id => status}
          end

        assign(socket, :sandbox_statuses, statuses)
    end
  end

  defp agent_status_label(:idle), do: "Idle"
  defp agent_status_label({:executing_tool, names}), do: "Tool: #{names}"
  defp agent_status_label(:thinking), do: "Thinking..."
  defp agent_status_label(:streaming), do: "Streaming..."

  defp agent_status_label(status) when is_atom(status),
    do: status |> Atom.to_string() |> String.capitalize()

  defp agent_status_label(_), do: "Active"

  defp agent_status_style(:idle), do: "background: #21262d; color: #8b949e;"
  defp agent_status_style({:executing_tool, _}), do: "background: #2d2000; color: #d29922;"
  defp agent_status_style(:thinking), do: "background: #0c2d6b; color: #58a6ff;"
  defp agent_status_style(:streaming), do: "background: #0c2d6b; color: #58a6ff;"
  defp agent_status_style(_), do: "background: #0e2a15; color: #7ee787;"

  defp sandbox_status_style(:ready), do: "background: #0e2a15; color: #7ee787;"
  defp sandbox_status_style(:starting), do: "background: #2d2000; color: #d29922;"
  defp sandbox_status_style(:error), do: "background: #3d1114; color: #f85149;"
  defp sandbox_status_style(_), do: "background: #21262d; color: #8b949e;"

  defp agent_mode_label(:host), do: "Host"
  defp agent_mode_label("host"), do: "Host"
  defp agent_mode_label(_), do: "VM"

  defp agent_mode_style(:host), do: "background: #3b2300; color: #ffb86b;"
  defp agent_mode_style("host"), do: "background: #3b2300; color: #ffb86b;"
  defp agent_mode_style(_), do: "background: #0b2d47; color: #79c0ff;"

  defp refresh_goals(socket) do
    case socket.assigns.current_project do
      nil -> assign(socket, :goals, [])
      project_id -> assign(socket, :goals, Orchid.Goals.list_for_project(project_id))
    end
  end

  defp refresh_project_knowledge(socket) do
    case socket.assigns.current_project do
      nil ->
        assign(socket, project_notes: [], project_facts: [])

      project_id ->
        assign(socket,
          project_notes: list_project_notes(project_id),
          project_facts: list_project_facts(project_id)
        )
    end
  end

  defp maybe_load_project_knowledge(socket, :knowledge), do: refresh_project_knowledge(socket)
  defp maybe_load_project_knowledge(socket, _tab), do: socket

  defp filter_agents(agents, nil), do: agents

  defp filter_agents(agents, current_project) do
    Enum.filter(agents, fn agent ->
      agent.project_id == current_project
    end)
  end

  defp filter_visible_goals(goals, false), do: goals

  defp filter_visible_goals(goals, true) do
    Enum.filter(goals, fn goal -> goal.metadata[:status] != :completed end)
  end

  defp recent_mcp_calls(project_id, limit) do
    try do
      Orchid.McpEvents.list_recent(project_id, limit, 250)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp short_agent_id(id) when is_binary(id) do
    String.slice(id, 0, 8)
  end

  defp short_agent_id(id), do: inspect(id)

  defp short_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp short_datetime(_), do: "--"
  defp short_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp short_time(_), do: "--:--:--"

  defp list_project_notes(project_id) do
    Orchid.Object.list_markdown_for_project(project_id)
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  defp list_project_facts(project_id) do
    Orchid.Object.list_facts_for_project(project_id)
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  defp compute_goal_graph(goals) do
    id_set = MapSet.new(goals, & &1.id)

    # Assign each goal a layer (depth) based on longest path from roots
    depths = compute_depths(goals, id_set)

    # Group by layer
    layers =
      goals
      |> Enum.group_by(&Map.get(depths, &1.id, 0))
      |> Enum.sort_by(fn {layer, _} -> layer end)

    node_w = 220
    node_h = 36
    h_gap = 30
    v_gap = 60
    pad = 20

    max_layer_count = layers |> Enum.map(fn {_, gs} -> length(gs) end) |> Enum.max(fn -> 1 end)
    svg_width = max(max_layer_count * (node_w + h_gap) - h_gap + pad * 2, 400)

    # Build node positions
    {nodes, pos_map} =
      Enum.reduce(layers, {[], %{}}, fn {layer, layer_goals}, {nodes_acc, pos_acc} ->
        count = length(layer_goals)
        total_w = count * node_w + (count - 1) * h_gap
        start_x = (svg_width - total_w) / 2

        layer_goals
        |> Enum.sort_by(& &1.name)
        |> Enum.with_index()
        |> Enum.reduce({nodes_acc, pos_acc}, fn {goal, idx}, {n_acc, p_acc} ->
          x = start_x + idx * (node_w + h_gap)
          y = pad + layer * (node_h + v_gap)

          node = %{
            id: goal.id,
            name: goal.name,
            status: goal.metadata[:status],
            agent_id: goal.metadata[:agent_id],
            x: x,
            y: y,
            w: node_w,
            h: node_h
          }

          {n_acc ++ [node], Map.put(p_acc, goal.id, {x, y})}
        end)
      end)

    # Build edges: from dependency -> dependent (arrow points to the goal that depends)
    edges =
      Enum.flat_map(goals, fn goal ->
        deps = (goal.metadata[:depends_on] || []) |> Enum.filter(&(&1 in id_set))

        Enum.map(deps, fn dep_id ->
          {dep_x, dep_y} = pos_map[dep_id]
          {goal_x, goal_y} = pos_map[goal.id]

          %{
            x1: dep_x + node_w / 2,
            y1: dep_y + node_h,
            x2: goal_x + node_w / 2,
            y2: goal_y
          }
        end)
      end)

    layer_count = length(layers)
    svg_height = pad * 2 + layer_count * node_h + max((layer_count - 1) * v_gap, 0)

    %{nodes: nodes, edges: edges, width: svg_width, height: svg_height}
  end

  defp compute_depths(goals, id_set) do
    # BFS from roots, tracking max depth
    initial =
      Map.new(goals, fn g ->
        deps = (g.metadata[:depends_on] || []) |> Enum.filter(&(&1 in id_set))
        {g.id, deps}
      end)

    roots = for g <- goals, (initial[g.id] || []) == [], do: g.id
    do_compute_depths(roots, initial, %{}, 0)
  end

  defp do_compute_depths([], _deps_map, depths, _layer), do: depths

  defp do_compute_depths(current, deps_map, depths, layer) do
    depths =
      Enum.reduce(current, depths, fn id, acc ->
        # Use max depth if already visited at a shallower layer
        Map.update(acc, id, layer, &max(&1, layer))
      end)

    # Find all goals whose deps are now fully resolved
    all_ids = Map.keys(deps_map)
    resolved = MapSet.new(Map.keys(depths))

    next =
      all_ids
      |> Enum.filter(fn id -> not Map.has_key?(depths, id) end)
      |> Enum.filter(fn id ->
        deps = deps_map[id] || []
        deps != [] and Enum.all?(deps, &MapSet.member?(resolved, &1))
      end)

    if next == [] do
      # Handle any remaining unresolved (cycles) — put them at layer + 1
      remaining = Enum.filter(all_ids, fn id -> not Map.has_key?(depths, id) end)
      Enum.reduce(remaining, depths, fn id, acc -> Map.put(acc, id, layer + 1) end)
    else
      do_compute_depths(next, deps_map, depths, layer + 1)
    end
  end

  defp goal_node_fill(:completed), do: "#0e2a15"
  defp goal_node_fill(_), do: "#0d1117"

  defp goal_node_stroke(:completed), do: "#238636"
  defp goal_node_stroke(_), do: "#30363d"

  defp goal_node_text(:completed), do: "#8b949e"
  defp goal_node_text(_), do: "#c9d1d9"

  defp truncate_name(name, max) do
    if String.length(name) > max do
      String.slice(name, 0, max - 1) <> "..."
    else
      name
    end
  end

  defp topo_sort_goals(goals) do
    id_set = MapSet.new(goals, & &1.id)

    # Kahn's algorithm
    # Build in-degree map (only count deps that exist in our goal list)
    in_deg =
      Map.new(goals, fn g ->
        deps = (g.metadata[:depends_on] || []) |> Enum.filter(&(&1 in id_set))
        {g.id, length(deps)}
      end)

    # Build reverse adjacency: dep_id -> list of goals that depend on it
    rev =
      Enum.reduce(goals, %{}, fn g, acc ->
        deps = (g.metadata[:depends_on] || []) |> Enum.filter(&(&1 in id_set))

        Enum.reduce(deps, acc, fn dep_id, acc2 ->
          Map.update(acc2, dep_id, [g.id], &[g.id | &1])
        end)
      end)

    by_id = Map.new(goals, &{&1.id, &1})
    queue = for g <- goals, in_deg[g.id] == 0, do: g.id

    do_topo(queue, rev, in_deg, by_id, [])
  end

  defp do_topo([], _rev, in_deg, by_id, sorted) do
    # Append any remaining (cycles) at the end
    remaining =
      in_deg
      |> Enum.filter(fn {id, deg} -> deg > 0 and Map.has_key?(by_id, id) end)
      |> Enum.map(fn {id, _} -> by_id[id] end)

    Enum.reverse(sorted) ++ remaining
  end

  defp do_topo([id | rest], rev, in_deg, by_id, sorted) do
    sorted = [by_id[id] | sorted]
    dependents = Map.get(rev, id, [])

    {queue_adds, in_deg} =
      Enum.reduce(dependents, {[], in_deg}, fn dep_id, {adds, deg} ->
        new_deg = deg[dep_id] - 1
        deg = Map.put(deg, dep_id, new_deg)

        if new_deg == 0 do
          {[dep_id | adds], deg}
        else
          {adds, deg}
        end
      end)

    do_topo(rest ++ queue_adds, rev, in_deg, by_id, sorted)
  end

  defp group_templates_by_category(templates) do
    templates
    |> Enum.group_by(fn t -> t.metadata[:category] || "General" end)
    |> Enum.sort_by(fn {category, _} ->
      # "General" first, then alphabetical
      if category == "General", do: {0, category}, else: {1, category}
    end)
  end

  defp maybe_load_diagnostics(socket, :diagnostics), do: refresh_diagnostics(socket)
  defp maybe_load_diagnostics(socket, _tab), do: socket

  defp refresh_diagnostics(socket) do
    fetched_at = DateTime.utc_now()
    log_path = socket.assigns.diagnostics_log_path

    case read_recent_log(log_path) do
      {:ok, excerpt} ->
        socket =
          assign(socket,
            diagnostics_running: true,
            diagnostics_log_excerpt: excerpt,
            diagnostics_summary: nil,
            diagnostics_error: nil,
            diagnostics_updated_at: fetched_at
          )

        pid = self()

        Task.start(fn ->
          result = summarize_diagnostics_excerpt(excerpt)
          send(pid, {:diagnostics_summary_done, excerpt, result, fetched_at})
        end)

        socket

      {:error, reason} ->
        assign(socket,
          diagnostics_running: false,
          diagnostics_log_excerpt: nil,
          diagnostics_summary: nil,
          diagnostics_error: format_diagnostics_error(reason),
          diagnostics_updated_at: fetched_at
        )
    end
  end

  defp diagnostics_log_path do
    Path.join(Application.get_env(:orchid, :data_dir, "priv/data"), "server.log")
  end

  defp read_recent_log(path) do
    with true <- File.exists?(path) or {:error, :missing_log},
         {:ok, raw} <- File.read(path) do
      excerpt =
        raw
        |> String.split("\n")
        |> Enum.take(-@diagnostics_tail_lines)
        |> Enum.join("\n")
        |> String.trim()
        |> truncate(@diagnostics_max_chars)

      {:ok, excerpt}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :missing_log}
    end
  end

  defp summarize_diagnostics_excerpt(""), do: {:ok, "The log is currently empty."}
  defp summarize_diagnostics_excerpt(nil), do: {:ok, "The log is currently empty."}

  defp summarize_diagnostics_excerpt(excerpt) do
    context = %{
      system: """
      You summarize recent server diagnostics.
      Be concrete and concise.
      Focus on the latest failures, probable cause, and the next thing to inspect.
      Do not call tools.
      """,
      messages: [
        %{
          role: :user,
          content: """
          Summarize these recent `server.log` lines.

          Requirements:
          - 3 short paragraphs max
          - mention the most recent error first
          - include the probable cause if it is clear
          - say "unclear" when the cause is not supported by the log

          Log tail:
          #{excerpt}
          """
        }
      ],
      objects: "",
      memory: %{}
    }

    case Orchid.LLM.chat(
           %{provider: :cli, model: :haiku, max_turns: 4, max_tokens: 500, disable_tools: true},
           context
         ) do
      {:ok, %{content: content}} -> {:ok, String.trim(content)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp format_diagnostics_error({:api_error, message}) when is_binary(message),
    do: truncate(message, 300)

  defp format_diagnostics_error(:missing_log), do: "server.log was not found."
  defp format_diagnostics_error(reason) when is_binary(reason), do: reason
  defp format_diagnostics_error(reason), do: "Diagnostics refresh failed: #{inspect(reason)}"

  defp parse_decomp_model("opus"), do: :opus
  defp parse_decomp_model("sonnet"), do: :sonnet
  defp parse_decomp_model("haiku"), do: :haiku
  defp parse_decomp_model("gpt54"), do: :gpt54
  defp parse_decomp_model("gpt53"), do: :gpt53
  defp parse_decomp_model("gpt52_codex"), do: :gpt52_codex
  defp parse_decomp_model("gpt51_codex_max"), do: :gpt51_codex_max
  defp parse_decomp_model("gpt51_codex"), do: :gpt51_codex
  defp parse_decomp_model("gpt51_codex_mini"), do: :gpt51_codex_mini
  defp parse_decomp_model("gemini_3_pro"), do: :gemini_3_pro
  defp parse_decomp_model("minimax_m2_5"), do: :minimax_m2_5
  defp parse_decomp_model("glm_5"), do: :glm_5
  defp parse_decomp_model("kimi_k2_5"), do: :kimi_k2_5
  defp parse_decomp_model(_), do: :sonnet

  defp parse_decomp_reasoning_effort("low"), do: :low
  defp parse_decomp_reasoning_effort("medium"), do: :medium
  defp parse_decomp_reasoning_effort("high"), do: :high
  defp parse_decomp_reasoning_effort("xhigh"), do: :xhigh
  defp parse_decomp_reasoning_effort(_), do: :medium

  defp decomp_llm_config(model, reasoning_effort)

  defp decomp_llm_config(:gpt54, reasoning_effort),
    do: %{provider: :codex, model: "gpt-5.4", reasoning_effort: reasoning_effort}

  defp decomp_llm_config(:gpt53, reasoning_effort),
    do: %{provider: :codex, model: :gpt53, reasoning_effort: reasoning_effort}

  defp decomp_llm_config(:gpt52_codex, reasoning_effort),
    do: %{provider: :codex, model: "gpt-5.2-codex", reasoning_effort: reasoning_effort}

  defp decomp_llm_config(:gpt51_codex_max, reasoning_effort),
    do: %{provider: :codex, model: "gpt-5.1-codex-max", reasoning_effort: reasoning_effort}

  defp decomp_llm_config(:gpt51_codex, reasoning_effort),
    do: %{provider: :codex, model: "gpt-5.1-codex", reasoning_effort: reasoning_effort}

  defp decomp_llm_config(:gpt51_codex_mini, reasoning_effort),
    do: %{provider: :codex, model: "gpt-5.1-codex-mini", reasoning_effort: reasoning_effort}

  defp decomp_llm_config(model, _reasoning_effort), do: %{provider: :cli, model: model}

  defp maybe_reset_decomp_reasoning_effort(socket, model) do
    if decomp_codex_model?(model) do
      socket
    else
      assign(socket, :decomp_reasoning_effort, :medium)
    end
  end

  defp decomp_codex_model?(model)
       when model in [:gpt54, :gpt53, :gpt52_codex, :gpt51_codex_max, :gpt51_codex, :gpt51_codex_mini],
       do: true

  defp decomp_codex_model?(_), do: false

  defp decomp_reasoning_effort_label(:low), do: "Low"
  defp decomp_reasoning_effort_label(:medium), do: "Medium"
  defp decomp_reasoning_effort_label(:high), do: "High"
  defp decomp_reasoning_effort_label(:xhigh), do: "Extra high"
  defp decomp_reasoning_effort_label(_), do: "Medium"

  defp decomp_reasoning_effort_description(:low), do: "Fast responses with lighter reasoning"
  defp decomp_reasoning_effort_description(:medium), do: "Balances speed and reasoning depth for everyday tasks"
  defp decomp_reasoning_effort_description(:high), do: "Greater reasoning depth for complex problems"
  defp decomp_reasoning_effort_description(:xhigh), do: "Extra high reasoning depth for complex problems"
  defp decomp_reasoning_effort_description(_), do: "Balances speed and reasoning depth for everyday tasks"

  defp parse_agent_execution_mode("host"), do: :host
  defp parse_agent_execution_mode("root_vm"), do: :host
  defp parse_agent_execution_mode(_), do: :vm

  defp clamp_int(raw, default, min, max) when is_binary(raw) do
    case Integer.parse(raw) do
      {v, _} -> v |> Kernel.max(min) |> Kernel.min(max)
      _ -> default
    end
  end

  defp clamp_int(v, _default, min, max) when is_integer(v), do: v |> Kernel.max(min) |> Kernel.min(max)
  defp clamp_int(_v, default, _min, _max), do: default

end
