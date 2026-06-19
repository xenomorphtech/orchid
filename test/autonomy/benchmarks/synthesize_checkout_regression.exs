alias Orchid.Autonomy.Benchmark

# Hard for a flat loop because the answer is not present in one file: the agent
# must join time-series metrics, deploy history, feature flags, and support
# tickets, then compute the p95 increase before writing a structured report.
Benchmark.new!(%{
  id: "synthesize_checkout_regression",
  objective: """
  Analyze the seeded checkout incident evidence in `/workspace/evidence` and
  write `analysis/regression_report.txt`. The report must be a set of
  `key: value` lines that identify the primary regressed service, affected
  region, latency increase, suspect deploy, suspect feature flag, ticket count,
  and recommended rollback/flag action. Use the evidence files as source of
  truth rather than guessing from a single note.
  """,
  success_check:
    {:shell,
     """
     cd /workspace &&
     test -f analysis/regression_report.txt &&
     grep -Eq '^primary_service:[[:space:]]*checkout-api$' analysis/regression_report.txt &&
     grep -Eq '^affected_region:[[:space:]]*us-east-2$' analysis/regression_report.txt &&
     grep -Eq '^baseline_p95_ms:[[:space:]]*180$' analysis/regression_report.txt &&
     grep -Eq '^incident_p95_ms:[[:space:]]*640$' analysis/regression_report.txt &&
     grep -Eq '^p95_increase_pct:[[:space:]]*256$' analysis/regression_report.txt &&
     grep -Eq '^ticket_count:[[:space:]]*4$' analysis/regression_report.txt &&
     grep -Eq '^suspect_deploy:.*checkout-api.*4f3c2a1' analysis/regression_report.txt &&
     grep -Eq '^suspect_flag:.*beta_pricing_rules' analysis/regression_report.txt &&
     grep -Eiq '^recommended_action:.*rollback.*4f3c2a1.*disable.*beta_pricing_rules' analysis/regression_report.txt
     """},
  max_steps: 70,
  category: :research,
  seed_files: [
    %{
      path: "evidence/README.md",
      content: """
      # Checkout Regression Evidence

      Produce analysis/regression_report.txt with these keys:

      primary_service
      affected_region
      baseline_p95_ms
      incident_p95_ms
      p95_increase_pct
      ticket_count
      suspect_deploy
      suspect_flag
      recommended_action

      Compute p95_increase_pct as round((incident_p95_ms - baseline_p95_ms) /
      baseline_p95_ms * 100). Use only the service and region that show both a
      latency spike and matching customer tickets after a deploy or flag change.
      """
    },
    %{
      path: "evidence/metrics.tsv",
      content: """
      service	region	window	p95_ms	error_rate
      checkout-api	us-east-2	baseline	180	0.2
      checkout-api	us-east-2	incident	640	5.8
      checkout-api	us-west-2	baseline	175	0.2
      checkout-api	us-west-2	incident	188	0.3
      catalog-api	us-east-2	baseline	120	0.1
      catalog-api	us-east-2	incident	126	0.1
      payments-api	us-east-2	baseline	210	0.4
      payments-api	us-east-2	incident	215	0.4
      """
    },
    %{
      path: "evidence/deploys.csv",
      content: """
      timestamp,service,region,version,commit,notes
      2026-06-18T09:58:00Z,catalog-api,us-east-2,v5.4.0,8aa19bd,cache header tune
      2026-06-18T10:22:00Z,checkout-api,us-east-2,v2.8.4,4f3c2a1,pricing adapter rollout
      2026-06-18T10:29:00Z,payments-api,us-east-2,v7.1.1,d91bc22,doc-only config refresh
      2026-06-18T10:44:00Z,checkout-api,us-west-2,v2.8.4,4f3c2a1,delayed regional rollout
      """
    },
    %{
      path: "evidence/feature_flags.json",
      content: """
      {
        "changes": [
          {
            "time": "2026-06-18T10:25:00Z",
            "flag": "beta_pricing_rules",
            "service": "checkout-api",
            "region": "us-east-2",
            "from": "5%",
            "to": "100%"
          },
          {
            "time": "2026-06-18T10:31:00Z",
            "flag": "new_catalog_cards",
            "service": "catalog-api",
            "region": "us-east-2",
            "from": "50%",
            "to": "50%"
          }
        ]
      }
      """
    },
    %{
      path: "evidence/tickets.md",
      content: """
      # Support Tickets

      - 10:34Z us-east-2 checkout-api: customer reports checkout timeout after price recalculation.
      - 10:36Z us-east-2 checkout-api: cart submit spins and returns 502.
      - 10:37Z us-west-2 checkout-api: unrelated coupon typo, no timeout.
      - 10:39Z us-east-2 checkout-api: order review takes more than 6 seconds.
      - 10:41Z us-east-2 checkout-api: checkout page fails after beta pricing rule path.
      - 10:43Z us-east-2 catalog-api: stale image complaint, not checkout.
      """
    }
  ]
})
