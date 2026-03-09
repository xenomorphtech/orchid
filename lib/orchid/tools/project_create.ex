defmodule Orchid.Tools.ProjectCreate do
  @moduledoc "Create Orchid projects"
  @behaviour Orchid.Tool

  @impl true
  def name, do: "project_create"

  @impl true
  def description, do: "Create a new Orchid project brief and return its workspace path"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        name: %{
          type: "string",
          description: "Project name"
        },
        objective: %{
          type: "string",
          description: "What this project is trying to accomplish"
        },
        success_criteria: %{
          type: "string",
          description: "Definition of done for the project"
        },
        background: %{
          type: "string",
          description: "Optional background context"
        },
        constraints: %{
          type: "string",
          description: "Optional constraints or non-goals"
        },
        relevant_paths: %{
          type: "array",
          items: %{type: "string"},
          description: "Optional relevant files, directories, or assets"
        },
        kickoff_goal: %{
          type: "string",
          description: "Optional first goal to create immediately"
        },
        default_template_id: %{
          type: "string",
          description: "Optional default agent template ID for this project"
        },
        default_execution_mode: %{
          type: "string",
          enum: ["vm", "host"],
          description: "Optional default execution mode for new agents in this project"
        }
      },
      required: ["name", "objective", "success_criteria"]
    }
  end

  @impl true
  def execute(args, _context) when is_map(args) do
    case Orchid.Projects.create(args) do
      {:ok, project} ->
        {:ok,
         "Created project #{project.name} (#{project.id})\nfiles: #{Orchid.Project.files_path(project.id)}"}

      {:error, errors} when is_map(errors) ->
        {:error, format_errors(errors)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def execute(_args, _context) do
    {:error, "name, objective, and success_criteria are required"}
  end

  defp format_errors(errors) do
    errors
    |> Enum.map(fn {field, message} -> "#{field}: #{message}" end)
    |> Enum.join("\n")
  end
end
