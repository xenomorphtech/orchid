alias Orchid.Autonomy.Benchmark

# Planning gap: two tests pull on one shared plan contract from opposite
# boundaries. A greedy flat loop tends to flip the shared canonical string from
# "pro" to "premium" to satisfy billing, then back toward "pro" to satisfy the
# warehouse event. Planning wins by naming the shared concept once and exposing
# boundary-specific codes from the contract instead of whack-a-mole local edits.
Benchmark.new!(%{
  id: "oscillating_constraint_refactor",
  objective: """
  Repair the seeded plan-sync Mix project in `/workspace`. The billing payload
  and warehouse event need different external plan codes for the same paid-plan
  contract. Do not chase one failing test at a time by flipping strings in the
  boundary modules; refactor the shared `PlanSync.Contract` so both tests pass
  together.
  """,
  success_check: {:shell, "cd /workspace && mix test 2>&1 | grep -q '0 failures'"},
  max_steps: 26,
  category: :development,
  seed_files: [
    %{
      path: "mix.exs",
      content: ~S"""
      defmodule PlanSync.MixProject do
        use Mix.Project

        def project do
          [
            app: :plan_sync,
            version: "0.1.0",
            elixir: "~> 1.15",
            start_permanent: Mix.env() == :prod,
            deps: []
          ]
        end

        def application do
          [extra_applications: [:logger]]
        end
      end
      """
    },
    %{
      path: "README.md",
      content: """
      # Plan Sync Refactor

      The shared business concept is a paid team plan. It has two boundary
      encodings:

      - Billing API code: `premium`
      - Warehouse event code: `pro`

      Paid team plans cost 4900 cents and include 25 seats. Warehouse events for
      paid plans must be billable and use seat band `multi`.

      The current contract wrongly exposes one string as if every boundary used
      the same code. Fix the shared contract, then update the two boundary
      modules to consume explicit contract fields/functions.
      """
    },
    %{
      path: "lib/plan_sync/contract.ex",
      content: ~S"""
      defmodule PlanSync.Contract do
        @moduledoc false

        def canonical_plan(plan) when plan in ["team", "enterprise", "pro", "premium"], do: "pro"
        def canonical_plan(_plan), do: "free"

        def amount_cents("pro"), do: 0
        def amount_cents(_plan), do: 0

        def included_seats("pro"), do: 5
        def included_seats(_plan), do: 1

        def seat_band("pro"), do: "single"
        def seat_band(_plan), do: "single"

        def billable?("pro"), do: false
        def billable?(_plan), do: false
      end
      """
    },
    %{
      path: "lib/plan_sync/billing_payload.ex",
      content: ~S"""
      defmodule PlanSync.BillingPayload do
        @moduledoc false

        alias PlanSync.Contract

        def build(attrs) do
          plan = Contract.canonical_plan(Map.fetch!(attrs, :plan))

          %{
            customer: Map.fetch!(attrs, :customer),
            plan: plan,
            amount_cents: Contract.amount_cents(plan),
            included_seats: Contract.included_seats(plan)
          }
        end
      end
      """
    },
    %{
      path: "lib/plan_sync/warehouse_event.ex",
      content: ~S"""
      defmodule PlanSync.WarehouseEvent do
        @moduledoc false

        alias PlanSync.Contract

        def build(attrs) do
          plan = Contract.canonical_plan(Map.fetch!(attrs, :plan))

          %{
            account_id: Map.fetch!(attrs, :account_id),
            plan_code: plan,
            seat_band: Contract.seat_band(plan),
            billable: Contract.billable?(plan)
          }
        end
      end
      """
    },
    %{
      path: "test/test_helper.exs",
      content: "ExUnit.start()\n"
    },
    %{
      path: "test/billing_payload_test.exs",
      content: ~S"""
      defmodule PlanSync.BillingPayloadTest do
        use ExUnit.Case, async: true

        test "billing boundary emits the premium API code and paid amounts" do
          assert PlanSync.BillingPayload.build(%{customer: "cust-7", plan: "team"}) == %{
                   customer: "cust-7",
                   plan: "premium",
                   amount_cents: 4900,
                   included_seats: 25
                 }
        end
      end
      """
    },
    %{
      path: "test/warehouse_event_test.exs",
      content: ~S"""
      defmodule PlanSync.WarehouseEventTest do
        use ExUnit.Case, async: true

        test "warehouse boundary keeps the pro event code for paid plans" do
          assert PlanSync.WarehouseEvent.build(%{account_id: "acct-9", plan: "team"}) == %{
                   account_id: "acct-9",
                   plan_code: "pro",
                   seat_band: "multi",
                   billable: true
                 }
        end
      end
      """
    }
  ]
})
