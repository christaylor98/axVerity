#!/usr/bin/env python3
"""W2 follow-up — per-run mode rate for the extra-ordering read penalty.

WHY THIS EXISTS. The first W2 pass (round-w2-wsprobe) pre-registered a
median-based falsification condition. The data then showed why that
statistic is under-powered here: source-bound latency is bimodal at
PROCESS granularity, not query granularity. A whole child process lands
either near 130 ns or near 250 ns for its entire measured pass; the median
of medians therefore snaps to one mode or the other and moves erratically
between repetitions. Zero-ballast arms landed in the slow mode in 0 of 42
runs; ballast-bearing arms did so routinely.

CLASSIFIER, and where it comes from. A run is SLOW if its source-bound p50
exceeds SLOW_NS. SLOW_NS = 180 is the midpoint of the two modes observed in
round-w2-wsprobe (~130 and ~250 ns). It is therefore derived from the first
pass and applied unchanged to the fresh runs of the confirmatory pass; it
is not tuned per arm.

FALSIFICATION CONDITION FOR H', STATED BEFORE THE CONFIRMATORY RUN.
  H' : additional resident working set raises the probability that a run
       lands in the slow mode.
  H' is FALSIFIED if slow_rate(ord6-ballast-100) - slow_rate(ord6-ballast-000)
       < 0.30, or if the slow rate is not monotone non-decreasing across
       ballast 000 -> 025 -> 050 -> 100 (ties allowed).
  SECONDARY, TLB-specific: with THP disabled, H' predicts
       slow_rate(ballast-100, THP off) >= slow_rate(ballast-100, THP on).
  H' is a POST-HOC hypothesis relative to the first pass. Nothing here
  upgrades it to a confirmed cause; it is registered so the confirmatory
  pass can fail it.

Usage: wsprobe-modes.py <wsprobe.csv> [more.csv ...]
"""

import csv
import sys
from collections import defaultdict

SLOW_NS = 180
BALLAST_ORDER = ["ord1", "ord3-ballast-000", "ord3-ballast-100",
                 "ord6-ballast-000", "ord6-ballast-025",
                 "ord6-ballast-050", "ord6-ballast-100"]


def main(paths):
    runs = defaultdict(list)
    for path in paths:
        with open(path, newline="") as fh:
            for r in csv.DictReader(fh):
                key = (r["scale"], r["threshold"], r["thp"])
                runs[key].append((r["arm"], int(r["p50_source_ns"]), int(r["rss_delta_kb"])))

    for key in sorted(runs):
        scale, thr, thp = key
        by_arm = defaultdict(list)
        rss = {}
        for arm, p50, kb in runs[key]:
            by_arm[arm].append(p50)
            rss.setdefault(arm, []).append(kb)
        print(f"\n=== scale={scale} threshold={thr} thp={thp}   "
              f"(slow := source-bound p50 > {SLOW_NS} ns) ===")
        rates = {}
        for arm in BALLAST_ORDER:
            v = by_arm.get(arm)
            if not v:
                continue
            slow = sum(1 for x in v if x > SLOW_NS)
            rates[arm] = slow / len(v)
            fast_vals = [x for x in v if x <= SLOW_NS]
            slow_vals = [x for x in v if x > SLOW_NS]
            fm = sum(fast_vals) / len(fast_vals) if fast_vals else float("nan")
            sm = sum(slow_vals) / len(slow_vals) if slow_vals else float("nan")
            print(f"  {arm:<20} n={len(v):<3} slow={slow:<3} rate={rates[arm]:.2f}  "
                  f"fast-mode mean={fm:6.0f} ns  slow-mode mean={sm:6.0f} ns  "
                  f"rss={sum(rss[arm]) // len(rss[arm]):,} KiB")

        b0 = rates.get("ord6-ballast-000")
        b100 = rates.get("ord6-ballast-100")
        if b0 is None or b100 is None:
            continue
        delta = b100 - b0
        seq = [rates.get(a) for a in ("ord6-ballast-000", "ord6-ballast-025",
                                      "ord6-ballast-050", "ord6-ballast-100")]
        seq = [x for x in seq if x is not None]
        monotone = all(seq[i] <= seq[i + 1] for i in range(len(seq) - 1))
        if delta >= 0.30 and monotone:
            verdict = "H' SURVIVES — ballast raises the slow-mode rate, monotonically"
        elif delta >= 0.30:
            verdict = (f"H' FALSIFIED — rate delta {delta:.2f} clears 0.30 but the "
                       f"ballast sweep is NOT monotone {['%.2f' % x for x in seq]}")
        else:
            verdict = f"H' FALSIFIED — rate delta {delta:.2f} < 0.30"
        print(f"  delta(b100 - b000) = {delta:.2f}   monotone={monotone}\n  {verdict}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
