defmodule OrchidWeb.AgentLiveTest do
  use ExUnit.Case, async: false

  alias Orchid.{Goals, Object, Projects}
  alias Phoenix.LiveView.Socket

  defmodule ProjectIntakeMockBackend do
    def reply(_messages, form, user_input, _current_focus) do
      {:ok,
       %{
         assistant_message: "What should count as done for this project?",
         candidate_fields: %{
           "name" => if(form.name == "", do: "Migration Hardening", else: form.name),
           "objective" => "Reduce migration risk across the release rollout.",
           "background" => user_input
         }
       }}
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:orchid)
    :ok
  end

  test "chat submit uses the current form value immediately" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        input: "",
        streaming: false,
        current_agent: "nonexistent-agent",
        messages: [],
        pending_message: nil,
        stream_content: "",
        retry_count: 0,
        message_fingerprint: nil
      }
    }

    assert {:noreply, updated_socket} =
             OrchidWeb.AgentLive.handle_event(
               "send_message",
               %{"input" => "hello on first submit"},
               socket
             )

    assert updated_socket.assigns.messages == [
             %{role: :user, content: "hello on first submit", tool_calls: nil}
           ]

    assert updated_socket.assigns.pending_message == "hello on first submit"
    assert updated_socket.assigns.input == ""
    assert updated_socket.assigns.streaming == true
  end

  test "show_new_project opens the right-pane flow and stores the return context" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        current_agent: "agent-123",
        current_project: "project-123",
        project_workspace_mode: :project,
        project_tab: :goals,
        selected_template: nil,
        agent_execution_mode: :vm
      }
    }

    assert {:noreply, updated_socket} =
             OrchidWeb.AgentLive.handle_event("show_new_project", %{}, socket)

    assert updated_socket.assigns.project_workspace_mode == :new_project
    assert updated_socket.assigns.new_project_return_project == "project-123"
    assert updated_socket.assigns.new_project_return_tab == :goals
    assert match?({:live, :patch, %{to: "/?new_project=1"}}, updated_socket.redirected)
  end

  test "create_project reports validation errors in the structured form" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        current_agent: nil,
        selected_template: nil,
        agent_execution_mode: :vm,
        project_workspace_mode: :new_project,
        current_project: nil,
        project_tab: :overview,
        new_project_form: %{
          name: "",
          objective: "",
          success_criteria: "",
          background: "",
          constraints: "",
          relevant_paths_text: "",
          kickoff_goal: "",
          default_template_id: nil,
          default_execution_mode: :vm
        },
        new_project_errors: %{},
        new_project_chat_messages: [
          %{role: :assistant, content: "What outcome should this project deliver?"},
          %{role: :user, content: "Ship the right-pane project flow."}
        ],
        new_project_chat_input: "",
        new_project_chat_running: false,
        new_project_chat_request_id: nil,
        new_project_ready_to_submit: false,
        new_project_missing_fields: [:name, :objective, :success_criteria],
        new_project_chat_focus: :objective,
        sandbox_statuses: %{}
      }
    }

    assert {:noreply, updated_socket} =
             OrchidWeb.AgentLive.handle_event(
               "create_project",
               %{"project" => %{"name" => "Only Name"}},
               socket
             )

    assert updated_socket.assigns.project_workspace_mode == :new_project
    assert updated_socket.assigns.new_project_form.name == "Only Name"
    assert updated_socket.assigns.new_project_errors[:objective] == "Objective is required."

    assert updated_socket.assigns.new_project_errors[:success_criteria] ==
             "Success criteria is required."
  end

  test "create_project creates the project, selects it, and creates the kickoff goal" do
    {:ok, template} =
      Object.create(:agent_template, "Executor", "You execute.", metadata: %{category: "General"})

    socket = %Socket{
      assigns: %{
        __changed__: %{},
        current_agent: nil,
        selected_template: template.id,
        agent_execution_mode: :vm,
        project_workspace_mode: :new_project,
        current_project: nil,
        project_tab: :overview,
        new_project_form: %{
          name: "",
          objective: "",
          success_criteria: "",
          background: "",
          constraints: "",
          relevant_paths_text: "",
          kickoff_goal: "",
          default_template_id: template.id,
          default_execution_mode: :host
        },
        new_project_errors: %{},
        new_project_chat_messages: [
          %{role: :assistant, content: "What outcome should this project deliver?"},
          %{role: :user, content: "Ship the right-pane project flow."}
        ],
        new_project_chat_input: "",
        new_project_chat_running: false,
        new_project_chat_request_id: nil,
        new_project_ready_to_submit: false,
        new_project_missing_fields: [:name, :objective, :success_criteria],
        new_project_chat_focus: :objective,
        new_project_return_project: nil,
        new_project_return_tab: :overview,
        projects: [],
        sandbox_statuses: %{}
      }
    }

    assert {:noreply, updated_socket} =
             OrchidWeb.AgentLive.handle_event(
               "create_project",
               %{
                 "project" => %{
                   "name" => "UI Flow Project",
                   "objective" => "Ship the right-pane project flow.",
                   "success_criteria" => "The project brief is persisted and visible.",
                   "kickoff_goal" => "Write the structured project contract",
                   "default_template_id" => template.id,
                   "default_execution_mode" => "host"
                 }
               },
               socket
             )

    project_id = updated_socket.assigns.current_project

    on_exit(fn ->
      Goals.clear_project(project_id)
      Projects.delete(project_id)
      Object.delete(template.id)
    end)

    assert updated_socket.assigns.project_workspace_mode == :project
    assert updated_socket.assigns.project_tab == :overview
    assert updated_socket.assigns.selected_template == template.id
    assert updated_socket.assigns.agent_execution_mode == :host
    assert match?({:live, :patch, %{to: "/"}}, updated_socket.redirected)

    assert {:ok, project} = Object.get(project_id)
    assert project.metadata[:objective] == "Ship the right-pane project flow."
    assert is_binary(project.metadata[:intake_conversation_id])
    assert {:ok, transcript} = Projects.intake_conversation(project_id)
    assert String.contains?(transcript.content, "Ship the right-pane project flow.")
    assert length(Goals.list_for_project(project_id)) == 1
  end

  test "new project chat updates candidate fields asynchronously" do
    Application.put_env(:orchid, :project_intake_backend, ProjectIntakeMockBackend)

    on_exit(fn ->
      Application.delete_env(:orchid, :project_intake_backend)
    end)

    socket = %Socket{
      assigns: %{
        __changed__: %{},
        new_project_form: %{
          name: "",
          objective: "",
          success_criteria: "",
          background: "",
          constraints: "",
          relevant_paths_text: "",
          kickoff_goal: "",
          default_template_id: nil,
          default_execution_mode: :vm
        },
        new_project_chat_messages: [
          %{role: :assistant, content: "What outcome should this project deliver?"}
        ],
        new_project_chat_input: "",
        new_project_chat_running: false,
        new_project_chat_request_id: nil,
        new_project_chat_focus: :objective,
        new_project_ready_to_submit: false,
        new_project_missing_fields: [:name, :objective, :success_criteria]
      }
    }

    assert {:noreply, updated_socket} =
             OrchidWeb.AgentLive.handle_event(
               "send_new_project_chat",
               %{"input" => "We need safer migrations for the next release."},
               socket
             )

    assert updated_socket.assigns.new_project_chat_running

    assert List.last(updated_socket.assigns.new_project_chat_messages) == %{
             role: :user,
             content: "We need safer migrations for the next release."
           }

    request_id = updated_socket.assigns.new_project_chat_request_id

    assert_receive {:new_project_chat_reply, ^request_id, _, {:ok, reply}}

    assert {:noreply, final_socket} =
             OrchidWeb.AgentLive.handle_info(
               {:new_project_chat_reply, request_id, "ignored", {:ok, reply}},
               updated_socket
             )

    assert final_socket.assigns.new_project_chat_running == false
    assert final_socket.assigns.new_project_form.name == "Migration Hardening"

    assert final_socket.assigns.new_project_form.objective ==
             "Reduce migration risk across the release rollout."

    assert final_socket.assigns.new_project_form.background ==
             "We need safer migrations for the next release."

    assert final_socket.assigns.new_project_chat_focus == :success_criteria
  end

  test "new project chat reply preserves template defaults on partial candidate updates" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        new_project_form: %{
          name: "",
          objective: "",
          success_criteria: "",
          background: "",
          constraints: "",
          relevant_paths_text: "",
          kickoff_goal: "",
          default_template_id: "template-123",
          default_execution_mode: :host
        },
        new_project_chat_messages: [
          %{role: :assistant, content: "What outcome should this project deliver?"},
          %{role: :user, content: "We need safer migrations for the next release."}
        ],
        new_project_chat_running: true,
        new_project_chat_request_id: :request_1
      }
    }

    reply = %{
      assistant_message: "What should count as done for this project?",
      candidate_fields: %{
        name: "Migration Hardening",
        objective: "Reduce migration risk across the release rollout.",
        background: "We need safer migrations for the next release.",
        constraints: "",
        success_criteria: "",
        relevant_paths_text: "",
        kickoff_goal: ""
      }
    }

    assert {:noreply, final_socket} =
             OrchidWeb.AgentLive.handle_info(
               {:new_project_chat_reply, :request_1, "ignored", {:ok, reply}},
               socket
             )

    assert final_socket.assigns.new_project_form.default_template_id == "template-123"
    assert final_socket.assigns.new_project_form.default_execution_mode == :host
    assert final_socket.assigns.new_project_form.name == "Migration Hardening"
  end
end
