defmodule Orchid.PlannerGeneratorBudgetPromptTest do
  use ExUnit.Case, async: true

  alias Orchid.Planner.Generator

  defmodule CapturingLLM do
    def chat(_config, context) do
      send(Process.get(:planner_generator_budget_prompt_test), {:llm_context, context})
      {:ok, %{content: "[]"}}
    end
  end

  test "generator prompt separates planner revision from executor step budget" do
    Process.put(:planner_generator_budget_prompt_test, self())

    assert {:ok, []} =
             Generator.generate("finish the benchmark", [],
               llm_module: CapturingLLM,
               llm_memoize: false,
               execution_step_budget_remaining: 7,
               execution_step_budget_total: 28
             )

    assert_receive {:llm_context, context}
    prompt = context.messages |> List.first() |> Map.fetch!(:content)

    assert prompt =~ "EXECUTION STEP BUDGET"
    assert prompt =~ "outside the executor"
    assert prompt =~ "7 of 28"
    assert prompt =~ "Delegate tasks recursively plan"
    assert prompt =~ "topologically ordered list of concrete tool tasks"
  end
end
