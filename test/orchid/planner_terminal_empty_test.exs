defmodule Orchid.PlannerTerminalEmptyTest do
  use ExUnit.Case, async: true

  alias Orchid.Planner

  defmodule EmptyTaskArrayLLM do
    def chat(_config, _context), do: {:ok, %{content: "[]"}}
  end

  test "empty task array is terminal only after prior G-V-R completion" do
    assert {:ok, []} =
             Planner.plan_tasks("finish benchmark", nil,
               llm_module: EmptyTaskArrayLLM,
               llm_memoize: false,
               num_paths: 1,
               max_iterations: 1,
               completed_tasks: [
                 %{
                   id: "implement",
                   type: :tool,
                   objective: "Implement and verify.",
                   result: "done"
                 }
               ]
             )
  end

  test "empty task array on the first planning round remains a planner miss" do
    assert {:error, reason} =
             Planner.plan_tasks("finish benchmark", nil,
               llm_module: EmptyTaskArrayLLM,
               llm_memoize: false,
               num_paths: 1,
               max_iterations: 1,
               completed_tasks: []
             )

    assert reason =~ "task array was empty before any G-V-R task completed"
  end
end
