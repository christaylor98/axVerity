#!/usr/bin/env bash
# AXVERITY_DURABLE_FORMAT_V1 / P0 — reproduce the write path's cost baseline
# IN THE SHIPPING SUBSTRATE (MEASURE_IN_THE_SHIPPING_SUBSTRATE).
#
# The intent's 8.89 ms/block, 2 fsyncs figure came from experiments/blockid,
# a Rust hand-replica of the bridge's write_durable(). This re-measures the
# same quantity through the real thing: the real wp-slice binary, the real
# fs_write_raw, the real fsyncs, on the repo's own filesystem.
#
# Two independent measures of the same number:
#   wall  — total process wall clock / N. Needs no instrumentation at all
#           and so cannot be biased by the ack path.
#   ack   — median of wp_wait_durable's own per-block wait (ack-bench.csv),
#           which after block 0 is the interval between consecutive durable
#           writes. This is the pre-existing opt-in instrument, unchanged.
# fsync count is counted directly with strace, not assumed.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
BIN="$ROOT/build/wp-slice"
N=${N:-300}
RUNS=${RUNS:-5}
PCAP=56   # lib/wp_block_capacity.m1 (64) - lib/wp_footer_size.m1 (8)

OUT="$ROOT/.axverity-store/fmt/baseline"
rm -rf "$OUT"; mkdir -p "$OUT"
CSV="$OUT/baseline.csv"
echo "run,blocks,wall_ns,wall_ns_per_block,ack_median_ns,ack_p99_ns" > "$CSV"

INPUT="$OUT/input.bin"
head -c $((PCAP * N)) /dev/urandom > "$INPUT"

for r in $(seq 1 "$RUNS"); do
  D="$OUT/run-$r"; mkdir -p "$D"; cd "$D"
  t0=$(date +%s%N)
  "$BIN" "$INPUT" "$N" > run.log 2>&1
  t1=$(date +%s%N)
  wall=$((t1 - t0))
  read -r med p99 <<<"$(python3 - "$D/.axverity-store/ack-bench.csv" <<'PY'
import sys
xs = sorted(int(l.split(',')[1]) for l in open(sys.argv[1]) if l.strip())
xs = xs[1:] if len(xs) > 1 else xs   # drop block 0: includes pipeline startup
print(xs[len(xs)//2], xs[min(len(xs)-1, int(len(xs)*0.99))])
PY
)"
  echo "$r,$N,$wall,$((wall / N)),$med,$p99" >> "$CSV"
  cd "$ROOT"
done

echo "--- fsync count per durable block (strace, 1 run of $N blocks) ---"
D="$OUT/strace"; mkdir -p "$D"; cd "$D"
strace -f -c -e trace=fsync,fdatasync,rename,openat -o "$OUT/strace.txt" \
  "$BIN" "$INPUT" "$N" > /dev/null 2>&1 || true
cd "$ROOT"
grep -E 'fsync|rename|calls|---' "$OUT/strace.txt" | head -10
FSYNCS=$(awk '/fsync/{print $4}' "$OUT/strace.txt" | head -1)
echo "fsyncs_total=$FSYNCS  blocks=$N  fsyncs_per_block=$(python3 -c "print(round(${FSYNCS:-0}/$N,4))")"

echo "--- $CSV ---"
column -t -s, "$CSV"
python3 - "$CSV" <<'PY'
import sys, statistics as st
rows = [l.strip().split(',') for l in open(sys.argv[1])][1:]
w = [int(r[3]) for r in rows]; a = [int(r[4]) for r in rows]
print(f"BASELINE wall  = {st.median(w)/1e6:.3f} ms/durable block (median of {len(w)} runs)")
print(f"BASELINE ack   = {st.median(a)/1e6:.3f} ms/durable block (median of run medians)")
PY
