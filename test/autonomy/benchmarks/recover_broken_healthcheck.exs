alias Orchid.Autonomy.Benchmark

healthcheck =
  {:shell, "cd /workspace && sh app/healthcheck.sh | grep -q '^HEALTHY state=ok port=8080$'"}

Benchmark.new!(%{
  id: "recover_broken_healthcheck",
  objective: """
  The seeded healthcheck is broken. Repair it so it reads `app/status.txt` and
  prints exactly `HEALTHY state=ok port=8080` when the service state is valid.
  Do not remove the status file.
  """,
  success_check: healthcheck,
  max_steps: 20,
  category: :operation,
  seed_files: [
    %{
      path: "app/status.txt",
      content: """
      state=ok
      port=8080
      """
    },
    %{
      path: "app/healthcheck.sh",
      mode: 0o755,
      content: """
      #!/bin/sh
      echo "BROKEN healthcheck"
      exit 1
      """
    },
    %{
      path: "README.md",
      content: """
      Recovery task: fix app/healthcheck.sh. The deterministic check intentionally
      fails before the agent repairs the seeded broken script.
      """
    }
  ],
  recovery_checks: [
    %{
      id: "broken_healthcheck",
      description: "Seeded healthcheck fails until the agent repairs app/healthcheck.sh.",
      check: healthcheck
    }
  ]
})
