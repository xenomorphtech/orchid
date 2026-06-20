defmodule Orchid.PlannerBestEffortTest do
  use ExUnit.Case, async: true

  alias Orchid.Planner

  defmodule RankingLLM do
    def chat(_config, %{messages: [%{content: prompt}]}) do
      cond do
        prompt =~ "Return exactly one JSON object" ->
          {:ok,
           %{
             content:
               ~s({"status":"flawed","flawless_case":"executable enough to try","terrible_case":"not fully proven","reason":"","critique":"Budget exhausted before approval.","required_fixes":["Add follow-up verification."]})
           }}

        prompt =~ "CANDIDATE PLAN 1 OF 2" ->
          {:ok,
           %{
             content:
               ~s([{"id":"broad","type":"delegate","objective":"Patch and verify everything."}])
           }}

        prompt =~ "CANDIDATE PLAN 2 OF 2" ->
          {:ok,
           %{
             content:
               ~s([{"id":"inspect","type":"tool","objective":"List project files.","tool":"list","args":{"path":"."}}])
           }}

        true ->
          {:ok, %{content: "[]"}}
      end
    end
  end

  test "planner executes the strongest retained candidate when revision budget is exhausted" do
    assert {:ok,
            [
              %{
                id: "inspect",
                type: :tool,
                objective: "List project files.",
                tool: "list",
                args: %{"path" => "."}
              }
            ]} =
             Planner.plan_tasks("finish benchmark", nil,
               llm_module: RankingLLM,
               llm_memoize: false,
               num_paths: 2,
               max_concurrency: 1,
               max_iterations: 1
             )
  end
end
