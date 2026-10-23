#!/usr/bin/env bash
# AXVERITY_DURABLE_FORMAT_V1 / P1 — FRAMING.
#
# Builds and measures every declared framing candidate, including the ones
# that lose (NO_RESULT_DISCARDED). Nothing is settled by argument here; each
# row below is a run.
#
#   F0   baseline, unframed          the live format, the control
#   F1f  fixed 4-byte length prefix
#   F1v  LEB128 length prefix
#   F2   trailing directory per block
#   F3   fixed-width slots
#
# Measures, in order of the intent's priority:
#   T1  round trip across a REAL process restart
#   T2  crash correctness by REAL SIGKILLs at unaligned points
#   T3  per-record overhead, bytes and nanoseconds, by record size
#   T4  write cost per durable block against the 9.10 ms substrate baseline
#   T7  record-size distribution — decides whether F3 applies at all
#
# The writers are M1 through the real bridge and the real fs_write_raw
# (MEASURE_IN_THE_SHIPPING_SUBSTRATE). The decoder is the independent Rust
# one in harness/, which shares no code with them.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
F="$HERE/harness/target/release/fmth"
P="$ROOT/experiments/format-m1/build/fmt-probe"
OUT="$ROOT/.axverity-store/fmt/p1"
rm -rf "$OUT"; mkdir -p "$OUT"
cd "$ROOT"

# Caps are chosen per corpus, not per candidate, and every candidate sees the
# same cap on the same corpus. STRUCT_CAP is a realistic block; SMALL_CAP is
# the live path's own 64 bytes, kept so one column is directly comparable to
# the shipping write path; MIXED_CAP has to clear the corpus's largest record
# because no framed candidate can span a block (measured below, not assumed).
STRUCT_CAP=4096
SMALL_CAP=64
MIXED_CAP=16384
W_STRUCT=20      # F3 slot width for the structure corpus: max record 14 + 4
W_MIXED=8192     # F3 slot width for the mixed corpus: max record 8176 + 4

echo "════════ T7  record-size distribution (decides whether F3 applies)"
for D in structure mixed; do
  "$F" corpus "$OUT/$D-100k.bin" 100000 $D 4242 > "$OUT/dist-$D.txt"
  "$F" flatten "$OUT/$D-100k.bin" "$OUT/$D-100k.flat" > /dev/null
  echo "── $D"; sed 's/^/   /' "$OUT/dist-$D.txt"
done

# Smaller working corpora, so a durable run is seconds not minutes.
for N in 1000 10000 50000; do
  "$F" corpus "$OUT/structure-$N.bin" $N structure 4242 > /dev/null
  "$F" flatten "$OUT/structure-$N.bin" "$OUT/structure-$N.flat" > /dev/null
done
"$F" corpus "$OUT/mixed-5000.bin" 5000 mixed 4242 > /dev/null
"$F" flatten "$OUT/mixed-5000.bin" "$OUT/mixed-5000.flat" > /dev/null

# corpus_bytes: the payload the format has to carry. Everything a durable
# store holds beyond this is framing overhead plus footers.
cb() { python3 -c "
import sys,struct
b=open(sys.argv[1],'rb').read(); i=0; t=0; n=0
while i+8<=len(b):
    l=struct.unpack('<q',b[i:i+8])[0]; i+=8+l; t+=l; n+=1
print(t,n)" "$1"; }

# One candidate, one corpus, one cap. Prints a CSV row.
#   run_case <label> <fmt> <cap> <slotw> <corpus> <n> <durable>
run_case() {
  local label=$1 fmt=$2 cap=$3 w=$4 corpus=$5 n=$6 dur=$7
  local input="$corpus"
  [ "$fmt" = f0 ] && input="${corpus%.bin}.flat"
  local dir="$OUT/store-$label"
  rm -rf "$dir"
  local log="$OUT/log-$label.txt"
  "$P" "$fmt" "$input" "$n" "$cap" "$w" "$dur" "$dir" > "$log" 2>&1
  local rc=$?
  local blocks dbytes ns nsrec nsblk over
  blocks=$(grep -m1 '^blocks='          "$log" | cut -d= -f2)
  dbytes=$(grep -m1 '^durable_bytes='   "$log" | cut -d= -f2)
  ns=$(    grep -m1 '^elapsed_ns='      "$log" | cut -d= -f2)
  nsrec=$( grep -m1 '^ns_per_record='   "$log" | cut -d= -f2)
  nsblk=$( grep -m1 '^ns_per_block='    "$log" | cut -d= -f2)
  over=$(  grep -m1 '^records_too_large=' "$log" | cut -d= -f2)
  echo "${blocks:-0},${dbytes:-0},${ns:-0},${nsrec:-0},${nsblk:-0},${over:-0},$rc"
}

fmt_of()  { case $1 in f3) echo "f3:$2";; *) echo "$1";; esac; }

echo
echo "════════ T1a  round trip: write in one process, decode in another"
RT="$OUT/t1a.csv"
echo "corpus,cap,candidate,records,blocks,durable_bytes,overhead_bytes,bytes_per_record,records_too_large,verdict" > "$RT"
for SPEC in "structure-50000:$STRUCT_CAP:$W_STRUCT:50000" \
            "mixed-5000:$MIXED_CAP:$W_MIXED:5000"; do
  IFS=: read -r CN CAP W N <<< "$SPEC"
  read -r CBYTES CN_REC <<< "$(cb "$OUT/$CN.bin")"
  for M in f0 f1f f1v f2 f3; do
    L="$CN-$CAP-$M"
    IFS=, read -r BL DB NS NR NB OV RC <<< "$(run_case "$L" $M $CAP $W "$OUT/$CN.bin" $N 1)"
    V=$("$F" verify "$(fmt_of $M $W)" $CAP "$OUT/store-$L" "$OUT/$CN.bin" --quiet 2>&1)
    VERD=$(echo "$V" | grep -c 'VERIFY PASS')
    [ "$VERD" = 1 ] && VERD=PASS || VERD="FAIL:$(echo "$V" | grep -m1 'VERIFY FAIL' | cut -d: -f2- | cut -c1-48)"
    [ "$M" = f0 ] && VERD="$VERD(stream-only)"
    OVH=$((DB - CBYTES))
    BPR=$(python3 -c "print(f'{$OVH/$N:.2f}')")
    echo "$CN,$CAP,$M,$N,$BL,$DB,$OVH,$BPR,$OV,$VERD" >> "$RT"
    echo "$V" > "$OUT/verify-$L.txt"
  done
done
column -t -s, "$RT"

echo
echo "════════ T1b  round trip across a REAL restart (two process lifetimes)"
echo "         seq mints from 0 in both runs — the live path's B0 behaviour."
RB="$OUT/t1b.csv"
echo "candidate,run1_records,run2_records,blocks_after,verdict" > "$RB"
CN=structure-10000; CAP=$STRUCT_CAP; N=10000; HALF=5000
read -r CBYTES _ <<< "$(cb "$OUT/$CN.bin")"
HALFBYTES=$(python3 -c "
import struct
b=open('$OUT/$CN.bin','rb').read(); i=0; t=0
for _ in range($HALF):
    l=struct.unpack('<q',b[i:i+8])[0]; i+=8+l; t+=l
print(t)")
for M in f0 f1f f1v f2 f3; do
  D="$OUT/restart-$M"; rm -rf "$D"
  IN="$OUT/$CN.bin"; S2=$HALF
  if [ "$M" = f0 ]; then IN="$OUT/$CN.flat"; S2=$HALFBYTES; fi
  "$P" $M "$IN" $HALF $CAP $W_STRUCT 1 "$D" 0 0        > "$OUT/rst-$M-1.txt" 2>&1
  "$P" $M "$IN" $HALF $CAP $W_STRUCT 1 "$D" $S2 0      > "$OUT/rst-$M-2.txt" 2>&1
  BL=$(ls "$D" 2>/dev/null | wc -l)
  V=$("$F" verify "$(fmt_of $M $W_STRUCT)" $CAP "$D" "$OUT/$CN.bin" --quiet 2>&1)
  if echo "$V" | grep -q 'VERIFY PASS'; then VERD=PASS; else VERD="FAIL:$(echo "$V" | grep -m1 'VERIFY FAIL' | cut -d: -f2- | cut -c1-48)"; fi
  echo "$M,$HALF,$HALF,$BL,$VERD" >> "$RB"
done
column -t -s, "$RB"

echo
echo "════════ T2  crash correctness — REAL SIGKILLs at unaligned points"
CR="$OUT/t2.csv"
echo "candidate,trials,killed_mid_write,prefix_exact,temp_files_left,truncated_targets,density_broken" > "$CR"
TRIALS=${TRIALS:-4}
CN=structure-50000; CAP=$STRUCT_CAP
for M in f0 f1f f1v f2 f3; do
  IN="$OUT/$CN.bin"; [ "$M" = f0 ] && IN="$OUT/$CN.flat"
  killed=0; exact=0; temps=0; trunc=0; dense=0
  for t in $(seq 1 $TRIALS); do
    D="$OUT/kill-$M-$t"; rm -rf "$D"; mkdir -p "$D"
    MS=$(( 20 + (RANDOM % 380) ))
    "$F" spawn-kill --store "$D" --after-ms $MS -- \
      "$P" $M "$IN" 50000 $CAP $W_STRUCT 1 "$D" > "$OUT/kill-$M-$t.txt" 2>&1
    grep -q 'killed=true' "$OUT/kill-$M-$t.txt" && killed=$((killed+1))
    LT=$(grep -o 'leftover_temp_files=[0-9]*' "$OUT/kill-$M-$t.txt" | cut -d= -f2)
    temps=$((temps + ${LT:-0}))
    V=$("$F" verify "$(fmt_of $M $W_STRUCT)" $CAP "$D" "$OUT/$CN.bin" --prefix-ok --quiet 2>&1)
    echo "$V" >> "$OUT/kill-$M-$t.txt"
    echo "$V" | grep -q 'VERIFY PASS' && exact=$((exact+1))
    echo "$V" | grep -q 'short file'   && trunc=$((trunc+1))
    echo "$V" | grep -q 'not dense'    && dense=$((dense+1))
    rm -rf "$D"
  done
  echo "$M,$TRIALS,$killed,$exact,$temps,$trunc,$dense" >> "$CR"
done
column -t -s, "$CR"

echo
echo "════════ T3  per-record cost in nanoseconds — packing only, no fsync"
echo "         (fsync is 9 ms and would bury a framing difference entirely)"
T3="$OUT/t3.csv"
echo "candidate,corpus,records,pack_ns_total,pack_ns_per_record" > "$T3"
for N in 1000 10000; do
  for M in f0 f1f f1v f2 f3; do
    L="pack-structure-$N-$M"
    IFS=, read -r BL DB NS NR NB OV RC <<< "$(run_case "$L" $M $STRUCT_CAP $W_STRUCT "$OUT/structure-$N.bin" $N 0)"
    echo "$M,structure,$N,$NS,$NR" >> "$T3"
  done
done
for M in f0 f1f f1v f2 f3; do
  L="pack-structure-100k-$M"
  IFS=, read -r BL DB NS NR NB OV RC <<< "$(run_case "$L" $M $STRUCT_CAP $W_STRUCT "$OUT/structure-100k.bin" 100000 0)"
  echo "$M,structure,100000,$NS,$NR" >> "$T3"
  L="pack-mixed-5000-$M"
  IFS=, read -r BL DB NS NR NB OV RC <<< "$(run_case "$L" $M $MIXED_CAP $W_MIXED "$OUT/mixed-5000.bin" 5000 0)"
  echo "$M,mixed,5000,$NS,$NR" >> "$T3"
done
column -t -s, "$T3"

echo
echo "════════ T4  write cost per durable block, against 9.10 ms / 2 fsyncs"
T4="$OUT/t4.csv"
echo "candidate,corpus,cap,blocks,ms_per_durable_block,total_ms,fsyncs_per_block" > "$T4"
for SPEC in "structure-50000:$STRUCT_CAP:$W_STRUCT:50000" "mixed-5000:$MIXED_CAP:$W_MIXED:5000"; do
  IFS=: read -r CN CAP W N <<< "$SPEC"
  for M in f0 f1f f1v f2 f3; do
    L="cost-$CN-$M"
    IFS=, read -r BL DB NS NR NB OV RC <<< "$(run_case "$L" $M $CAP $W "$OUT/$CN.bin" $N 1)"
    MSB=$(python3 -c "print(f'{$NB/1e6:.3f}')")
    TOT=$(python3 -c "print(f'{$NS/1e6:.1f}')")
    # fsyncs counted, not assumed
    # fsync count on a SMALL corpus — every candidate seals through the same
    # fx_seal, so the count is structural, but it is counted rather than
    # asserted.
    SD="$OUT/fsync-$L"; rm -rf "$SD"
    SIN="$OUT/structure-1000.bin"; [ "$M" = f0 ] && SIN="$OUT/structure-1000.flat"
    strace -f -c -e trace=fsync -o "$OUT/strace-$L.txt" \
      "$P" $M "$SIN" 1000 $CAP $W 1 "$SD" > "$OUT/fsyncrun-$L.txt" 2>&1
    FS=$(awk '/fsync/{print $4}' "$OUT/strace-$L.txt" | head -1)
    SBL=$(grep -m1 '^blocks=' "$OUT/fsyncrun-$L.txt" | cut -d= -f2)
    FSB=$(python3 -c "print(f'{${FS:-0}/max(${SBL:-1},1):.4f}')")
    rm -rf "$SD"
    echo "$M,$CN,$CAP,$BL,$MSB,$TOT,$FSB" >> "$T4"
  done
done
column -t -s, "$T4"

echo
echo "════════ NC  negative control on the framed candidates"
echo "         every suite above must fail when the thing it tests is broken"
NCF=0; NCP=0
CN=structure-1000; CAP=$STRUCT_CAP
for M in f1f f1v f2 f3; do
  L="nc-$CN-$M"
  run_case "$L" $M $CAP $W_STRUCT "$OUT/$CN.bin" 1000 1 > /dev/null
  for MODE in truncate flip drop reorder shiftlen; do
    D="$OUT/ncstore-$M-$MODE"; rm -rf "$D"; cp -r "$OUT/store-$L" "$D"
    "$F" corrupt "$D" "$MODE" > /dev/null 2>&1
    if "$F" verify "$(fmt_of $M $W_STRUCT)" $CAP "$D" "$OUT/$CN.bin" --quiet > /dev/null 2>&1; then
      echo "   ✗ $M/$MODE: still PASSED — no teeth"; NCF=$((NCF+1))
    else
      NCP=$((NCP+1))
    fi
    rm -rf "$D"
  done
done
echo "   negative controls: $NCP passed, $NCF failed"

echo
echo "CSVs under $OUT"
[ "$NCF" -eq 0 ] || exit 1
