#!/usr/bin/env bash
set -uo pipefail
# gvr discriminator grind: rounds=6 (full revision budget — needed for the
# verifier->reviser to APPROVE a plan on the flaky free model; rounds=1 in the
# c170 over-correction caused {:gvr_planner_failed, "No approved plan after
# revision budget"} -> 0 execution -> false 0.0 closure) but depth=1 (the
# recursive sub-goal delegation at depth=3 was the real slowness culprit, NOT
# the rounds). This is the tractable config that still lets gvr execute.
ONLY_IDS="budget_constrained_build_order,oscillating_constraint_refactor,garden_path_diagnosis"
mkdir -p priv/autonomy
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] starting gvr grind (rounds=6 depth=1 — adequate revision budget, no deep recursion)"
mix orchid.autonomy \
  --mode gvr \
  --runs 3 \
  --only "$ONLY_IDS" \
  --out priv/autonomy/discriminators_gvr.json \
  --gvr-memoize \
  --max-rounds 6 \
  --max-delegate-depth 1
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] gvr grind DONE (exit $?)"
