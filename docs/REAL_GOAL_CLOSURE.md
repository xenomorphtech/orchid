# Real-Goal Closure — Orchid's autonomous goal-pursuit capability

This document is the **no-AI-in-loop reproducibility recipe** for Orchid's core
capability: closing real, externally-defined goals end-to-end through the
production planner→executor path, and regression-checking that capability with
one command.

## What "closure" means

A goal is **closed** when the system, unattended, drives a fresh sandbox project
from an objective string to a state that satisfies the goal's **own external
shell success-check** (e.g. `mix test` exit 0, or a file-content invariant) —
with **no agent reasoning in the loop at run time**. The external check is the
ground truth, never Orchid's internal self-report.

## The production path (what every closure exercises)

```
GoalWatcher.runtime_planner_request
  → RuntimeGoal.from_goal_watcher
  → Router            (routes :flat | :gvr on runtime markers)
  → resolved planner  (flat agent  OR  Orchid.Planner.plan/3 G-V-R)
  → executor          (per-goal Podman sandbox; torn down after)
```

`Router` picks `:gvr` when the objective carries planning markers
(constraint / ordering / dependency / refactor / multi-step + a tight step
budget); otherwise `:flat`. The runner supports a forced `--mode flat|gvr`
override (`lib/orchid/autonomy/runner.ex`) — still the real planner path, not a
test shortcut.

## Proven capability (on `main`)

| Branch | Goals closed | Harness |
|---|---|---|
| `:flat` | 4 real goals: `alpha_marker_file`, `bravo_executable_script`, `charlie_status_json`, `echo_multifile` (multi-file, exact-content `cmp`) | `lib/mix/tasks/orchid.real_goal_closure.ex` |
| `:gvr` | 1 real goal: `delta_dependency_order_refactor` (routes `:gvr`, closes nudges=0) | `lib/mix/tasks/orchid.gvr_real_goal_closure.ex` |

Each goal closes via its **own** external shell check. Facts:
`orchid_real_goal_closure`, `orchid_gvr_real_goal_closure`, `orchid_widen_flat`.

## The standing regression oracle (one command)

`mix orchid.closure_regression` runs the flat suite + a gvr goal through the
production path and emits one combined `priv/autonomy/closure_regression.json`
with `overall_pass`. **`make regression`** wraps it as a CI gate: it runs the
oracle and asserts `overall_pass` via `jq`, exiting non-zero on a real
regression.

```
make regression        # run the oracle + gate on overall_pass (needs OPENROUTER_API_KEY)
make closure-flat      # flat suite only
make closure-gvr       # gvr goal only
make regression-report # pretty-print the last report
```

`overall_pass` = (flat arm closes all goals) AND (gvr arm closes ≥1 **OR** its
non-closure is classified `free_model_convergence_variance`). A flat goal
failing is a **real** regression and fails the gate; a transient free-model
flake on the gvr arm is **not**.

## Flake resilience

The flat arm wraps each goal's run in a **bounded per-goal retry** that fires
**only** on a transient free-model reliability flake (`reliability_failure ==
true`: empty-200 / 429 / timeout), bounded at `max_retries = 2` (gvr arm = 0). A
**genuine** (non-reliability) failure is recorded immediately and never retried
— so the gate cannot be made green by masking a real defect. Live-validated
firing on real `:not_found` and `:timeout` planner flakes
(`orchid_flake_resilience_live_validated`).

## The model gate

Closures run on the FREE model `nex-agi/nex-n2-pro:free` (2000 req/day, resets
00:00 UTC; flaky empty-200 / 429 / timeout). This is sufficient to **close**
real goals on both branches. The one capability it does **not** settle is the
**discriminator** — whether G-V-R planning measurably *beats* flat on
hard planning gaps — because the free model's run-to-run convergence variance
floors the gvr arm stochastically. Settling that needs a paid / stronger
OpenRouter planner model; it is a money/third-party gate, not a code gap.

## Reproduce from scratch

```
cp .orchid/facts.local.json.example .orchid/facts.local.json   # add OPENROUTER_API_KEY
make deps && make compile
make regression
```

Requires Podman (per-goal sandboxes) and `jq`. The run is bounded; do not loop
it (free-model quota).
