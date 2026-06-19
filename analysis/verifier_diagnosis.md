# Verifier Diagnosis

## Scope

Task 1 instrumented every verifier verdict in `Orchid.Planner.generate_and_verify/5`.
The log now records both `:approved` reasons and `:flawed` critiques before
`Planner.plan_tasks/3` collapses candidate results into a rejection summary.

The briefing asked for `mix orchid.autonomy --mode gvr --runs 1`, but this
worktree rejects that command:

```text
** (Mix) --runs must be an integer >= 3, got: 1
```

I kept a single planning-gap benchmark active, `garden_path_diagnosis.exs`, and
ran the minimum accepted sample:

```text
mix orchid.autonomy --mode gvr --runs 3
```

Result: `goal_closure_rate` was `0.0` for the filtered benchmark.

## Evidence

Run 1 failed before a verifier verdict:

```text
All generated plans failed verification: path 1 error: no decodable JSON array found
```

Run 2 reached the verifier and logged a real `:flawed` verdict:

```text
[GVR] verifier path 1/1: flawed:
Revise `write_diagnosis` to require `ops/diagnosis.txt` to include explicit lines such as `root_cause: ...token audience...`, `rejected_hypothesis: cache size hypothesis rejected...`, and `verification: ...invalid_audience/401/orchid-api evidence...`, and make `apply_verified_fix` explicitly depend on the verified diagnosis output before editing config.
```

The run then stopped at planner failure with no executed steps:

```text
"error": "{:gvr_planner_failed, \"All generated plans failed verification: path 1 flawed: Revise `write_diagnosis` ...\"}"
"depth": 0
"steps": []
```

Run 3 also failed before a verifier verdict:

```text
All generated plans failed verification: path 1 error: task 1: type must be delegate or tool
```

The relevant code path matches the runtime behavior:

- `Planner.plan_tasks/3` reads `max_iterations` into `_max_iterations`, but no
  iteration or revision loop uses it.
- `generate_and_verify/5` calls `Generator.generate/3` once and then
  `Verifier.verify/3` once.
- `{:flawed, critique}` is returned as a rejected path result.
- If no path is approved, `plan_tasks/3` returns `{:error, rejected_summary}`.
- `Runner.run_gvr_loop/8` treats that planner error as terminal
  `{:gvr_planner_failed, reason}` instead of feeding the critique back into the
  generator.

## Classification

Dominant cause: **(c) missing/weak revise loop**.

The only observed verifier `:flawed` verdict was not a malformed verifier
response. It was a specific, fixable critique about preserving verified
diagnosis evidence before editing config, which is aligned with the benchmark's
objective and success check. The G-V-R loop wasted that critique by aborting the
sample at depth 0 instead of revising and retrying within the planner budget.

Not dominant: **(a) verifier parse artifact**. No logged verifier verdict used
the `Verifier returned a non-JSON or invalid decision` fallback. The parse
failures in this sample came from the generator output before verifier execution:
one non-decodable task array and one task with an invalid type.

Not dominant: **(b) too-strict verifier rubric**. The observed critique asks for
explicit root cause, rejected hypothesis, verification evidence, and dependency
ordering. Those requirements directly match the benchmark objective and shell
success check, so the rejection appears correct rather than over-strict.

## Fix Direction

Implement a real revise-and-retry loop for flawed plans. A verifier critique
should be passed back to the generator as revision context and retried within
`max_iterations`/G-V-R budget. Generator JSON wobble should also be treated as
retryable planner feedback, but that is separate from verifier over-rejection.
