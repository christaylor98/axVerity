#!/usr/bin/env python3
"""W3 — threshold sizing: does ingest throughput separate 4 vs 8 vs 16?

Reads a round's cells-config.csv and reports, per
(strategy, profile, scale, ordering-count), the repetition count and the
observed interval for each threshold, then applies ONE declared
separation criterion:

    Two thresholds are SEPARATED iff their observed [min, max] ranges over
    repetitions are disjoint.

That is deliberately conservative and distribution-free: it makes no
normality assumption and cannot manufacture separation from a difference
that sits inside the repetition range, which is the failure mode the
intent names. Where ranges overlap the pair is reported UNSEPARATED with
the overlap stated, not quietly rounded to a ratio.

Usage: threshold-separation.py <cells-config.csv> [more.csv ...]
"""

import csv
import sys
from collections import defaultdict

THRESHOLD_ORDER = ["4", "8", "16", "unbounded"]


def main(paths):
    rows = defaultdict(list)
    for path in paths:
        with open(path, newline="") as fh:
            for r in csv.DictReader(fh):
                key = (r["strategy"], r["profile"], r["scale"], r["orderings"])
                rows[key].append((r["threshold"], float(r["triples_per_sec"]), r["round"]))

    for key in sorted(rows):
        strategy, profile, scale, ords = key
        by_thr = defaultdict(list)
        rounds = set()
        for thr, tps, rnd in rows[key]:
            by_thr[thr].append(tps)
            rounds.add(rnd)
        print(f"\n=== {strategy} / {profile} / {scale} / ordering-count {ords} "
              f"[rounds: {','.join(sorted(rounds))}] ===")
        for thr in THRESHOLD_ORDER:
            v = sorted(by_thr.get(thr, []))
            if not v:
                continue
            n = len(v)
            med = v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2
            print(f"  thr={thr:<9} n={n:<3} median={med:>12,.0f}  "
                  f"range=[{v[0]:>12,.0f}, {v[-1]:>12,.0f}]  "
                  f"spread={v[-1] / v[0]:.2f}x")

        bounded = [t for t in ("4", "8", "16") if by_thr.get(t)]
        for i in range(len(bounded)):
            for j in range(i + 1, len(bounded)):
                a, b = bounded[i], bounded[j]
                va, vb = sorted(by_thr[a]), sorted(by_thr[b])
                lo_a, hi_a, lo_b, hi_b = va[0], va[-1], vb[0], vb[-1]
                disjoint = hi_a < lo_b or hi_b < lo_a
                med_a = va[len(va) // 2]
                med_b = vb[len(vb) // 2]
                ratio = med_b / med_a if med_a else 0.0
                if disjoint:
                    gap = lo_b - hi_a if hi_a < lo_b else lo_a - hi_b
                    print(f"  {a} vs {b}: SEPARATED   median ratio {ratio:.2f}x, "
                          f"ranges disjoint by {gap:,.0f} tr/s")
                else:
                    overlap = min(hi_a, hi_b) - max(lo_a, lo_b)
                    print(f"  {a} vs {b}: UNSEPARATED median ratio {ratio:.2f}x, "
                          f"ranges overlap over {overlap:,.0f} tr/s "
                          f"([{lo_a:,.0f},{hi_a:,.0f}] vs [{lo_b:,.0f},{hi_b:,.0f}])")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
