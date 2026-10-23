#!/usr/bin/env bash
# W5 population sweep for AXVERITY_READ_INDEX_RAM_TIER_V1.
#
# Two passes per population:
#   pop   — build the structures and stop; peak RSS is read from OUTSIDE the
#           process (getrusage on the child), so no filesystem primitive
#           appears anywhere in the M1 sources — the read tier must not be
#           able to touch disk even to measure itself.
#           bytes/triple is (RSS(n) - RSS(0)) / n.
#   bench — time every binding pattern.
#
# RSS(0) is a real run at population 0, so the baseline subtracts the process,
# the runtime and the bridge, leaving the structures.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
BIN=$HERE/readtier/build/rt-driver
POPS=${*:-0 1000 10000 100000}

# One child per invocation, so ru_maxrss is that child's peak and nothing else.
rss_kb() {
  python3 -c '
import subprocess, resource, sys
subprocess.run([sys.argv[1], "pop", sys.argv[2]], stdout=subprocess.DEVNULL)
print(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)
' "$BIN" "$1"
}

echo "=== resident cost (peak RSS, KiB) ==="
BASE=$(rss_kb 0)
echo "baseline(n=0)=${BASE}"
for n in $POPS; do
  [ "$n" = "0" ] && continue
  R=$(rss_kb "$n")
  echo "n=$n peak_rss_kb=$R bytes_per_triple=$(( (R - BASE) * 1024 / n ))"
done

echo
echo "=== per-pattern latency ==="
for n in $POPS; do
  [ "$n" = "0" ] && continue
  echo "--- population=$n ---"
  "$BIN" bench "$n" | grep -v '^failures='
done
