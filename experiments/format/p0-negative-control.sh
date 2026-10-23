#!/usr/bin/env bash
# AXVERITY_DURABLE_FORMAT_V1 / P0 — NEGATIVE_CONTROL_REQUIRED.
#
# "A suite that passes on first run and has not been broken on purpose is not
# evidence." So: build a store with the REAL, UNMODIFIED write path, confirm
# the harness passes it, then break exactly one property at a time and
# require the harness to fail each time. A control that fails to fail is
# itself a failure of this script.
#
# Nothing here modifies the write path. wp-slice is used read-only, as the
# producer of the F0/B0/S0 control store.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
F="$HERE/harness/target/release/fmth"
BIN="$ROOT/build/wp-slice"
CAP=64
PCAP=56
OUT="$ROOT/.axverity-store/fmt/negctl"

rm -rf "$OUT"; mkdir -p "$OUT"
PASS=0; FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

# A corpus of real records, and the undelimited stream the current write path
# actually consumes. The corpus is what "round trip" is measured against; the
# stream is all the current format is able to carry.
CORPUS="$OUT/corpus.bin"
INPUT="$OUT/input.bin"
"$F" corpus "$CORPUS" 400 structure 7 > "$OUT/corpus.txt"
"$F" flatten "$CORPUS" "$INPUT"
FILESIZE=$(stat -c%s "$INPUT")
N=$(( (FILESIZE + PCAP - 1) / PCAP ))
echo "control store: $FILESIZE bytes of records -> N=$N blocks at PCAP=$PCAP"

# ── the control store, written by the real binary ───────────────────────────
GOOD="$OUT/good"; mkdir -p "$GOOD"
( cd "$GOOD" && "$BIN" "$INPUT" "$N" ) > "$OUT/good.log" 2>&1 || { echo "FATAL: wp-slice failed"; exit 1; }
STORE="$GOOD/.axverity-store/blocks"

echo
echo "── NC0  the harness passes an intact store (if this fails, nothing below means anything)"
if "$F" verify f0 $CAP "$STORE" "$CORPUS" > "$OUT/nc0.txt" 2>&1; then
  ok "intact F0 store verifies"
else
  bad "intact F0 store did NOT verify — harness is broken, not the format"
  cat "$OUT/nc0.txt"
fi
grep -q 'RECORDS_RECOVERABLE=no' "$OUT/nc0.txt" \
  && ok "and the harness reports F0 carries no record boundaries (the defect, stated)" \
  || bad "harness failed to report F0's missing record framing"

# ── one property broken at a time ───────────────────────────────────────────
for MODE in truncate flip drop reorder; do
  D="$OUT/broken-$MODE"; rm -rf "$D"; cp -r "$GOOD" "$D"
  "$F" corrupt "$D/.axverity-store/blocks" "$MODE" > "$OUT/nc-$MODE.txt" 2>&1
  if "$F" verify f0 $CAP "$D/.axverity-store/blocks" "$CORPUS" >> "$OUT/nc-$MODE.txt" 2>&1; then
    bad "NC[$MODE] verify still PASSED on a deliberately broken store — NO TEETH"
  else
    ok "NC[$MODE] verify failed as required: $(grep -m1 'VERIFY FAIL' "$OUT/nc-$MODE.txt" | cut -c1-90)"
  fi
done

# ── NC-restart: the block-id defect, caught by the harness ──────────────────
# Two runs into one store. seq mints from 0 every run (mem_controller.m1:46)
# and the filename is a pure function of seq (wp_flusher_step.m1:33-34), so
# run 2's block-0.bin lands on top of run 1's. A harness that cannot see this
# cannot test block-id stability at all.
echo
echo "── NC-restart  run 2 overwrites run 1 (the defect this intent exists to fix)"
R2="$OUT/restart"; mkdir -p "$R2"
CORPUS2="$OUT/corpus2.bin"; INPUT2="$OUT/input2.bin"
# fixed:12, not structure: `structure` is a pure function of the record
# index and ignores the seed (by design — it mirrors rt_pop_step.m1), so two
# structure corpora of the same n are byte-identical and would prove nothing
# about overwriting. This control caught exactly that on its first run.
"$F" corpus "$CORPUS2" 400 fixed:12 99 > /dev/null
"$F" flatten "$CORPUS2" "$INPUT2"
N2=$(( ($(stat -c%s "$INPUT2") + PCAP - 1) / PCAP ))
( cd "$R2" && "$BIN" "$INPUT" "$N" )   > /dev/null 2>&1
BEFORE=$(sha256sum "$R2/.axverity-store/blocks/block-0.bin" | cut -d' ' -f1)
( cd "$R2" && "$BIN" "$INPUT2" "$N2" ) > /dev/null 2>&1
AFTER=$(sha256sum "$R2/.axverity-store/blocks/block-0.bin" | cut -d' ' -f1)
if [ "$BEFORE" = "$AFTER" ]; then
  bad "block-0.bin unchanged across runs — expected run 2 to overwrite it"
else
  ok "block-0.bin was overwritten by run 2 ($BEFORE -> $AFTER)"
fi
if "$F" verify f0 $CAP "$R2/.axverity-store/blocks" "$CORPUS" > "$OUT/nc-restart.txt" 2>&1; then
  bad "run 1's records still verify after run 2 — harness cannot see the overwrite"
else
  ok "run 1's records no longer verify after a restart: $(grep -m1 'VERIFY FAIL' "$OUT/nc-restart.txt" | cut -c1-90)"
fi

# ── NC-kill: a real SIGKILL, not a constructed filesystem state ─────────────
echo
echo "── NC-kill  the harness kills a live writer for real"
K="$OUT/killed"; mkdir -p "$K/.axverity-store/blocks"
BIG="$OUT/big.bin"; head -c $((PCAP * 400)) /dev/urandom > "$BIG"
"$F" spawn-kill --store "$K/.axverity-store/blocks" --after-blocks 20 --cwd "$K" \
  -- "$BIN" "$BIG" 400 > "$OUT/nc-kill.txt" 2>&1
cat "$OUT/nc-kill.txt" | sed 's/^/    /'
if grep -q 'killed=true' "$OUT/nc-kill.txt" && grep -q 'signal=Some(9)' "$OUT/nc-kill.txt"; then
  ok "writer died of SIGKILL mid-write"
else
  bad "writer was not actually SIGKILLed"
fi
LEFT=$(grep -o 'blocks_after=[0-9]*' "$OUT/nc-kill.txt" | cut -d= -f2)
if [ "${LEFT:-0}" -gt 0 ] && [ "${LEFT:-0}" -lt 400 ]; then
  ok "store left mid-stream: $LEFT of 400 blocks durable"
else
  bad "kill did not land mid-write (blocks_after=$LEFT)"
fi

echo
echo "NEGATIVE CONTROL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
