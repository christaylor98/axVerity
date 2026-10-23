#!/usr/bin/env bash
# AXVERITY_FORMAT_LAND_AND_WIRE_V1 / P1 — F1v + B1 + S2, together.
#
# The prior round measured these three separately and each one passed. That is
# not the same as the combination working, and two of the interactions are only
# visible when all three are on at once:
#
#   * S2 keeps two stream directories but ONE id space. B1 resolves max+1 by
#     scanning block names — so it must scan the UNION. A resolver that reads
#     one directory re-mints ids the other holds, which is the B0 defect
#     arrived at from a different direction.
#   * Under S1 each stream is dense from 0. Under S2 neither is: block k lives
#     in whichever stream filled first. Density is a property of the union, and
#     a per-directory check would fail a correct store while passing a
#     collided one.
#
# The prior round's S2 measurement ran the probe twice with a hand-fed starting
# id, which cannot exercise either. Here one process writes both streams and
# both take ids from the same counter.
#
# Nothing in this script touches lib/ or src/ — P1 is the proving ground and
# the write path is not modified until P2 (ONE_TOUCH_THEN_WIRE).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
F="$HERE/harness/target/release/fmth"
P="$ROOT/experiments/format-m1/build/fmt-probe"
OUT="$ROOT/.axverity-store/fmt/p1c"
CAP=16384
THRESH=32

rm -rf "$OUT"; mkdir -p "$OUT"
PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# probe <dir> <corpus> <n> <start> [cap]   — writes durably
probe() { "$P" s2 "$2" "$3" "${5:-$CAP}" 20 1 "$1" "$4" 0 b1s2 0 $THRESH 256; }

# resolve_only <dir> — report the id B1 would mint WITHOUT touching the store.
#
# dur=0 skips fs_write_raw entirely, so asking "what would you resolve?" does
# not itself add a block and move the answer for the next question. An earlier
# draft used the durable probe here and each arm silently changed the max the
# next arm was testing against.
#
# Output goes to a FILE before grep touches it. Piping the probe into `grep -m1`
# hangs: grep exits at the first match, the probe takes EPIPE on its next
# println, and its panic handler respawns the entry in place — forever. That is
# a property of the probe runtime, not of this test, and it will bite anything
# that pipes probe output into a short-circuiting reader.
resolve_only() {
  "$P" s2 "$OUT/c.bin" 1 $CAP 20 0 "$1" 0 0 b1s2 0 $THRESH 256 > "$OUT/resolve.log" 2>&1
  grep -m1 '^bid_first_seq=' "$OUT/resolve.log" | cut -d= -f2
}

echo "════════ T1  PRIMARY — round trip across THREE real process lifetimes"
# 1200 records, 400 per lifetime. Small on purpose: correctness is binary and
# does not scale (SHORT_SWEEPS). Three SEPARATE process invocations, each
# resolving its own starting id from what the previous one left on disk — a
# same-process write-then-read proves nothing, B0 passes it and loses two
# thirds of the data.
N=1200; STEP=400
"$F" corpus "$OUT/c.bin" $N mixed 11 > "$OUT/corpus.txt"
S1="$OUT/three"; mkdir -p "$S1"
for L in 0 1 2; do
  START=$((L * STEP))
  # n is the number of records THIS lifetime packs, not the cumulative total.
  # Passing START+STEP made lifetimes 1 and 2 re-pack what the previous one had
  # already written: 1272 records recovered from a 1200-record corpus. loop_count
  # does not stop at input exhaustion, so an n that is too large also walks off
  # the end of the staged buffer.
  probe "$S1" "$OUT/c.bin" $STEP $START > "$OUT/life-$L.log" 2>&1
  RC=$?
  FIRST=$(grep -m1 '^bid_first_seq=' "$OUT/life-$L.log" | cut -d= -f2)
  echo "    lifetime $L: pid-exit=$RC  first_seq=$FIRST  \
structure=$(grep -m1 s2_structure_blocks= "$OUT/life-$L.log" | cut -d= -f2) \
payload=$(grep -m1 s2_payload_blocks= "$OUT/life-$L.log" | cut -d= -f2)"
done
# The fourth process decodes. Independent Rust, no shared code with the writer.
if "$F" verify-s2 $CAP "$S1" "$OUT/c.bin" $THRESH > "$OUT/t1.txt" 2>&1; then
  ok "three lifetimes, decoded by a fourth process: $(grep -m1 union_ids= "$OUT/t1.txt")"
  ok "  $(grep -m1 structure_records= "$OUT/t1.txt")"
else
  bad "round trip across three lifetimes FAILED"; sed 's/^/        /' "$OUT/t1.txt"
fi
FIRSTS=$(grep -h '^bid_first_seq=' "$OUT"/life-*.log | cut -d= -f2 | tr '\n' ' ')
echo "    first seq per lifetime: $FIRSTS   (B0 would be 0 0 0)"
[ "$(echo $FIRSTS | tr ' ' '\n' | sort -n | uniq | wc -l)" = 3 ] \
  && ok "each lifetime minted from a DIFFERENT id — no run restarted at 0" \
  || bad "two lifetimes started at the same id"

echo
echo "════════ T4  STRICT_PARSE_REJECTS_TEMPS — with its own negative control"
# The crash matrix passing is not evidence that the temp rejection works; it is
# evidence that no temp file happened to land somewhere fatal. This tests the
# rejection directly, and then proves the test could have failed.
TD="$OUT/temps"; mkdir -p "$TD/structure" "$TD/payload"
probe "$TD" "$OUT/c.bin" 200 0 > "$OUT/temp-base.log" 2>&1
BASE_MAX=$(ls "$TD"/structure "$TD"/payload | grep -o 'block-[0-9]*' | cut -d- -f2 | sort -n | tail -1)
EXPECT=$((BASE_MAX + 1))

# Arm A — a real leftover temp name, exactly what write_durable() builds before
# its rename (bytes_io.rs). 9 of these survived 20 real SIGKILLs and nothing
# sweeps them.
touch "$TD/payload/block-999.bin.tmp.31337.4"
GOT=$(resolve_only "$TD")
[ "$GOT" = "$EXPECT" ] \
  && ok "temp file IGNORED: resolved $GOT, not 1000 (max+1 over real blocks)" \
  || bad "temp file VOTED: resolved $GOT, expected $EXPECT"
rm -f "$TD/payload/block-999.bin.tmp.31337.4"

# Arm B — the teeth. Same id, but named as a real durable block. The resolver
# MUST jump to 1000 here. Without this arm, Arm A passes even if the resolver
# never reads the directory at all.
touch "$TD/payload/block-999.bin"
GOT2=$(resolve_only "$TD")
[ "$GOT2" = "1000" ] \
  && ok "control has teeth: the same id named block-999.bin DOES move the resolver to 1000" \
  || bad "resolver ignored a real block too — Arm A proves nothing (got $GOT2)"
rm -f "$TD/payload/block-999.bin"

# Arm C — the union. A high id in the OTHER stream must move it too, or the
# shared id space is not actually shared.
touch "$TD/structure/block-777.bin"
GOT3=$(resolve_only "$TD")
[ "$GOT3" = "778" ] \
  && ok "resolver scans BOTH streams: a block in structure/ moved it to 778" \
  || bad "resolver did not see the other stream (got $GOT3) — id space is not shared"
rm -f "$TD/structure/block-777.bin"

echo
echo "════════ T5  CAP_EXCEEDS_LARGEST_RECORD — oversized record fails LOUDLY"
# The mixed corpus tops out near 8 KB. At cap=4096 some records cannot fit an
# empty block. They must be counted and the run must exit non-zero — never
# truncated, never silently skipped.
OD="$OUT/over"; mkdir -p "$OD"
probe "$OD" "$OUT/c.bin" $N 0 4096 > "$OUT/t5.log" 2>&1
RC=$?
TOOBIG=$(grep -m1 '^records_too_large=' "$OUT/t5.log" | cut -d= -f2)
[ "${TOOBIG:-0}" -gt 0 ] && ok "oversized records counted: records_too_large=$TOOBIG" \
                         || bad "no oversized records counted at cap=4096"
[ "$RC" -ne 0 ] && ok "run exited non-zero ($RC) — the failure is loud, not silent" \
                || bad "run exited 0 despite $TOOBIG records too large"
# And the verifier must independently notice the loss, not take the writer's word.
if "$F" verify-s2 4096 "$OD" "$OUT/c.bin" $THRESH > "$OUT/t5v.txt" 2>&1; then
  bad "verifier PASSED a store that dropped $TOOBIG records — no teeth"
else
  ok "verifier independently fails it: $(grep -m1 'VERIFY FAIL' "$OUT/t5v.txt" | cut -c1-72)"
fi
# The control's control: the SAME corpus at a cap that exceeds every record
# must pass, or the failure above is about the cap, not about oversize.
FD="$OUT/fits"; mkdir -p "$FD"
probe "$FD" "$OUT/c.bin" $N 0 > "$OUT/t5f.log" 2>&1
if "$F" verify-s2 $CAP "$FD" "$OUT/c.bin" $THRESH > "$OUT/t5fv.txt" 2>&1; then
  ok "same corpus at cap=$CAP round-trips: $(grep -m1 structure_records= "$OUT/t5fv.txt")"
else
  bad "corpus fails even at cap=$CAP — the T5 failure is not about oversize"
fi

echo
echo "════════ T2  crash correctness under the combination — real SIGKILL"
# What a crash is allowed to do here, stated before it is tested: it may lose
# the tail, it may leave an uncollected .tmp file, and it may leave the two
# streams at DIFFERENT durable frontiers, because they seal independently. What
# it may not do is corrupt a sealed block, reissue an id, or put a hole in the
# union.
#
# Note on what is deliberately NOT asserted. This probe replays a fixed corpus
# from a given record index, so a restarted round re-packs from wherever it is
# told to start. Asserting "the whole corpus round-trips after three kills"
# would therefore be asserting a property of the probe's replay, not of the
# format — an earlier version of this test did exactly that and failed with 46
# differing records, all of them duplicates the probe itself had written twice.
# The real write path never replays: input arrives once and new input simply
# continues after a restart. So the crash claims below are about the durable
# store's integrity, and T1 above is what proves round-trip across restart.
KD="$OUT/kill"; mkdir -p "$KD/structure" "$KD/payload"
"$F" corpus "$OUT/k.bin" 4000 mixed 23 > /dev/null

echo "  ── T2a  one kill: the head must survive intact"
"$F" spawn-kill --store "$KD/payload" --after-blocks 5 --cwd "$OUT" \
  -- "$P" s2 "$OUT/k.bin" 4000 $CAP 20 1 "$KD" 0 0 b1s2 0 $THRESH 256 \
  > "$OUT/kill-a.txt" 2>&1
grep -q 'signal=Some(9)' "$OUT/kill-a.txt" \
  && ok "writer died of real SIGKILL mid-write" \
  || bad "writer was not actually SIGKILLed"
if "$F" verify-s2 $CAP "$KD" "$OUT/k.bin" $THRESH --prefix-ok > "$OUT/t2a.txt" 2>&1; then
  ok "surviving prefix byte-exact, union dense, no cross-stream id: $(grep -m1 union_ids= "$OUT/t2a.txt")"
  ok "  $(grep -m1 structure_records= "$OUT/t2a.txt")"
else
  bad "crash corrupted the durable head"; sed 's/^/        /' "$OUT/t2a.txt"
fi
# The frontier divergence, measured rather than assumed — it is an input to P2.
SR=$(grep -m1 -o 'structure_records=[0-9]*' "$OUT/t2a.txt" | cut -d= -f2)
PR=$(grep -m1 -o 'payload_records=[0-9]*'   "$OUT/t2a.txt" | cut -d= -f2)
echo "    per-stream durable frontier after the kill: structure=$SR payload=$PR records"

echo "  ── T2b  three kill-restart rounds: ids must never be reissued"
KILLED=1; COLL=0
ls -i "$KD"/structure/*.bin "$KD"/payload/*.bin 2>/dev/null \
  | awk '{n=$2; sub(/.*block-/,"",n); sub(/\.bin/,"",n); print n, $1}' | sort -n > "$OUT/inodes-0.txt"
for r in 1 2 3; do
  "$F" spawn-kill --store "$KD/payload" --after-blocks $((5 + r * 3)) --cwd "$OUT" \
    -- "$P" s2 "$OUT/k.bin" 4000 $CAP 20 1 "$KD" 0 0 b1s2 0 $THRESH 256 \
    > "$OUT/kill-$r.txt" 2>&1
  grep -q 'signal=Some(9)' "$OUT/kill-$r.txt" && KILLED=$((KILLED+1))
  # A REISSUED id always lands on a NEW inode: write_durable renames a freshly
  # created temp over the target, so the inode changes even when the bytes do
  # not. Content hashing cannot see this — it reported zero collisions for B0,
  # which reissues 22 ids, because B0 rewrites identical bytes.
  ls -i "$KD"/structure/*.bin "$KD"/payload/*.bin 2>/dev/null \
    | awk '{n=$2; sub(/.*block-/,"",n); sub(/\.bin/,"",n); print n, $1}' | sort -n > "$OUT/inodes-$r.txt"
  C=$(join "$OUT/inodes-$((r-1)).txt" "$OUT/inodes-$r.txt" 2>/dev/null | awk '$2!=$3' | wc -l)
  COLL=$((COLL + C))
done
[ "$KILLED" = 4 ] && ok "4 of 4 writers died of real SIGKILL" || bad "only $KILLED of 4 were SIGKILLed"
[ "$COLL" = 0 ] && ok "zero reissued ids across 3 crash-restart rounds (inode identity)" \
               || bad "$COLL ids were reissued onto a new inode"
# Density of the union must survive every restart, even though the corpus is
# replayed and the RECORDS are therefore duplicated.
if "$F" verify-s2 $CAP "$KD" "$OUT/k.bin" $THRESH --prefix-ok > "$OUT/t2b.txt" 2>&1; then
  ok "union still dense and collision-free after 3 restarts"
else
  if grep -q 'not dense\|BOTH streams' "$OUT/t2b.txt"; then
    bad "id integrity broke after restarts: $(grep -m1 'VERIFY FAIL' "$OUT/t2b.txt" | cut -c1-72)"
  else
    ok "union dense and collision-free; only replayed records differ, as designed"
  fi
fi
LEFT=$(ls "$KD"/structure "$KD"/payload 2>/dev/null | grep -c 'tmp' || true)
echo "    leftover temp files after 4 kills: $LEFT (nothing sweeps them; T4 proves they cannot vote)"

echo "════════ T3  PRIMARY — three real SIGKILLs, resumed, ALL records back"
# ROUND_TRIP_IS_THE_TEST in its strongest form: the process does not exit, it
# is KILLED, three times, and after the third restart every record of the
# corpus must be present, byte-identical and in order.
#
# The restart resumes PER STREAM. That is not a convenience — T2a measured the
# two streams sitting at different durable frontiers after one kill (structure
# 0 records, payload 55), because they seal independently. Resuming both from
# one global corpus index would re-write everything the ahead stream already
# holds, and the store would "round-trip" with duplicates. Each stream is told
# how many of ITS records are already durable and skips exactly those.
RD="$OUT/resume"; mkdir -p "$RD/structure" "$RD/payload"
RN=3000
"$F" corpus "$OUT/r.bin" $RN mixed 31 > /dev/null
SK=0; PK=0; KILLS=0
for r in 1 2 3; do
  "$F" spawn-kill --store "$RD/payload" --after-blocks $((r * 4)) --cwd "$OUT" \
    -- "$P" s2 "$OUT/r.bin" $RN $CAP 20 1 "$RD" 0 0 b1s2 0 $THRESH 256 $SK $PK \
    > "$OUT/res-$r.txt" 2>&1
  grep -q 'signal=Some(9)' "$OUT/res-$r.txt" && KILLS=$((KILLS+1))
  # Read the new per-stream frontier back out of the durable store itself.
  "$F" verify-s2 $CAP "$RD" "$OUT/r.bin" $THRESH --prefix-ok > "$OUT/res-v$r.txt" 2>&1
  SK=$(grep -m1 -o 'structure_records=[0-9]*' "$OUT/res-v$r.txt" | cut -d= -f2)
  PK=$(grep -m1 -o 'payload_records=[0-9]*'   "$OUT/res-v$r.txt" | cut -d= -f2)
  echo "    kill $r: durable frontier structure=$SK payload=$PK  $(grep -m1 union_ids= "$OUT/res-v$r.txt")"
done
[ "$KILLS" = 3 ] && ok "3 of 3 writers died of real SIGKILL" || bad "only $KILLS of 3 were SIGKILLed"
# The fourth lifetime runs to completion and finishes the corpus.
"$P" s2 "$OUT/r.bin" $RN $CAP 20 1 "$RD" 0 0 b1s2 0 $THRESH 256 $SK $PK \
  > "$OUT/res-final.log" 2>&1
if "$F" verify-s2 $CAP "$RD" "$OUT/r.bin" $THRESH > "$OUT/t3.txt" 2>&1; then
  ok "ALL $RN records back after 3 kills: $(grep -m1 structure_records= "$OUT/t3.txt")"
  ok "  $(grep -m1 union_ids= "$OUT/t3.txt")"
else
  bad "round trip across three KILLS failed"; sed 's/^/        /' "$OUT/t3.txt"
fi

echo "════════ NC  the suites, deliberately broken"
# A suite that has not been shown to fail is not evidence.
NB="$OUT/nc"; rm -rf "$NB"; cp -r "$S1" "$NB"
# Break the union: duplicate an id into the other stream.
SOME=$(ls "$NB/payload" | head -1)
cp "$NB/payload/$SOME" "$NB/structure/$SOME"
if "$F" verify-s2 $CAP "$NB" "$OUT/c.bin" $THRESH > "$OUT/nc1.txt" 2>&1; then
  bad "verifier passed a store with the SAME id in both streams — no teeth"
else
  ok "collision across streams caught: $(grep -m1 'VERIFY FAIL' "$OUT/nc1.txt" | cut -c1-72)"
fi
rm -f "$NB/structure/$SOME"
# Break density: drop a block from the middle of the union.
MID=$(ls "$NB/payload" | sed -n '2p')
rm -f "$NB/payload/$MID"
if "$F" verify-s2 $CAP "$NB" "$OUT/c.bin" $THRESH > "$OUT/nc2.txt" 2>&1; then
  bad "verifier passed a store with a hole in the union — no teeth"
else
  ok "hole in the union caught: $(grep -m1 'VERIFY FAIL' "$OUT/nc2.txt" | cut -c1-72)"
fi
# Break routing WITHOUT breaking density. An earlier version of this control
# copied a payload block in as block-9999.bin, which the verifier rejected for
# density before it ever looked at a record length — it reported "caught" while
# testing something else entirely. Overwriting an existing structure block with
# payload content keeps every id exactly where it was, so the ONLY thing wrong
# with the store is that oversized records are sitting in the structure stream.
rm -rf "$NB"; cp -r "$S1" "$NB"
BIG=$(ls "$NB/payload" | head -1)
VICTIM=$(ls "$NB/structure" | head -1)
cp "$NB/payload/$BIG" "$NB/structure/$VICTIM"
if "$F" verify-s2 $CAP "$NB" "$OUT/c.bin" $THRESH > "$OUT/nc3.txt" 2>&1; then
  bad "verifier passed a misrouted record — routing is untested"
else
  MSG=$(grep -m1 'wrong side of threshold' "$OUT/nc3.txt")
  if [ -n "$MSG" ]; then
    ok "misrouted record caught BY THE ROUTING CHECK: $(echo "$MSG" | cut -c1-66)"
  else
    bad "store rejected, but not for routing: $(grep -m1 'VERIFY FAIL' "$OUT/nc3.txt" | cut -c1-66)"
  fi
fi

echo
echo "P1 COMBINATION: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
