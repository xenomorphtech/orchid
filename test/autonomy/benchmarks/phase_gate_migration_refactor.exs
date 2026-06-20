alias Orchid.Autonomy.Benchmark

# Planning gap: the migration note makes "rename fast_checkout to
# accelerated_checkout" look globally correct. That local edit satisfies the
# dashboard boundary but breaks the worker and audit boundaries. The durable
# fix is to backtrack and split the shared contract into boundary-specific
# encodings.
Benchmark.new!(%{
  id: "phase_gate_migration_refactor",
  objective: """
  Repair the seeded feature-flag migration Mix project in `/workspace`. The
  obvious global rename from `fast_checkout` to `accelerated_checkout` is a
  trap: dashboard, worker, and audit boundaries use different external flag
  codes for the same rollout. Refactor the shared `PhaseGate.Rule` contract so
  all boundary modules pass together.
  """,
  success_check: {:shell, "cd /workspace && mix test 2>&1 | grep -q '0 failures'"},
  max_steps: 28,
  category: :development,
  seed_files: [
    %{
      path: "mix.exs",
      content: ~S"""
      defmodule PhaseGate.MixProject do
        use Mix.Project

        def project do
          [
            app: :phase_gate,
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
      # Phase Gate Migration

      The same rollout has three boundary encodings:

      - Dashboard API flag: `accelerated_checkout`
      - Worker queue flag: `fast_checkout`
      - Audit ledger code: `fc_legacy`

      The migration note says "rename fast_checkout to accelerated_checkout",
      but that instruction only applies to the dashboard API. Worker jobs must
      keep the old queue flag, and audit events must keep the ledger code.

      Paid rollout metadata:

      - enabled: true
      - dashboard cohort: `guarded`
      - worker queue: `checkout.fast`
      - audit retention: `90d`
      """
    },
    %{
      path: "lib/phase_gate/rule.ex",
      content: ~S"""
      defmodule PhaseGate.Rule do
        @moduledoc false

        def canonical_flag(flag) when flag in ["fast_checkout", "accelerated_checkout", "fc_legacy"] do
          "fast_checkout"
        end

        def canonical_flag(_flag), do: "off"

        def enabled?("fast_checkout"), do: false
        def enabled?(_flag), do: false

        def dashboard_cohort("fast_checkout"), do: "open"
        def dashboard_cohort(_flag), do: "closed"

        def worker_queue("fast_checkout"), do: "checkout.default"
        def worker_queue(_flag), do: "checkout.default"

        def audit_retention("fast_checkout"), do: "7d"
        def audit_retention(_flag), do: "7d"
      end
      """
    },
    %{
      path: "lib/phase_gate/dashboard_payload.ex",
      content: ~S"""
      defmodule PhaseGate.DashboardPayload do
        @moduledoc false

        alias PhaseGate.Rule

        def build(attrs) do
          flag = Rule.canonical_flag(Map.fetch!(attrs, :flag))

          %{
            account: Map.fetch!(attrs, :account),
            flag: flag,
            enabled: Rule.enabled?(flag),
            cohort: Rule.dashboard_cohort(flag)
          }
        end
      end
      """
    },
    %{
      path: "lib/phase_gate/worker_job.ex",
      content: ~S"""
      defmodule PhaseGate.WorkerJob do
        @moduledoc false

        alias PhaseGate.Rule

        def build(attrs) do
          flag = Rule.canonical_flag(Map.fetch!(attrs, :flag))

          %{
            tenant: Map.fetch!(attrs, :tenant),
            flag: flag,
            queue: Rule.worker_queue(flag)
          }
        end
      end
      """
    },
    %{
      path: "lib/phase_gate/audit_event.ex",
      content: ~S"""
      defmodule PhaseGate.AuditEvent do
        @moduledoc false

        alias PhaseGate.Rule

        def build(attrs) do
          flag = Rule.canonical_flag(Map.fetch!(attrs, :flag))

          %{
            actor: Map.fetch!(attrs, :actor),
            flag_code: flag,
            retention: Rule.audit_retention(flag)
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
      path: "test/dashboard_payload_test.exs",
      content: ~S"""
      defmodule PhaseGate.DashboardPayloadTest do
        use ExUnit.Case, async: true

        test "dashboard boundary receives the new public flag code" do
          assert PhaseGate.DashboardPayload.build(%{account: "acct-10", flag: "fast_checkout"}) == %{
                   account: "acct-10",
                   flag: "accelerated_checkout",
                   enabled: true,
                   cohort: "guarded"
                 }
        end
      end
      """
    },
    %{
      path: "test/worker_job_test.exs",
      content: ~S"""
      defmodule PhaseGate.WorkerJobTest do
        use ExUnit.Case, async: true

        test "worker boundary keeps the queue flag for the same rollout" do
          assert PhaseGate.WorkerJob.build(%{tenant: "team-4", flag: "accelerated_checkout"}) == %{
                   tenant: "team-4",
                   flag: "fast_checkout",
                   queue: "checkout.fast"
                 }
        end
      end
      """
    },
    %{
      path: "test/audit_event_test.exs",
      content: ~S"""
      defmodule PhaseGate.AuditEventTest do
        use ExUnit.Case, async: true

        test "audit boundary keeps the legacy ledger code" do
          assert PhaseGate.AuditEvent.build(%{actor: "ops", flag: "fast_checkout"}) == %{
                   actor: "ops",
                   flag_code: "fc_legacy",
                   retention: "90d"
                 }
        end
      end
      """
    }
  ]
})
