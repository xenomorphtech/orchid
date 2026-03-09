defmodule Orchid.AgentSpawnTest do
  use ExUnit.Case

  setup do
    {:ok, _} = Application.ensure_all_started(:orchid)

    {:ok, template} =
      Orchid.Object.create(
        :agent_template,
        "agent-spawn-test-#{System.unique_integer([:positive])}",
        "You are a no-op test agent.",
        metadata: %{provider: :cli}
      )

    on_exit(fn ->
      Orchid.Object.delete(template.id)
    end)

    %{template: template}
  end

  test "spawns with MCP-style minimal context that omits execution_mode", %{template: template} do
    assert {:ok, result} =
             Orchid.Tools.AgentSpawn.execute(
               %{"template" => template.id},
               %{agent_state: %{id: "creator-agent", project_id: nil}}
             )

    [_, agent_id] = Regex.run(~r/Spawned agent ([^\s]+)/, result)

    assert {:ok, state} = Orchid.Agent.get_state(agent_id)
    assert state.execution_mode == :vm

    :ok = Orchid.Agent.stop(agent_id)
  end
end
