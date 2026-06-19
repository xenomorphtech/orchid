# Autonomy Metrics & Test Suite

> Status: **draft / scaffolding** (campaign goal `orchid` — "A system for Autonomous Goal Pursuit").
> Purpose: make "how autonomous is Orchid?" a **number computed deterministically every run, with no human and no AI-judge in the scoring loop** — so the loops have a target to optimize and regressions are visible.

## Why two metrics, not one

A single binary "did it finish the goal?" is too coarse to optimize against early — it stays 0 until the whole stack works, giving the loops no gradient. So the suite tracks a **continuous distance metric** for gradient and a **terminal metric** for success. They are complementary, not competing.

| Metric | Type | Definition | Direction |
|---|---|---|---|
| **unattended_depth** | continuous (ordinal) | # of plan steps completed with **zero human input** before the run stalls or errors, on a fixed benchmark goal | higher better |
| **goal_closure_rate** | terminal (fraction) | fraction of the benchmark goal-set driven to their declared `success_check` with **zero human approvals** | higher better → 1.0 |
| **recovery_rate** | diagnostic | fraction of *injected* failures the Verifier→Reviser loop recovers from (re-plans and proceeds) instead of halting | higher better |

`goal_closure_rate` is the campaign's headline (`orchid_goals_autonomously_closed`). `unattended_depth` is the per-cycle gradient the loops climb. `recovery_rate` isolates whether the autonomy is *robust* (re-plans on failure) vs *lucky* (only works on the happy path).

## Hard rules (what makes a score valid)

1. **No human in the scoring loop.** A run scores by executing against a deterministic `success_check` (a shell command, file assertion, or pure-Elixir predicate that returns pass/fail). No human approval, no "looks done".
2. **No AI judge in the scoring loop.** The *agent under test* may be an LLM; the *scorer* must not be. (An LLM grading its own autonomy is a false-positive generator.) If a check genuinely needs semantic judgement, encode it as a concrete assertion (regex, exit code, output diff), not a model call.
3. **Zero-nudge or it doesn't count.** Any run that required a human message mid-flight scores `unattended_depth` only up to the step *before* the nudge, and `goal_closure = false`.
4. **Deterministic + reproducible.** Same benchmark goal + same Orchid commit ⇒ same score modulo LLM stochasticity; report median of N≥3 runs, not a single sample (thin-sample noise is not signal).
5. **Sandboxed.** Every benchmark goal runs in the standard agent sandbox (Podman/overlay). The scorer reads results from the sandbox; it never reaches into agent internals.

## Benchmark goal format

Each benchmark goal is a self-contained spec the harness can run unattended and score:

```elixir
%{
  id: "build_cli_wordcount",
  objective: "Write a CLI that counts words in a file and passes its own tests.",
  # deterministic, agent-free pass/fail — run in the sandbox after the agent stops:
  success_check: {:shell, "cd /work && mix test 2>&1 | grep -q '0 failures'"},
  max_steps: 40,          # circuit breaker; also the denominator context for depth
  category: :development   # :research | :development | :operation
}
```

The three categories map directly to the README's claim (autonomous **research / development / operation**); the suite must have ≥1 benchmark in each before the metric is credible.

## Harness shape (to implement)

- `test/autonomy/benchmarks/` — one file per benchmark goal (the structs above).
- `Orchid.Autonomy.Runner` — given a benchmark, spins up an agent with `intervention: :disabled`, drives the goal to stall/closure, returns `%{depth: n, closed: bool, recovered: [..], steps: [...]}`.
- `Orchid.Autonomy.Scorer` — pure function `run_result -> %{unattended_depth, goal_closure, recovery_rate}`; runs the `success_check` in the sandbox; **no LLM calls**.
- `mix orchid.autonomy` — run the whole suite N times, emit a JSON report + a one-line summary the orchestrator loop reads each cycle.
- Report sink: write `priv/autonomy/last_report.json` so the LiveView dashboard and the external control loop can both read the current score without re-running.

## Open implementation choices (resolve when building, not blocking the spec)

- **Stall detection:** how the Runner decides a run has "stalled" unattended (no new completed step in K turns, or an explicit `:halted` from the Verifier/Reviser loop). Start with: stall = Reviser gives up OR `max_steps` hit OR same step retried 3×.
- **Failure injection for recovery_rate:** start with a deterministic fault (a benchmark whose `success_check` only passes after the agent works around a seeded broken file) rather than runtime monkeypatching.
- **Cost guard:** default agent is the free `nex-agi/nex-n2-pro:free` model, so suite runs are zero-token-cost; still cap wall-clock per benchmark.

---

## Campaign results & current architecture (2026-06-19, main f9d0627)

The spec above is **implemented and the campaign thesis is proven**. State of the system:

### Suite (built, `lib/orchid/autonomy/` + `mix orchid.autonomy`)
- `Runner` / `Scorer` / `Benchmark` live; `mix orchid.autonomy --mode flat|gvr|auto --runs N [--max-rounds R] [--max-delegate-depth D]` → `priv/autonomy/last_report.json`. Scorer is LLM-free (`Orchid.Sandbox.exec/3`).
- **11 benchmarks** = 4 easy + 4 endurance + **3 planning-gap discriminators** (`budget_constrained_build_order`, `oscillating_constraint_refactor`, `garden_path_diagnosis`). Only the 3 discriminators expose a *planning* gap (tight `max_steps` + a greedy-failure trap); flat closure on them is low (≈0.0–0.22). Endurance benchmarks do **not** discriminate — a flat loop with enough steps grinds through.
- **Sandbox teardown:** `Runner.run/2` wraps the goal in `try … after cleanup …` so each goal's Podman container is destroyed on success/failure/exception (an un-torn-down sandbox per goal previously filled the disk and crashed runs — looked like a planner failure, was an infra precondition).

### Planner: Generator → Verifier → Reviser (`lib/orchid/planner/`)
- `:flat` = single greedy LLM planner-agent. `:gvr` = Generator proposes a plan, Verifier critiques, Reviser revises within `gvr_max_rounds`, recursively delegating sub-goals up to `gvr_max_delegate_depth`.
- **Revise-loop fix:** the loop originally *aborted* a sample on the first `:flawed` verdict (the "R" never ran); fixed to feed the critique back and revise.
- **Both-node empty-output retry:** the free model `nex-agi/nex-n2-pro:free` intermittently returns EMPTY output on generator AND verifier calls; both nodes now retry (~6×) instead of mis-counting empties as planning failures. This was the unlock that let the decisive measurement run validly.
- **Memoization** (`planner/llm_memo.ex`): opt-controllable within-run `(prompt,model)→response` cache (generator task-arrays + verifier decisions); behaviour-preserving, ~66% wall-clock cut on identical-prompt repeats across the 3-run repetitions.

### Mode router (`lib/orchid/planner/router.ex`) — the metric-mover
- **Finding:** G-V-R **beats** flat where planning matters (gvr `oscillating` 0.333 / `garden_path` 0.667 vs flat 0.0) but **regresses easy** goals hard (gvr-easy 0.250 vs flat-easy 0.900 — verification/revision overhead starves simple goals). So a *global* gvr switch lowers the aggregate.
- **Router** classifies each goal on **runtime signals only** — objective planning-markers (ordering/dependency/budget/constraint/refactor), objective word-count, `max_steps`-or-equivalent, `success_check` kind — and routes easy→`:flat` / planning-gap→`:gvr`. It MUST NOT read benchmark `id`/`category` (those are harness labels, absent for real goals; routing on them would be a demo, not a deliverable).
- **H1 (proven):** routing raises the **aggregate** `goal_closure_rate` by the discriminator gain with **zero easy regression** — the gain a global switch can't get. `:auto` (router) is the **default mode** in `Runner` + the `mix orchid.autonomy` CLI; `:flat`/`:gvr` stay explicitly selectable for measurement.

### Production wiring (`lib/orchid/goal_watcher.ex` + `lib/orchid/planner/runtime_goal.ex`)
- The **real** goal-pursuit loop now routes through the proven stack: `goal_watcher.spawn_planner` builds a `RuntimeGoal` from the live `Orchid.Object` project/goals → `Router` (`[ROUTER] -> :flat|:gvr`) → `:flat` planner-agent path OR `:gvr` `Planner.plan/3` → approved task array to a real planner agent. Runtime-signals-only; no benchmark coupling. (Previously goal_watcher used a freeform LLM agent that bypassed the entire planner stack.)

### Open / gated
- **Empirical real-goal closure measurement** is the remaining frontier. It is gated by (a) the free model's ~95s/call latency (a paid/faster planner model collapses a suite/closure run from multi-hour to minutes) and (b) full app boot requiring SSL certs absent in this environment (`mix run --no-start` only). Both are external resource gates; the durable engineering above is complete and folded to `main`.

---
_This spec is the contract the autonomy test suite and the optimizing loops build against. Implementation lands under `test/autonomy/` + `lib/orchid/autonomy/` + `lib/orchid/planner/` + `mix orchid.autonomy`._
