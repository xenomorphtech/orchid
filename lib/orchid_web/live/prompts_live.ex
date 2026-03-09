defmodule OrchidWeb.PromptsLive do
  use Phoenix.LiveView

  alias Orchid.Object

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:prompts, Object.list_prompts())
      |> assign(:editing, nil)
      |> assign(:creating, false)
      |> assign(:form_name, "")
      |> assign(:form_content, "")
      |> assign(:projects, Object.list_projects())
      |> assign(:project_query, "")
      |> assign(:current_project, nil)
      |> assign(:creating_project, false)
      |> assign(:new_project_name, "")
      |> assign(:goals, [])
      |> assign(:creating_goal, false)
      |> assign(:new_goal_name, "")
      |> assign(:adding_dependency_to, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("new_prompt", _params, socket) do
    {:noreply, assign(socket, creating: true, editing: nil, form_name: "", form_content: "")}
  end

  def handle_event("edit_prompt", %{"id" => id}, socket) do
    case Object.get(id) do
      {:ok, prompt} ->
        {:noreply,
         assign(socket,
           editing: id,
           creating: false,
           form_name: prompt.name,
           form_content: prompt.content
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: nil, creating: false)}
  end

  def handle_event("update_form", %{"name" => name, "content" => content}, socket) do
    {:noreply, assign(socket, form_name: name, form_content: content)}
  end

  def handle_event("save_prompt", _params, socket) do
    name = String.trim(socket.assigns.form_name)
    content = socket.assigns.form_content

    if name == "" do
      {:noreply, socket}
    else
      if socket.assigns.creating do
        {:ok, _} = Object.create(:prompt, name, content)
      else
        {:ok, _} = Object.update(socket.assigns.editing, content)
      end

      {:noreply,
       assign(socket,
         prompts: Object.list_prompts(),
         editing: nil,
         creating: false,
         form_name: "",
         form_content: ""
       )}
    end
  end

  def handle_event("delete_prompt", %{"id" => id}, socket) do
    Object.delete(id)
    {:noreply, assign(socket, prompts: Object.list_prompts())}
  end

  # Project events
  def handle_event("search_projects", %{"query" => query}, socket) do
    {:noreply, assign(socket, :project_query, query)}
  end

  def handle_event("select_project", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:current_project, id)
     |> assign(:goals, Object.list_goals_for_project(id))}
  end

  def handle_event("clear_project", _params, socket) do
    {:noreply,
     socket
     |> assign(:current_project, nil)
     |> assign(:goals, [])}
  end

  def handle_event("show_new_project", _params, socket) do
    {:noreply, push_navigate(socket, to: "/?new_project=1")}
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
      {:ok, project} = Object.create(:project, name, "")
      Orchid.Project.ensure_dir(project.id)

      {:noreply,
       assign(socket,
         projects: Object.list_projects(),
         creating_project: false,
         new_project_name: "",
         current_project: project.id
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_project", %{"id" => id}, socket) do
    Orchid.Project.delete_dir(id)
    Object.delete(id)

    socket =
      socket
      |> assign(:projects, Object.list_projects())
      |> then(fn s ->
        if s.assigns.current_project == id do
          assign(s, :current_project, nil)
        else
          s
        end
      end)

    {:noreply, socket}
  end

  # Goal events
  def handle_event("show_new_goal", _params, socket) do
    {:noreply, assign(socket, creating_goal: true, new_goal_name: "")}
  end

  def handle_event("cancel_new_goal", _params, socket) do
    {:noreply, assign(socket, creating_goal: false, new_goal_name: "")}
  end

  def handle_event("update_new_goal_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :new_goal_name, name)}
  end

  def handle_event("create_goal", _params, socket) do
    name = String.trim(socket.assigns.new_goal_name)
    project_id = socket.assigns.current_project

    if name != "" and project_id do
      {:ok, _goal} =
        Object.create(:goal, name, "",
          metadata: %{
            project_id: project_id,
            status: :pending,
            depends_on: []
          }
        )

      {:noreply,
       assign(socket,
         goals: Object.list_goals_for_project(project_id),
         creating_goal: false,
         new_goal_name: ""
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_goal_status", %{"id" => id}, socket) do
    case Object.get(id) do
      {:ok, goal} ->
        new_status =
          case goal.metadata[:status] do
            :completed -> :pending
            _ -> :completed
          end

        {:ok, _} = Object.update_metadata(id, %{status: new_status})

        {:noreply,
         assign(socket, :goals, Object.list_goals_for_project(socket.assigns.current_project))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_goal", %{"id" => id}, socket) do
    # Remove this goal from any depends_on lists
    goals = socket.assigns.goals

    for goal <- goals do
      depends_on = goal.metadata[:depends_on] || []

      if id in depends_on do
        Object.update_metadata(goal.id, %{depends_on: List.delete(depends_on, id)})
      end
    end

    Object.delete(id)

    {:noreply,
     assign(socket, :goals, Object.list_goals_for_project(socket.assigns.current_project))}
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
    case Object.get(goal_id) do
      {:ok, goal} ->
        current_deps = goal.metadata[:depends_on] || []

        if depends_on_id not in current_deps do
          {:ok, _} =
            Object.update_metadata(goal_id, %{depends_on: [depends_on_id | current_deps]})
        end

        {:noreply,
         socket
         |> assign(:goals, Object.list_goals_for_project(socket.assigns.current_project))
         |> assign(:adding_dependency_to, nil)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "remove_dependency",
        %{"goal-id" => goal_id, "depends-on" => depends_on_id},
        socket
      ) do
    case Object.get(goal_id) do
      {:ok, goal} ->
        current_deps = goal.metadata[:depends_on] || []

        {:ok, _} =
          Object.update_metadata(goal_id, %{depends_on: List.delete(current_deps, depends_on_id)})

        {:noreply,
         assign(socket, :goals, Object.list_goals_for_project(socket.assigns.current_project))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="app-layout">
      <div class="sidebar">
        <div class="sidebar-header">
          <h2>Projects</h2>
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
              <div
                class="project-item"
                phx-click="select_project"
                phx-value-id={project.id}
              >
                <span class="project-icon"></span>
                <span style="flex: 1;"><%= project.name %></span>
                <button
                  class="btn btn-danger btn-sm"
                  style="padding: 0.15rem 0.4rem; font-size: 0.7rem; opacity: 0.7;"
                  phx-click="delete_project"
                  phx-value-id={project.id}
                >×</button>
              </div>
            <% end %>
            <%= if @projects == [] and not @creating_project do %>
              <div class="no-projects">No projects yet</div>
            <% end %>
          <% end %>
        </div>
        <div class="sidebar-footer">
          <button class="btn btn-secondary" phx-click="show_new_project">+ New Project</button>
        </div>
      </div>

      <div class="main-content">
        <div class="container">
          <div class="header">
            <h1>Orchid</h1>
            <div style="display: flex; gap: 0.5rem; align-items: center;">
              <a href="/" class="btn btn-secondary">Agents</a>
              <a href="/settings" class="btn btn-secondary">Settings</a>
              <button class="btn" phx-click="new_prompt">New Prompt</button>
            </div>
          </div>

          <%= if @current_project do %>
            <div class="project-detail" style="margin-bottom: 1.5rem;">
              <h2 style="color: #c9d1d9; margin-bottom: 1rem;">
                Project: <%= get_project_name(@projects, @current_project) %>
              </h2>

              <div class="goals-section" style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
                <h3 style="color: #c9d1d9; margin: 0 0 1rem 0; font-size: 1rem;">Goals</h3>

                <%= if @creating_goal do %>
                  <form phx-submit="create_goal" phx-change="update_new_goal_name" style="margin-bottom: 1rem;">
                    <input
                      type="text"
                      name="name"
                      value={@new_goal_name}
                      placeholder="Goal name"
                      class="sidebar-search"
                      style="width: 100%; margin-bottom: 0.5rem;"
                      autofocus
                    />
                    <div style="display: flex; gap: 0.5rem;">
                      <button type="submit" class="btn btn-sm">Add</button>
                      <button type="button" class="btn btn-secondary btn-sm" phx-click="cancel_new_goal">Cancel</button>
                    </div>
                  </form>
                <% end %>

                <%= if @goals == [] and not @creating_goal do %>
                  <p style="color: #8b949e; margin: 0 0 1rem 0;">No goals yet.</p>
                <% else %>
                  <div class="goals-list" style="display: flex; flex-direction: column; gap: 0.5rem; margin-bottom: 1rem;">
                    <%= for goal <- @goals do %>
                      <div class="goal-item" style="background: #0d1117; border: 1px solid #30363d; border-radius: 4px; padding: 0.75rem;">
                        <div style="display: flex; align-items: center; gap: 0.5rem;">
                          <button
                            phx-click="toggle_goal_status"
                            phx-value-id={goal.id}
                            style={"width: 1.25rem; height: 1.25rem; border-radius: 3px; border: 1px solid #30363d; background: #{if Orchid.Goals.terminal_status?(goal.metadata[:status]), do: "#238636", else: "transparent"}; cursor: pointer; display: flex; align-items: center; justify-content: center; color: white; font-size: 0.7rem;"}
                          >
                            <%= if Orchid.Goals.terminal_status?(goal.metadata[:status]), do: "✓", else: "" %>
                          </button>
                          <span style={"flex: 1; color: #{if Orchid.Goals.terminal_status?(goal.metadata[:status]), do: "#8b949e", else: "#c9d1d9"}; #{if Orchid.Goals.terminal_status?(goal.metadata[:status]), do: "text-decoration: line-through;", else: ""}"}><%= goal.name %></span>
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
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%= if not @creating_goal do %>
                  <button class="btn btn-secondary" phx-click="show_new_goal">+ Add Goal</button>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @creating or @editing do %>
            <div class="prompt-form">
              <form phx-submit="save_prompt" phx-change="update_form">
                <div style="margin-bottom: 1rem;">
                  <label style="display: block; margin-bottom: 0.5rem; color: #c9d1d9;">Name</label>
                  <input
                    type="text"
                    name="name"
                    value={@form_name}
                    placeholder="Prompt name"
                    style="width: 100%; padding: 0.5rem; background: #0d1117; border: 1px solid #30363d; border-radius: 6px; color: #c9d1d9;"
                    disabled={@editing != nil}
                  />
                </div>
                <div style="margin-bottom: 1rem;">
                  <label style="display: block; margin-bottom: 0.5rem; color: #c9d1d9;">Content</label>
                  <textarea
                    name="content"
                    rows="15"
                    placeholder="Enter your system prompt..."
                    style="width: 100%; padding: 0.5rem; background: #0d1117; border: 1px solid #30363d; border-radius: 6px; color: #c9d1d9; font-family: monospace; resize: vertical;"
                  ><%= @form_content %></textarea>
                </div>
                <div style="display: flex; gap: 0.5rem;">
                  <button type="submit" class="btn">Save</button>
                  <button type="button" class="btn btn-secondary" phx-click="cancel">Cancel</button>
                </div>
              </form>
            </div>
          <% else %>
            <%= if @prompts == [] do %>
              <p style="color: #8b949e;">No prompts yet. Create one to get started.</p>
            <% else %>
              <div class="prompt-list">
                <%= for prompt <- @prompts do %>
                  <div class="prompt-card">
                    <div class="prompt-header">
                      <h3><%= prompt.name %></h3>
                      <span style="color: #8b949e; font-size: 0.8rem;"><%= prompt.id %></span>
                    </div>
                    <div class="prompt-preview">
                      <%= String.slice(prompt.content, 0, 200) %><%= if String.length(prompt.content) > 200, do: "..." %>
                    </div>
                    <div class="actions" style="margin-top: 0.5rem;">
                      <button class="btn btn-secondary" phx-click="edit_prompt" phx-value-id={prompt.id}>Edit</button>
                      <button class="btn btn-danger" phx-click="delete_prompt" phx-value-id={prompt.id}>Delete</button>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>

    <style>
      .prompt-form {
        background: #161b22;
        border: 1px solid #30363d;
        border-radius: 6px;
        padding: 1rem;
        margin-bottom: 1rem;
      }
      .prompt-list {
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }
      .prompt-card {
        background: #161b22;
        border: 1px solid #30363d;
        border-radius: 6px;
        padding: 1rem;
      }
      .prompt-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 0.5rem;
      }
      .prompt-header h3 {
        margin: 0;
        color: #c9d1d9;
      }
      .prompt-preview {
        color: #8b949e;
        font-family: monospace;
        font-size: 0.9rem;
        white-space: pre-wrap;
        word-break: break-word;
      }
    </style>
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
end
