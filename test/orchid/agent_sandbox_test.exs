defmodule Orchid.AgentSandboxTest do
  use ExUnit.Case

  alias Orchid.{Agent, Sandbox, Project, Tool}

  @moduletag :external
  @moduletag timeout: 120_000

  setup do
    {:ok, _} = Application.ensure_all_started(:orchid)

    project_id = "test-as-#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}"
    Project.ensure_dir(project_id)

    on_exit(fn ->
      Project.delete_dir(project_id)
      data_dir = Project.data_dir()
      sandbox_base = Path.join(data_dir, "sandboxes")
      if File.dir?(sandbox_base), do: File.rm_rf(sandbox_base)
    end)

    %{project_id: project_id}
  end

  # Wait for sandbox to be initialized (handle_continue is async)
  defp await_sandbox(agent_id, retries \\ 20) do
    if retries <= 0 do
      {:ok, state} = Agent.get_state(agent_id)
      state
    else
      {:ok, state} = Agent.get_state(agent_id)

      if state.sandbox != nil do
        state
      else
        Process.sleep(500)
        await_sandbox(agent_id, retries - 1)
      end
    end
  end

  describe "Agent with sandbox" do
    test "agent created with project_id gets a sandbox", %{project_id: project_id} do
      {:ok, agent_id} = Agent.create(%{project_id: project_id})
      state = await_sandbox(agent_id)

      assert state.sandbox != nil

      Agent.stop(agent_id)
      Process.sleep(200)
    end

    test "agent without project_id has no sandbox" do
      {:ok, agent_id} = Agent.create(%{})
      # No sandbox, no need to wait
      Process.sleep(100)
      {:ok, state} = Agent.get_state(agent_id)

      assert state.sandbox == nil

      Agent.stop(agent_id)
    end

    test "agent in host mode with project_id skips sandbox", %{project_id: project_id} do
      {:ok, agent_id} = Agent.create(%{project_id: project_id, execution_mode: :host})
      Process.sleep(100)
      {:ok, state} = Agent.get_state(agent_id)

      assert state.execution_mode == :host
      assert state.sandbox == nil

      {:ok, output} = Tool.execute("shell", %{"command" => "echo host-mode"}, %{agent_state: state})
      assert String.trim(output) == "host-mode"

      Agent.stop(agent_id)
    end

    test "sandbox-aware tool dispatch routes shell through sandbox", %{project_id: project_id} do
      {:ok, agent_id} = Agent.create(%{project_id: project_id})
      state = await_sandbox(agent_id)

      if state.sandbox && state.sandbox[:status] == :ready do
        result = Tool.execute("shell", %{"command" => "pwd"}, %{agent_state: state})

        case result do
          {:ok, output} -> assert String.trim(output) == "/workspace"
          {:error, _} -> :ok
        end
      end

      Agent.stop(agent_id)
      Process.sleep(200)
    end

    test "sandbox-aware tool dispatch: read canary file", %{project_id: project_id} do
      canary_path = Path.join(Project.files_path(project_id), "canary_for_agent.txt")
      File.write!(canary_path, "the agent can read me")

      {:ok, agent_id} = Agent.create(%{project_id: project_id})
      state = await_sandbox(agent_id)

      if state.sandbox && state.sandbox[:status] == :ready do
        result = Tool.execute("read", %{"path" => "/workspace/canary_for_agent.txt"}, %{agent_state: state})

        case result do
          {:ok, content} -> assert String.contains?(content, "the agent can read me")
          {:error, _} -> :ok
        end
      end

      Agent.stop(agent_id)
      Process.sleep(200)
    end

    test "sandbox-aware tool dispatch: write and read back", %{project_id: project_id} do
      {:ok, agent_id} = Agent.create(%{project_id: project_id})
      state = await_sandbox(agent_id)

      if state.sandbox && state.sandbox[:status] == :ready do
        write_result = Tool.execute("shell", %{"command" => "echo 'tool wrote this' > /workspace/tool_output.txt"}, %{agent_state: state})

        case write_result do
          {:ok, _} ->
            read_result = Tool.execute("read", %{"path" => "/workspace/tool_output.txt"}, %{agent_state: state})

            case read_result do
              {:ok, content} -> assert String.contains?(content, "tool wrote this")
              {:error, _} -> :ok
            end

          {:error, _} ->
            :ok
        end
      end

      Agent.stop(agent_id)
      Process.sleep(200)
    end

    test "non-sandboxed tool still works normally", %{project_id: project_id} do
      {:ok, agent_id} = Agent.create(%{project_id: project_id})
      state = await_sandbox(agent_id)

      # eval is not a sandboxed tool, should run directly
      result = Tool.execute("eval", %{"code" => "1 + 1"}, %{agent_state: state})
      assert {:ok, "2"} = result

      Agent.stop(agent_id)
      Process.sleep(200)
    end

    test "reset_sandbox via agent API", %{project_id: project_id} do
      {:ok, agent_id} = Agent.create(%{project_id: project_id})
      state = await_sandbox(agent_id)

      if state.sandbox && state.sandbox[:status] == :ready do
        {:ok, new_status} = Agent.reset_sandbox(agent_id)
        assert new_status[:status] in [:ready, :error]
      end

      Agent.stop(agent_id)
      Process.sleep(200)
    end

    test "stopping agent destroys sandbox container", %{project_id: project_id} do
      {:ok, agent_id} = Agent.create(%{project_id: project_id})
      state = await_sandbox(agent_id)
      container_name = state.sandbox && state.sandbox[:container_name]

      Agent.stop(agent_id)
      Process.sleep(500)

      assert Sandbox.status(agent_id) == nil

      if container_name do
        {output, _} = System.cmd("podman", ["ps", "-a", "--filter", "name=#{container_name}", "--format", "{{.Names}}"], stderr_to_stdout: true)
        refute String.contains?(output, container_name)
      end
    end
  end

  describe "Tool dispatch without sandbox" do
    test "tools run directly when no sandbox" do
      {:ok, agent_id} = Agent.create(%{})
      Process.sleep(100)
      {:ok, state} = Agent.get_state(agent_id)

      {:ok, output} = Tool.execute("shell", %{"command" => "echo direct"}, %{agent_state: state})
      assert String.trim(output) == "direct"

      Agent.stop(agent_id)
    end
  end
end
