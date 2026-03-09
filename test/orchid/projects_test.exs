defmodule Orchid.ProjectsTest do
  use ExUnit.Case, async: false

  alias Orchid.{Goals, Object, Projects}

  setup do
    {:ok, _} = Application.ensure_all_started(:orchid)
    :ok
  end

  test "create stores a structured project brief and kickoff goal" do
    {:ok, template} =
      Object.create(:agent_template, "Planner", "You are a planner.",
        metadata: %{category: "General"}
      )

    attrs = %{
      name: "Decoder Overhaul",
      objective: "Replace the fragile packet decoder with a verified structure-driven flow.",
      success_criteria: "Target packets decode cleanly and the project brief is persisted.",
      background: "Current packet parsing stops early on several captures.",
      constraints: "Do not rewrite the sandbox pipeline.",
      relevant_paths: ["lib/orchid_web/live/agent_live.ex", "lib/orchid/projects.ex"],
      kickoff_goal: "Map the first failing decoder path",
      intake_conversation: [
        %{role: :assistant, content: "What outcome should this project deliver?"},
        %{role: :user, content: "Replace the fragile packet decoder with a verified flow."}
      ],
      default_template_id: template.id,
      default_execution_mode: "host"
    }

    assert {:ok, project} = Projects.create(attrs)

    on_exit(fn ->
      Goals.clear_project(project.id)
      Projects.delete(project.id)
      Object.delete(template.id)
    end)

    assert project.name == "Decoder Overhaul"
    assert project.metadata[:objective] == attrs.objective
    assert project.metadata[:success_criteria] == attrs.success_criteria
    assert project.metadata[:background] == attrs.background
    assert project.metadata[:constraints] == attrs.constraints
    assert project.metadata[:relevant_paths] == attrs.relevant_paths
    assert project.metadata[:kickoff_goal] == attrs.kickoff_goal
    assert project.metadata[:default_template_id] == template.id
    assert project.metadata[:default_execution_mode] == :host
    assert is_binary(project.metadata[:intake_conversation_id])
    assert String.contains?(project.content, "## Objective")
    assert String.contains?(project.content, attrs.objective)
    assert File.dir?(Orchid.Project.files_path(project.id))

    assert {:ok, transcript} = Projects.intake_conversation(project.id)
    assert transcript.metadata[:project_id] == project.id
    assert transcript.metadata[:kind] == :project_intake_conversation
    assert String.contains?(transcript.content, "# Project Intake Conversation")
    assert String.contains?(transcript.content, "Replace the fragile packet decoder")

    goals = Goals.list_for_project(project.id)
    assert length(goals) == 1
    assert hd(goals).name == attrs.kickoff_goal
    assert hd(goals).content == attrs.objective
  end

  test "create validates required fields" do
    assert {:error, errors} =
             Projects.create(%{
               name: "   ",
               objective: "",
               success_criteria: "  "
             })

    assert errors[:name] == "Project name is required."
    assert errors[:objective] == "Objective is required."
    assert errors[:success_criteria] == "Success criteria is required."
  end
end
