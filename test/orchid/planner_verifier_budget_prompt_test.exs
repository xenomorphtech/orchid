defmodule Orchid.PlannerVerifierBudgetPromptTest do
  use ExUnit.Case, async: true

  alias Orchid.Planner.Verifier

  defmodule CapturingLLM do
    def chat(_config, context) do
      send(Process.get(:planner_verifier_budget_prompt_test), {:llm_context, context})

      {:ok,
       %{
         content:
           ~s({"status":"approved","flawless_case":"ok","terrible_case":"risk","reason":"ok","critique":""})
       }}
    end
  end

  test "verifier prompt treats delegate-heavy plans as expensive under tight budget" do
    Process.put(:planner_verifier_budget_prompt_test, self())

    tasks = [
      %{
        id: "inspect",
        type: :delegate,
        objective: "Inspect and patch the known files."
      }
    ]

    assert {:approved, "ok"} =
             Verifier.verify("finish the benchmark", tasks,
               llm_module: CapturingLLM,
               llm_memoize: false,
               execution_step_budget_remaining: 5,
               execution_step_budget_total: 28,
               workspace_context: "README.md\nlib/example.ex\ntest/example_test.exs"
             )

    assert_receive {:llm_context, context}
    prompt = context.messages |> List.first() |> Map.fetch!(:content)

    assert prompt =~ "EXECUTION STEP BUDGET"
    assert prompt =~ "5 of 28"
    assert prompt =~ "treat delegate-heavy plans as expensive"
    assert prompt =~ "require concrete read/list/grep/shell/edit/tool tasks"
    assert prompt =~ "partial subsystem"
    assert prompt =~ "only read by earlier tasks in"
    assert prompt =~ "inspection-only round followed by replanning"
    assert prompt =~ "\"required_fixes\""
    assert prompt =~ "concrete edit instructions"
  end

  test "flawed verifier decisions preserve concrete required fixes" do
    raw =
      ~s({
        "status": "flawed",
        "flawless_case": "It might eventually work.",
        "terrible_case": "It hides the known test command behind delegation.",
        "reason": "",
        "critique": "The plan is too broad to execute under the remaining step budget.",
        "required_fixes": [
          "Replace the delegate with a shell task that runs mix test.",
          {"instruction": "Add a task_report_result task after verification."}
        ]
      })

    assert {:flawed, critique} = Verifier.parse_decision(raw)
    assert critique =~ "too broad"
    assert critique =~ "Required fixes:"
    assert critique =~ "Replace the delegate with a shell task that runs mix test."
    assert critique =~ "Add a task_report_result task after verification."
  end
end
