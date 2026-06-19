alias Orchid.Autonomy.Benchmark

# Hard for a flat loop because the single closure check depends on a working
# chain of parser, pricing-rule, and renderer modules, with tests covering both
# the intermediate layers and the final public pipeline.
Benchmark.new!(%{
  id: "build_layered_invoice_pipeline",
  objective: """
  Implement the seeded invoice Mix project in `/workspace`. Read the README and
  tests, then complete the parser, pricing rules, renderer, and public pipeline
  so the whole invoice summary suite passes. Keep the implementation in the
  seeded layered modules rather than replacing the tests.
  """,
  success_check: {:shell, "cd /workspace && mix test 2>&1 | grep -q '0 failures'"},
  max_steps: 80,
  category: :development,
  seed_files: [
    %{
      path: "mix.exs",
      content: ~S"""
      defmodule InvoicePipeline.MixProject do
        use Mix.Project

        def project do
          [
            app: :invoice_pipeline,
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
      content: ~S"""
      # Invoice Pipeline

      Input rows are pipe-delimited as:

          customer|category|unit_price|quantity

      Ignore blank rows and malformed rows. Group valid rows by customer.
      Customers and category labels should render in alphabetical order.

      For each customer:

      - subtotal is the sum of unit_price * quantity.
      - discount is 10% of subtotal when subtotal is at least 100.00.
      - discount is a flat 5.00 when subtotal is at least 50.00 and below 100.00.
      - discount is 0.00 otherwise.
      - tax is computed from category totals before discount:
        food: 2%, book: 0%, tool: 7.5%, service: 9%, unknown categories: 0%.
      - total is subtotal - discount + tax.
      - render all money values with exactly two decimal places.

      The public API is `InvoicePipeline.run/1`, implemented through the
      `InvoicePipeline.Parser`, `InvoicePipeline.Rules`, and
      `InvoicePipeline.Renderer` modules.
      """
    },
    %{
      path: "lib/invoice_pipeline.ex",
      content: ~S"""
      defmodule InvoicePipeline do
        @moduledoc false

        def run(source) do
          source
          |> InvoicePipeline.Parser.parse()
          |> InvoicePipeline.Rules.summarize()
          |> InvoicePipeline.Renderer.render()
        end
      end
      """
    },
    %{
      path: "lib/invoice_pipeline/parser.ex",
      content: ~S"""
      defmodule InvoicePipeline.Parser do
        @moduledoc false

        def parse(_source), do: []
      end
      """
    },
    %{
      path: "lib/invoice_pipeline/rules.ex",
      content: ~S"""
      defmodule InvoicePipeline.Rules do
        @moduledoc false

        def summarize(_rows), do: []
      end
      """
    },
    %{
      path: "lib/invoice_pipeline/renderer.ex",
      content: ~S"""
      defmodule InvoicePipeline.Renderer do
        @moduledoc false

        def render(_summaries), do: []
      end
      """
    },
    %{
      path: "test/test_helper.exs",
      content: "ExUnit.start()\n"
    },
    %{
      path: "test/invoice_pipeline_test.exs",
      content: ~S"""
      defmodule InvoicePipelineTest do
        use ExUnit.Case, async: true

        alias InvoicePipeline.Parser
        alias InvoicePipeline.Rules
        alias InvoicePipeline.Renderer

        test "parser keeps valid rows and skips malformed input" do
          source = "ACME|food|12.00|2\nBROKEN|food|oops|3\n\nZED|tool|40.00|1\nSKIP|too|few\n"

          assert Parser.parse(source) == [
                   %{customer: "ACME", category: "food", unit_price: 12.0, quantity: 2},
                   %{customer: "ZED", category: "tool", unit_price: 40.0, quantity: 1}
                 ]
        end

        test "rules compute discounts, taxes, totals, and category totals" do
          rows = [
            %{customer: "MIRA", category: "service", unit_price: 100.0, quantity: 1},
            %{customer: "BETA", category: "food", unit_price: 2.5, quantity: 4},
            %{customer: "MIRA", category: "service", unit_price: 25.0, quantity: 2}
          ]

          assert Rules.summarize(rows) == [
                   %{
                     customer: "BETA",
                     subtotal: 10.0,
                     discount: 0.0,
                     tax: 0.2,
                     total: 10.2,
                     categories: %{"food" => 10.0}
                   },
                   %{
                     customer: "MIRA",
                     subtotal: 150.0,
                     discount: 15.0,
                     tax: 13.5,
                     total: 148.5,
                     categories: %{"service" => 150.0}
                   }
                 ]
        end

        test "renderer formats stable customer summaries" do
          summaries = [
            %{
              customer: "ZED",
              subtotal: 40.0,
              discount: 0.0,
              tax: 3.0,
              total: 43.0,
              categories: %{"tool" => 40.0}
            },
            %{
              customer: "ACME",
              subtotal: 64.25,
              discount: 5.0,
              tax: 0.92,
              total: 60.17,
              categories: %{"food" => 45.75, "book" => 18.5}
            }
          ]

          assert Renderer.render(summaries) == [
                   "customer=ACME subtotal=64.25 discount=5.00 tax=0.92 total=60.17 categories=book:18.50,food:45.75",
                   "customer=ZED subtotal=40.00 discount=0.00 tax=3.00 total=43.00 categories=tool:40.00"
                 ]
        end

        test "public pipeline composes all layers" do
          source = "ACME|food|12.00|2\nACME|book|18.50|1\nZED|tool|40.00|1\nACME|food|7.25|3\nBAD|tool|oops|1\n"

          assert InvoicePipeline.run(source) == [
                   "customer=ACME subtotal=64.25 discount=5.00 tax=0.92 total=60.17 categories=book:18.50,food:45.75",
                   "customer=ZED subtotal=40.00 discount=0.00 tax=3.00 total=43.00 categories=tool:40.00"
                 ]
        end
      end
      """
    }
  ]
})
