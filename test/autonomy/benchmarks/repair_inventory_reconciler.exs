alias Orchid.Autonomy.Benchmark

audit_check = {:shell, "cd /workspace && mix test 2>&1 | grep -q '0 failures'"}

# Hard for a flat loop because the project already has plausible but wrong code:
# the agent must diagnose failing tests, repair CSV parsing and movement rules,
# preserve the public API, and prove the fix by rerunning the suite.
Benchmark.new!(%{
  id: "repair_inventory_reconciler",
  objective: """
  The seeded inventory audit Mix project has a broken reconciler. Use the README
  and failing tests to repair `InventoryAudit` so it parses the CSV-like inputs,
  applies all movement types, returns sorted anomalies, and formats the report.
  Keep the public API intact and verify the seeded test suite passes.
  """,
  success_check: audit_check,
  max_steps: 80,
  category: :development,
  seed_files: [
    %{
      path: "mix.exs",
      content: ~S"""
      defmodule InventoryAudit.MixProject do
        use Mix.Project

        def project do
          [
            app: :inventory_audit,
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
      # Inventory Audit

      `InventoryAudit.anomalies/3` receives three CSV-like strings:

      - stock: `sku,on_hand`
      - movements: `type,sku,quantity`
      - counts: `sku,counted`

      Movement rules:

      - `shipment`, `return`, and `adjustment` add quantity.
      - `sale` and `damage` subtract quantity.

      Expected stock is starting on_hand plus all movements for a SKU.
      Delta is counted minus expected. Only non-zero deltas are anomalies.
      A positive delta has status `over`; a negative delta has status `short`.
      Sort anomalies by absolute delta descending, then by SKU ascending.

      `InventoryAudit.report/3` renders one line per anomaly:

      `sku=<sku> expected=<expected> counted=<counted> delta=<delta> status=<status>`
      """
    },
    %{
      path: "lib/inventory_audit.ex",
      content: ~S"""
      defmodule InventoryAudit do
        @moduledoc false

        def anomalies(stock_csv, _movement_csv, count_csv) do
          stock = parse_pairs(stock_csv)
          counts = parse_pairs(count_csv)

          stock
          |> Enum.map(fn {sku, expected} ->
            counted = Map.get(counts, sku, expected)
            delta = counted - expected

            %{
              sku: sku,
              expected: expected,
              counted: counted,
              delta: delta,
              status: if(delta > 0, do: "over", else: "ok")
            }
          end)
        end

        def report(stock_csv, movement_csv, count_csv) do
          stock_csv
          |> anomalies(movement_csv, count_csv)
          |> Enum.map_join("\n", fn anomaly ->
            "sku=#{anomaly.sku} expected=#{anomaly.expected} counted=#{anomaly.counted}"
          end)
        end

        defp parse_pairs(csv) do
          csv
          |> String.split("\n", trim: true)
          |> Enum.drop(1)
          |> Map.new(fn line ->
            [sku, value] = String.split(line, ",", trim: true)
            {sku, String.to_integer(value)}
          end)
        end
      end
      """
    },
    %{
      path: "test/test_helper.exs",
      content: "ExUnit.start()\n"
    },
    %{
      path: "test/inventory_audit_test.exs",
      content: ~S"""
      defmodule InventoryAuditTest do
        use ExUnit.Case, async: true

        @stock "sku,on_hand\nA-1,10\nB-2,4\nC-3,0\nD-4,20\n"
        @movements "type,sku,quantity\nshipment,A-1,3\nsale,A-1,5\nreturn,B-2,2\nsale,C-3,1\nadjustment,C-3,4\nsale,D-4,2\ndamage,D-4,3\n"
        @counts "sku,counted\nA-1,8\nB-2,5\nC-3,3\nD-4,18\n"

        test "applies movement rules and reports only real anomalies" do
          assert InventoryAudit.anomalies(@stock, @movements, @counts) == [
                   %{sku: "D-4", expected: 15, counted: 18, delta: 3, status: "over"},
                   %{sku: "B-2", expected: 6, counted: 5, delta: -1, status: "short"}
                 ]
        end

        test "formats sorted anomaly report lines" do
          assert InventoryAudit.report(@stock, @movements, @counts) ==
                   Enum.join(
                     [
                       "sku=D-4 expected=15 counted=18 delta=3 status=over",
                       "sku=B-2 expected=6 counted=5 delta=-1 status=short"
                     ],
                     "\n"
                   )
        end
      end
      """
    }
  ],
  recovery_checks: [
    %{
      id: "inventory_reconciler_tests",
      description: "Seeded implementation ignores movement rules and fails until repaired.",
      check: audit_check
    }
  ]
})
