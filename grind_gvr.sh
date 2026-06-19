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

# --- Preflight quota guard (added 2026-06-19) ----------------------------------
# nex-n2-pro is OpenRouter FREE-ONLY (no paid variant; $5 credit does NOT lift the
# per-model free daily cap). The c175 grind launched into an exhausted 2000/day
# free quota and produced a 100% 429-CONTAMINATED false-0.0 (all 10 plan-approvals
# discarded). This guard makes ONE minimal free-model call, reads the live
# X-RateLimit-Remaining header, and ABORTS before the multi-hour grind if the
# daily free quota is exhausted — so the auto-relaunch can never re-contaminate.
preflight_quota() {
  local key remaining
  key=$(python3 -c "import json;print(json.load(open('.orchid/facts.local.json'))['openrouter_api_key'])") || {
    echo "[preflight] could not read OpenRouter key; proceeding (in-suite retry will handle transients)"; return 0; }
  remaining=$(curl -s -D - -o /dev/null -X POST https://openrouter.ai/api/v1/chat/completions \
    -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
    -d '{"model":"nex-agi/nex-n2-pro:free","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="x-ratelimit-remaining"{print $2}' | tail -1)
  echo "[preflight] free-model X-RateLimit-Remaining=${remaining:-unknown}"
  # Abort ONLY on an explicit 0 (exhausted). Empty/unknown header => proceed
  # (a missing header must not block; the bounded in-suite retry handles transients).
  if [ "$remaining" = "0" ]; then
    echo "[preflight] ABORT: free-model daily quota exhausted (remaining=0). NOT launching the grind"
    echo "[preflight] (avoids a 429-contaminated false-0.0). Retry after the 00:00 UTC daily reset."
    exit 3
  fi
}
preflight_quota
# ------------------------------------------------------------------------------

# The 4 EASY benchmarks (flat baseline 0.833, in last_report.json). Needed under
# gvr for the H1 no-easy-regression half: H1 = gvr beats flat on the discriminators
# AND does NOT regress the easy goals. grind_gvr.sh covered only the discriminator
# half; without these 4 the no-regression check is unmeasurable.
EASY_IDS="build_cli_wordcount,operate_service_health,recover_broken_healthcheck,research_incident_summary"

# Discriminators FIRST (the decisive half — captured before any quota drawdown).
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] starting gvr DISCRIMINATOR grind (rounds=6 depth=1 — adequate revision budget, no deep recursion)"
mix orchid.autonomy \
  --mode gvr \
  --runs 3 \
  --only "$ONLY_IDS" \
  --out priv/autonomy/discriminators_gvr.json \
  --gvr-memoize \
  --max-rounds 6 \
  --max-delegate-depth 1
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] gvr DISCRIMINATOR grind DONE (exit $?)"

# Easy goals under gvr (for the no-regression half). Separate --out so the
# analyzer can compare against the flat-easy 0.833 baseline (last_report.json).
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] starting gvr EASY grind (no-regression half)"
mix orchid.autonomy \
  --mode gvr \
  --runs 3 \
  --only "$EASY_IDS" \
  --out priv/autonomy/easy_gvr.json \
  --gvr-memoize \
  --max-rounds 6 \
  --max-delegate-depth 1
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] gvr EASY grind DONE (exit $?)"
