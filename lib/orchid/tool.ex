defmodule Orchid.Tool do
  @moduledoc """
  Tool behaviour and execution for agent tools.
  Tools allow agents to interact with objects, run code, and execute commands.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(args :: map(), context :: map()) :: {:ok, any()} | {:error, any()}

  @tools [
    Orchid.Tools.FileList,
    Orchid.Tools.FileRead,
    Orchid.Tools.FileEdit,
    Orchid.Tools.FileGrep,
    Orchid.Tools.Shell,
    Orchid.Tools.Eval,
    Orchid.Tools.ProjectList,
    Orchid.Tools.ProjectCreate,
    Orchid.Tools.PromptList,
    Orchid.Tools.PromptRead,
    Orchid.Tools.PromptCreate,
    Orchid.Tools.PromptUpdate,
    Orchid.Tools.GoalList,
    Orchid.Tools.GoalRead,
    Orchid.Tools.GoalCreate,
    Orchid.Tools.GoalUpdate,
    Orchid.Tools.PlanAletheia,
    Orchid.Tools.TaskReportResult,
    Orchid.Tools.SandboxReset,
    Orchid.Tools.AgentSpawn,
    Orchid.Tools.Wait
  ]

  @sandboxed_tools ~w(shell read edit list grep)
  @template_scoped_tools ~w(project_list project_create)
  @tool_aliases %{"task_report" => "task_report_result"}

  @doc """
  List all available tools with their schemas.
  """
  def list_tools(allowed_names \\ nil) do
    selected = select_tools(allowed_names)

    Enum.map(selected, fn mod ->
      %{
        name: mod.name(),
        description: mod.description(),
        parameters: mod.parameters()
      }
    end)
  end

  @doc """
  Execute a tool by name.
  Routes sandboxed tools through the sandbox when active.
  """
  def execute(name, args, context) do
    if allowed?(name, context) do
      try do
        do_execute(name, args, context)
      rescue
        e ->
          {:error, "Tool #{name} crashed: #{Exception.message(e)}"}
      catch
        :exit, reason ->
          {:error, "Tool #{name} exited: #{inspect(reason)}"}

        kind, reason ->
          {:error, "Tool #{name} #{kind}: #{inspect(reason)}"}
      end
    else
      {:error, {:tool_not_allowed, name}}
    end
  end

  defp do_execute(name, args, context) do
    case find_tool(name) do
      nil ->
        {:error, {:unknown_tool, name}}

      mod ->
        cond do
          name in @sandboxed_tools and sandbox_active?(context) ->
            execute_in_sandbox(name, args, context)

          name in @sandboxed_tools and host_project_mode?(context) ->
            execute_in_host_project(name, args, context)

          true ->
            mod.execute(args, context)
        end
    end
  end

  defp select_tools(nil),
    do: Enum.reject(@tools, fn mod -> mod.name() in @template_scoped_tools end)

  defp select_tools([]), do: []

  defp select_tools(allowed_names) when is_list(allowed_names) do
    allowed =
      allowed_names
      |> Enum.map(&to_string/1)
      |> Enum.map(&canonical_name/1)
      |> MapSet.new()

    Enum.filter(@tools, fn mod -> MapSet.member?(allowed, mod.name()) end)
  end

  defp select_tools(_), do: @tools

  defp allowed?(name, %{agent_state: %{config: config}}) when is_map(config) do
    case config[:allowed_tools] do
      nil ->
        canonical_name(name) not in @template_scoped_tools

      names when is_list(names) ->
        canonical = canonical_name(name)

        names
        |> Enum.map(&to_string/1)
        |> Enum.map(&canonical_name/1)
        |> Enum.member?(canonical)

      _ ->
        true
    end
  end

  defp allowed?(name, _context), do: canonical_name(name) not in @template_scoped_tools

  defp find_tool(name) do
    canonical = canonical_name(name)
    Enum.find(@tools, fn mod -> mod.name() == canonical end)
  end

  defp canonical_name(name) do
    name
    |> to_string()
    |> then(&Map.get(@tool_aliases, &1, &1))
  end

  defp sandbox_active?(%{agent_state: %{project_id: project_id, sandbox: s}})
       when is_binary(project_id) and not is_nil(s) and s != false do
    Orchid.Sandbox.status(project_id) != nil
  end

  defp sandbox_active?(_), do: false

  defp host_project_mode?(%{agent_state: %{project_id: project_id}}) when is_binary(project_id),
    do: true

  defp host_project_mode?(_), do: false

  defp execute_in_sandbox(name, args, ctx) do
    pid = ctx.agent_state.project_id

    case name do
      "shell" ->
        Orchid.Sandbox.exec(pid, args["command"], timeout: args["timeout"] || 30_000)

      "read" ->
        Orchid.Sandbox.read_file(pid, args["path"])

      "edit" ->
        Orchid.Sandbox.edit_file(pid, args["path"], args["old_string"], args["new_string"])

      "list" ->
        Orchid.Sandbox.list_files(pid, args["path"] || "/workspace")

      "grep" ->
        Orchid.Sandbox.grep_files(pid, args["pattern"], args["path"] || "/workspace",
          glob: args["glob"]
        )
    end
  end

  defp execute_in_host_project(name, args, %{agent_state: %{project_id: project_id}} = ctx) do
    root = Orchid.Project.files_path(project_id) |> Path.expand()

    case name do
      "shell" ->
        command = rewrite_workspace_paths(args["command"], root)
        wrapped = "cd #{shell_escape(root)} && #{command}"
        Orchid.Tools.Shell.execute(Map.put(args, "command", wrapped), ctx)

      "read" ->
        Orchid.Tools.FileRead.execute(Map.put(args, "path", host_path(args["path"], root)), ctx)

      "edit" ->
        Orchid.Tools.FileEdit.execute(Map.put(args, "path", host_path(args["path"], root)), ctx)

      "list" ->
        Orchid.Tools.FileList.execute(Map.put(args, "path", host_path(args["path"], root)), ctx)

      "grep" ->
        Orchid.Tools.FileGrep.execute(Map.put(args, "path", host_path(args["path"], root)), ctx)
    end
  end

  defp host_path(nil, root), do: root
  defp host_path("/workspace", root), do: root

  defp host_path(path, root) when is_binary(path) do
    cond do
      String.starts_with?(path, "/workspace/") ->
        Path.join(root, String.trim_leading(path, "/workspace/"))

      Path.type(path) == :absolute ->
        path

      true ->
        Path.expand(path, root)
    end
  end

  defp rewrite_workspace_paths(command, _root) when not is_binary(command), do: command
  defp rewrite_workspace_paths(command, root), do: String.replace(command, "/workspace", root)

  defp shell_escape(arg) do
    escaped = String.replace(arg, "'", "'\\''")
    "'#{escaped}'"
  end
end
