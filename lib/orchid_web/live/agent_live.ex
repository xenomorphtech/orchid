defmodule OrchidWeb.AgentLive do
  use Phoenix.LiveView

  alias Orchid.{ProjectIntake, LLM.Catalog}

  @active_poll_interval_ms 1_500
  @idle_poll_interval_ms 5_000
  @event_log_tail_lines 80
  @server_log_tail_lines 80
  @server_log_tail_chunk_bytes 16_384

  @impl true
  def mount(params, _session, socket) do
    agent_id = params["id"]

    socket =
      socket
      |> assign(:agents, list_agents_with_info())
      |> assign(:current_agent, agent_id)
      |> assign(:messages, [])
      |> assign(:message_fingerprint, nil)
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
      |> assign(:project_workspace_mode, :project)
      |> assign(:project_tab, :overview)
      |> assign(:new_project_form, default_new_project_form(nil, :vm))
      |> assign(:new_project_errors, %{})
      |> assign(:new_project_chat_messages, [])
      |> assign(:new_project_chat_input, "")
      |> assign(:new_project_chat_running, false)
      |> assign(:new_project_chat_request_id, nil)
      |> assign(:new_project_ready_to_submit, false)
      |> assign(
        :new_project_missing_fields,
        ProjectIntake.missing_fields(default_new_project_form(nil, :vm))
      )
      |> assign(
        :new_project_chat_focus,
        ProjectIntake.next_focus(default_new_project_form(nil, :vm))
      )
      |> assign(:new_project_return_project, nil)
      |> assign(:new_project_return_tab, :overview)
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
      |> assign(:show_diagnostics, false)
      |> clear_diagnostics()
      |> assign(:decomp_goal_text, "")
      |> assign(:decomp_num_paths, 3)
      |> assign(:decomp_max_iterations, 3)
      |> assign(:decomp_model, :sonnet)
      |> assign(:decomp_running, false)
      |> assign(:decomp_result, nil)
      |> assign(:decomp_error, nil)
      |> assign(:template_provider_options, Catalog.providers(context: :template))
      |> assign(:template_model_options, Catalog.models(context: :template))
      |> assign(:decomp_model_options, Catalog.models(context: :decomp))
      |> assign(:templates, Orchid.Object.list_agent_templates())
      |> then(fn s ->
        templates = s.assigns.templates
        first_template = List.first(templates)
        default_template_id = first_template && first_template.id

        s
        |> assign(:selected_template, default_template_id)
        |> reset_new_project_draft(default_template_id, s.assigns.agent_execution_mode)
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
            |> assign(:message_fingerprint, message_fingerprint(state.messages))
            |> assign(:agent_status, state.status)
            |> assign(:agent_wait_status, wait_status_from_memory(state.memory))
            |> assign(:system_prompt, state.config[:system_prompt])
            |> assign(:current_agent_template, template_info)
            |> then(fn s ->
              if state.project_id do
                select_project_workspace(s, state.project_id)
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
      Phoenix.PubSub.subscribe(Orchid.PubSub, "event_log")
      schedule_poll(socket)
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
    new_project? = truthy_param?(params["new_project"])

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
            |> assign(:message_fingerprint, message_fingerprint(state.messages))
            |> assign(:agent_status, state.status)
            |> assign(:agent_wait_status, wait_status_from_memory(state.memory))
            |> assign(:current_agent_template, template_info)
            |> assign(:system_prompt, state.config[:system_prompt])
            |> assign(:show_system_prompt, false)
            |> then(fn s ->
              if state.project_id do
                select_project_workspace(s, state.project_id)
              else
                s
              end
            end)

          _ ->
            socket
            |> assign(:messages, [])
            |> assign(:message_fingerprint, nil)
            |> assign(:agent_status, :idle)
            |> assign(:agent_wait_status, nil)
            |> assign(:current_agent_template, nil)
            |> assign(:system_prompt, nil)
            |> assign(:show_system_prompt, false)
        end
      else
        socket
        |> assign(:messages, [])
        |> assign(:message_fingerprint, nil)
        |> assign(:agent_status, :idle)
        |> assign(:agent_wait_status, nil)
        |> assign(:current_agent_template, nil)
        |> assign(:system_prompt, nil)
        |> assign(:show_system_prompt, false)
      end

    socket =
      cond do
        new_project? -> open_new_project_workspace(socket)
        true -> assign(socket, :project_workspace_mode, :project)
      end

    {:noreply, socket}
  end

  defp get_template_info(nil), do: nil

  defp get_template_info(template_id) do
    case Orchid.Object.get(template_id) do
      {:ok, template} ->
        provider = Catalog.normalize_provider(template.metadata[:provider])
        model = Catalog.normalize_model(template.metadata[:model])

        %{
          id: template.id,
          name: template.name,
          model: Catalog.model_label(model),
          provider: Catalog.provider_label(provider),
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
            if template.metadata[:model_reasoning_effort],
              do:
                Map.put(
                  config,
                  :model_reasoning_effort,
                  template.metadata[:model_reasoning_effort]
                ),
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
    {:noreply, assign(socket, :model, parse_model(model, socket.assigns.model))}
  end

  def handle_event("update_provider", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, :provider, parse_provider(provider, socket.assigns.provider))}
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
          |> assign(:model, parse_model(template.metadata[:model], socket.assigns.model))
          |> assign(:provider, parse_provider(template.metadata[:provider], :cli))

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
                parse_model(template.metadata[:model], socket.assigns.model),
                parse_provider(template.metadata[:provider], :cli),
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
    {:noreply, assign(socket, :template_model, parse_model(model, socket.assigns.template_model))}
  end

  def handle_event("update_template_provider", %{"provider" => provider}, socket) do
    {:noreply,
     assign(
       socket,
       :template_provider,
       parse_provider(provider, socket.assigns.template_provider)
     )}
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
    from_new_project? =
      socket.assigns.project_workspace_mode == :new_project and
        is_nil(socket.assigns.current_agent)

    socket = select_project_workspace(socket, id)
    socket = if from_new_project?, do: push_patch(socket, to: "/"), else: socket
    {:noreply, socket}
  end

  def handle_event("clear_project", _params, socket) do
    {:noreply,
     socket
     |> assign(:project_workspace_mode, :project)
     |> assign(:current_project, nil)
     |> assign(:goals, [])
     |> assign(:project_tab, :overview)
     |> assign(:decomp_result, nil)
     |> assign(:decomp_error, nil)
     |> refresh_sandbox_statuses()
     |> assign(:event_log_entries, recent_events(nil, @event_log_tail_lines))
     |> assign(:mcp_calls, recent_mcp_calls(nil, 40))}
  end

  def handle_event("show_new_project", _params, socket) do
    socket =
      socket
      |> open_new_project_workspace()
      |> push_patch(to: "/?new_project=1")

    {:noreply, socket}
  end

  def handle_event("cancel_new_project", _params, socket) do
    return_project = socket.assigns.new_project_return_project
    return_tab = socket.assigns.new_project_return_tab || :overview

    socket =
      socket
      |> assign(:project_workspace_mode, :project)
      |> reset_new_project_draft(
        socket.assigns.selected_template,
        socket.assigns.agent_execution_mode
      )
      |> assign(:new_project_return_project, nil)
      |> assign(:new_project_return_tab, :overview)
      |> then(fn s ->
        if return_project do
          select_project_workspace(s, return_project, tab: return_tab)
        else
          s
          |> assign(:current_project, nil)
          |> assign(:goals, [])
          |> assign(:project_tab, :overview)
          |> assign(:event_log_entries, recent_events(nil, @event_log_tail_lines))
          |> assign(:mcp_calls, recent_mcp_calls(nil, 40))
          |> refresh_sandbox_statuses()
        end
      end)
      |> push_patch(to: "/")

    {:noreply, socket}
  end

  def handle_event("update_new_project_form", %{"project" => attrs}, socket) do
    form = merge_new_project_form(socket.assigns.new_project_form, attrs)

    {:noreply, socket |> assign_new_project_form_state(form)}
  end

  def handle_event("update_new_project_chat_input", %{"input" => input}, socket) do
    {:noreply, assign(socket, :new_project_chat_input, input)}
  end

  def handle_event("send_new_project_chat", params, socket) do
    input =
      params
      |> Map.get("input", socket.assigns.new_project_chat_input)
      |> to_string()
      |> String.trim()

    cond do
      input == "" ->
        {:noreply, socket}

      socket.assigns.new_project_chat_running ->
        {:noreply, socket}

      true ->
        request_id = make_ref()
        pid = self()
        messages = socket.assigns.new_project_chat_messages
        form = socket.assigns.new_project_form
        focus = socket.assigns.new_project_chat_focus

        Task.start(fn ->
          result = ProjectIntake.continue(messages, form, input, focus)
          send(pid, {:new_project_chat_reply, request_id, input, result})
        end)

        updated_messages = messages ++ [%{role: :user, content: input}]

        {:noreply,
         socket
         |> assign(:new_project_chat_messages, updated_messages)
         |> assign(:new_project_chat_input, "")
         |> assign(:new_project_chat_running, true)
         |> assign(:new_project_chat_request_id, request_id)}
    end
  end

  def handle_event("create_project", params, socket) do
    form =
      socket.assigns.new_project_form
      |> merge_new_project_form(Map.get(params, "project", %{}))

    attrs = project_create_attrs(form, socket.assigns.new_project_chat_messages)

    case Orchid.Projects.create(attrs) do
      {:ok, project} ->
        socket =
          socket
          |> assign(:projects, Orchid.Object.list_projects())
          |> reset_new_project_draft(
            socket.assigns.selected_template,
            socket.assigns.agent_execution_mode
          )
          |> assign(:new_project_return_project, nil)
          |> assign(:new_project_return_tab, :overview)
          |> select_project_workspace(project.id)
          |> push_patch(to: "/")

        {:noreply, socket}

      {:error, errors} when is_map(errors) ->
        {:noreply,
         socket
         |> assign(:project_workspace_mode, :new_project)
         |> assign_new_project_form_state(form)
         |> assign(:new_project_errors, errors)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:project_workspace_mode, :new_project)
         |> assign(
           :new_project_errors,
           %{general: "Unable to create project. Check the form and try again."}
         )}
    end
  end

  def handle_event("delete_project", %{"id" => id}, socket) do
    Orchid.Projects.delete(id)

    socket =
      socket
      |> assign(:projects, Orchid.Object.list_projects())
      |> then(fn s ->
        if s.assigns.current_project == id do
          s
          |> assign(:current_project, nil)
          |> assign(:goals, [])
          |> assign(:project_tab, :overview)
          |> assign(:mcp_calls, recent_mcp_calls(nil, 40))
          |> refresh_sandbox_statuses()
        else
          s
        end
      end)
      |> then(fn s ->
        if s.assigns.new_project_return_project == id do
          assign(s, :new_project_return_project, nil)
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
        "overview" -> :overview
        "decomposition" -> :decomposition
        _ -> :goals
      end

    {:noreply, assign(socket, :project_tab, project_tab)}
  end

  def handle_event("toggle_diagnostics", _params, socket) do
    socket =
      socket
      |> assign(:show_diagnostics, !socket.assigns.show_diagnostics)
      |> maybe_refresh_diagnostics()

    {:noreply, socket}
  end

  def handle_event("refresh_diagnostics", _params, socket) do
    {:noreply, refresh_diagnostics(socket)}
  end

  def handle_event("refresh_events", _params, socket) do
    {:noreply,
     assign(
       socket,
       :event_log_entries,
       recent_events(socket.assigns.current_project, @event_log_tail_lines)
     )}
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
    {:noreply, assign(socket, :decomp_model, parse_model(model, socket.assigns.decomp_model))}
  end

  def handle_event("run_decomposition_test", params, socket) do
    project_id = socket.assigns.current_project
    objective = String.trim(params["goal"] || socket.assigns.decomp_goal_text || "")

    model =
      parse_model(params["model"] || socket.assigns.decomp_model, socket.assigns.decomp_model)

    num_paths = clamp_int(params["num_paths"], socket.assigns.decomp_num_paths, 1, 8)

    max_iterations =
      clamp_int(params["max_iterations"], socket.assigns.decomp_max_iterations, 0, 6)

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
          |> assign(:decomp_num_paths, num_paths)
          |> assign(:decomp_max_iterations, max_iterations)
          |> assign(:decomp_running, true)
          |> assign(:decomp_error, nil)
          |> assign(:decomp_result, nil)

        Task.start(fn ->
          llm_config = decomp_llm_config(model)

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
            {:decomposition_test_done, result, raw_output, duration_ms, model, num_paths,
             max_iterations}
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

  def handle_event("send_message", params, socket) do
    input =
      params
      |> Map.get("input", socket.assigns.input)
      |> to_string()
      |> String.trim()

    submit_message(socket, input)
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

  def handle_info({:new_project_chat_reply, request_id, _input, result}, socket) do
    cond do
      socket.assigns.new_project_chat_request_id != request_id ->
        {:noreply, socket}

      true ->
        case result do
          {:ok, reply} ->
            form =
              ProjectIntake.merge_candidate_fields(
                socket.assigns.new_project_form,
                reply.candidate_fields
              )

            updated_messages =
              socket.assigns.new_project_chat_messages ++
                [%{role: :assistant, content: reply.assistant_message}]

            {:noreply,
             socket
             |> assign_new_project_form_state(form)
             |> assign(:new_project_chat_messages, updated_messages)
             |> assign(:new_project_chat_running, false)
             |> assign(:new_project_chat_request_id, nil)}

          {:error, reason} ->
            updated_messages =
              socket.assigns.new_project_chat_messages ++
                [
                  %{
                    role: :assistant,
                    content: "I couldn't turn that into candidate fields. #{format_error(reason)}"
                  }
                ]

            {:noreply,
             socket
             |> assign(:new_project_chat_messages, updated_messages)
             |> assign(:new_project_chat_running, false)
             |> assign(:new_project_chat_request_id, nil)}
        end
    end
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

  def handle_info({:event_log, event}, socket) do
    relevant =
      is_nil(socket.assigns.current_project) or event.project_id == socket.assigns.current_project

    socket =
      if relevant do
        entries = [event | socket.assigns.event_log_entries] |> Enum.take(@event_log_tail_lines)
        assign(socket, :event_log_entries, entries)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(
        {:decomposition_test_done, result, raw_output, duration_ms, model, num_paths,
         max_iterations},
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

  def handle_info(:poll_agent_status, socket) do
    socket =
      case socket.assigns.current_agent do
        nil ->
          socket

        agent_id ->
          case Orchid.Agent.get_state(agent_id, 2000) do
            {:ok, state} ->
              fingerprint = message_fingerprint(state.messages)

              socket
              |> assign(:agent_status, state.status)
              |> assign(:agent_wait_status, wait_status_from_memory(state.memory))
              |> maybe_assign_messages(state.messages, fingerprint)

            _ ->
              socket
              |> assign(:agent_status, :idle)
              |> assign(:agent_wait_status, nil)
          end
      end

    socket =
      socket
      |> assign(:agents, list_agents_with_info())
      |> refresh_sandbox_statuses()
      |> refresh_goals()
      |> maybe_refresh_diagnostics()

    schedule_poll(socket)
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
            <div style="display: flex; gap: 0.35rem;">
              <%= if @current_project do %>
                <button
                  class="btn btn-secondary btn-sm"
                  style="padding: 0.2rem 0.5rem; font-size: 0.75rem;"
                  phx-click="clear_project"
                >Clear</button>
              <% end %>
              <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="show_new_project">+ New</button>
            </div>
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
          <%= for project <- filter_projects(@projects, @project_query) do %>
            <% p_status = project.metadata[:status] %>
            <div
              class={["project-item", if(project.id == @current_project, do: "active")]}
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
          <%= if @projects == [] do %>
            <div class="no-projects">No projects yet</div>
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
              <button
                class="btn btn-secondary"
                phx-click="toggle_diagnostics"
                style={"padding: 0.4rem 0.6rem; #{if @show_diagnostics, do: "border-color: #58a6ff; color: #58a6ff;", else: ""}"}
              >Diagnostics</button>
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
                      <%= for provider <- @template_provider_options do %>
                        <option value={Atom.to_string(provider.id)} selected={@template_provider == provider.id}>
                          <%= provider.label %>
                        </option>
                      <% end %>
                    </select>
                  </div>
                  <div style="flex: 1;">
                    <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">Model</label>
                    <select class="sidebar-search" style="width: 100%;" phx-change="update_template_model" name="model">
                      <option value="" selected={@template_model == nil}>Default</option>
                      <%= for model <- @template_model_options do %>
                        <option value={Atom.to_string(model.id)} selected={@template_model == model.id}>
                          <%= model.label %>
                        </option>
                      <% end %>
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

          <div class="goals-section" style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
            <div style="display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; margin-bottom: 0.75rem;">
              <div>
                <h3 style="color: #c9d1d9; margin: 0; font-size: 1rem;">Recent Events</h3>
                <div style="color: #8b949e; font-size: 0.8rem; margin-top: 0.2rem;">
                  <%= event_scope_label(@current_project) %> · last <%= @event_log_tail_lines %> shown from a <%= Orchid.EventLog.window() %>-event buffer
                </div>
              </div>
              <button
                class="btn btn-secondary btn-sm"
                style="padding: 0.2rem 0.5rem; font-size: 0.75rem;"
                phx-click="refresh_events"
              >Refresh</button>
            </div>

            <%= if @event_log_entries == [] do %>
              <div style="color: #8b949e; font-size: 0.85rem;">No event output yet.</div>
            <% else %>
              <div style="max-height: 18rem; overflow-y: auto; background: #0d1117; border: 1px solid #30363d; border-radius: 4px; padding: 0.25rem 0.75rem;">
                <%= for ev <- @event_log_entries do %>
                  <div style="display: flex; gap: 0.6rem; align-items: flex-start; font-size: 0.75rem; padding: 0.4rem 0; border-bottom: 1px solid #21262d;">
                    <span style="color: #8b949e; min-width: 56px;"><%= short_time(ev.inserted_at) %></span>
                    <span style="color: #d29922; min-width: 92px;"><%= event_source_label(ev.source) %></span>
                    <%= if is_nil(@current_project) do %>
                      <span style="color: #58a6ff; font-family: monospace; min-width: 74px;"><%= short_project_id(ev.project_id) %></span>
                    <% end %>
                    <span style="color: #79c0ff; font-family: monospace; min-width: 74px;"><%= short_agent_id(ev.agent_id || "-") %></span>
                    <span style="color: #c9d1d9; white-space: pre-wrap; word-break: break-word; flex: 1;"><%= ev.message %></span>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <%= if @show_diagnostics do %>
            <div class="goals-section" style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
              <div style="display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; margin-bottom: 0.75rem;">
                <div>
                  <h3 style="color: #c9d1d9; margin: 0; font-size: 1rem;">Diagnostics</h3>
                  <div style="color: #8b949e; font-size: 0.8rem; margin-top: 0.2rem;">
                    Showing the last <%= @server_log_tail_lines %> lines of <code>priv/data/server.log</code>
                  </div>
                </div>
                <div style="display: flex; gap: 0.5rem; align-items: center;">
                  <span style="color: #8b949e; font-size: 0.75rem;">
                    Updated <%= short_time(@server_log_updated_at) %>
                  </span>
                  <button
                    class="btn btn-secondary btn-sm"
                    style="padding: 0.2rem 0.5rem; font-size: 0.75rem;"
                    phx-click="refresh_diagnostics"
                  >Refresh</button>
                </div>
              </div>

              <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.75rem; word-break: break-all;">
                <%= @server_log_path %>
              </div>

              <%= if @server_log_error do %>
                <div style="background: #3d1114; color: #f85149; border: 1px solid #f85149; border-radius: 4px; padding: 0.5rem; font-size: 0.85rem;">
                  <%= @server_log_error %>
                </div>
              <% else %>
                <%= if @server_log_tail == "" do %>
                  <div style="color: #8b949e; font-size: 0.85rem;">No log output yet.</div>
                <% else %>
                  <pre style="margin: 0; white-space: pre-wrap; word-break: break-word; max-height: 32rem; overflow-y: auto; background: #0d1117; border: 1px solid #30363d; border-radius: 4px; padding: 0.75rem; color: #c9d1d9; font-size: 0.8rem;"><%= @server_log_tail %></pre>
                <% end %>
              <% end %>
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
            <%= if @project_workspace_mode == :new_project do %>
              <div class="project-detail" style="margin-bottom: 1.5rem;">
                <div style="display: flex; align-items: flex-start; justify-content: space-between; gap: 1rem; margin-bottom: 1rem;">
                  <div>
                    <h2 style="color: #c9d1d9; margin: 0 0 0.35rem 0;">New Project</h2>
                    <p style="color: #8b949e; margin: 0; max-width: 48rem;">
                      Capture enough context to make the workspace actionable from the start.
                    </p>
                  </div>
                  <button class="btn btn-secondary" phx-click="cancel_new_project">Cancel</button>
                </div>

                <div style="display: flex; gap: 1rem; flex-wrap: wrap; align-items: flex-start;">
                  <div class="goals-section" style="flex: 1 1 24rem; background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
                    <div style="display: flex; align-items: flex-start; justify-content: space-between; gap: 0.75rem; margin-bottom: 0.85rem;">
                      <div>
                        <h3 style="color: #c9d1d9; margin: 0 0 0.35rem 0; font-size: 1rem;">Brief Workshop</h3>
                        <p style="color: #8b949e; margin: 0; font-size: 0.85rem;">
                          Work out the candidate fields through a short intake chat. The form stays editable throughout.
                        </p>
                      </div>
                      <span style={"font-size: 0.75rem; padding: 0.2rem 0.55rem; border-radius: 999px; #{if @new_project_ready_to_submit, do: "background: #0e2a15; color: #7ee787;", else: "background: #2d2000; color: #d29922;"}"}>
                        <%= if @new_project_ready_to_submit, do: "Ready", else: "Drafting" %>
                      </span>
                    </div>

                    <div style="background: #0d1117; border: 1px solid #30363d; border-radius: 6px; padding: 0.75rem; margin-bottom: 0.85rem;">
                      <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.3rem;">Required fields</div>
                      <div style="color: #c9d1d9; font-size: 0.85rem;">
                        <%= if @new_project_missing_fields == [] do %>
                          Name, objective, and definition of done are all present.
                        <% else %>
                          Still needed: <%= Enum.map_join(@new_project_missing_fields, ", ", &ProjectIntake.field_label/1) %>
                        <% end %>
                      </div>
                    </div>

                    <div style="background: #0d1117; border: 1px solid #30363d; border-radius: 6px; padding: 0.75rem; max-height: 22rem; overflow-y: auto; margin-bottom: 0.85rem;">
                      <%= for msg <- @new_project_chat_messages do %>
                        <div style={"margin-bottom: 0.75rem; padding: 0.7rem 0.8rem; border-radius: 6px; border: 1px solid #30363d; #{new_project_chat_message_style(msg.role)}"}>
                          <div style="font-size: 0.72rem; color: #8b949e; margin-bottom: 0.3rem;"><%= new_project_chat_role_label(msg.role) %></div>
                          <div style="white-space: pre-wrap; color: #c9d1d9; font-size: 0.85rem;"><%= msg.content %></div>
                        </div>
                      <% end %>

                      <%= if @new_project_chat_running do %>
                        <div style="padding: 0.7rem 0.8rem; border-radius: 6px; border: 1px solid #30363d; background: #111b2e; color: #58a6ff; font-size: 0.85rem;">
                          Asking the next question...
                        </div>
                      <% end %>
                    </div>

                    <form phx-submit="send_new_project_chat" phx-change="update_new_project_chat_input">
                      <div style="display: flex; flex-direction: column; gap: 0.65rem;">
                        <textarea
                          name="input"
                          class="sidebar-search"
                          placeholder="Answer the current question or add more context."
                          style="width: 100%; min-height: 5.5rem; resize: vertical;"
                        ><%= @new_project_chat_input %></textarea>
                        <div style="display: flex; justify-content: space-between; align-items: center; gap: 0.75rem; flex-wrap: wrap;">
                          <div style="color: #8b949e; font-size: 0.75rem;">
                            Current focus: <%= ProjectIntake.field_label(@new_project_chat_focus || "final review") %>
                          </div>
                          <button class="btn" type="submit" disabled={@new_project_chat_running}>
                            <%= if @new_project_chat_running, do: "Thinking...", else: "Continue Intake" %>
                          </button>
                        </div>
                      </div>
                    </form>
                  </div>

                  <div class="goals-section" style="flex: 1 1 30rem; background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
                    <div style="display: flex; align-items: flex-start; justify-content: space-between; gap: 0.75rem; margin-bottom: 0.85rem;">
                      <div>
                        <h3 style="color: #c9d1d9; margin: 0 0 0.35rem 0; font-size: 1rem;">Candidate Fields</h3>
                        <p style="color: #8b949e; margin: 0; font-size: 0.85rem;">
                          Chat suggestions land here, but you can edit any field directly before submitting.
                        </p>
                      </div>
                    </div>

                    <%= if @new_project_errors[:general] do %>
                      <div style="background: #3d1114; color: #f85149; border: 1px solid #f85149; border-radius: 4px; padding: 0.65rem 0.75rem; margin-bottom: 0.75rem; font-size: 0.85rem;">
                        <%= @new_project_errors[:general] %>
                      </div>
                    <% end %>

                    <form phx-submit="create_project" phx-change="update_new_project_form">
                      <div style="display: flex; flex-direction: column; gap: 0.9rem;">
                        <div>
                          <label style="display: block; color: #c9d1d9; margin-bottom: 0.35rem; font-size: 0.85rem;">Project Name</label>
                          <input
                            type="text"
                            name="project[name]"
                            value={@new_project_form.name}
                            placeholder="Migration hardening, packet decoder overhaul, docs cleanup..."
                            class="sidebar-search"
                            style="width: 100%;"
                            autofocus
                          />
                          <%= if @new_project_errors[:name] do %>
                            <div style="color: #f85149; font-size: 0.78rem; margin-top: 0.3rem;"><%= @new_project_errors[:name] %></div>
                          <% end %>
                        </div>

                        <div>
                          <label style="display: block; color: #c9d1d9; margin-bottom: 0.35rem; font-size: 0.85rem;">Objective</label>
                          <textarea
                            name="project[objective]"
                            class="sidebar-search"
                            placeholder="What should this project achieve?"
                            style="width: 100%; min-height: 4.5rem; resize: vertical;"
                          ><%= @new_project_form.objective %></textarea>
                          <%= if @new_project_errors[:objective] do %>
                            <div style="color: #f85149; font-size: 0.78rem; margin-top: 0.3rem;"><%= @new_project_errors[:objective] %></div>
                          <% end %>
                        </div>

                        <div>
                          <label style="display: block; color: #c9d1d9; margin-bottom: 0.35rem; font-size: 0.85rem;">Definition Of Done</label>
                          <textarea
                            name="project[success_criteria]"
                            class="sidebar-search"
                            placeholder="What must be true before this project is considered complete?"
                            style="width: 100%; min-height: 4.5rem; resize: vertical;"
                          ><%= @new_project_form.success_criteria %></textarea>
                          <%= if @new_project_errors[:success_criteria] do %>
                            <div style="color: #f85149; font-size: 0.78rem; margin-top: 0.3rem;"><%= @new_project_errors[:success_criteria] %></div>
                          <% end %>
                        </div>

                        <div>
                          <label style="display: block; color: #c9d1d9; margin-bottom: 0.35rem; font-size: 0.85rem;">Background</label>
                          <textarea
                            name="project[background]"
                            class="sidebar-search"
                            placeholder="Relevant context, prior work, decisions, or business constraints."
                            style="width: 100%; min-height: 4rem; resize: vertical;"
                          ><%= @new_project_form.background %></textarea>
                        </div>

                        <div>
                          <label style="display: block; color: #c9d1d9; margin-bottom: 0.35rem; font-size: 0.85rem;">Constraints / Non-Goals</label>
                          <textarea
                            name="project[constraints]"
                            class="sidebar-search"
                            placeholder="What should not change? What constraints must be respected?"
                            style="width: 100%; min-height: 4rem; resize: vertical;"
                          ><%= @new_project_form.constraints %></textarea>
                        </div>

                        <div>
                          <label style="display: block; color: #c9d1d9; margin-bottom: 0.35rem; font-size: 0.85rem;">Relevant Paths</label>
                          <textarea
                            name="project[relevant_paths_text]"
                            class="sidebar-search"
                            placeholder="One entry per line. Repos, files, directories, and URLs all work."
                            style="width: 100%; min-height: 3.5rem; resize: vertical;"
                          ><%= @new_project_form.relevant_paths_text %></textarea>
                        </div>

                        <div>
                          <label style="display: block; color: #c9d1d9; margin-bottom: 0.35rem; font-size: 0.85rem;">Suggested First Goal</label>
                          <input
                            type="text"
                            name="project[kickoff_goal]"
                            value={@new_project_form.kickoff_goal}
                            placeholder="Optional kickoff goal to create immediately"
                            class="sidebar-search"
                            style="width: 100%;"
                          />
                        </div>

                        <div style="display: flex; gap: 0.75rem; flex-wrap: wrap;">
                          <div style="flex: 1 1 18rem;">
                            <label style="display: block; color: #c9d1d9; margin-bottom: 0.35rem; font-size: 0.85rem;">Default Template</label>
                            <select
                              name="project[default_template_id]"
                              class="sidebar-search"
                              style="width: 100%;"
                            >
                              <option value="" selected={is_nil(@new_project_form.default_template_id)}>No default</option>
                              <%= for {category, templates} <- group_templates_by_category(@templates) do %>
                                <optgroup label={category}>
                                  <%= for template <- templates do %>
                                    <option value={template.id} selected={@new_project_form.default_template_id == template.id}>
                                      <%= template.name %>
                                    </option>
                                  <% end %>
                                </optgroup>
                              <% end %>
                            </select>
                            <%= if @new_project_errors[:default_template_id] do %>
                              <div style="color: #f85149; font-size: 0.78rem; margin-top: 0.3rem;"><%= @new_project_errors[:default_template_id] %></div>
                            <% end %>
                          </div>

                          <div style="flex: 1 1 12rem;">
                            <label style="display: block; color: #c9d1d9; margin-bottom: 0.35rem; font-size: 0.85rem;">Default Execution Mode</label>
                            <select
                              name="project[default_execution_mode]"
                              class="sidebar-search"
                              style="width: 100%;"
                            >
                              <option value="vm" selected={@new_project_form.default_execution_mode == :vm}>VM</option>
                              <option value="host" selected={@new_project_form.default_execution_mode == :host}>Host</option>
                            </select>
                            <%= if @new_project_errors[:default_execution_mode] do %>
                              <div style="color: #f85149; font-size: 0.78rem; margin-top: 0.3rem;"><%= @new_project_errors[:default_execution_mode] %></div>
                            <% end %>
                          </div>
                        </div>

                        <div style="display: flex; gap: 0.5rem; justify-content: flex-end;">
                          <button type="button" class="btn btn-secondary" phx-click="cancel_new_project">Cancel</button>
                          <button type="submit" class="btn" disabled={!@new_project_ready_to_submit}>Create Project</button>
                        </div>
                      </div>
                    </form>
                  </div>
                </div>
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
                    style={"padding: 0.2rem 0.6rem; font-size: 0.75rem; #{if @project_tab == :overview, do: "border-color: #58a6ff; color: #58a6ff;", else: ""}"}
                    phx-click="set_project_tab"
                    phx-value-tab="overview"
                  >Overview</button>
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
                </div>

                <% project = get_project(@projects, @current_project) %>
                <%= if @project_tab == :overview do %>
                <div class="goals-section" style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
                  <h3 style="color: #c9d1d9; margin: 0 0 1rem 0; font-size: 1rem;">Project Brief</h3>
                  <div style="display: flex; flex-direction: column; gap: 0.9rem;">
                    <div>
                      <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.25rem;">Objective</div>
                      <div style="color: #c9d1d9; white-space: pre-wrap;"><%= project_text(project && project.metadata[:objective]) %></div>
                    </div>
                    <div>
                      <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.25rem;">Definition Of Done</div>
                      <div style="color: #c9d1d9; white-space: pre-wrap;"><%= project_text(project && project.metadata[:success_criteria]) %></div>
                    </div>
                    <div>
                      <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.25rem;">Background</div>
                      <div style="color: #c9d1d9; white-space: pre-wrap;"><%= project_text(project && project.metadata[:background]) %></div>
                    </div>
                    <div>
                      <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.25rem;">Constraints</div>
                      <div style="color: #c9d1d9; white-space: pre-wrap;"><%= project_text(project && project.metadata[:constraints]) %></div>
                    </div>
                    <div>
                      <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.25rem;">Relevant Paths</div>
                      <%= if project_paths(project) == [] do %>
                        <div style="color: #8b949e;">Not set.</div>
                      <% else %>
                        <div style="display: flex; flex-wrap: wrap; gap: 0.35rem;">
                          <%= for path <- project_paths(project) do %>
                            <span style="background: #0d1117; border: 1px solid #30363d; border-radius: 999px; padding: 0.15rem 0.5rem; color: #c9d1d9; font-family: monospace; font-size: 0.78rem;"><%= path %></span>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                    <div style="display: flex; gap: 0.75rem; flex-wrap: wrap;">
                      <div style="flex: 1 1 15rem;">
                        <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.25rem;">Suggested First Goal</div>
                        <div style="color: #c9d1d9; white-space: pre-wrap;"><%= project_text(project && project.metadata[:kickoff_goal]) %></div>
                      </div>
                      <div style="flex: 1 1 15rem;">
                        <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.25rem;">Default Template</div>
                        <div style="color: #c9d1d9;"><%= project_default_template(project) %></div>
                      </div>
                      <div style="flex: 1 1 12rem;">
                        <div style="color: #8b949e; font-size: 0.75rem; margin-bottom: 0.25rem;">Default Execution Mode</div>
                        <div style="color: #c9d1d9;"><%= project_execution_mode(project) %></div>
                      </div>
                    </div>
                  </div>
                </div>

                <div class="goals-section" style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
                  <div style="display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; margin-bottom: 0.75rem;">
                    <h3 style="color: #c9d1d9; margin: 0; font-size: 1rem;">Saved Brief</h3>
                    <div style="display: flex; gap: 0.5rem;">
                      <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="show_new_goal">+ Add Goal</button>
                      <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="set_project_tab" phx-value-tab="decomposition">Open Lab</button>
                    </div>
                  </div>
                  <%= if project && String.trim(project.content || "") != "" do %>
                    <pre style="margin: 0; white-space: pre-wrap; word-break: break-word; background: #0d1117; border: 1px solid #30363d; border-radius: 4px; padding: 0.75rem; color: #c9d1d9; font-size: 0.85rem;"><%= project.content %></pre>
                  <% else %>
                    <div style="color: #8b949e;">No saved project brief yet.</div>
                  <% end %>
                </div>
                <% else %>
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
                                style={"width: 1.25rem; height: 1.25rem; border-radius: 3px; border: 1px solid #30363d; background: #{if Orchid.Goals.terminal_status?(goal.metadata[:status]), do: "#238636", else: "transparent"}; cursor: pointer; display: flex; align-items: center; justify-content: center; color: white; font-size: 0.7rem;"}
                              >
                                <%= if Orchid.Goals.terminal_status?(goal.metadata[:status]), do: "✓", else: "" %>
                              </button>
                              <span
                                style={"flex: 1; cursor: pointer; color: #{if Orchid.Goals.terminal_status?(goal.metadata[:status]), do: "#8b949e", else: "#c9d1d9"}; #{if Orchid.Goals.terminal_status?(goal.metadata[:status]), do: "text-decoration: line-through;", else: ""}"}
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
                          <%= for model <- @decomp_model_options do %>
                            <option value={Atom.to_string(model.id)} selected={@decomp_model == model.id}>
                              <%= model.label %>
                            </option>
                          <% end %>
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
                      model=<%= @decomp_result.model %> • paths=<%= @decomp_result.num_paths %> • iterations=<%= @decomp_result.max_iterations %> • duration=<%= @decomp_result.duration_ms %>ms • <%= short_time(@decomp_result.ran_at) %>
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
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp filter_projects(projects, query) do
    projects
    |> Enum.filter(fn p ->
      query == "" or String.contains?(String.downcase(p.name), String.downcase(query))
    end)
  end

  defp get_project(projects, id) do
    Enum.find(projects, fn p -> p.id == id end)
  end

  defp get_project_name(projects, id) do
    case get_project(projects, id) do
      nil -> "Unknown"
      project -> project.name
    end
  end

  defp get_project_status(projects, id) do
    case get_project(projects, id) do
      nil -> nil
      project -> project.metadata[:status]
    end
  end

  defp project_text(nil), do: "Not set."

  defp project_text(value) when is_binary(value) do
    if String.trim(value) == "", do: "Not set.", else: value
  end

  defp project_text(value), do: to_string(value)

  defp project_paths(nil), do: []

  defp project_paths(project) do
    case project.metadata[:relevant_paths] do
      paths when is_list(paths) -> Enum.reject(paths, &(&1 in [nil, ""]))
      path when is_binary(path) and path != "" -> [path]
      _ -> []
    end
  end

  defp project_default_template(nil), do: "Not set."

  defp project_default_template(project) do
    case project.metadata[:default_template_id] do
      nil ->
        "Not set."

      "" ->
        "Not set."

      template_id ->
        case Orchid.Object.get(template_id) do
          {:ok, template} -> template.name
          _ -> template_id
        end
    end
  end

  defp project_execution_mode(nil), do: "VM"

  defp project_execution_mode(project) do
    case project.metadata[:default_execution_mode] do
      :host -> "Host"
      "host" -> "Host"
      _ -> "VM"
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
      status == :superseded -> :superseded
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
  defp goal_outcome_label(:superseded), do: "Superseded"
  defp goal_outcome_label(:failure), do: "Failed"
  defp goal_outcome_label(:blocked), do: "Blocked"
  defp goal_outcome_label(_), do: "Done"

  defp goal_outcome_style(:success), do: "background: #0e2a15; color: #7ee787;"
  defp goal_outcome_style(:superseded), do: "background: #2d2000; color: #d29922;"
  defp goal_outcome_style(:failure), do: "background: #3d1114; color: #f85149;"
  defp goal_outcome_style(:blocked), do: "background: #2d2000; color: #d29922;"
  defp goal_outcome_style(_), do: "background: #21262d; color: #8b949e;"

  defp normalize_status(v) when is_atom(v), do: v

  defp normalize_status(v) when is_binary(v) do
    case String.downcase(v) do
      "completed" -> :completed
      "pending" -> :pending
      "superseded" -> :superseded
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

  defp new_project_chat_role_label(:assistant), do: "Guide"
  defp new_project_chat_role_label(:user), do: "You"
  defp new_project_chat_role_label(role), do: role |> to_string() |> String.capitalize()

  defp new_project_chat_message_style(:assistant),
    do: "background: #111b2e; border-color: #24405c;"

  defp new_project_chat_message_style(:user),
    do: "background: #0d1117; border-color: #30363d;"

  defp new_project_chat_message_style(_role),
    do: "background: #0d1117; border-color: #30363d;"

  defp default_new_project_form(default_template_id, default_execution_mode) do
    %{
      name: "",
      objective: "",
      success_criteria: "",
      background: "",
      constraints: "",
      relevant_paths_text: "",
      kickoff_goal: "",
      default_template_id: default_template_id,
      default_execution_mode: default_execution_mode || :vm
    }
  end

  defp assign_new_project_form_state(socket, form) do
    form = normalize_new_project_form(form, socket.assigns[:new_project_form] || %{})

    socket
    |> assign(:new_project_form, form)
    |> assign(:new_project_ready_to_submit, ProjectIntake.ready_to_submit?(form))
    |> assign(:new_project_missing_fields, ProjectIntake.missing_fields(form))
    |> assign(:new_project_chat_focus, ProjectIntake.next_focus(form))
  end

  defp normalize_new_project_form(form, fallback) when is_map(form) and is_map(fallback) do
    default_template_id =
      case Map.get(form, :default_template_id) do
        nil -> Map.get(fallback, :default_template_id)
        value -> value
      end

    default_execution_mode =
      case Map.get(form, :default_execution_mode) do
        nil -> Map.get(fallback, :default_execution_mode, :vm)
        value -> value
      end

    Map.merge(
      default_new_project_form(default_template_id, default_execution_mode),
      form,
      fn
        key, left, nil when key in [:default_template_id, :default_execution_mode] -> left
        _key, _left, right -> right
      end
    )
  end

  defp reset_new_project_draft(socket, default_template_id, default_execution_mode) do
    form = default_new_project_form(default_template_id, default_execution_mode)

    socket
    |> assign_new_project_form_state(form)
    |> assign(:new_project_errors, %{})
    |> assign(:new_project_chat_messages, ProjectIntake.initial_messages(form))
    |> assign(:new_project_chat_input, "")
    |> assign(:new_project_chat_running, false)
    |> assign(:new_project_chat_request_id, nil)
  end

  defp open_new_project_workspace(socket) do
    socket
    |> assign(:project_workspace_mode, :new_project)
    |> reset_new_project_draft(
      socket.assigns.selected_template,
      socket.assigns.agent_execution_mode
    )
    |> assign(:new_project_return_project, socket.assigns.current_project)
    |> assign(:new_project_return_tab, socket.assigns.project_tab || :overview)
  end

  defp merge_new_project_form(form, attrs) when is_map(attrs) do
    %{
      name: Map.get(attrs, "name", form.name),
      objective: Map.get(attrs, "objective", form.objective),
      success_criteria: Map.get(attrs, "success_criteria", form.success_criteria),
      background: Map.get(attrs, "background", form.background),
      constraints: Map.get(attrs, "constraints", form.constraints),
      relevant_paths_text: Map.get(attrs, "relevant_paths_text", form.relevant_paths_text),
      kickoff_goal: Map.get(attrs, "kickoff_goal", form.kickoff_goal),
      default_template_id:
        normalize_select_value(Map.get(attrs, "default_template_id", form.default_template_id)),
      default_execution_mode:
        normalize_form_execution_mode(
          Map.get(attrs, "default_execution_mode", form.default_execution_mode)
        )
    }
  end

  defp project_create_attrs(form, intake_conversation) do
    %{
      name: form.name,
      objective: form.objective,
      success_criteria: form.success_criteria,
      background: form.background,
      constraints: form.constraints,
      relevant_paths: form.relevant_paths_text,
      kickoff_goal: form.kickoff_goal,
      intake_conversation: intake_conversation,
      default_template_id: form.default_template_id,
      default_execution_mode: form.default_execution_mode
    }
  end

  defp select_project_workspace(socket, project_id, opts \\ []) do
    tab = Keyword.get(opts, :tab, :overview)

    socket
    |> assign(:project_workspace_mode, :project)
    |> assign(:current_project, project_id)
    |> assign(:project_tab, tab)
    |> assign(:goals, Orchid.Goals.list_for_project(project_id))
    |> assign(:event_log_entries, recent_events(project_id, @event_log_tail_lines))
    |> assign(:mcp_calls, recent_mcp_calls(project_id, 40))
    |> assign(:decomp_result, nil)
    |> assign(:decomp_error, nil)
    |> assign(:new_project_errors, %{})
    |> assign(:new_project_chat_running, false)
    |> assign(:new_project_chat_request_id, nil)
    |> maybe_apply_project_defaults(project_id)
    |> refresh_sandbox_statuses()
  end

  defp maybe_apply_project_defaults(socket, nil), do: socket

  defp maybe_apply_project_defaults(socket, project_id) do
    case Orchid.Object.get(project_id) do
      {:ok, project} ->
        socket
        |> maybe_assign_template(project.metadata[:default_template_id])
        |> maybe_assign_execution_mode(project.metadata[:default_execution_mode])

      _ ->
        socket
    end
  end

  defp maybe_assign_template(socket, nil), do: socket
  defp maybe_assign_template(socket, ""), do: socket

  defp maybe_assign_template(socket, template_id) do
    case Orchid.Object.get(template_id) do
      {:ok, %{type: :agent_template}} -> assign(socket, :selected_template, template_id)
      _ -> socket
    end
  end

  defp maybe_assign_execution_mode(socket, mode) when mode in [:vm, :host] do
    assign(socket, :agent_execution_mode, mode)
  end

  defp maybe_assign_execution_mode(socket, mode) when mode in ["vm", "host"] do
    assign(socket, :agent_execution_mode, parse_agent_execution_mode(mode))
  end

  defp maybe_assign_execution_mode(socket, _mode), do: socket

  defp normalize_select_value(nil), do: nil
  defp normalize_select_value(""), do: nil
  defp normalize_select_value(value), do: value

  defp normalize_form_execution_mode(:vm), do: :vm
  defp normalize_form_execution_mode(:host), do: :host
  defp normalize_form_execution_mode("host"), do: :host
  defp normalize_form_execution_mode("root_vm"), do: :host
  defp normalize_form_execution_mode(_value), do: :vm

  defp truthy_param?(value) when value in [true, "true", "1", 1], do: true
  defp truthy_param?(_value), do: false

  defp submit_message(socket, input) do
    if input == "" or socket.assigns.streaming do
      {:noreply, socket}
    else
      agent_id = socket.assigns.current_agent
      messages = socket.assigns.messages ++ [%{role: :user, content: input, tool_calls: nil}]

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:message_fingerprint, nil)
        |> assign(:pending_message, input)
        |> assign(:input, "")
        |> assign(:streaming, true)
        |> assign(:stream_content, "")
        |> assign(:retry_count, 0)

      start_stream(socket, agent_id, input)
      {:noreply, socket}
    end
  end

  defp maybe_assign_messages(socket, messages, fingerprint) do
    if socket.assigns[:message_fingerprint] == fingerprint do
      socket
    else
      socket
      |> assign(:messages, format_messages(messages))
      |> assign(:message_fingerprint, fingerprint)
    end
  end

  defp message_fingerprint(messages) when is_list(messages) do
    last =
      case List.last(messages) do
        nil -> nil
        msg -> {msg.role, msg.content, length(msg[:tool_calls] || [])}
      end

    {length(messages), last}
  end

  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max) <> "..."
  end

  defp truncate(str, _max), do: str

  defp list_agents_with_info do
    agent_ids = Orchid.Agent.list()

    states_by_id =
      Enum.reduce(agent_ids, %{}, fn agent_id, acc ->
        case Orchid.Agent.get_state(agent_id) do
          {:ok, state} -> Map.put(acc, agent_id, state)
          _ -> acc
        end
      end)

    template_names =
      Orchid.Object.list_agent_templates()
      |> Map.new(fn template -> {template.id, template.name} end)

    goals_by_project =
      states_by_id
      |> Map.values()
      |> Enum.map(& &1.project_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(fn project_id ->
        {project_id, Orchid.Object.list_goals_for_project(project_id)}
      end)

    Enum.map(agent_ids, fn agent_id ->
      case Map.get(states_by_id, agent_id) do
        nil ->
          %{
            id: agent_id,
            project_id: nil,
            template: nil,
            goal: nil,
            status: :unknown,
            wait_status: nil,
            execution_mode: :vm
          }

        state ->
          template_name =
            case state.config[:template_id] do
              nil -> nil
              tid -> Map.get(template_names, tid)
            end

          goal_name =
            case state.project_id do
              nil ->
                nil

              pid ->
                Map.get(goals_by_project, pid, [])
                |> Enum.find(fn g -> g.metadata[:agent_id] == agent_id end)
                |> case do
                  nil -> nil
                  g -> g.name
                end
            end

          %{
            id: agent_id,
            project_id: state.project_id,
            template: template_name,
            goal: goal_name,
            status: state.status,
            wait_status: wait_status_from_memory(state.memory),
            execution_mode: state.execution_mode || :vm
          }
      end
    end)
  end

  defp schedule_poll(socket) do
    Process.send_after(self(), :poll_agent_status, poll_interval_ms(socket))
  end

  defp poll_interval_ms(socket) do
    cond do
      socket.assigns[:streaming] ->
        @active_poll_interval_ms

      socket.assigns[:current_agent] && socket.assigns[:agent_status] != :idle ->
        @active_poll_interval_ms

      true ->
        @idle_poll_interval_ms
    end
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

  defp clear_diagnostics(socket) do
    socket
    |> assign(
      :event_log_entries,
      recent_events(socket.assigns.current_project, @event_log_tail_lines)
    )
    |> assign(:event_log_tail_lines, @event_log_tail_lines)
    |> assign(:server_log_path, server_log_path())
    |> assign(:server_log_tail, "")
    |> assign(:server_log_error, nil)
    |> assign(:server_log_updated_at, nil)
    |> assign(:server_log_tail_lines, @server_log_tail_lines)
  end

  defp maybe_refresh_diagnostics(socket) do
    if socket.assigns[:show_diagnostics] do
      refresh_diagnostics(socket)
    else
      socket
    end
  end

  defp refresh_diagnostics(socket) do
    path = server_log_path()

    socket =
      socket
      |> assign(
        :event_log_entries,
        recent_events(socket.assigns.current_project, @event_log_tail_lines)
      )
      |> assign(:event_log_tail_lines, @event_log_tail_lines)
      |> assign(:server_log_path, path)
      |> assign(:server_log_tail_lines, @server_log_tail_lines)
      |> assign(:server_log_updated_at, DateTime.utc_now())

    case read_log_tail(path, @server_log_tail_lines) do
      {:ok, content} ->
        socket
        |> assign(:server_log_tail, content)
        |> assign(:server_log_error, nil)

      {:error, :enoent} ->
        socket
        |> assign(:server_log_tail, "")
        |> assign(:server_log_error, "Log file has not been created yet.")

      {:error, reason} ->
        socket
        |> assign(:server_log_tail, "")
        |> assign(:server_log_error, "Failed to read log: #{inspect(reason)}")
    end
  end

  defp server_log_path do
    Orchid.Project.data_dir()
    |> Path.join("server.log")
    |> Path.expand()
  end

  defp read_log_tail(path, max_lines) when max_lines > 0 do
    case :file.open(path, [:read, :binary]) do
      {:ok, fd} ->
        try do
          with {:ok, size} <- :file.position(fd, :eof),
               {:ok, content} <- read_log_tail_chunks(fd, size, max_lines, "") do
            {:ok, extract_tail_lines(content, max_lines)}
          end
        after
          :file.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_log_tail_chunks(_fd, 0, _max_lines, acc), do: {:ok, acc}

  defp read_log_tail_chunks(fd, pos, max_lines, acc) do
    read_size = min(pos, @server_log_tail_chunk_bytes)
    start_pos = pos - read_size

    with {:ok, _} <- :file.position(fd, {:bof, start_pos}),
         {:ok, chunk} <- :file.read(fd, read_size) do
      updated = chunk <> acc

      if start_pos == 0 or newline_count(updated) > max_lines do
        {:ok, updated}
      else
        read_log_tail_chunks(fd, start_pos, max_lines, updated)
      end
    end
  end

  defp extract_tail_lines(content, max_lines) do
    trailing_newline? = String.ends_with?(content, "\n")

    lines =
      content
      |> String.split("\n", trim: false)
      |> then(fn parts ->
        if trailing_newline? do
          Enum.drop(parts, -1)
        else
          parts
        end
      end)
      |> Enum.take(-max_lines)

    case {Enum.join(lines, "\n"), trailing_newline? and lines != []} do
      {joined, true} -> joined <> "\n"
      {joined, false} -> joined
    end
  end

  defp newline_count(content) do
    content
    |> :binary.matches("\n")
    |> length()
  end

  defp filter_agents(agents, nil), do: agents

  defp filter_agents(agents, current_project) do
    Enum.filter(agents, fn agent ->
      agent.project_id == current_project
    end)
  end

  defp filter_visible_goals(goals, false), do: goals

  defp filter_visible_goals(goals, true) do
    Enum.filter(goals, fn goal -> Orchid.Goals.open_status?(goal.metadata[:status]) end)
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

  defp recent_events(project_id, limit) do
    try do
      Orchid.EventLog.list_recent(project_id: project_id, limit: limit)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp event_scope_label(nil), do: "All projects"
  defp event_scope_label(_project_id), do: "Current project"

  defp event_source_label(source) when is_binary(source) do
    source
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp event_source_label(source), do: inspect(source)

  defp short_agent_id(id) when is_binary(id) do
    String.slice(id, 0, 8)
  end

  defp short_agent_id(id), do: inspect(id)

  defp short_project_id(nil), do: "global"
  defp short_project_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_project_id(id), do: inspect(id)

  defp short_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp short_time(_), do: "--:--:--"

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
  defp goal_node_fill(:superseded), do: "#2d2000"
  defp goal_node_fill(_), do: "#0d1117"

  defp goal_node_stroke(:completed), do: "#238636"
  defp goal_node_stroke(:superseded), do: "#d29922"
  defp goal_node_stroke(_), do: "#30363d"

  defp goal_node_text(:completed), do: "#8b949e"
  defp goal_node_text(:superseded), do: "#d29922"
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

  defp parse_model(value, fallback) do
    case Catalog.normalize_model(value) do
      nil -> fallback
      model -> model
    end
  end

  defp parse_provider(value, fallback) do
    case Catalog.normalize_provider(value) do
      nil -> fallback
      provider -> provider
    end
  end

  defp decomp_llm_config(model) do
    %{provider: Catalog.provider_for_model(model) || :cli, model: model}
  end

  defp parse_agent_execution_mode("host"), do: :host
  defp parse_agent_execution_mode("root_vm"), do: :host
  defp parse_agent_execution_mode(_), do: :vm

  defp clamp_int(raw, default, min, max) when is_binary(raw) do
    case Integer.parse(raw) do
      {v, _} -> v |> Kernel.max(min) |> Kernel.min(max)
      _ -> default
    end
  end

  defp clamp_int(v, _default, min, max) when is_integer(v),
    do: v |> Kernel.max(min) |> Kernel.min(max)

  defp clamp_int(_v, default, _min, _max), do: default
end
