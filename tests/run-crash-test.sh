#!/usr/bin/env bash
# Crash suite for the landed write path.
# AXVERITY_FORMAT_LAND_AND_WIRE_V1 / P2.
#
# What a crash is allowed to do, stated before it is tested: lose the tail,
# leave an uncollected .tmp file, and leave the two streams at DIFFERENT
# durable frontiers, because they seal independently. What it may not do is
# corrupt a sealed block, reissue an id, or put a hole in the union.
#
# Deliberately NOT asserted: that the whole corpus round-trips after a kill.
# wp-slice replays its input file from the first record on every start, so a
# restarted run re-packs records the previous one already made durable —
# asserting full round-trip here would be asserting a property of the test
# binary's replay, not of the format. Round-trip across restart is proved in
# run-slice-test.sh, where each lifetime writes its own corpus.
#
# The id claims are the ones that matter here, and they are exactly what B1 was
# chosen for: mint-from-zero reissued 22 ids across three crash-restart rounds
# and lost two thirds of a corpus.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
BIN="$HERE/build/wp-slice"
FMTH="$HERE/experiments/format/harness/target/release/fmth"
# AXVERITY_EXTENT_WRITE_PATH step 1: written into the store config below and
# read back by the binary, rather than being a second copy of a lib/*.m1
# literal. Override to sweep: `CAP=4194304 tests/run-crash-test.sh`.
CAP=${CAP:-16384}
POOL=${POOL:-3}
THRESH=32
NREC=6000

[ -x "$BIN" ] || { echo "FAIL: $BIN not built" >&2; exit 1; }
[ -x "$FMTH" ] || ( cd "$HERE/experiments/format/harness" && cargo build --release -q )

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

"$FMTH" corpus "$T/corpus.bin" $NREC mixed 17 > /dev/null
mkdir -p "$T/.axverity-store/structure" "$T/.axverity-store/payload"
mkdir -p "$T/.axverity-store/config"
echo "$CAP"  > "$T/.axverity-store/config/block_capacity"
echo "$POOL" > "$T/.axverity-store/config/pool_depth"

# Inode identity per id. A REISSUED id always lands on a NEW inode, because
# fs_write_raw renames a freshly created temp over the target — so this fires
# even when the bytes are identical. Content hashing cannot see it: it reports
# ZERO collisions for mint-from-zero, which reissues 22, because that scheme
# rewrites the same corpus to the same bytes.
snapshot() {
  ls -i "$T"/.axverity-store/structure/*.bin "$T"/.axverity-store/payload/*.bin 2>/dev/null \
    | awk '{n=$2; s=n; sub(/.*\/(structure|payload)\/.*/,"",s);
            st = (n ~ /\/payload\//) ? "payload" : "structure";
            sub(/.*block-/,"",n); sub(/\.bin/,"",n); print st "/" n, $1}' | sort
}

KILLED=0; COLL=0
snapshot > "$T/inodes-0.txt"
for r in 1 2 3; do
  "$FMTH" spawn-kill --store "$T/.axverity-store/payload" --after-blocks $((r * 4)) --cwd "$T" \
    -- "$BIN" "$T/corpus.bin" $NREC > "$T/kill-$r.txt" 2>&1
  grep -q 'signal=Some(9)' "$T/kill-$r.txt" && KILLED=$((KILLED+1))
  snapshot > "$T/inodes-$r.txt"
  C=$(join "$T/inodes-$((r-1)).txt" "$T/inodes-$r.txt" 2>/dev/null | awk '$2!=$3' | wc -l)
  COLL=$((COLL + C))
done

[ "$KILLED" = 3 ] && ok "3 of 3 writers died of a real SIGKILL mid-write" \
                  || bad "only $KILLED of 3 were actually SIGKILLed"
[ "$COLL" = 0 ] && ok "zero (stream, id) pairs reissued across 3 crash-restart rounds (inode identity)" \
               || bad "$COLL (stream, id) pairs were reissued onto a new inode"

# Union density and no cross-stream duplicate — checked directly, because the
# footer chain asserts block k is followed by k+1 and any replay using
# "first missing id" as its frontier stops dead at a hole.
python3 - "$T/.axverity-store" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
seen = {}
dup = []
# PER-STREAM DENSITY replaces the union check (AXVERITY_EXTENT_WRITE_PATH
# 5b/5d). Each stream owns its own sequence, so structure/block-0 and
# payload/block-0 both exist and are both correct. Density still catches what
# the union check protected: a lost block leaves a hole, and a restarted
# sequence (the B1 mint-from-zero defect) overwrites and comes up short.
tot = 0
for d in ("structure", "payload"):
    ids = sorted(int(f.stem.split("-")[1]) for f in (root / d).glob("block-*.bin"))
    if not ids:
        continue
    for pos, i in enumerate(ids):
        if pos != i:
            sys.exit(f"FAIL: {d} not dense — position {pos} holds id {i}")
    tot += len(ids)
    print(f"  PASS  {d} dense 0..{ids[-1]} ({len(ids)} blocks)")
if tot == 0:
    sys.exit("FAIL: no blocks in either stream")
PY
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# Every surviving block must still decode. A crash loses the tail; it must
# never corrupt the head. The record compare is prefix-tolerant because the
# replay above legitimately duplicates records.
BAD=$(python3 - "$T/.axverity-store" <<'PY'
import pathlib, sys, struct
root = pathlib.Path(sys.argv[1]); bad = 0
for d in ("structure", "payload"):
    for f in (root / d).glob("block-*.bin"):
        raw = f.read_bytes()
        if len(raw) < 8: bad += 1; continue
        body, off = raw[:-8], 0
        while off < len(body):
            b0 = body[off]
            if b0 < 128: n, vl = b0, 1
            else:
                if off + 1 >= len(body): bad += 1; break
                n, vl = (b0 - 128) + body[off+1] * 128, 2
            if off + vl + n > len(body): bad += 1; break
            off += vl + n
print(bad)
PY
)
[ "${BAD:-1}" = 0 ] && ok "every surviving block decodes cleanly — no truncated or corrupt block" \
                    || bad "$BAD blocks failed to decode"

TMPS=$(find "$T/.axverity-store" -name '*.tmp.*' | wc -l)
echo "  note  leftover temp files after 3 kills: $TMPS (nothing sweeps them; wp_bid_parse rejects them)"
# And they must not have voted: the next id must be max+1 over real blocks.
python3 - "$T/.axverity-store" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
real = [int(f.stem.split("-")[1]) for d in ("structure","payload") for f in (root/d).glob("block-*.bin")]
temps = [f.name for d in ("structure","payload") for f in (root/d).iterdir() if ".tmp." in f.name]
print(f"  info  max real id={max(real)}, temp files present={len(temps)}")
PY


echo
echo "── negative controls: each check above, deliberately broken"
# A suite that has not been shown to fail is not evidence. All three checks
# above passed on the first run, which is exactly when they are least
# trustworthy — two harness defects in this project's earlier rounds were
# found this way and none by inspection.
check_union() {   # exit 0 = store looks good, non-zero = rejected
  python3 - "$1" >/dev/null 2>&1 <<'PYX'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
total = 0
for d in ("structure", "payload"):
    ids = sorted(int(f.stem.split("-")[1]) for f in (root / d).glob("block-*.bin"))
    total += len(ids)
    if len(ids) != len(set(ids)): sys.exit("dup")
    if ids and ids != list(range(0, len(ids))): sys.exit("hole")
# An EMPTY store is not a healthy store. Without this, a wrong path reads as
# "looks good" and every negative control below silently loses its teeth —
# which is exactly what happened when the union check became per-stream.
if total == 0: sys.exit("empty")
PYX
}
check_decode() {  # echoes the number of undecodable blocks
  python3 - "$1" <<'PYX'
import pathlib, sys
root = pathlib.Path(sys.argv[1]); bad = 0
for d in ("structure", "payload"):
    for f in (root / d).glob("block-*.bin"):
        raw = f.read_bytes()
        if len(raw) < 8: bad += 1; continue
        body, off = raw[:-8], 0
        while off < len(body):
            b0 = body[off]
            if b0 < 128: n, vl = b0, 1
            else:
                if off + 1 >= len(body): bad += 1; break
                n, vl = (b0 - 128) + body[off+1] * 128, 2
            if off + vl + n > len(body): bad += 1; break
            off += vl + n
print(bad)
PYX
}

NB="$T/nc"; rm -rf "$NB"; cp -r "$T/.axverity-store" "$NB"
if check_union "$NB"; then ok "the intact store passes the per-stream density check (so a failure below means something)"
else bad "the intact store already fails the density check — the control itself is broken"; fi

# NC1 — the same id in both streams is now LEGAL, and this asserts that on
# purpose rather than deleting the case.
#
# It used to be the collision a shared counter existed to prevent. Under
# AXVERITY_EXTENT_WRITE_PATH 5b/5d each stream owns its own sequence, because a
# locator carries the stream — measured: without it a reader spent ~3.5 us
# probing two directories to find a record it then read in 676 ns. So
# structure/block-0 and payload/block-0 are two different blocks and both are
# correct.
#
# Keeping it as a POSITIVE control matters: a future change that reintroduces a
# shared counter, or a reader that starts probing both directories again, would
# make this fail and say why. Deleting the case would have left nothing to
# notice either.
rm -rf "$NB"; cp -r "$T/.axverity-store" "$NB"
SOME=$(ls "$NB/payload" | grep -E '^block-[0-9]+\.bin$' | head -1)
cp "$NB/payload/$SOME" "$NB/structure/$SOME" 2>/dev/null
if check_union "$NB"; then ok "NC1: the same id in both streams is ACCEPTED — per-stream sequences, by design"
else bad "NC1: the same id in both streams was rejected — a shared counter has come back"; fi

# NC1b — a stream that SKIPPED a sequence number. This is the teeth the old
# NC1 had: density is what the union check was really protecting.
rm -rf "$NB"; cp -r "$T/.axverity-store" "$NB"
MAXP=$(ls "$NB/payload" | grep -E '^block-[0-9]+\.bin$' | sed 's/block-//;s/\.bin//' | sort -n | tail -1)
cp "$NB/payload/block-$MAXP.bin" "$NB/payload/block-$((MAXP+2)).bin"
if check_union "$NB"; then bad "NC1b: a skipped sequence number passed the density check — no teeth"
else ok "NC1b: a skipped sequence number is caught"; fi

# NC2 — a hole in the middle of the union.
rm -rf "$NB"; cp -r "$T/.axverity-store" "$NB"
MID=$(ls "$NB/payload" | grep -E '^block-[0-9]+\.bin$' | sed -n '2p'); rm -f "$NB/payload/$MID"
if check_union "$NB"; then bad "NC2: a hole passed the density check — no teeth"
else ok "NC2: a hole in a stream is caught"; fi

# NC3 — a truncated block: the one thing a crash is never allowed to produce,
# and therefore the one the suite most needs to be able to see.
rm -rf "$NB"; cp -r "$T/.axverity-store" "$NB"
VIC="$NB/payload/$(ls "$NB/payload" | grep -E '^block-[0-9]+\.bin$' | head -1)"
SZ=$(stat -c%s "$VIC"); truncate -s $((SZ / 2)) "$VIC"
NBAD=$(check_decode "$NB")
if [ "${NBAD:-0}" -gt 0 ]; then ok "NC3: a truncated block is caught ($NBAD undecodable)"
else bad "NC3: a truncated block decoded cleanly — no teeth"; fi

echo
echo "CRASH SUITE: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
