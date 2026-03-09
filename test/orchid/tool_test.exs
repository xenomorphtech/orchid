defmodule Orchid.ToolTest do
  use ExUnit.Case, async: true

  test "wraps tool exits as structured errors" do
    result =
      Orchid.Tool.execute(
        "eval",
        %{"code" => "exit(:boom)"},
        %{agent_state: %{config: %{}}}
      )

    assert {:error, message} = result
    assert message =~ "Tool eval exited:"
    assert message =~ ":boom"
  end
end
