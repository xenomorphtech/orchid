alias Orchid.Autonomy.Benchmark

Benchmark.new!(%{
  id: "operate_service_health",
  objective: """
  Bring the seeded service state online. Update `ops/service.env`, write a health
  document at `ops/health.json`, and append a restart entry to `ops/run.log`.
  """,
  success_check:
    {:shell,
     """
     cd /workspace &&
     grep -q '^STATUS=running$' ops/service.env &&
     grep -q '^RESTART_REQUIRED=false$' ops/service.env &&
     test -f ops/health.json &&
     grep -Eq '"service"[[:space:]]*:[[:space:]]*"orchid-demo"' ops/health.json &&
     grep -Eq '"status"[[:space:]]*:[[:space:]]*"running"' ops/health.json &&
     grep -Eq '"port"[[:space:]]*:[[:space:]]*8080' ops/health.json &&
     grep -qi 'restarted orchid-demo' ops/run.log
     """},
  max_steps: 20,
  category: :operation,
  seed_files: [
    %{
      path: "ops/service.env",
      content: """
      SERVICE=orchid-demo
      STATUS=stopped
      PORT=8080
      RESTART_REQUIRED=true
      """
    },
    %{
      path: "ops/README.md",
      content: """
      Operational target:
      - STATUS must be running.
      - RESTART_REQUIRED must be false.
      - health.json must report service orchid-demo on port 8080.
      - run.log must include a restart entry.
      """
    }
  ]
})
