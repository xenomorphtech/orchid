defmodule Orchid.Tools.AgentSpawn do
  @moduledoc "Spawn an agent from a template and assign it a goal"
  @behaviour Orchid.Tool

  alias Orchid.{Object, Goals}
  alias Orchid.Tools.GoalHelpers

  @impl true
  def name, do: "agent_spawn"

  @impl true
  def description,
    do:
      "Spawn a new agent from a template and optionally assign it a goal. Returns the new agent ID."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        template: %{
          type: "string",
          description: "Template name or ID to use for the new agent"
        },
        goal_id: %{
          type: "string",
          description: "Goal ID or name to assign to the new agent"
        },
        message: %{
          type: "string",
          description: "Initial message to send to the agent after spawning"
        }
      },
      required: ["template"]
    }
  end

  @impl true
  def execute(%{"template" => template_ref} = args, %{agent_state: state}) do
    project_id = state.project_id

    case resolve_template(template_ref) do
      nil ->
        templates =
          Object.list_agent_templates()
          |> Enum.map(fn t -> "- #{t.name} (#{t.id})" end)
          |> Enum.join("\n")

        {:error, "Template not found: #{template_ref}\nAvailable templates:\n#{templates}"}

      template ->
        config = %{
          provider: template.metadata[:provider] || :cli,
          system_prompt: template.content,
          template_id: template.id,
          project_id: project_id,
          creator_agent_id: state.id,
          execution_mode: Map.get(state, :execution_mode) || :vm
        }

        # Only set model if template specifies one — providers have their own defaults
        config =
          if template.metadata[:model],
            do: Map.put(config, :model, template.metadata[:model]),
            else: config

        config =
          if template.metadata[:model_reasoning_effort],
            do:
              Map.put(config, :model_reasoning_effort, template.metadata[:model_reasoning_effort]),
            else: config

        config =
          if is_list(template.metadata[:allowed_tools]),
            do: Map.put(config, :allowed_tools, template.metadata[:allowed_tools]),
            else: config

        # Pass through extra template metadata flags
        config =
          if template.metadata[:use_orchid_tools],
            do: Map.put(config, :use_orchid_tools, true),
            else: config

        case Orchid.Agent.create(config) do
          {:ok, agent_id} ->
            result = "Spawned agent #{agent_id} (template: #{template.name})"

            # Assign goal if provided
            result =
              case resolve_goal(args["goal_id"], project_id) do
                nil ->
                  result

                goal_id ->
                  Goals.assign_to_agent(goal_id, agent_id)
                  result <> "\nAssigned goal #{goal_id}"
              end

            # Send initial message if provided (and no goal — goal assignment already sends one)
            result =
              if args["message"] && is_nil(args["goal_id"]) do
                Task.start(fn ->
                  Orchid.Agent.stream(agent_id, args["message"], fn _chunk -> :ok end)
                end)

                result <> "\nSent initial message"
              else
                result
              end

            {:ok, result}

          {:error, reason} ->
            {:error, "Failed to spawn agent: #{inspect(reason)}"}
        end
    end
  end

  def execute(_args, _context) do
    {:error, "No agent context available"}
  end

  defp resolve_template(ref) do
    templates = Object.list_agent_templates()

    # Try by ID first, then by name (case-insensitive)
    Enum.find(templates, fn t -> t.id == ref end) ||
      Enum.find(templates, fn t ->
        String.downcase(t.name) == String.downcase(ref)
      end)
  end

  defp resolve_goal(nil, _project_id), do: nil
  defp resolve_goal(ref, project_id), do: GoalHelpers.resolve_goal_ref(ref, project_id)
end
