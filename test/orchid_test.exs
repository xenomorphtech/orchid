defmodule OrchidTest do
  use ExUnit.Case

  setup do
    # Start the application for each test
    {:ok, _} = Application.ensure_all_started(:orchid)
    :ok
  end

  describe "Object" do
    test "create and read object" do
      {:ok, obj} = Orchid.Object.create(:file, "test.ex", "defmodule Test do\nend")

      assert obj.type == :file
      assert obj.name == "test.ex"
      assert obj.language == "elixir"
      assert obj.content == "defmodule Test do\nend"

      {:ok, fetched} = Orchid.Object.get(obj.id)
      assert fetched.id == obj.id
    end

    test "update object preserves history" do
      {:ok, obj} = Orchid.Object.create(:file, "test.ex", "v1")
      {:ok, updated} = Orchid.Object.update(obj.id, "v2")

      assert updated.content == "v2"
      assert length(updated.versions) == 1
      assert hd(updated.versions).content == "v1"
    end

    test "eval function object" do
      {:ok, obj} = Orchid.Object.create(:function, "add", "1 + 1")
      {:ok, result} = Orchid.Object.eval(obj.id)

      assert result == 2
    end

    test "undo restores previous version" do
      {:ok, obj} = Orchid.Object.create(:file, "test.ex", "original")
      {:ok, _} = Orchid.Object.update(obj.id, "modified")
      {:ok, restored} = Orchid.Object.undo(obj.id)

      assert restored.content == "original"
    end
  end

  describe "Tools" do
    test "list_tools returns all tools" do
      tools = Orchid.Tool.list_tools()

      assert length(tools) >= 15
      assert Enum.any?(tools, &(&1.name == "shell"))
      assert Enum.any?(tools, &(&1.name == "sandbox_reset"))
      assert Enum.any?(tools, &(&1.name == "eval"))
      refute Enum.any?(tools, &(&1.name == "project_list"))
      refute Enum.any?(tools, &(&1.name == "project_create"))

      scoped = Orchid.Tool.list_tools(["project_list", "project_create"])
      assert Enum.any?(scoped, &(&1.name == "project_list"))
      assert Enum.any?(scoped, &(&1.name == "project_create"))
    end

    test "execute shell command" do
      {:ok, result} = Orchid.Tool.execute("shell", %{"command" => "echo hello"}, %{})
      assert String.trim(result) == "hello"
    end

    test "execute eval" do
      {:ok, result} = Orchid.Tool.execute("eval", %{"code" => "2 * 3"}, %{})
      assert result == "6"
    end

    test "object_write rejects invalid candidate plan JSON" do
      {:ok, obj} = Orchid.Object.create(:artifact, "candidate_plan_alpha", "{\"goal\":\"x\"}")

      assert {:error, msg} =
               Orchid.Tools.ObjectWrite.execute(
                 %{"id" => obj.id, "content" => "{\"goal\":\"only goal\"}"},
                 %{}
               )

      assert String.contains?(msg, "candidate_plan_* field")
    end

    test "object_write accepts valid candidate plan JSON" do
      {:ok, obj} = Orchid.Object.create(:artifact, "candidate_plan_beta", "{\"goal\":\"x\"}")

      content =
        Jason.encode!(%{
          "goal" => "Implement migration",
          "strategy" => "Ecto migration",
          "steps" => ["Inspect current schema", "Write migration", "Run migration"],
          "checks" => ["mix ecto.migrate exits 0"],
          "risks" => ["Missing DB_URL"]
        })

      assert {:ok, _} =
               Orchid.Tools.ObjectWrite.execute(%{"id" => obj.id, "content" => content}, %{})
    end

    test "project_create requires a structured payload" do
      assert {:error, message} =
               Orchid.Tools.ProjectCreate.execute(%{"name" => "Only Name"}, %{})

      assert String.contains?(message, "objective")
      assert String.contains?(message, "success_criteria")
    end

    test "project_create creates a project workspace" do
      {:ok, template} =
        Orchid.Object.create(:agent_template, "Builder", "You build things.", metadata: %{})

      assert {:ok, result} =
               Orchid.Tools.ProjectCreate.execute(
                 %{
                   "name" => "Workspace Contract",
                   "objective" => "Create a project with a durable brief.",
                   "success_criteria" => "Workspace exists and project is queryable.",
                   "default_template_id" => template.id,
                   "default_execution_mode" => "vm"
                 },
                 %{}
               )

      project =
        Orchid.Object.list_projects()
        |> Enum.find(fn obj -> obj.name == "Workspace Contract" end)

      on_exit(fn ->
        if project do
          Orchid.Goals.clear_project(project.id)
          Orchid.Projects.delete(project.id)
        end

        Orchid.Object.delete(template.id)
      end)

      assert project
      assert String.contains?(result, project.id)
      assert File.dir?(Orchid.Project.files_path(project.id))
    end
  end

  describe "Agent" do
    test "create agent" do
      {:ok, agent_id} = Orchid.Agent.create()
      assert is_binary(agent_id)

      agents = Orchid.Agent.list()
      assert agent_id in agents
    end

    test "get agent state" do
      {:ok, agent_id} = Orchid.Agent.create()
      {:ok, state} = Orchid.Agent.get_state(agent_id)

      assert state.id == agent_id
      assert state.status == :idle
      assert state.messages == []
    end

    test "attach objects to agent" do
      {:ok, obj} = Orchid.Object.create(:file, "test.ex", "code")
      {:ok, agent_id} = Orchid.Agent.create()

      :ok = Orchid.Agent.attach(agent_id, obj.id)

      {:ok, state} = Orchid.Agent.get_state(agent_id)
      assert obj.id in state.objects
    end

    test "remember and recall" do
      {:ok, agent_id} = Orchid.Agent.create()

      :ok = Orchid.Agent.remember(agent_id, "key", "value")
      assert Orchid.Agent.recall(agent_id, "key") == "value"
    end

    test "stop agent removes it from list" do
      {:ok, agent_id} = Orchid.Agent.create()
      :ok = Orchid.Agent.stop(agent_id)

      agents = Orchid.Agent.list()
      refute agent_id in agents
    end

    test "stopped agent cannot republish stale state" do
      {:ok, agent_id} = Orchid.Agent.create()
      {:ok, state} = Orchid.Agent.get_state(agent_id)

      :ok = Orchid.Agent.stop(agent_id)
      Orchid.Agent.publish_state(state)

      assert {:error, :not_found} = Orchid.Agent.get_state(agent_id)
    end

    test "stream on stopped agent fails fast" do
      {:ok, agent_id} = Orchid.Agent.create()
      :ok = Orchid.Agent.stop(agent_id)

      assert {:error, :not_found} =
               Orchid.Agent.stream(agent_id, "hello", fn _chunk -> :ok end)
    end

    test "worker down clears stale thinking status" do
      {:ok, agent_id} = Orchid.Agent.create()
      [{agent_pid, _}] = Registry.lookup(Orchid.Registry, agent_id)
      worker_pid = spawn(fn -> Process.sleep(:infinity) end)
      worker_ref = make_ref()

      send(agent_pid, {:update_status, :thinking})

      :ets.insert(
        :orchid_agent_runtime,
        {agent_id, %{lifecycle: :running, worker_pid: worker_pid, worker_ref: worker_ref}}
      )

      send(agent_pid, {:DOWN, worker_ref, :process, worker_pid, :boom})
      Process.sleep(50)

      {:ok, state} = Orchid.Agent.get_state(agent_id)
      assert state.status == :idle

      assert [{^agent_id, runtime}] = :ets.lookup(:orchid_agent_runtime, agent_id)
      assert runtime.worker_pid == nil
      assert runtime.worker_ref == nil

      Process.exit(worker_pid, :kill)
    end
  end

  describe "Goals" do
    test "clear_project deletes goals and stops project agents" do
      {:ok, project} =
        Orchid.Object.create(:project, "clear-project-test", "", metadata: %{status: :active})

      {:ok, _goal} = Orchid.Goals.create("goal-a", "", project.id)
      {:ok, _goal2} = Orchid.Goals.create("goal-b", "", project.id)

      {:ok, planner_id} =
        Orchid.Agent.create(%{
          project_id: project.id,
          execution_mode: :host,
          provider: :codex,
          use_orchid_tools: true
        })

      {:ok, worker_id} =
        Orchid.Agent.create(%{
          project_id: project.id,
          execution_mode: :host,
          provider: :cli
        })

      assert planner_id in Orchid.Agent.list()
      assert worker_id in Orchid.Agent.list()
      assert length(Orchid.Goals.list_for_project(project.id)) == 2

      :ok = Orchid.Goals.clear_project(project.id)

      assert Orchid.Goals.list_for_project(project.id) == []
      refute planner_id in Orchid.Agent.list()
      refute worker_id in Orchid.Agent.list()
    end
  end
end
