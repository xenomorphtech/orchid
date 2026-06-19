alias Orchid.Autonomy.Benchmark

worker_recovery =
  {:shell,
   """
   cd /workspace &&
   grep -q '^MODE=active$' ops/service.env &&
   grep -q '^QUEUE_NAME=critical-email$' ops/service.env &&
   grep -q '^MAX_RETRIES=5$' ops/service.env &&
   grep -q '^BACKOFF_MS=250$' ops/service.env &&
   grep -q '^DRAIN_STRATEGY=batch$' ops/service.env &&
   grep -q '^CHECKPOINT=2026-06-18T22:40:00Z$' ops/service.env &&
   test -f ops/health.json &&
   grep -Eq '"service"[[:space:]]*:[[:space:]]*"queue-worker"' ops/health.json &&
   grep -Eq '"status"[[:space:]]*:[[:space:]]*"active"' ops/health.json &&
   grep -Eq '"queue"[[:space:]]*:[[:space:]]*"critical-email"' ops/health.json &&
   grep -Eq '"checkpoint"[[:space:]]*:[[:space:]]*"2026-06-18T22:40:00Z"' ops/health.json &&
   grep -Eq '"pending_jobs"[[:space:]]*:[[:space:]]*0' ops/health.json &&
   grep -Eq '"backoff_ms"[[:space:]]*:[[:space:]]*250' ops/health.json &&
   test -f ops/recovery.md &&
   grep -Eiq 'root cause:.*(default queue|QUEUE_NAME=default)' ops/recovery.md &&
   grep -Eiq 'backoff.*250' ops/recovery.md &&
   grep -Eiq 'checkpoint.*2026-06-18T22:40:00Z' ops/recovery.md &&
   grep -qi 'restarted queue-worker' ops/run.log
   """}

# Hard for a flat loop because the correct operational state is distributed
# across a runbook, an incident timeline, and a deploy note; closure requires
# updating config, producing machine-readable health, and writing an operator
# recovery note that ties the diagnosis to the fix.
Benchmark.new!(%{
  id: "stabilize_queue_worker_runbook",
  objective: """
  Recover the seeded `queue-worker` service in `/workspace`. Use the runbook and
  incident evidence to repair `ops/service.env`, produce `ops/health.json`, write
  `ops/recovery.md`, and append the restart action to `ops/run.log`. The service
  should be healthy for the critical email queue and the report should explain
  the root cause and verification.
  """,
  success_check: worker_recovery,
  max_steps: 70,
  category: :operation,
  seed_files: [
    %{
      path: "ops/service.env",
      content: """
      SERVICE=queue-worker
      MODE=degraded
      QUEUE_NAME=default
      MAX_RETRIES=1
      BACKOFF_MS=0
      DRAIN_STRATEGY=single
      CHECKPOINT=unknown
      """
    },
    %{
      path: "ops/runbook.md",
      content: """
      # Queue Worker Recovery Runbook

      1. Read the incident timeline before changing config.
      2. Use the dispatch manifest entry with the latest acknowledged checkpoint.
      3. A stable worker must run active mode, batch drain, five retries, and
         a 250 ms retry backoff.
      4. After config repair, create ops/health.json with the service, status,
         queue, checkpoint, pending job count, and backoff.
      5. Write ops/recovery.md with a root cause, the applied fix, and the
         verification evidence. Append the restart to ops/run.log.
      """
    },
    %{
      path: "ops/incidents/worker.log",
      content: """
      2026-06-18T22:32:03Z queue-worker booted MODE=degraded QUEUE_NAME=default BACKOFF_MS=0
      2026-06-18T22:33:11Z dispatch manifest selected queue=critical-email priority=sev2
      2026-06-18T22:35:27Z retries exhausted immediately; no backoff between attempts
      2026-06-18T22:38:52Z drain probe: pending_jobs=47 for queue=default
      2026-06-18T22:40:00Z ack committed checkpoint=2026-06-18T22:40:00Z for queue=critical-email
      2026-06-18T22:41:12Z drain complete pending_jobs=0 after switching to critical-email with batch drain
      """
    },
    %{
      path: "ops/incidents/deploy-note.txt",
      content: """
      Deployment guardrails for queue-worker:
      MAX_RETRIES=5
      BACKOFF_MS=250
      DRAIN_STRATEGY=batch
      The worker should restart after service.env is repaired.
      """
    },
    %{
      path: "ops/run.log",
      content: """
      2026-06-18T22:31:55Z observed queue-worker degraded
      """
    }
  ],
  recovery_checks: [
    %{
      id: "queue_worker_recovered",
      description: "Seeded service.env is degraded until the agent repairs the worker state.",
      check: worker_recovery
    }
  ]
})
