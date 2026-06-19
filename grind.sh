#!/usr/bin/env bash
set -euo pipefail

ONLY_IDS="budget_constrained_build_order,oscillating_constraint_refactor,garden_path_diagnosis"

mkdir -p priv/autonomy

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] starting flat discriminator grind"
mix orchid.autonomy \
  --mode flat \
  --runs 3 \
  --only "$ONLY_IDS" \
  --out priv/autonomy/discriminators_flat.json \
  --gvr-memoize

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] starting gvr discriminator grind"
mix orchid.autonomy \
  --mode gvr \
  --runs 3 \
  --only "$ONLY_IDS" \
  --out priv/autonomy/discriminators_gvr.json \
  --gvr-memoize

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] discriminator grind complete"
