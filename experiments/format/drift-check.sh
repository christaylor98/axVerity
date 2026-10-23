#!/usr/bin/env bash
# Short indicative drift check for the landed write path.
#
# The question this answers is NOT "what is the cost" — p2-cost.sh does that at
# length. It is "is 9.360 a regression or session noise", and the reason it
# could not be answered before is that both prior figures (9.097 legacy, 9.005
# at P2) are medians of five runs taken on ONE occasion each. Within-occasion
# spread was ~3.8%; cross-occasion spread was never measured at all, so there
# was no error bar that could resolve a 4% shift either way.
#
# So this runs three INDEPENDENT sessions rather than one longer one. Three
# session medians give the between-session spread directly, which is the
# quantity that was missing. Each session is deliberately small — ~60 blocks is
# enough for a stable median at ~9 ms/block and costs under a second per run.
#
# Sessions are spaced and gated on load, because the run that produced 9.360
# was taken while the machine was still shedding load from a 100k-record sweep,
# and that run contains its own proof: B1 resolve came back SLOWER at 0 blocks
# (21.22 ms) than at 1000 (16.70 ms), which cannot happen if the measurement is
# clean.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
BIN="$ROOT/build/wp-slice"
F="$HERE/harness/target/release/fmth"
NREC=${NREC:-2500}
RUNS=${RUNS:-3}
SESSIONS=${SESSIONS:-3}
OUT="$ROOT/.axverity-store/drift"

rm -rf "$OUT"; mkdir -p "$OUT"
"$F" corpus "$OUT/c.bin" "$NREC" mixed 5 > /dev/null
echo "session,run,blocks,wall_ns_per_block,ack_median_ns" > "$OUT/drift.csv"

wait_idle() {  # gate on load, but never hang: 60 s cap
  local i=0
  while [ "$(awk '{print ($1 < 0.60)}' /proc/loadavg)" != "1" ] && [ $i -lt 12 ]; do
    sleep 5; i=$((i+1))
  done
  awk '{printf "    load %s ", $1}' /proc/loadavg
}

for s in $(seq 1 "$SESSIONS"); do
  echo "── session $s"
  wait_idle
  echo ""
  for r in $(seq 1 "$RUNS"); do
    D="$OUT/s$s-r$r"; mkdir -p "$D"; cd "$D"
    t0=$(date +%s%N); "$BIN" "$OUT/c.bin" "$NREC" > run.log 2>&1; t1=$(date +%s%N)
    BLK=$(find "$D/.axverity-store" -name 'block-*.bin' | wc -l)
    ACK=$(python3 - "$D/.axverity-store/ack-bench.csv" <<'PY'
import sys
xs = sorted(int(l.split(',')[1]) for l in open(sys.argv[1]) if l.strip())
xs = xs[1:] if len(xs) > 1 else xs   # drop block 0: carries pipeline startup
print(xs[len(xs)//2])
PY
)
    echo "$s,$r,$BLK,$(( (t1-t0) / BLK )),$ACK" >> "$OUT/drift.csv"
    cd "$ROOT"
  done
  # fsync count once per session — the structural check. If the write path were
  # doing more durable work, this is the number that moves, and it is counted
  # rather than assumed.
  D="$OUT/s$s-strace"; mkdir -p "$D"; cd "$D"
  strace -f -c -e trace=fsync -o "$OUT/strace-$s.txt" "$BIN" "$OUT/c.bin" "$NREC" > /dev/null 2>&1 || true
  SB=$(find "$D/.axverity-store" -name 'block-*.bin' | wc -l)
  FS=$(awk '/fsync/{print $4}' "$OUT/strace-$s.txt" | head -1)
  echo "    fsyncs $FS / $SB blocks = $(python3 -c "print(round(${FS:-0}/$SB,4))")"
  cd "$ROOT"
  [ "$s" -lt "$SESSIONS" ] && sleep 10
done

echo
column -t -s, "$OUT/drift.csv"
echo
python3 - "$OUT/drift.csv" <<'PY'
import sys, statistics as st
rows = [l.strip().split(',') for l in open(sys.argv[1])][1:]
by = {}
for r in rows:
    by.setdefault(int(r[0]), []).append(int(r[3]))
meds = {s: st.median(v)/1e6 for s, v in sorted(by.items())}
print("session medians, ms/durable block:")
for s, m in meds.items():
    print(f"  session {s}: {m:.3f}")
vals = list(meds.values())
lo, hi, mid = min(vals), max(vals), st.median(vals)
print(f"\nbetween-session spread: {lo:.3f} .. {hi:.3f} ms  ({100*(hi-lo)/lo:.1f}%)")
print(f"median of session medians: {mid:.3f} ms")
for label, base in (("legacy pre-format", 9.097), ("P2 landed", 9.005), ("the suspect run", 9.360)):
    print(f"  vs {label:18s} {base:.3f} ms : {100*(mid-base)/base:+.1f}%")
print("\nread this as: a shift is only real if it exceeds the between-session spread.")
PY
