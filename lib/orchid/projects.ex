defmodule Orchid.Projects do
  @moduledoc """
  Context module for project business logic.
  All project operations go through here — no LiveView awareness.
  """

  alias Orchid.{Goals, Object}

  @doc "Create a new project with its directory."
  def create(attrs) when is_list(attrs) do
    attrs
    |> Enum.into(%{})
    |> create()
  end

  def create(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)
    errors = validate_attrs(attrs)

    if map_size(errors) > 0 do
      {:error, errors}
    else
      metadata = project_metadata(attrs)

      with {:ok, project} <-
             Object.create(:project, attrs.name, build_project_brief(attrs), metadata: metadata),
           {:ok, _path} <- Orchid.Project.ensure_dir(project.id),
           :ok <- maybe_create_kickoff_goal(project.id, attrs),
           {:ok, project} <- maybe_store_intake_conversation(project, attrs) do
        {:ok, project}
      end
    end
  end

  @doc "Delete a project and its directory."
  def delete(project_id) do
    delete_intake_conversation(project_id)
    stop_sandbox(project_id)
    Orchid.Project.delete_dir(project_id)
    Object.delete(project_id)
  end

  @doc "Get the stored intake conversation object for a project, if present."
  def intake_conversation(project_id) do
    with {:ok, project} <- Object.get(project_id),
         conversation_id when is_binary(conversation_id) <-
           project.metadata[:intake_conversation_id] do
      Object.get(conversation_id)
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Pause a project and stop its agents and sandbox (fire-and-forget)."
  def pause(project_id) do
    {:ok, _} = Object.update_metadata(project_id, %{status: :paused})
    stop_sandbox(project_id)
    stop_agents_async(project_id)
    :ok
  end

  @doc "Resume a paused project."
  def resume(project_id) do
    {:ok, _} = Object.update_metadata(project_id, %{status: :active})
    :ok
  end

  @doc "Archive a project and stop its agents and sandbox (fire-and-forget)."
  def archive(project_id) do
    {:ok, _} = Object.update_metadata(project_id, %{status: :archived})
    stop_sandbox(project_id)
    stop_agents_async(project_id)
    :ok
  end

  @doc "Restore an archived project."
  def restore(project_id) do
    {:ok, _} = Object.update_metadata(project_id, %{status: :active})
    :ok
  end

  @doc "Get a project's status from its metadata."
  def status(project) do
    project.metadata[:status]
  end

  @doc "Ensure a sandbox is running for the given project. Idempotent."
  def ensure_sandbox(project_id) do
    case Orchid.Sandbox.status(project_id) do
      nil ->
        start_sandbox(project_id)

      _status ->
        if Orchid.Sandbox.healthy?(project_id) do
          {:ok, :already_running}
        else
          case Orchid.Sandbox.reset(project_id) do
            {:ok, _} ->
              if Orchid.Sandbox.healthy?(project_id) do
                {:ok, :reset}
              else
                Orchid.Sandbox.stop(project_id)
                start_sandbox(project_id)
              end

            _ ->
              Orchid.Sandbox.stop(project_id)
              start_sandbox(project_id)
          end
        end
    end
  end

  @doc "Stop the sandbox for a project if running."
  def stop_sandbox(project_id) do
    Orchid.Sandbox.stop(project_id)
  end

  @doc "Get sandbox status for a project, or nil if not running."
  def sandbox_status(project_id) do
    Orchid.Sandbox.status(project_id)
  end

  # Stop all agents for a project using fire-and-forget tasks
  defp stop_agents_async(project_id) do
    for agent_id <- Orchid.Agent.list() do
      case Orchid.Agent.get_state(agent_id, 1000) do
        {:ok, state} when state.project_id == project_id ->
          Task.start(fn -> Orchid.Agent.stop(agent_id) end)

        _ ->
          :ok
      end
    end
  end

  defp start_sandbox(project_id) do
    case DynamicSupervisor.start_child(
           Orchid.AgentSupervisor,
           {Orchid.Sandbox, project_id}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  defp normalize_attrs(attrs) do
    %{
      name: normalize_text(get_attr(attrs, :name)),
      objective: normalize_text(get_attr(attrs, :objective)),
      success_criteria: normalize_text(get_attr(attrs, :success_criteria)),
      background: normalize_text(get_attr(attrs, :background)),
      constraints: normalize_text(get_attr(attrs, :constraints)),
      relevant_paths: normalize_paths(get_attr(attrs, :relevant_paths)),
      kickoff_goal: normalize_text(get_attr(attrs, :kickoff_goal)),
      intake_conversation: normalize_conversation(get_attr(attrs, :intake_conversation)),
      default_template_id: normalize_text(get_attr(attrs, :default_template_id)),
      default_execution_mode: normalize_execution_mode(get_attr(attrs, :default_execution_mode))
    }
  end

  defp validate_attrs(attrs) do
    %{}
    |> require_field(attrs.name, :name, "Project name is required.")
    |> require_field(attrs.objective, :objective, "Objective is required.")
    |> require_field(
      attrs.success_criteria,
      :success_criteria,
      "Success criteria is required."
    )
    |> validate_template(attrs.default_template_id)
    |> validate_execution_mode(attrs.default_execution_mode)
  end

  defp require_field(errors, value, field, message) do
    if value == "" do
      Map.put(errors, field, message)
    else
      errors
    end
  end

  defp validate_template(errors, ""), do: errors

  defp validate_template(errors, template_id) do
    case Object.get(template_id) do
      {:ok, %{type: :agent_template}} ->
        errors

      _ ->
        Map.put(
          errors,
          :default_template_id,
          "Default template must reference an agent template."
        )
    end
  end

  defp validate_execution_mode(errors, mode) when mode in [:vm, :host], do: errors

  defp validate_execution_mode(errors, _mode) do
    Map.put(errors, :default_execution_mode, "Execution mode must be vm or host.")
  end

  defp project_metadata(attrs) do
    %{
      status: :active,
      objective: attrs.objective,
      success_criteria: attrs.success_criteria,
      background: attrs.background,
      constraints: attrs.constraints,
      relevant_paths: attrs.relevant_paths,
      kickoff_goal: attrs.kickoff_goal,
      default_template_id: attrs.default_template_id,
      default_execution_mode: attrs.default_execution_mode
    }
    |> Enum.reject(fn {key, value} -> blank_metadata_value?(key, value) end)
    |> Map.new()
  end

  defp build_project_brief(attrs) do
    [
      "# #{attrs.name}",
      "",
      "## Objective",
      attrs.objective,
      "",
      "## Definition of Done",
      attrs.success_criteria,
      optional_section("Background", attrs.background),
      optional_section("Constraints", attrs.constraints),
      optional_paths_section(attrs.relevant_paths),
      optional_section("Suggested First Goal", attrs.kickoff_goal),
      optional_defaults_section(attrs.default_template_id, attrs.default_execution_mode)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp optional_section(_title, ""), do: nil

  defp optional_section(title, content) do
    ["", "## #{title}", content]
  end

  defp optional_paths_section([]), do: nil

  defp optional_paths_section(paths) do
    ["", "## Relevant Paths" | Enum.map(paths, &"- #{&1}")]
  end

  defp optional_defaults_section("", :vm), do: nil

  defp optional_defaults_section(template_id, execution_mode) do
    lines =
      []
      |> maybe_add_default_template(template_id)
      |> maybe_add_execution_mode(execution_mode)

    if lines == [] do
      nil
    else
      ["", "## Defaults" | lines]
    end
  end

  defp maybe_add_default_template(lines, ""), do: lines

  defp maybe_add_default_template(lines, template_id),
    do: lines ++ ["- Default template: #{template_id}"]

  defp maybe_add_execution_mode(lines, :vm), do: lines
  defp maybe_add_execution_mode(lines, mode), do: lines ++ ["- Default execution mode: #{mode}"]

  defp maybe_create_kickoff_goal(_project_id, %{kickoff_goal: ""}), do: :ok

  defp maybe_create_kickoff_goal(project_id, %{kickoff_goal: kickoff_goal, objective: objective}) do
    case Goals.create(kickoff_goal, objective, project_id) do
      {:ok, _goal} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_store_intake_conversation(project, %{intake_conversation: []}), do: {:ok, project}

  defp maybe_store_intake_conversation(project, %{intake_conversation: conversation}) do
    if Enum.any?(conversation, &(&1.role == :user)) do
      metadata = %{
        project_id: project.id,
        kind: :project_intake_conversation,
        message_count: length(conversation)
      }

      with {:ok, transcript} <-
             Object.create(
               :markdown,
               "#{project.name} Intake Conversation",
               build_intake_conversation_markdown(project, conversation),
               metadata: metadata
             ),
           {:ok, updated_project} <-
             Object.update_metadata(project.id, %{intake_conversation_id: transcript.id}) do
        {:ok, updated_project}
      end
    else
      {:ok, project}
    end
  end

  defp build_intake_conversation_markdown(project, conversation) do
    header = [
      "# Project Intake Conversation",
      "",
      "Project: #{project.name}",
      "Project ID: #{project.id}"
    ]

    transcript =
      conversation
      |> Enum.map(fn msg ->
        role =
          case msg.role do
            :assistant -> "Guide"
            :user -> "User"
            other -> other |> to_string() |> String.capitalize()
          end

        ["", "## #{role}", msg.content]
      end)

    [header | transcript]
    |> List.flatten()
    |> Enum.join("\n")
    |> String.trim()
  end

  defp delete_intake_conversation(project_id) do
    with {:ok, project} <- Object.get(project_id),
         conversation_id when is_binary(conversation_id) <-
           project.metadata[:intake_conversation_id] do
      Object.delete(conversation_id)
    else
      _ -> :ok
    end
  end

  defp normalize_conversation(messages) when is_list(messages) do
    messages
    |> Enum.map(&normalize_conversation_message/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_conversation(_messages), do: []

  defp normalize_conversation_message(%{role: role, content: content}) do
    normalize_conversation_message(%{"role" => role, "content" => content})
  end

  defp normalize_conversation_message(%{"role" => role, "content" => content}) do
    normalized_content = normalize_text(content)

    if normalized_content == "" do
      nil
    else
      %{
        role: normalize_conversation_role(role),
        content: normalized_content
      }
    end
  end

  defp normalize_conversation_message(_message), do: nil

  defp normalize_conversation_role(role) when role in [:assistant, "assistant"], do: :assistant
  defp normalize_conversation_role(role) when role in [:user, "user"], do: :user
  defp normalize_conversation_role(role) when is_atom(role), do: role

  defp normalize_conversation_role(role) when is_binary(role) do
    case String.downcase(role) do
      "assistant" -> :assistant
      "user" -> :user
      _ -> :unknown
    end
  end

  defp normalize_conversation_role(_role), do: :unknown

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp normalize_text(nil), do: ""
  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(value), do: value |> to_string() |> String.trim()

  defp normalize_paths(nil), do: []

  defp normalize_paths(value) when is_binary(value) do
    value
    |> String.split(["\n", ","], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_paths(values) when is_list(values) do
    values
    |> Enum.map(&normalize_text/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_paths(_value), do: []

  defp normalize_execution_mode(nil), do: :vm
  defp normalize_execution_mode(""), do: :vm
  defp normalize_execution_mode(:vm), do: :vm
  defp normalize_execution_mode(:host), do: :host
  defp normalize_execution_mode("vm"), do: :vm
  defp normalize_execution_mode("host"), do: :host
  defp normalize_execution_mode("root_vm"), do: :host
  defp normalize_execution_mode(_value), do: :invalid

  defp blank_metadata_value?(:default_execution_mode, _value), do: false
  defp blank_metadata_value?(:status, _value), do: false
  defp blank_metadata_value?(_key, nil), do: true
  defp blank_metadata_value?(_key, ""), do: true
  defp blank_metadata_value?(_key, []), do: true
  defp blank_metadata_value?(_key, _value), do: false
end
