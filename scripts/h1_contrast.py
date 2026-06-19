#!/usr/bin/env python3
"""H1 contrast analyzer for the Orchid at-scale discriminator suite.

Computes the decisive H1 number: does :gvr beat :flat on the 3 planning-gap
discriminators (budget_constrained_build_order, oscillating_constraint_refactor,
garden_path_diagnosis) WITHOUT easy-goal regression?

Pure stdlib. No agent/AI in the loop — reads the two report jsons that
`mix orchid.autonomy --out <path>` writes and prints the contrast. This is the
codified reader so the post-reset tick is `run grind -> run this -> bank`.

Usage:
  scripts/h1_contrast.py --flat priv/autonomy/discriminators_flat.json \
                         --gvr  priv/autonomy/discriminators_gvr.json \
                         [--easy-baseline priv/autonomy/last_report.json] \
                         [--json]

Exit codes: 0 = computed; 2 = a report missing/malformed (so a tick can branch).
"""
import argparse
import json
import sys


def load(path):
    with open(path) as f:
        return json.load(f)


def by_id(report):
    """Map benchmark id -> goal_closure_rate."""
    return {b["id"]: b.get("goal_closure_rate") for b in report.get("benchmarks", [])}


def agg(report):
    return report.get("summary", {}).get("goal_closure_rate")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--flat", required=True)
    ap.add_argument("--gvr", required=True)
    ap.add_argument("--easy-baseline", default=None,
                    help="optional report whose summary.goal_closure_rate is the easy-goal baseline for the no-regression check")
    ap.add_argument("--json", action="store_true", help="emit machine-readable JSON instead of text")
    args = ap.parse_args()

    try:
        flat, gvr = load(args.flat), load(args.gvr)
    except (OSError, json.JSONDecodeError) as e:
        print(f"ERROR: could not load a report: {e}", file=sys.stderr)
        return 2

    flat_ids, gvr_ids = by_id(flat), by_id(gvr)
    flat_agg, gvr_agg = agg(flat), agg(gvr)
    if flat_agg is None or gvr_agg is None:
        print("ERROR: a report is missing summary.goal_closure_rate (malformed/incomplete)", file=sys.stderr)
        return 2

    shared = sorted(set(flat_ids) & set(gvr_ids))
    per = []
    for bid in shared:
        f, g = flat_ids[bid], gvr_ids[bid]
        per.append({"id": bid, "flat": f, "gvr": g,
                    "delta": (None if f is None or g is None else round(g - f, 4))})

    aggregate_delta = round(gvr_agg - flat_agg, 4)
    # H1 = gvr beats flat on the discriminators in aggregate (delta > 0), and no
    # discriminator regresses below its flat value by more than noise (>0.0).
    improved = [p for p in per if p["delta"] is not None and p["delta"] > 0]
    regressed = [p for p in per if p["delta"] is not None and p["delta"] < 0]

    regression_check = None
    if args.easy_baseline:
        try:
            easy = load(args.easy_baseline)
            easy_agg = agg(easy)
            regression_check = {
                "easy_baseline_agg": easy_agg,
                "gvr_agg_on_discriminators": gvr_agg,
                "note": "compare gvr easy-goal closure (separate easy run) against this baseline; this report is discriminators-only",
            }
        except (OSError, json.JSONDecodeError) as e:
            regression_check = {"error": str(e)}

    h1_supported = aggregate_delta > 0 and not regressed

    result = {
        "flat_aggregate": flat_agg,
        "gvr_aggregate": gvr_agg,
        "aggregate_delta": aggregate_delta,
        "per_discriminator": per,
        "improved": [p["id"] for p in improved],
        "regressed": [p["id"] for p in regressed],
        "h1_supported": h1_supported,
        "easy_regression_check": regression_check,
        "flat_generated_at": flat.get("generated_at"),
        "gvr_generated_at": gvr.get("generated_at"),
    }

    if args.json:
        print(json.dumps(result, indent=2))
        return 0

    print("=== Orchid H1 contrast: :gvr vs :flat on the 3 discriminators ===")
    print(f"flat aggregate goal_closure_rate: {flat_agg:.4f}  ({flat.get('generated_at')})")
    print(f"gvr  aggregate goal_closure_rate: {gvr_agg:.4f}  ({gvr.get('generated_at')})")
    print(f"AGGREGATE DELTA (gvr - flat):     {aggregate_delta:+.4f}")
    print()
    print(f"{'discriminator':<36} {'flat':>6} {'gvr':>6} {'delta':>8}")
    for p in per:
        fs = "n/a" if p["flat"] is None else f"{p['flat']:.3f}"
        gs = "n/a" if p["gvr"] is None else f"{p['gvr']:.3f}"
        ds = "n/a" if p["delta"] is None else f"{p['delta']:+.3f}"
        print(f"{p['id']:<36} {fs:>6} {gs:>6} {ds:>8}")
    print()
    print(f"improved:  {', '.join(p['id'] for p in improved) or '(none)'}")
    print(f"regressed: {', '.join(p['id'] for p in regressed) or '(none)'}")
    print(f"H1 SUPPORTED (aggregate gain AND no discriminator regression): {h1_supported}")
    if regression_check:
        print(f"easy-regression check: {regression_check}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
