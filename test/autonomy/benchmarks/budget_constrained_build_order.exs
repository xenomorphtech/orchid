alias Orchid.Autonomy.Benchmark

# Planning gap: the code files are intentionally named in reverse dependency
# order, so a greedy flat loop that edits or tests in listing order starts at
# Pipeline/Validator, sees cascading failures, and burns a tight step budget.
# A planner wins by topologically sorting the DAG first: Parser + Rules,
# then Validator + Renderer, then Pipeline.
Benchmark.new!(%{
  id: "budget_constrained_build_order",
  objective: """
  Complete the seeded Mix project in `/workspace` under a tight budget. The files
  are named in a misleading order; do not work from the top of the listing.
  Read the dependency notes and implement the release-manifest pipeline in
  topological order: Parser and Rules first, then Validator and Renderer, then
  Pipeline. The single integration test must pass.
  """,
  success_check: {:shell, "cd /workspace && mix test 2>&1 | grep -q '0 failures'"},
  max_steps: 28,
  category: :development,
  seed_files: [
    %{
      path: "mix.exs",
      content: ~S"""
      defmodule BuildOrder.MixProject do
        use Mix.Project

        def project do
          [
            app: :build_order,
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
      # Budget-Constrained Build Order

      Dependency DAG:

      - BuildOrder.Parser is foundation A.
      - BuildOrder.Rules is foundation B.
      - BuildOrder.Validator depends on Parser and Rules.
      - BuildOrder.Renderer depends on the validated manifest entries.
      - BuildOrder.Pipeline depends on Validator and Renderer.

      The file names are reverse ordered on purpose. Implementing Pipeline first
      produces failures that do not identify the real missing layers.

      Input rows are `sku|quantity|priority|region`. Ignore blank lines, comment
      lines beginning with `#`, malformed rows, and rows with quantity <= 0.

      Priority multipliers:

      - gold: 30
      - silver: 12
      - bronze: 5

      Score is quantity * multiplier. Keep only entries with score >= 10.
      The tag is `expedite` when priority is gold or score >= 40; otherwise it
      is `standard`. Sort by score descending, then SKU ascending.

      Render lines exactly as:

      `region=<region> sku=<sku> score=<score> tag=<tag>`
      """
    },
    %{
      path: "lib/build_order/00_pipeline.ex",
      content: ~S"""
      defmodule BuildOrder.Pipeline do
        @moduledoc false

        def run(_source), do: []
      end
      """
    },
    %{
      path: "lib/build_order/01_validator.ex",
      content: ~S"""
      defmodule BuildOrder.Validator do
        @moduledoc false

        def accepted(_source), do: []
      end
      """
    },
    %{
      path: "lib/build_order/02_renderer.ex",
      content: ~S"""
      defmodule BuildOrder.Renderer do
        @moduledoc false

        def format(_entries), do: []
      end
      """
    },
    %{
      path: "lib/build_order/03_rules.ex",
      content: ~S"""
      defmodule BuildOrder.Rules do
        @moduledoc false

        def classify(entry), do: entry
      end
      """
    },
    %{
      path: "lib/build_order/04_parser.ex",
      content: ~S"""
      defmodule BuildOrder.Parser do
        @moduledoc false

        def parse(_source), do: []
      end
      """
    },
    %{
      path: "test/test_helper.exs",
      content: "ExUnit.start()\n"
    },
    %{
      path: "test/build_order_pipeline_test.exs",
      content: ~S"""
      defmodule BuildOrderPipelineTest do
        use ExUnit.Case, async: true

        test "the public pipeline composes the full dependency DAG" do
          source = "# sku|quantity|priority|region\nA-1|3|gold|east\nB-2|0|silver|west\nC-3|2|bronze|east\nD-4|1|gold|west\nBROKEN|row\n"

          assert BuildOrder.Pipeline.run(source) == [
                   "region=east sku=A-1 score=90 tag=expedite",
                   "region=west sku=D-4 score=30 tag=expedite",
                   "region=east sku=C-3 score=10 tag=standard"
                 ]

          second_source = "R-7|4|silver|north\nM-1|1|bronze|north\nA-9|2|silver|south\n"

          assert BuildOrder.Pipeline.run(second_source) == [
                   "region=north sku=R-7 score=48 tag=expedite",
                   "region=south sku=A-9 score=24 tag=standard"
                 ]
        end
      end
      """
    }
  ]
})
