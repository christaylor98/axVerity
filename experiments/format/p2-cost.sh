#!/usr/bin/env bash
# AXVERITY_FORMAT_LAND_AND_WIRE_V1 / P2 — COST_BASELINE_HELD.
#
# The baseline is 9.097 ms per durable block and 2.0000 fsyncs, measured in
# this same shipping substrate before the format landed
# (experiments/format/baseline.sh, reported in REPORT.md). This re-measures
# the same two quantities through the landed write path.
#
# It cannot reuse baseline.sh: that script feeds an undelimited byte stream and
# passes argv[2] as a BLOCK count, and the write path now takes a
# length-prefixed record stream with argv[2] as a RECORD count. Blocks are
# therefore counted from the store afterwards rather than assumed up front —
# which is the honest measure anyway, since under F1v the block count depends
# on how records pack.
#
# Two independent measures of the same number, as before:
#   wall — total process wall clock / blocks. No instrumentation at all, so it
#          cannot be biased by the ack path.
#   ack  — median of wp_wait_durable's own per-block wait, the pre-existing
#          opt-in instrument, unchanged.
# fsyncs are counted with strace, not assumed.
#
# Each run writes into a FRESH store, which is what makes it comparable to the
# baseline: B1's resolve scans the durable store, so on an empty one it costs
# nothing. That startup cost is real and is reported separately below.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
BIN="$ROOT/build/wp-slice"
F="$HERE/harness/target/release/fmth"
NREC=${NREC:-10000}
RUNS=${RUNS:-5}

OUT="$ROOT/.axverity-store/fmt/p2cost"
rm -rf "$OUT"; mkdir -p "$OUT"
CSV="$OUT/cost.csv"
echo "run,blocks,wall_ns,wall_ns_per_block,ack_median_ns,ack_p99_ns" > "$CSV"

INPUT="$OUT/corpus.bin"
"$F" corpus "$INPUT" $NREC mixed 5 > /dev/null

for r in $(seq 1 "$RUNS"); do
  D="$OUT/run-$r"; mkdir -p "$D"; cd "$D"
  t0=$(date +%s%N)
  "$BIN" "$INPUT" "$NREC" > run.log 2>&1
  t1=$(date +%s%N)
  wall=$((t1 - t0))
  BLK=$(find "$D/.axverity-store" -name 'block-*.bin' | wc -l)
  read -r med p99 <<<"$(python3 - "$D/.axverity-store/ack-bench.csv" <<'PY'
import sys
xs = sorted(int(l.split(',')[1]) for l in open(sys.argv[1]) if l.strip())
xs = xs[1:] if len(xs) > 1 else xs   # drop block 0: includes pipeline startup
print(xs[len(xs)//2], xs[min(len(xs)-1, int(len(xs)*0.99))])
PY
)"
  echo "$r,$BLK,$wall,$((wall / BLK)),$med,$p99" >> "$CSV"
  cd "$ROOT"
done

echo "--- fsync count per durable block (strace, 1 run) ---"
D="$OUT/strace"; mkdir -p "$D"; cd "$D"
strace -f -c -e trace=fsync,fdatasync,rename,openat -o "$OUT/strace.txt" \
  "$BIN" "$INPUT" "$NREC" > /dev/null 2>&1 || true
SBLK=$(find "$D/.axverity-store" -name 'block-*.bin' | wc -l)
cd "$ROOT"
grep -E 'fsync|rename|calls|---' "$OUT/strace.txt" | head -10
FSYNCS=$(awk '/fsync/{print $4}' "$OUT/strace.txt" | head -1)
echo "fsyncs_total=$FSYNCS  blocks=$SBLK  fsyncs_per_block=$(python3 -c "print(round(${FSYNCS:-0}/$SBLK,4))")"

echo
echo "--- $CSV ---"
column -t -s, "$CSV"
python3 - "$CSV" <<'PY'
import sys, statistics as st
rows = [l.strip().split(',') for l in open(sys.argv[1])][1:]
w = [int(r[3]) for r in rows]; a = [int(r[4]) for r in rows]
mw, ma = st.median(w)/1e6, st.median(a)/1e6
print(f"LANDED wall = {mw:.3f} ms/durable block   (baseline 9.097, delta {100*(mw-9.097)/9.097:+.1f}%)")
print(f"LANDED ack  = {ma:.3f} ms/durable block   (baseline 9.038, delta {100*(ma-9.038)/9.038:+.1f}%)")
PY

echo
echo "--- B1 startup resolve, the one cost the format ADDS (paid once per run) ---"
# Measured as the wall-clock difference between a run into an empty store and
# the same run into a store that already holds K blocks. Everything else about
# the two runs is identical, so the difference is the directory scan.
for K in 0 1000 5000; do
  D="$OUT/resolve-$K"; rm -rf "$D"; mkdir -p "$D/.axverity-store/structure" "$D/.axverity-store/payload"
  python3 - "$D/.axverity-store" "$K" <<'PY'
import sys, pathlib
root, k = pathlib.Path(sys.argv[1]), int(sys.argv[2])
for i in range(k):
    d = "structure" if i % 7 == 0 else "payload"
    (root / d / f"block-{i}.bin").write_bytes(b"\x00" * 16)
PY
  cd "$D"
  SMALL="$OUT/small.bin"
  [ -f "$SMALL" ] || "$F" corpus "$SMALL" 20 structure 3 > /dev/null
  t0=$(date +%s%N); "$BIN" "$SMALL" 20 > /dev/null 2>&1; t1=$(date +%s%N)
  cd "$ROOT"
  echo "  store held $K blocks -> total run $(python3 -c "print(f'{($t1-$t0)/1e6:.2f}')") ms"
done
