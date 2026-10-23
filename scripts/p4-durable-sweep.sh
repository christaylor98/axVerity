#!/usr/bin/env bash
# AXVERITY_FORMAT_LAND_AND_WIRE_V1 / P4 — the durable read tier, measured.
#
# SHORT_SWEEPS: populations cap at 10k and one repetition, because slope
# settles linear-vs-quadratic in two points and a decade is a 10x-vs-100x tell.
# Anything past that is extrapolated and labelled as such.
#
# Each population gets its OWN store, written by a real wp-slice process, then
# read by a separate rt-driver process that never saw the writer. The rebuild
# cost is therefore a cold cost including the first open of every block.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
BIN="$HERE/build/wp-slice"
RT="$HERE/readtier/build/rt-driver"
F="$HERE/experiments/format/harness/target/release/fmth"
OUT="$HERE/.axverity-store/p4"
POPS=${*:-1000 10000}

rm -rf "$OUT"; mkdir -p "$OUT"
echo "n,blocks,durable_bytes,records,names,rebuild_ns,rebuild_ns_per_record,bytes_per_triple" > "$OUT/rebuild.csv"

for N in $POPS; do
  D="$OUT/n$N"; mkdir -p "$D"
  "$F" corpus "$D/c.bin" "$N" structure 1 > /dev/null
  ( cd "$D" && "$BIN" "$D/c.bin" "$N" ) > "$D/write.log" 2>&1 || { echo "writer failed at $N"; continue; }
  BLK=$(ls "$D/.axverity-store/structure" | wc -l)
  BY=$(du -sb "$D/.axverity-store/structure" | cut -f1)
  ( cd "$D" && "$RT" rebuild ) > "$D/rb.txt" 2>&1
  REC=$(grep -m1 -o 'rebuild_records=[0-9]*'  "$D/rb.txt" | cut -d= -f2)
  NAM=$(grep -m1 -o 'rebuild_names=[0-9]*'    "$D/rb.txt" | cut -d= -f2)
  NS=$( grep -m1 -o 'rebuild_ns=[0-9]*'       "$D/rb.txt" | cut -d= -f2)
  echo "$N,$BLK,$BY,$REC,$NAM,$NS,$((NS / REC)),$((BY / REC))" >> "$OUT/rebuild.csv"
  # Pattern latency and point reads against the rebuilt structures.
  ( cd "$D" && "$RT" coldbench "$N" ) > "$D/cb.txt" 2>&1
done

echo
echo "── cold rebuild from the structure stream ──"
column -t -s, "$OUT/rebuild.csv"

echo
echo "── per-pattern latency AFTER a cold rebuild (ns/op) ──"
printf "%-10s" "n"; for m in 1 4 3 6 5 7 2 0; do printf "%-12s" "mask$m"; done; echo
for N in $POPS; do
  D="$OUT/n$N"; [ -f "$D/cb.txt" ] || continue
  printf "%-10s" "$N"
  for m in 1 4 3 6 5 7 2 0; do
    printf "%-12s" "$(grep -m1 "pattern mask=$m " "$D/cb.txt" | grep -o 'ns_per_op=[0-9]*' | cut -d= -f2)"
  done
  echo
done

echo
echo "── point read: name -> RID -> bytes (ns/op) ──"
for N in $POPS; do
  D="$OUT/n$N"; [ -f "$D/cb.txt" ] || continue
  echo "  n=$N  $(grep -m1 'point_read' "$D/cb.txt")"
done

echo
echo "── slope (linear = ratio tracks the population ratio) ──"
python3 - "$OUT/rebuild.csv" <<'PY'
import sys
rows = [l.strip().split(',') for l in open(sys.argv[1])][1:]
if len(rows) < 2:
    print("  (need two populations for a slope)"); sys.exit()
for a, b in zip(rows, rows[1:]):
    pn, cn = int(a[0]), int(b[0])
    pt, ct = int(a[5]), int(b[5])
    print(f"  n {pn} -> {cn} is {cn/pn:.0f}x population and {ct/pt:.2f}x rebuild time "
          f"({int(a[6])} -> {int(b[6])} ns/record)")
PY
