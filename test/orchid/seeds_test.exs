defmodule Orchid.SeedsTest do
  use ExUnit.Case

  setup do
    {:ok, _} = Application.ensure_all_started(:orchid)
    :ok
  end

  test "Coder template uses Codex gpt-5.4 high reasoning" do
    coder =
      Orchid.Object.list_agent_templates()
      |> Enum.find(fn template -> template.name == "Coder" end)

    assert coder
    assert coder.metadata[:provider] == :codex
    assert coder.metadata[:model] == :gpt54
    assert coder.metadata[:model_reasoning_effort] == "high"
  end
end
