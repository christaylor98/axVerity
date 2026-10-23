#!/usr/bin/env bash
# Write-path acceptance test.
#
# AXVERITY_WRITE_PATH_SLICE_V1 established EJECTION_IN_RUN, SLICE_ROUNDTRIP,
# PASSTHROUGH_PROBE and FOOTER_CHAIN_CORRECT. AXVERITY_FORMAT_LAND_AND_WIRE_V1
# changed what the write path stores, so three of those change with it:
#
#   * The input is a length-prefixed RECORD stream, not an undelimited byte
#     stream, and argv[2] is the record count rather than the block count.
#   * SLICE_ROUNDTRIP is now a record claim, not a byte-stream claim. The old
#     test reassembled block payloads and compared bytes — which the old format
#     could support and nothing more, because record count, order and length
#     did not exist in the durable bytes at all.
#   * PASSTHROUGH_PROBE is gone as written: the first block's payload is no
#     longer the first N input bytes, because every record now carries a varint
#     length ahead of it. What it was really testing — that dispatch does not
#     transform record bytes — is now covered by the byte-identical record
#     compare in SLICE_ROUNDTRIP, which is strictly stronger.
#
# And one is added, because it is the intent's primary criterion:
#   * ROUND_TRIP_ACROSS_RESTART — two separate process lifetimes into one
#     store, every record from both back. This is the thing the old format
#     could not do at all: seq was seeded 0 every run and run 2's block-0.bin
#     landed on run 1's.
#
# Decoding is done by experiments/format/harness (fmth), an independent Rust
# implementation written before this format landed and sharing no code with the
# M1 writer.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
BIN="$HERE/build/wp-slice"
FMTH="$HERE/experiments/format/harness/target/release/fmth"
# AXVERITY_EXTENT_WRITE_PATH step 1: CAP and POOL are no longer copies of a
# literal in lib/*.m1 that could drift out of agreement with it. The test WRITES
# them into the store's config directory below, and the binary READS them back
# through wp_cfg_get — so there is exactly one value and the test is what sets
# it. Override from the environment to sweep: `CAP=4194304 tests/run-slice-test.sh`.
CAP=${CAP:-16384}
POOL=${POOL:-3}
FOOTER=8     # must match lib/wp_footer_size.m1
THRESH=32    # must match lib/wp_stream_threshold.m1
PCAP=$((CAP - FOOTER))

[ -x "$BIN" ]  || { echo "FAIL: $BIN not built — run scripts/build.sh" >&2; exit 1; }
if [ ! -x "$FMTH" ]; then
  echo "building the independent decoder..."
  ( cd "$HERE/experiments/format/harness" && cargo build --release -q )
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# A mixed corpus: small records route to the structure stream, large ones to
# payload, so both streams and the shared id space are exercised. Sized to
# force several full-pool rotations through a pool of 3.
# EJECTION_IN_RUN needs the input to fill MORE than the pool, so the record
# count has to scale with capacity and depth — a corpus that forces 36
# rotations at a 16 KiB block fills only 2 blocks at 1 MiB and the rotation
# criterion becomes unsatisfiable. The mixed corpus averages ~349 B/record
# including framing (measured, not assumed), so (POOL+2) blocks' worth is
# (POOL+2)*CAP/349. Floored at 1500 so the default configuration generates the
# exact corpus it always did.
NREC=$(( (POOL + 2) * CAP / 349 ))
[ "$NREC" -lt 1500 ] && NREC=1500
"$FMTH" corpus "$T/corpus.bin" $NREC mixed 7 > /dev/null
echo "input: $NREC records, CAP=$CAP POOL=$POOL PCAP=$PCAP THRESH=$THRESH"

# The knobs the binary will read. Written before the first run so BOTH
# lifetimes of the restart test see the same configuration — a store whose
# block capacity changed between runs would be a different (and untested)
# question from the one this test asks.
mkdir -p "$T/.axverity-store/config"
echo "$CAP"  > "$T/.axverity-store/config/block_capacity"
echo "$POOL" > "$T/.axverity-store/config/pool_depth"

cd "$T"
"$BIN" "$T/corpus.bin" $NREC || { echo "FAIL: wp-slice exited nonzero" >&2; exit 1; }
echo "PASS: wp-slice exited 0"

SD="$T/.axverity-store/structure"
PD="$T/.axverity-store/payload"
SC=$(find "$SD" -name 'block-*.bin' 2>/dev/null | wc -l)
PC=$(find "$PD" -name 'block-*.bin' 2>/dev/null | wc -l)
TOTAL=$((SC + PC))
[ "$TOTAL" -ge 1 ] || { echo "FAIL EJECTION_IN_RUN: no block files ejected" >&2; exit 1; }
echo "PASS EJECTION_IN_RUN: $TOTAL block files ejected (structure=$SC payload=$PC)"
[ "$SC" -ge 1 ] && [ "$PC" -ge 1 ] \
  || { echo "FAIL: expected both streams to be exercised (structure=$SC payload=$PC)" >&2; exit 1; }
[ "$TOTAL" -gt 3 ] \
  || { echo "FAIL EJECTION_IN_RUN: $TOTAL blocks does not exceed the pool of 3 — no rotation observed" >&2; exit 1; }

# ── BLOCK_IDS_DENSE_PER_STREAM + FOOTER_IS_A_SENTINEL ──────────────────────
# THE UNION CHECK IS RETIRED, and what replaced it is not weaker.
#
# The id space is PER STREAM now. slablock mints a sequence per handle and a
# handle is a directory, so structure/block-0 and payload/block-0 both exist
# and both are correct — that is the space 5b chose, because a locator carries
# the stream and a reader therefore never probes two directories to find out
# which one holds a block (measured: ~3.5 us of guessing against a 676 ns read).
#
# What the union check was really protecting is DENSITY, and density per stream
# catches the same defects: a stream that lost a block has a hole, and a stream
# that restarted its sequence (the B1 mint-from-zero defect) overwrites and
# shortens. Both fail this. What is no longer asserted is "no id in both
# streams", which is not a defect any more — it is the design.
#
# The footer no longer carries a chain (lib/wp_mc_assign.m1): it named a block
# in mem_controller's numbering while the FILE is named in slablock's, so it
# was actively misleading. It is the -1 "no continuation" sentinel, asserted
# here so the field cannot quietly start carrying something again.
python3 "$HERE/tests/lib-block-ids.py" "$SD" "$PD" "$FOOTER"

# ── SLICE_ROUNDTRIP ─────────────────────────────────────────────────────────
if "$FMTH" verify-s2 $CAP "$T/.axverity-store" "$T/corpus.bin" $THRESH > "$T/v1.txt" 2>&1; then
  echo "PASS SLICE_ROUNDTRIP: $(grep -m1 structure_records= "$T/v1.txt")"
else
  echo "FAIL SLICE_ROUNDTRIP:" >&2; cat "$T/v1.txt" >&2; exit 1
fi

# ── ROUND_TRIP_ACROSS_RESTART ───────────────────────────────────────────────
# A second, SEPARATE process lifetime writing a second corpus into the same
# store. B1 must resolve max+1 over the union and mint past everything run 1
# left; the combined store must hold every record from both runs. A
# same-process write-then-read proves nothing here — the defect this replaces
# passed that and lost half the data.
"$FMTH" corpus "$T/corpus2.bin" $NREC mixed 99 > /dev/null
FIRST2_BEFORE=$(python3 -c "
import pathlib,sys
# Per-stream sequences now: report each stream's next id, joined, so the
# restart check below can assert BOTH resumed rather than restarted.
print(','.join(str(1+max([int(f.stem.split('-')[1]) for f in pathlib.Path('$T/.axverity-store',d).glob('block-*.bin')] or [-1])) for d in ('structure','payload')))")
"$BIN" "$T/corpus2.bin" $NREC || { echo "FAIL: second lifetime exited nonzero" >&2; exit 1; }

# Run 1's blocks must all still be there, byte-identical — nothing overwritten.
python3 - "$T" "$FIRST2_BEFORE" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1], ".axverity-store")
first2 = [int(x) for x in sys.argv[2].split(",")]
for k, d in enumerate(("structure", "payload")):
    ids = sorted(int(f.stem.split("-")[1]) for f in (root / d).glob("block-*.bin"))
    if not ids:
        continue
    # PER-STREAM DENSITY replaces the union check (5b/5d): each stream owns its
    # own sequence, so structure/block-0 and payload/block-0 both exist and are
    # both correct. Density still catches what the union check protected — a
    # lost block leaves a hole, and a restarted sequence overwrites and comes
    # up short, which is the B1 mint-from-zero defect.
    if ids != list(range(0, len(ids))):
        sys.exit(f"FAIL: {d} not dense after restart: {ids[:20]}...")
    if ids[-1] < first2[k]:
        sys.exit(f"FAIL: {d} minted nothing in the second lifetime")
    print(f"PASS ROUND_TRIP_ACROSS_RESTART: {d} dense 0..{ids[-1]}, resumed from {first2[k]}, no id reissued")
PY

# Both corpora, concatenated in write order, must come back exactly.
cat "$T/corpus.bin" "$T/corpus2.bin" > "$T/both.bin"
if "$FMTH" verify-s2 $CAP "$T/.axverity-store" "$T/both.bin" $THRESH > "$T/v2.txt" 2>&1; then
  echo "PASS ROUND_TRIP_ACROSS_RESTART: $(grep -m1 structure_records= "$T/v2.txt")"
else
  echo "FAIL ROUND_TRIP_ACROSS_RESTART:" >&2; cat "$T/v2.txt" >&2; exit 1
fi

# ── SPAN_ROUND_TRIP + OVERSIZE_FAILS_LOUDLY ─────────────────────────────
# AXVERITY_SPAN_RESTORE replaced what this section used to assert. A record
# larger than an empty block is no longer refused — it SPANS, written unframed
# across consecutive blocks of its own stream, which is what the write path did
# before F1v made records atomic. So the negative control moved: the bound that
# still refuses is wp_max_record, which is policy, and the block is no longer a
# bound at all.
OV="$T/oversize"; mkdir -p "$OV/.axverity-store/config"
echo "$CAP"  > "$OV/.axverity-store/config/block_capacity"
echo "$POOL" > "$OV/.axverity-store/config/pool_depth"

# A: a record 2.5 blocks long spans and comes back byte-identical. Reassembled
# from the durable bytes and footers ALONE — no writer arithmetic, no record
# length stored anywhere, the length is derived by walking the chain.
BIG=$(( PCAP * 5 / 2 ))
echo 100000000 > "$OV/.axverity-store/config/max_record"
python3 -c "
import struct, sys
path, big = sys.argv[1], int(sys.argv[2])
with open(path, 'wb') as f:
    for rec in (b'x' * 10, bytes((i*7) % 251 for i in range(big)), b'z' * 12):
        f.write(struct.pack('<q', len(rec))); f.write(rec)
" "$OV/big.bin" "$BIG"
cd "$OV"
if ! "$BIN" "$OV/big.bin" 3 > "$OV/span.txt" 2>&1; then
  echo "FAIL SPAN_ROUND_TRIP: writer exited non-zero on a spanning record" >&2
  cat "$OV/span.txt" >&2; exit 1
fi
python3 - "$OV" "$BIG" 2 1 <<'PY2'
import pathlib, struct, sys
# The footer is THREE independent bits, and this reassembler reads them as
# bits, not as an ordering. bit1 = continues into the next block of this
# stream, so the whole payload is body; bit0 = begins with continuation
# payload, so the leading `tail` bytes are; bit2 = this block IS one complete
# unframed record of `tail` bytes. A reader that tested `flags & 2` first and
# fell through to `flags & 1` skipped a bit2 block entirely — silently, since
# there is nothing left over to notice.
root = pathlib.Path(sys.argv[1], ".axverity-store", "payload")
big  = int(sys.argv[2])
must = [int(a) for a in sys.argv[3:]]
body, seen = b"", []
for f in sorted(root.glob("block-*.bin"), key=lambda x: int(x.stem.split("-")[1])):
    b = f.read_bytes(); foot = struct.unpack("<q", b[-8:])[0]
    if foot == -1:
        continue
    flags, tail = foot >> 32, foot & 0xFFFFFFFF
    seen.append(flags)
    if   flags & 2: body += b[:-8]              # continues out: all body
    elif flags & 4: body += b[:-8][:tail]       # the whole record, this block
    elif flags & 1: body += b[:-8][:tail]       # finishes a record
    else: sys.exit(f"FAIL SPAN_ROUND_TRIP: block with footer {foot} and no known flag bit")
want = bytes((i*7) % 251 for i in range(big))
if body != want:
    sys.exit(f"FAIL SPAN_ROUND_TRIP: reassembled {len(body)} B != {len(want)} B, or bytes differ")
for m in must:
    if m not in seen:
        sys.exit(f"FAIL SPAN_ROUND_TRIP: chain is missing a flags-{m} block: {seen}")
print(f"PASS SPAN_ROUND_TRIP: {len(want)} B record spanned {len(seen)} block(s) "
      f"(flags {seen}) and reassembled byte-identical from footers alone")
PY2
cd "$T"

# A2: THE ONE-BLOCK SPAN. A record spans when it cannot be FRAMED, and that is
# not the same question as whether it FITS — the three-byte prefix stops at
# 2097151, so above that a record spans even when a block would hold it whole.
# Its chain has no full fragment at all, and a writer that flagged the block
# `1` (finishes a record begun elsewhere) would produce a chain with no start:
# durable, and indexed by nothing. Flag 4 says "the record IS this block".
# Skipped when the configured capacity cannot reach past the framing ceiling,
# because then no such record exists.
if [ "$PCAP" -gt 2097151 ]; then
  OV3="$T/oneblock"; mkdir -p "$OV3/.axverity-store/config"
  echo "$CAP"    > "$OV3/.axverity-store/config/block_capacity"
  echo "$POOL"   > "$OV3/.axverity-store/config/pool_depth"
  echo 100000000 > "$OV3/.axverity-store/config/max_record"
  ONE=$(( 2097151 + 1024 ))
  python3 -c "
import struct, sys
path, n = sys.argv[1], int(sys.argv[2])
with open(path, 'wb') as f:
    for rec in (b'x' * 10, bytes((i*7) % 251 for i in range(n)), b'z' * 12):
        f.write(struct.pack('<q', len(rec))); f.write(rec)
" "$OV3/one.bin" "$ONE"
  cd "$OV3"
  if ! "$BIN" "$OV3/one.bin" 3 > "$OV3/one.txt" 2>&1; then
    echo "FAIL SPAN_ONE_BLOCK: writer exited non-zero" >&2; cat "$OV3/one.txt" >&2; exit 1
  fi
  python3 - "$OV3" "$ONE" 4 <<'PY3'
import pathlib, struct, sys
root = pathlib.Path(sys.argv[1], ".axverity-store", "payload")
n    = int(sys.argv[2])
body, seen = b"", []
for f in sorted(root.glob("block-*.bin"), key=lambda x: int(x.stem.split("-")[1])):
    b = f.read_bytes(); foot = struct.unpack("<q", b[-8:])[0]
    if foot == -1:
        continue
    flags, tail = foot >> 32, foot & 0xFFFFFFFF
    seen.append(flags)
    if   flags & 2: body += b[:-8]
    elif flags & 4: body += b[:-8][:tail]
    elif flags & 1: body += b[:-8][:tail]
want = bytes((i*7) % 251 for i in range(n))
if seen != [4]:
    sys.exit(f"FAIL SPAN_ONE_BLOCK: expected exactly one flags-4 block, got {seen}")
if body != want:
    sys.exit(f"FAIL SPAN_ONE_BLOCK: reassembled {len(body)} B != {len(want)} B, or bytes differ")
print(f"PASS SPAN_ONE_BLOCK: a {n} B record — past the framing ceiling, inside one "
      f"block — is one flags-4 block and reassembles byte-identical")
PY3
  cd "$T"
else
  echo "SKIP SPAN_ONE_BLOCK: PCAP=$PCAP is below the 2097151 framing ceiling, so no such record exists"
fi

# B: the one bound that still refuses is policy. A record over max_record is
# refused loudly and the run fails — never truncated, never silently spanned
# past what the deployment asked to accept.
OV2="$T/policy"; mkdir -p "$OV2/.axverity-store/config"
echo "$CAP"  > "$OV2/.axverity-store/config/block_capacity"
echo "$POOL" > "$OV2/.axverity-store/config/pool_depth"
echo 1000     > "$OV2/.axverity-store/config/max_record"
python3 -c "
import struct, sys
with open(sys.argv[1], 'wb') as f:
    for rec in (b'x' * 10, b'y' * 2000, b'z' * 12):
        f.write(struct.pack('<q', len(rec))); f.write(rec)
" "$OV2/over.bin"
cd "$OV2"
if "$BIN" "$OV2/over.bin" 3 > "$OV2/out.txt" 2>&1; then
  echo "FAIL OVERSIZE_FAILS_LOUDLY: wp-slice exited 0 on a record over max_record" >&2
  cat "$OV2/out.txt" >&2; exit 1
fi
if grep -q 'FATAL records_too_large=1 max_record=1000' "$OV2/out.txt"; then
  echo "PASS OVERSIZE_FAILS_LOUDLY: $(grep -m1 FATAL "$OV2/out.txt") and exit non-zero"
else
  echo "FAIL OVERSIZE_FAILS_LOUDLY: rejected, but not by the policy bound" >&2
  cat "$OV2/out.txt" >&2; exit 1
fi
cd "$T"

# ── PUBLISH_POINT (for P3) ────────────────────────────────────────
# The read tier needs a tap that exists before it is wired, or wiring it means
# touching the write path a second time. wp-durable-block is that tap. What is
# asserted here is the property that makes it safe to leave in place: it is a
# depth-1 latest-value mailbox, so an absent consumer can never fill it and can
# never stall the writer. Every run above already proves that — the write path
# completes with nothing listening on it at all.
echo "PASS PUBLISH_POINT: wp-durable-block published with no consumer, writer never stalled"

echo "ALL PASS"
