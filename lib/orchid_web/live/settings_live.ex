defmodule OrchidWeb.SettingsLive do
  use Phoenix.LiveView

  alias Orchid.Object

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:facts, Object.list_facts())
      |> assign(:editing, nil)
      |> assign(:creating, false)
      |> assign(:form_name, "")
      |> assign(:form_value, "")
      |> assign(:form_category, "API Keys")
      |> assign(:form_sensitive, true)
      |> assign(:form_description, "")
      |> assign(:revealed_facts, MapSet.new())
      |> assign(:search_query, "")
      |> assign(:filter_category, "All")
      |> assign(:projects, Object.list_projects())
      |> assign(:project_query, "")
      |> assign(:current_project, nil)
      |> assign(:creating_project, false)
      |> assign(:new_project_name, "")

    {:ok, socket}
  end

  @impl true
  def handle_event("new_fact", _params, socket) do
    {:noreply,
     assign(socket,
       creating: true,
       editing: nil,
       form_name: "",
       form_value: "",
       form_category: "API Keys",
       form_sensitive: true,
       form_description: ""
     )}
  end

  def handle_event("edit_fact", %{"id" => id}, socket) do
    case Object.get(id) do
      {:ok, fact} ->
        {:noreply,
         assign(socket,
           editing: id,
           creating: false,
           form_name: fact.name,
           form_value: fact.content,
           form_category: fact.metadata[:category] || "General",
           form_sensitive: fact.metadata[:sensitive] || false,
           form_description: fact.metadata[:description] || ""
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: nil, creating: false)}
  end

  def handle_event("update_form", params, socket) do
    socket =
      socket
      |> assign(:form_name, params["name"] || socket.assigns.form_name)
      |> assign(:form_value, params["value"] || socket.assigns.form_value)
      |> assign(:form_category, params["category"] || socket.assigns.form_category)
      |> assign(:form_description, params["description"] || socket.assigns.form_description)
      |> assign(:form_sensitive, params["sensitive"] == "true")

    {:noreply, socket}
  end

  def handle_event("save_fact", _params, socket) do
    name = String.trim(socket.assigns.form_name)
    value = socket.assigns.form_value

    if name == "" do
      {:noreply, socket}
    else
      metadata = %{
        category: socket.assigns.form_category,
        sensitive: socket.assigns.form_sensitive,
        description: socket.assigns.form_description
      }

      if socket.assigns.creating do
        {:ok, _} = Object.create(:fact, name, value, metadata: metadata)
      else
        {:ok, _} = Object.update(socket.assigns.editing, value)
        {:ok, _} = Object.update_metadata(socket.assigns.editing, metadata)
      end

      {:noreply,
       assign(socket,
         facts: Object.list_facts(),
         editing: nil,
         creating: false,
         form_name: "",
         form_value: "",
         form_category: "API Keys",
         form_sensitive: true,
         form_description: ""
       )}
    end
  end

  def handle_event("delete_fact", %{"id" => id}, socket) do
    Object.delete(id)
    {:noreply, assign(socket, facts: Object.list_facts())}
  end

  def handle_event("toggle_show_value", %{"id" => id}, socket) do
    revealed = socket.assigns.revealed_facts

    revealed =
      if MapSet.member?(revealed, id) do
        MapSet.delete(revealed, id)
      else
        MapSet.put(revealed, id)
      end

    {:noreply, assign(socket, :revealed_facts, revealed)}
  end

  def handle_event("search_facts", %{"query" => query}, socket) do
    {:noreply, assign(socket, :search_query, query)}
  end

  def handle_event("filter_category", %{"category" => category}, socket) do
    {:noreply, assign(socket, :filter_category, category)}
  end

  # Project sidebar events
  def handle_event("search_projects", %{"query" => query}, socket) do
    {:noreply, assign(socket, :project_query, query)}
  end

  def handle_event("select_project", %{"id" => id}, socket) do
    {:noreply, assign(socket, :current_project, id)}
  end

  def handle_event("clear_project", _params, socket) do
    {:noreply, assign(socket, :current_project, nil)}
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
                >x</button>
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
                >x</button>
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
            <h1>Settings</h1>
            <div style="display: flex; gap: 0.5rem; align-items: center;">
              <a href="/" class="btn btn-secondary">Agents</a>
              <a href="/prompts" class="btn btn-secondary">Prompts</a>
              <button class="btn" phx-click="new_fact">+ New Fact</button>
            </div>
          </div>

          <div style="display: flex; gap: 0.5rem; margin-bottom: 1rem;">
            <form phx-change="search_facts" style="flex: 1;">
              <input
                type="text"
                name="query"
                placeholder="Search facts..."
                value={@search_query}
                class="sidebar-search"
                style="width: 100%;"
                phx-debounce="150"
              />
            </form>
            <form phx-change="filter_category">
              <select name="category" class="sidebar-search" style="min-width: 120px;">
                <option value="All" selected={@filter_category == "All"}>All</option>
                <%= for cat <- get_categories(@facts) do %>
                  <option value={cat} selected={@filter_category == cat}><%= cat %></option>
                <% end %>
              </select>
            </form>
          </div>

          <%= if @creating or @editing do %>
            <div style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
              <h3 style="color: #c9d1d9; margin: 0 0 1rem 0;">
                <%= if @creating, do: "Create Fact", else: "Edit Fact" %>
              </h3>
              <form phx-submit="save_fact" phx-change="update_form">
                <div style="margin-bottom: 0.75rem;">
                  <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">Name</label>
                  <input
                    type="text"
                    name="name"
                    value={@form_name}
                    placeholder="e.g. cerebras_api_key"
                    class="sidebar-search"
                    style="width: 100%;"
                    disabled={@editing != nil}
                    autofocus
                  />
                </div>
                <div style="margin-bottom: 0.75rem;">
                  <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">Value</label>
                  <textarea
                    name="value"
                    placeholder="Fact value..."
                    class="sidebar-search"
                    style="width: 100%; min-height: 60px; resize: vertical;"
                  ><%= @form_value %></textarea>
                </div>
                <div style="display: flex; gap: 0.75rem; margin-bottom: 0.75rem;">
                  <div style="flex: 1;">
                    <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">Category</label>
                    <input
                      type="text"
                      name="category"
                      value={@form_category}
                      class="sidebar-search"
                      style="width: 100%;"
                      list="fact-category-suggestions"
                    />
                    <datalist id="fact-category-suggestions">
                      <option value="API Keys" />
                      <option value="URLs" />
                      <option value="Configuration" />
                      <option value="General" />
                    </datalist>
                  </div>
                  <div style="display: flex; align-items: end; padding-bottom: 0.25rem;">
                    <label style="display: flex; align-items: center; gap: 0.5rem; color: #8b949e; cursor: pointer;">
                      <input
                        type="hidden"
                        name="sensitive"
                        value="false"
                      />
                      <input
                        type="checkbox"
                        name="sensitive"
                        value="true"
                        checked={@form_sensitive}
                        style="width: 1rem; height: 1rem;"
                      />
                      Sensitive
                    </label>
                  </div>
                </div>
                <div style="margin-bottom: 0.75rem;">
                  <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">Description</label>
                  <input
                    type="text"
                    name="description"
                    value={@form_description}
                    placeholder="Optional description"
                    class="sidebar-search"
                    style="width: 100%;"
                  />
                </div>
                <div style="display: flex; gap: 0.5rem;">
                  <button type="submit" class="btn">Save</button>
                  <button type="button" class="btn btn-secondary" phx-click="cancel">Cancel</button>
                </div>
              </form>
            </div>
          <% end %>

          <%= if filtered_facts(@facts, @search_query, @filter_category) == [] and !@creating and !@editing do %>
            <p style="color: #8b949e;">No facts yet. Create one to store API keys, URLs, or configuration values.</p>
          <% else %>
            <%= for {category, facts} <- group_facts_by_category(filtered_facts(@facts, @search_query, @filter_category)) do %>
              <div style="margin-bottom: 1.5rem;">
                <h3 style="color: #8b949e; font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 0.5rem;"><%= category %></h3>
                <div style="display: flex; flex-direction: column; gap: 0.5rem;">
                  <%= for fact <- facts do %>
                    <div style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 0.75rem 1rem;">
                      <div style="display: flex; align-items: center; gap: 0.75rem;">
                        <div style="flex: 1;">
                          <div style="color: #58a6ff; font-weight: 500; font-size: 0.95rem;"><%= fact.name %></div>
                          <%= if fact.metadata[:description] && fact.metadata[:description] != "" do %>
                            <div style="color: #8b949e; font-size: 0.8rem; margin-top: 0.15rem;"><%= fact.metadata[:description] %></div>
                          <% end %>
                        </div>
                        <div style="display: flex; align-items: center; gap: 0.5rem;">
                          <code style="background: #0d1117; padding: 0.25rem 0.5rem; border-radius: 4px; font-size: 0.85rem; color: #c9d1d9; max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                            <%= if fact.metadata[:sensitive] && not MapSet.member?(@revealed_facts, fact.id) do %>
                              ********
                            <% else %>
                              <%= fact.content %>
                            <% end %>
                          </code>
                          <%= if fact.metadata[:sensitive] do %>
                            <button
                              class="btn btn-secondary btn-sm"
                              style="padding: 0.2rem 0.5rem; font-size: 0.75rem;"
                              phx-click="toggle_show_value"
                              phx-value-id={fact.id}
                            >
                              <%= if MapSet.member?(@revealed_facts, fact.id), do: "Hide", else: "Show" %>
                            </button>
                          <% end %>
                          <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="edit_fact" phx-value-id={fact.id}>Edit</button>
                          <button class="btn btn-danger btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem; opacity: 0.7;" phx-click="delete_fact" phx-value-id={fact.id}>Delete</button>
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
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

  defp get_categories(facts) do
    facts
    |> Enum.map(fn f -> f.metadata[:category] || "General" end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp filtered_facts(facts, query, category) do
    facts
    |> Enum.filter(fn f ->
      matches_query =
        query == "" or String.contains?(String.downcase(f.name), String.downcase(query))

      matches_category = category == "All" or (f.metadata[:category] || "General") == category
      matches_query and matches_category
    end)
  end

  defp group_facts_by_category(facts) do
    facts
    |> Enum.group_by(fn f -> f.metadata[:category] || "General" end)
    |> Enum.sort_by(fn {category, _} ->
      if category == "API Keys", do: {0, category}, else: {1, category}
    end)
  end
end
