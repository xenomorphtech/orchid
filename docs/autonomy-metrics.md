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
_This spec is the contract the autonomy test suite and the optimizing loops build against. Implementation lands under `test/autonomy/` + `lib/orchid/autonomy/` + `mix orchid.autonomy`._
