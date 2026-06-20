defmodule Orchid.SandboxTest do
  use ExUnit.Case

  alias Orchid.{Sandbox, Project}

  @moduletag :external
  @moduletag timeout: 120_000

  setup do
    {:ok, _} = Application.ensure_all_started(:orchid)

    project_id = "test-sbx-#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}"
    agent_id = "agent-#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}"

    Project.ensure_dir(project_id)

    on_exit(fn ->
      Sandbox.stop(agent_id)
      # Small delay for container cleanup
      Process.sleep(200)
      Project.delete_dir(project_id)
      data_dir = Project.data_dir()
      File.rm_rf(Path.join([data_dir, "sandboxes", agent_id]))
    end)

    %{project_id: project_id, agent_id: agent_id}
  end

  describe "Sandbox lifecycle" do
    test "start and get status", %{agent_id: agent_id, project_id: project_id} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Orchid.AgentSupervisor,
          {Sandbox, {agent_id, project_id}}
        )

      status = Sandbox.status(agent_id)
      assert status != nil
      assert status.status in [:ready, :error]
      assert status.container_name == "orchid-#{agent_id}"
    end

    test "stop removes sandbox from registry", %{agent_id: agent_id, project_id: project_id} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Orchid.AgentSupervisor,
          {Sandbox, {agent_id, project_id}}
        )

      assert Sandbox.status(agent_id) != nil

      Sandbox.stop(agent_id)
      Process.sleep(100)

      assert Sandbox.status(agent_id) == nil
    end
  end

  describe "Sandbox exec" do
    test "runs a command in the container", %{agent_id: agent_id, project_id: project_id} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Orchid.AgentSupervisor,
          {Sandbox, {agent_id, project_id}}
        )

      status = Sandbox.status(agent_id)

      if status.status == :ready do
        {:ok, output} = Sandbox.exec(agent_id, "echo hello")
        assert String.trim(output) == "hello"
      end
    end

    test "sees /workspace directory", %{agent_id: agent_id, project_id: project_id} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Orchid.AgentSupervisor,
          {Sandbox, {agent_id, project_id}}
        )

      status = Sandbox.status(agent_id)

      if status.status == :ready do
        {:ok, output} = Sandbox.exec(agent_id, "pwd")
        assert String.trim(output) == "/workspace"
      end
    end
  end

  describe "Sandbox file operations with canary" do
    test "write file goes to upper layer, not lower", %{agent_id: agent_id, project_id: project_id} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Orchid.AgentSupervisor,
          {Sandbox, {agent_id, project_id}}
        )

      status = Sandbox.status(agent_id)

      if status.status == :ready do
        # Write a file through the sandbox
        {:ok, _} = Sandbox.write_file(agent_id, "/workspace/agent_output.txt", "agent was here")

        # Read it back through the sandbox
        {:ok, content} = Sandbox.read_file(agent_id, "/workspace/agent_output.txt")
        assert String.trim(content) == "agent was here"

        # Verify it's in the upper layer on the host
        data_dir = Project.data_dir()
        upper_file = Path.join([data_dir, "sandboxes", agent_id, "upper", "agent_output.txt"])
        assert File.exists?(upper_file)
        assert File.read!(upper_file) == "agent was here"

        # Verify it's NOT in the project's lower dir
        lower_file = Path.join(Project.files_path(project_id), "agent_output.txt")
        refute File.exists?(lower_file)
      end
    end

    test "canary: project file is readable by agent", %{agent_id: agent_id, project_id: project_id} do
      # Place a canary file in the project directory
      canary_path = Path.join(Project.files_path(project_id), "canary.txt")
      File.write!(canary_path, "canary says hello")

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Orchid.AgentSupervisor,
          {Sandbox, {agent_id, project_id}}
        )

      status = Sandbox.status(agent_id)

      if status.status == :ready do
        case status.overlay_method do
          :overlay ->
            # With real overlay, file should be visible at /workspace/canary.txt
            {:ok, content} = Sandbox.read_file(agent_id, "/workspace/canary.txt")
            assert String.trim(content) == "canary says hello"

          :union ->
            # Union mode reads from lower via the Elixir-side overlay
            {:ok, content} = Sandbox.read_file(agent_id, "/workspace/canary.txt")
            assert String.trim(content) == "canary says hello"
        end
      end
    end

    test "canary: second agent cannot see first agent's files", %{project_id: project_id} do
      agent_a = "agent-a-#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}"
      agent_b = "agent-b-#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}"

      {:ok, _} =
        DynamicSupervisor.start_child(
          Orchid.AgentSupervisor,
          {Sandbox, {agent_a, project_id}}
        )

      {:ok, _} =
        DynamicSupervisor.start_child(
          Orchid.AgentSupervisor,
          {Sandbox, {agent_b, project_id}}
        )

      status_a = Sandbox.status(agent_a)
      status_b = Sandbox.status(agent_b)

      if status_a.status == :ready and status_b.status == :ready do
        # Agent A writes a file
        {:ok, _} = Sandbox.write_file(agent_a, "/workspace/secret_a.txt", "only for A")

        # Agent A can read it
        {:ok, content} = Sandbox.read_file(agent_a, "/workspace/secret_a.txt")
        assert String.trim(content) == "only for A"

        # Agent B should NOT see agent A's file
        result = Sandbox.read_file(agent_b, "/workspace/secret_a.txt")

        case result do
          {:ok, output} ->
            # If using overlay method, podman exec cat will fail with non-zero (returned as ok with exit code)
            assert String.contains?(output, "Exit code") or String.contains?(output, "No such file")

          {:error, _} ->
            # Union mode returns error
            :ok
        end
      end

      # Cleanup
      Sandbox.stop(agent_a)
      Sandbox.stop(agent_b)
      Process.sleep(200)
      data_dir = Project.data_dir()
      File.rm_rf(Path.join([data_dir, "sandboxes", agent_a]))
      File.rm_rf(Path.join([data_dir, "sandboxes", agent_b]))
    end

    test "both agents can read project base files", %{project_id: project_id} do
      # Place a shared file
      shared_path = Path.join(Project.files_path(project_id), "shared.txt")
      File.write!(shared_path, "shared content")

      agent_a = "agent-shared-a-#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}"
      agent_b = "agent-shared-b-#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}"

      {:ok, _} =
        DynamicSupervisor.start_child(
          Orchid.AgentSupervisor,
          {Sandbox, {agent_a, project_id}}
        )

      {:ok, _} =
        DynamicSupervisor.start_child(
          Orchid.AgentSupervisor,
          {Sandbox, {agent_b, project_id}}
        )

      status_a = Sandbox.status(agent_a)
      status_b = Sandbox.status(agent_b)

      if status_a.status == :ready and status_b.status == :ready do
        {:ok, content_a} = Sandbox.read_file(agent_a, "/workspace/shared.txt")
        {:ok, content_b} = Sandbox.read_file(agent_b, "/workspace/shared.txt")

        assert String.trim(content_a) == "shared content"
        assert String.trim(content_b) == "shared content"
      end

      # Cleanup
      Sandbox.stop(agent_a)
      Sandbox.stop(agent_b)
      Process.sleep(200)
      data_dir = Project.data_dir()
      File.rm_rf(Path.join([data_dir, "sandboxes", agent_a]))
      File.rm_rf(Path.join([data_dir, "sandboxes", agent_b]))
    end
  end

  describe "Sandbox reset" do
    test "reset recreates container", %{agent_id: agent_id, project_id: project_id} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Orchid.AgentSupervisor,
          {Sandbox, {agent_id, project_id}}
        )

      status = Sandbox.status(agent_id)

      if status.status == :ready do
        # Write a file first
        {:ok, _} = Sandbox.write_file(agent_id, "/workspace/before_reset.txt", "persists")

        # Reset
        {:ok, new_status} = Sandbox.reset(agent_id)
        assert new_status.status in [:ready, :error]

        if new_status.status == :ready do
          # Upper layer data should still be there (reset preserves overlay upper)
          data_dir = Project.data_dir()
          upper_file = Path.join([data_dir, "sandboxes", agent_id, "upper", "before_reset.txt"])
          assert File.exists?(upper_file)
        end
      end
    end
  end

  describe "Sandbox edit_file" do
    test "edit replaces old_string with new_string", %{agent_id: agent_id, project_id: project_id} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Orchid.AgentSupervisor,
          {Sandbox, {agent_id, project_id}}
        )

      status = Sandbox.status(agent_id)

      if status.status == :ready do
        # Write a file
        {:ok, _} = Sandbox.write_file(agent_id, "/workspace/editable.txt", "hello world")

        # Edit it
        {:ok, _} = Sandbox.edit_file(agent_id, "/workspace/editable.txt", "world", "elixir")

        # Read back
        {:ok, content} = Sandbox.read_file(agent_id, "/workspace/editable.txt")
        assert String.trim(content) == "hello elixir"
      end
    end
  end

  describe "Sandbox list_files" do
    test "lists files in workspace", %{agent_id: agent_id, project_id: project_id} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Orchid.AgentSupervisor,
          {Sandbox, {agent_id, project_id}}
        )

      status = Sandbox.status(agent_id)

      if status.status == :ready do
        # Write some files
        {:ok, _} = Sandbox.write_file(agent_id, "/workspace/file1.txt", "content1")
        {:ok, _} = Sandbox.write_file(agent_id, "/workspace/file2.txt", "content2")

        {:ok, listing} = Sandbox.list_files(agent_id, "/workspace")
        assert String.contains?(listing, "file1.txt")
        assert String.contains?(listing, "file2.txt")
      end
    end
  end
end
