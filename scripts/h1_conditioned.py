#!/usr/bin/env python3
"""H1 conditioned-metric analyzer for the Orchid discriminator suite.

The binary `goal_closure_rate` is blind to two things that dominate the
flat-vs-gvr discriminator contrast on the flaky FREE model:

  1. PLANNER-RELIABILITY noise — gvr samples that die with
     `{:gvr_planner_failed, ...}` (status `agent_error`) never produced a
     runnable plan, so they measure free-model output reliability, NOT plan
     quality. Counting them as closure-0 floors gvr for a reason unrelated to
     the hypothesis.
  2. ORDINAL execution depth — `unattended_depth` (already in every sample's
     `score` dict) shows how far a plan actually executed before stalling. Two
     arms can both score closure 0.0 while differing sharply in depth.

This reader, given the two report JSONs `mix orchid.autonomy --out` writes,
reports per benchmark + aggregate:
  - raw binary closure (unchanged, for back-compat)
  - planner_failed_rate (fraction of samples = {:gvr_planner_failed})
  - clean-sample-conditioned closure (exclude planner_failed samples)
  - unattended_depth mean/max (all samples, and clean-only)
  - clean sample count (n) — so thin-sample verdicts are visible, not hidden.

No agent/AI in the loop: pure stdlib reader over the committed JSON. Reusable
for any flat/gvr report pair (free OR paid model).

Usage:
  scripts/h1_conditioned.py --a priv/autonomy/discriminators_flat_elixir.json \
                            --b priv/autonomy/discriminators_gvr_budget_elixir.json \
                            [--a-label flat] [--b-label gvr] [--json]
Exit: 0 ok; 2 a report missing/malformed.
"""
import argparse
import json
import sys

PLANNER_FAILED_MARK = "gvr_planner_failed"


def load(path):
    with open(path) as f:
        return json.load(f)


def sample_status(s):
    return s.get("status")


def sample_depth(s):
    return (s.get("score") or {}).get("unattended_depth")


def sample_closed(s):
    return bool((s.get("score") or {}).get("goal_closure"))


def sample_planner_failed(s):
    # a gvr sample whose result.error names gvr_planner_failed, or agent_error
    # with that marker anywhere in the result blob
    if s.get("status") != "agent_error":
        return False
    blob = json.dumps(s.get("result") or {})
    return PLANNER_FAILED_MARK in blob


def summarize_benchmark(b):
    samples = b.get("samples", [])
    n = len(samples)
    failed = [s for s in samples if sample_planner_failed(s)]
    clean = [s for s in samples if not sample_planner_failed(s)]
    depths_all = [sample_depth(s) for s in samples if isinstance(sample_depth(s), int)]
    depths_clean = [sample_depth(s) for s in clean if isinstance(sample_depth(s), int)]
    closed_all = sum(1 for s in samples if sample_closed(s))
    closed_clean = sum(1 for s in clean if sample_closed(s))

    def meanmax(xs):
        return (None, None) if not xs else (round(sum(xs) / len(xs), 2), max(xs))

    dm_all, dx_all = meanmax(depths_all)
    dm_clean, dx_clean = meanmax(depths_clean)
    return {
        "id": b.get("id"),
        "n": n,
        "planner_failed": len(failed),
        "planner_failed_rate": (None if n == 0 else round(len(failed) / n, 3)),
        "closure_raw": (None if n == 0 else round(closed_all / n, 3)),
        "closure_clean": (None if not clean else round(closed_clean / len(clean), 3)),
        "clean_n": len(clean),
        "depth_mean_all": dm_all, "depth_max_all": dx_all,
        "depth_mean_clean": dm_clean, "depth_max_clean": dx_clean,
        "statuses": [sample_status(s) for s in samples],
        "depths": [sample_depth(s) for s in samples],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True)
    ap.add_argument("--b", required=True)
    ap.add_argument("--a-label", default="A")
    ap.add_argument("--b-label", default="B")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    try:
        ra, rb = load(args.a), load(args.b)
    except (OSError, json.JSONDecodeError) as e:
        print(f"ERROR: could not load a report: {e}", file=sys.stderr)
        return 2

    a_by = {b["id"]: summarize_benchmark(b) for b in ra.get("benchmarks", [])}
    b_by = {b["id"]: summarize_benchmark(b) for b in rb.get("benchmarks", [])}
    shared = sorted(set(a_by) & set(b_by))
    rows = []
    for bid in shared:
        rows.append({"id": bid, args.a_label: a_by[bid], args.b_label: b_by[bid]})

    if args.json:
        print(json.dumps({"a_label": args.a_label, "b_label": args.b_label,
                          "benchmarks": rows}, indent=2))
        return 0

    print(f"=== Orchid H1 conditioned contrast: {args.a_label} vs {args.b_label} ===")
    for r in rows:
        a, b = r[args.a_label], r[args.b_label]
        print(f"\n# {r['id']}")
        print(f"  {'metric':<26} {args.a_label:>12} {args.b_label:>12}")
        for label, key in [
            ("closure_raw", "closure_raw"),
            ("planner_failed_rate", "planner_failed_rate"),
            ("closure_clean (n)", None),
            ("depth_mean_all", "depth_mean_all"),
            ("depth_max_all", "depth_max_all"),
            ("depth_mean_clean", "depth_mean_clean"),
        ]:
            if key is None:
                av = f"{a['closure_clean']} ({a['clean_n']})"
                bv = f"{b['closure_clean']} ({b['clean_n']})"
            else:
                av, bv = a[key], b[key]
            print(f"  {label:<26} {str(av):>12} {str(bv):>12}")
        print(f"  statuses {args.a_label}: {a['statuses']}  depths: {a['depths']}")
        print(f"  statuses {args.b_label}: {b['statuses']}  depths: {b['depths']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
