#!/usr/bin/env bash
# AXVERITY_DURABLE_FORMAT_V1 / P2 — BLOCK ID and STRUCTURE/PAYLOAD SEPARATION.
#
# One sweep. Every declared candidate is built, run and reported, including
# the losers (NO_RESULT_DISCARDED).
#
#   B0  seq from 0, consulting nothing        the live path. Control.
#   B1  max+1 over durable blocks, strict parse
#   B2  per-run directory, dense from 0 inside it
#   B3  durably leased id range
#
#   S0  interleaved                            the live path. Control.
#   S1  separate streams, independent id spaces
#   S2  separate streams, one shared id space
#
# Framing under the separation candidates is held fixed at F1v — P1 measured
# it the cheapest framing that works, and holding it constant is what makes a
# difference between S0/S1/S2 a difference in separation.
#
# Crash cases are real SIGKILLs to real processes. Startup cost is M1 through
# the real bridge. The lease's durable write is fs_write_bytes, the bridge's
# own barrier, not a replica.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
F="$HERE/harness/target/release/fmth"
P="$ROOT/experiments/format-m1/build/fmt-probe"
OUT="$ROOT/.axverity-store/fmt/p2"
mkdir -p "$OUT"
cd "$ROOT"

CAP=4096
MIXCAP=16384
THRESH=32

blockfiles() { find "$1" -type f -name 'block-*.bin' 2>/dev/null | sort; }

# A snapshot maps each block path to its INODE, not to a content hash.
# Content is the wrong probe: B0 rewrites block-0.bin from the same corpus
# every run, so the bytes are identical and a hash comparison sees nothing —
# it reported zero collisions for the one scheme that certainly collides, and
# the negative control caught it. Every durable write is a rename of a freshly
# created temp file, so a REISSUED id always lands on a new inode whether or
# not the bytes changed. Same class of mistake as the P0 corpus-seed one:
# the detector agreed with the truth by accident, not by construction.
snap() { blockfiles "$1" | while read -r f; do echo "${f#$2/} $(stat -c '%i' "$f")"; done; }

# Section selection, so a fixed section can be re-run without redoing the
# durable work of the others. SECTIONS="t2 nc" runs just those.
want() { case " ${SECTIONS:-all} " in *" all "*|*" $1 "*) return 0;; *) return 1;; esac; }

# Wipe only on a full sweep. A subset run must leave the other sections'
# stores alone — the first attempt at re-running one section deleted the
# corpora the others had already written, and every number that came back
# was of an empty store.
want all && { rm -rf "$OUT"; mkdir -p "$OUT"; }

# Corpora are cheap and every section needs them, so they are built outside
# the section guards.
"$F" corpus "$OUT/s9000.bin"  9000  structure 4242 > /dev/null
"$F" corpus "$OUT/s20000.bin" 20000 structure 4242 > /dev/null

# ══════════════════════════════════════════════════════════════════ T1
if want t1; then
echo "════════ T1  PRIMARY — round trip across TWO real restarts"
echo "         one corpus, three process lifetimes, decoded by a fourth"
T1="$OUT/t1.csv"
echo "scheme,lifetimes,block_files,first_seq_per_run,verdict" > "$T1"
for B in b0 b1 b2 b3; do
  D="$OUT/rt-$B"; rm -rf "$D"; SEQS=""
  for k in 0 1 2; do
    "$P" f1v "$OUT/s9000.bin" 3000 $CAP 20 1 "$D" $((k*3000)) 0 $B > "$OUT/rt-$B-$k.log" 2>&1
    SEQS="$SEQS $(grep -m1 bid_first_seq "$OUT/rt-$B-$k.log" | cut -d= -f2)"
  done
  NF=$(blockfiles "$D" | wc -l)
  V=$("$F" verify f1v $CAP "$D" "$OUT/s9000.bin" --quiet 2>&1)
  if echo "$V" | grep -q 'VERIFY PASS'; then VD=PASS; else VD="FAIL:$(echo "$V" | grep -m1 'VERIFY FAIL' | cut -d: -f2- | cut -c1-46)"; fi
  echo "$B,3,$NF,\"$(echo $SEQS)\",$VD" >> "$T1"
done
column -t -s, "$T1"

# ══════════════════════════════════════════════════════════════════ T2
echo
fi
if want t2; then
echo "════════ T2  crash matrix — real SIGKILLs, then restart, repeatedly"
echo "         a COLLISION is a block path a later run replaced (inode changed):"
echo "         an id reissued that a previous run had already used."
T2="$OUT/t2.csv"
echo "scheme,rounds,killed,collisions,density_broken,temp_files_left,ids_left_unused" > "$T2"
ROUNDS=${ROUNDS:-5}
for B in b0 b1 b2 b3; do
  D="$OUT/crash-$B"; rm -rf "$D"; mkdir -p "$D"
  killed=0; coll=0; temps=0
  cp /dev/null "$OUT/snap-$B.txt"
  for r in $(seq 1 $ROUNDS); do
    MS=$(( 25 + (RANDOM % 200) ))
    "$F" spawn-kill --store "$D" --after-ms $MS -- \
      "$P" f1v "$OUT/s9000.bin" 9000 $CAP 20 1 "$D" 0 0 $B > "$OUT/crash-$B-$r.txt" 2>&1
    grep -q 'killed=true' "$OUT/crash-$B-$r.txt" && killed=$((killed+1))
    LT=$(grep -o 'leftover_temp_files=[0-9]*' "$OUT/crash-$B-$r.txt" | cut -d= -f2); temps=$((temps+${LT:-0}))
    snap "$D" "$D" > "$OUT/snap-$B-$r.txt"
    if [ "$r" -gt 1 ]; then
      # a path present before whose INODE changed = a reissued id
      C=$(join "$OUT/snap-$B-$((r-1)).txt" "$OUT/snap-$B-$r.txt" 2>/dev/null | awk '$2!=$3' | wc -l)
      coll=$((coll + C))
    fi
  done
  V=$("$F" verify f1v $CAP "$D" "$OUT/s9000.bin" --prefix-ok --quiet 2>&1)
  DENS=$(echo "$V" | grep -c 'not dense')
  # Unused ids only means something in a single flat namespace. B2 gives each
  # run its own directory and each run its own dense sequence from 0, so
  # "max id + 1 - file count" is not a hole count there, it is nonsense — it
  # came out negative on the first sweep, which is how that was noticed.
  NF=$(blockfiles "$D" | wc -l)
  if [ "$B" = b2 ]; then
    HOLES="n/a (per-run namespace)"
  else
    MAXID=$(blockfiles "$D" | sed 's/.*block-\([0-9]*\)\.bin/\1/' | sort -n | tail -1)
    HOLES=$(( ${MAXID:-0} + 1 - NF ))
  fi
  echo "$B,$ROUNDS,$killed,$coll,$DENS,$temps,$HOLES" >> "$T2"
done
column -t -s, "$T2"

# ══════════════════════════════════════════════════════════════════ T5
echo
fi
if want t5; then
echo "════════ T5  startup id-resolution cost, in M1 through the real bridge"
T5="$OUT/t5.csv"
echo "scheme,existing_blocks,entries_folded,resolve_ns" > "$T5"
for N in 1000 10000 100000; do
  FLAT="$OUT/pop-flat-$N"; rm -rf "$FLAT"; mkdir -p "$FLAT"
  seq 0 $((N-1)) | sed "s|^|$FLAT/block-|; s|$|.bin|" | xargs -P8 -n2000 touch
  # B2 at the same store size: one run directory per 4000 blocks, which is
  # what a run of that length actually leaves behind.
  RUNS=$(( (N + 3999) / 4000 )); [ $RUNS -lt 1 ] && RUNS=1
  PER="$OUT/pop-run-$N"; rm -rf "$PER"; mkdir -p "$PER"
  for i in $(seq 0 $((RUNS-1))); do mkdir -p "$PER/run-$i"; done
  for B in b0 b1 b2 b3; do
    case $B in
      b1) DIR=$FLAT; ENT=$N ;;
      b2) DIR=$PER;  ENT=$RUNS ;;
      *)  DIR=$FLAT; ENT=0 ;;
    esac
    # resolve only: zero records to pack, so the number is the resolve itself
    "$P" f1v "$OUT/s9000.bin" 0 $CAP 20 0 "$DIR" 0 0 $B > "$OUT/res-$B-$N.log" 2>&1
    NS=$(grep -m1 bid_resolve_ns "$OUT/res-$B-$N.log" | cut -d= -f2)
    echo "$B,$N,$ENT,${NS:-0}" >> "$T5"
  done
  rm -rf "$FLAT" "$PER"
done
column -t -s, "$T5"

# ══════════════════════════════════════════════════════════════════ T4
echo
fi
if want t4; then
echo "════════ T4  write cost per durable block, against 9.10 ms / 2.00 fsyncs"
echo "         B3 is run at three lease sizes: the open question is whether a"
echo "         durable id reservation costs an fsync, and at lease 1 it must."
T4="$OUT/t4.csv"
echo "scheme,lease,blocks,ms_per_durable_block,total_ms,fsyncs_total,fsyncs_per_block" > "$T4"
for SPEC in "b0:256" "b1:256" "b2:256" "b3:1" "b3:16" "b3:256"; do
  IFS=: read -r B LZ <<< "$SPEC"
  D="$OUT/cost-$B-$LZ"; rm -rf "$D"
  "$P" f1v "$OUT/s20000.bin" 20000 $CAP 20 1 "$D" 0 0 $B 0 32 $LZ > "$OUT/cost-$B-$LZ.log" 2>&1
  BL=$(grep -m1 '^blocks='      "$OUT/cost-$B-$LZ.log" | cut -d= -f2)
  NB=$(grep -m1 '^ns_per_block=' "$OUT/cost-$B-$LZ.log" | cut -d= -f2)
  NS=$(grep -m1 '^elapsed_ns='   "$OUT/cost-$B-$LZ.log" | cut -d= -f2)
  SD="$OUT/fs-$B-$LZ"; rm -rf "$SD"
  strace -f -c -e trace=fsync -o "$OUT/st-$B-$LZ.txt" \
    "$P" f1v "$OUT/s20000.bin" 20000 $CAP 20 1 "$SD" 0 0 $B 0 32 $LZ > /dev/null 2>&1
  FS=$(awk '/fsync/{print $4}' "$OUT/st-$B-$LZ.txt" | head -1)
  rm -rf "$SD" "$D"
  echo "$B,$LZ,$BL,$(python3 -c "print(f'{${NB:-0}/1e6:.3f}')"),$(python3 -c "print(f'{${NS:-0}/1e6:.1f}')"),${FS:-0},$(python3 -c "print(f'{${FS:-0}/max(${BL:-1},1):.4f}')")" >> "$T4"
done
column -t -s, "$T4"

# ══════════════════════════════════════════════════════════════════ S
echo
fi
if want s; then
echo "════════ S0/S1/S2  structure/payload separation — write side"
"$F" corpus "$OUT/mix.bin" 10000 mixed 4242 > "$OUT/mix-dist.txt"
"$F" corpus-filter "$OUT/mix.bin" "$OUT/mix-struct.bin" le $THRESH > "$OUT/mix-struct.txt"
"$F" corpus-filter "$OUT/mix.bin" "$OUT/mix-pay.bin"    gt $THRESH > "$OUT/mix-pay.txt"
echo "   corpus: $(grep -m1 records= "$OUT/mix-dist.txt")  $(cat "$OUT/mix-struct.txt" | sed 's/filtered/structure/')  $(cat "$OUT/mix-pay.txt" | sed 's/filtered/payload/')"
SW="$OUT/sep-write.csv"
echo "candidate,stream,blocks,durable_bytes,total_ms,verdict" > "$SW"

run_sep() {   # run_sep <label> <filt> <dir> <seq0>
  "$P" f1v "$OUT/mix.bin" 10000 $MIXCAP 20 1 "$3" 0 "$4" b0 "$2" $THRESH 256 > "$OUT/sep-$1.log" 2>&1
  grep -m1 '^blocks='        "$OUT/sep-$1.log" | cut -d= -f2
  grep -m1 '^durable_bytes=' "$OUT/sep-$1.log" | cut -d= -f2
  grep -m1 '^elapsed_ns='    "$OUT/sep-$1.log" | cut -d= -f2
}

# S0 — interleaved, one stream
rm -rf "$OUT/s0"; read -r B0N B0B B0T <<< "$(run_sep s0 0 "$OUT/s0" 0 | tr '\n' ' ')"
V=$("$F" verify f1v $MIXCAP "$OUT/s0" "$OUT/mix.bin" --quiet 2>&1 | grep -c 'VERIFY PASS')
echo "S0,combined,$B0N,$B0B,$(python3 -c "print(f'{$B0T/1e6:.1f}')"),$([ $V = 1 ] && echo PASS || echo FAIL)" >> "$SW"

# S1 — separate streams, independent id spaces
rm -rf "$OUT/s1"
read -r S1SN S1SB S1ST <<< "$(run_sep s1struct 1 "$OUT/s1/structure" 0 | tr '\n' ' ')"
read -r S1PN S1PB S1PT <<< "$(run_sep s1pay    2 "$OUT/s1/payload"   0 | tr '\n' ' ')"
VS=$("$F" verify f1v $MIXCAP "$OUT/s1/structure" "$OUT/mix-struct.bin" --quiet 2>&1 | grep -c 'VERIFY PASS')
VP=$("$F" verify f1v $MIXCAP "$OUT/s1/payload"   "$OUT/mix-pay.bin"    --quiet 2>&1 | grep -c 'VERIFY PASS')
echo "S1,structure,$S1SN,$S1SB,$(python3 -c "print(f'{$S1ST/1e6:.1f}')"),$([ $VS = 1 ] && echo PASS || echo FAIL)" >> "$SW"
echo "S1,payload,$S1PN,$S1PB,$(python3 -c "print(f'{$S1PT/1e6:.1f}')"),$([ $VP = 1 ] && echo PASS || echo FAIL)" >> "$SW"

# S2 — separate streams, one shared id space (payload continues structure's ids)
rm -rf "$OUT/s2"
read -r S2SN S2SB S2ST <<< "$(run_sep s2struct 1 "$OUT/s2/structure" 0 | tr '\n' ' ')"
read -r S2PN S2PB S2PT <<< "$(run_sep s2pay    2 "$OUT/s2/payload" "$S2SN" | tr '\n' ' ')"
VS2=$("$F" verify f1v $MIXCAP "$OUT/s2/structure" "$OUT/mix-struct.bin" --quiet 2>&1 | grep -c 'VERIFY PASS')
echo "S2,structure,$S2SN,$S2SB,$(python3 -c "print(f'{$S2ST/1e6:.1f}')"),$([ $VS2 = 1 ] && echo PASS || echo FAIL)" >> "$SW"
echo "S2,payload,$S2PN,$S2PB,$(python3 -c "print(f'{$S2PT/1e6:.1f}')"),(ids $S2SN..$((S2SN+S2PN-1)), no overlap)" >> "$SW"
column -t -s, "$SW"

# ══════════════════════════════════════════════════════════════════ T6
echo
fi
if want t6; then
echo "════════ T6  structure-only replay vs scanning everything — MEASURED"
T6="$OUT/t6.csv"
echo "candidate,scanned,blocks_opened,bytes_read,records_decoded,scan_ms" > "$T6"
scan_one() {  # scan_one <label> <dir>
  "$P" scan x 0 $MIXCAP 20 0 "$2" > "$OUT/scan-$1.log" 2>&1
  local R BK BY NS
  R=$( grep -m1 scan_records= "$OUT/scan-$1.log" | cut -d= -f2)
  BK=$(grep -m1 scan_blocks=  "$OUT/scan-$1.log" | cut -d= -f2)
  BY=$(grep -m1 scan_bytes=   "$OUT/scan-$1.log" | cut -d= -f2)
  NS=$(grep -m1 scan_ns=      "$OUT/scan-$1.log" | cut -d= -f2)
  echo "${BK:-0},${BY:-0},${R:-0},$(python3 -c "print(f'{${NS:-0}/1e6:.2f}')")"
}
echo "S0,everything (structure is interleaved with payload),$(scan_one s0 "$OUT/s0")" >> "$T6"
echo "S1,structure stream only,$(scan_one s1 "$OUT/s1/structure")" >> "$T6"
echo "S2,structure stream only,$(scan_one s2 "$OUT/s2/structure")" >> "$T6"
column -t -s, "$T6"

# ══════════════════════════════════════════════════════════════════ NC
echo
fi
if want nc; then
echo "════════ NC  negative control on the P2 suites"
NCP=0; NCF=0
T1="$OUT/t1.csv"; T2="$OUT/t2.csv"
chk() { if [ "$1" = "$2" ]; then echo "   ✓ $3"; NCP=$((NCP+1)); else echo "   ✗ $3 (got $1, want $2)"; NCF=$((NCF+1)); fi; }
# the collision detector must fire on B0 and must not fire on B1/B2/B3
B0C=$(awk -F, '$1=="b0"{print ($4>0)?"yes":"no"}' "$T2")
chk "$B0C" yes "collision detector fires on B0, the scheme known to overwrite"
for B in b1 b2 b3; do
  C=$(awk -F, -v b=$B '$1==b{print ($4>0)?"yes":"no"}' "$T2")
  chk "$C" no "collision detector stays silent on $B"
done
# the scanner must notice a missing structure block
cp -r "$OUT/s1/structure" "$OUT/s1-broken"
"$F" corrupt "$OUT/s1-broken" drop > /dev/null 2>&1
BR=$(scan_one broken "$OUT/s1-broken" | cut -d, -f3)
OK=$(scan_one s1 "$OUT/s1/structure" | cut -d, -f3)
chk "$([ "${BR:-0}" -lt "${OK:-1}" ] && echo yes || echo no)" yes "scanner reports fewer records after a block is dropped ($BR < $OK)"
# the round-trip suite must still fail B0
B0V=$(awk -F, '$1=="b0"{print ($5=="PASS")?"pass":"fail"}' "$T1")
chk "$B0V" fail "round trip still FAILS under B0"
echo "   negative controls: $NCP passed, $NCF failed"

echo
fi
echo "CSVs under $OUT"
[ "${NCF:-0}" -eq 0 ] || exit 1
