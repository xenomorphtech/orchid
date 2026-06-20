defmodule Orchid.AutonomyRunnerMetadataTest do
  use ExUnit.Case, async: true

  alias Orchid.Autonomy.Runner

  test "planner metadata resolves the Codex provider model used by autonomy runs" do
    assert %{
             provider: "codex",
             model_id: "gpt55",
             model: "gpt-5.5",
             model_proof: "provider=codex model=gpt-5.5"
           } = Runner.planner_llm_metadata()
  end
end
