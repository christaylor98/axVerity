#!/usr/bin/env bash
# Read tier against the durable store.
# AXVERITY_FORMAT_LAND_AND_WIRE_V1 / P3.
#
# COLD_START_IS_THE_TEST. Every assertion runs in a process that never saw the
# writer, against bytes on disk. The read tier's own README said this could not
# be built yet — "durable blocks have no record framing and no stable block id,
# so a durable name -> RID map would be WRONG after restart, not stale". F1v
# and B1 removed both obstacles; this is the check that they actually did.
#
# NO SECOND WRITE-PATH TOUCH. The suite re-verifies the P2 hashes at the end.
# The read tier reads the durable store, which is a shared artefact rather than
# a channel, so it needs no tap into the pipeline at all.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
BIN="$HERE/build/wp-slice"
RT="$HERE/readtier/build/rt-driver"
FMTH="$HERE/experiments/format/harness/target/release/fmth"
THRESH=32

for b in "$BIN" "$RT"; do
  [ -x "$b" ] || { echo "FAIL: $b not built" >&2; exit 1; }
done
[ -x "$FMTH" ] || ( cd "$HERE/experiments/format/harness" && cargo build --release -q )

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# ── T1  cold start over a MULTI-BLOCK structure store ───────────────────────
# 6000 records at ~15 bytes is several blocks, so this exercises the
# directory fold and the RID's block component, not just one block's ordinals.
#
# CAP IS PINNED SMALL HERE, ON PURPOSE (AXVERITY_SIZE_THRESHOLD_RECONCILE).
# Every store this suite builds asks a MULTI-BLOCK question — the directory
# fold, the RID's block component, a dropped block, a truncated block. None of
# them is a question about block size. When the production default moved to
# 4 MiB this same 90 KB corpus landed in ONE block and T1 failed on its own
# precondition, which is the test losing its subject, not the write path
# regressing. Pinning the capacity keeps the corpus small and the subject
# intact; the 4 MiB default is exercised end to end by
# `CAP=4194304 tests/run-slice-test.sh`. The decoding here is already
# capacity-agnostic — it reads the stamp (see `stride` below), not a literal.
CAP=${CAP:-16384}
pin_cap() { mkdir -p "$1/.axverity-store/config"; echo "$CAP" > "$1/.axverity-store/config/block_capacity"; }
echo "════════ T1  cold start, multi-block structure store  (CAP=$CAP)"
N=6000
D="$T/multi"; mkdir -p "$D"; pin_cap "$D"
"$FMTH" corpus "$D/c.bin" $N structure 1 > /dev/null
( cd "$D" && "$BIN" "$D/c.bin" $N ) > "$D/write.log" 2>&1 \
  || { echo "FAIL: writer exited nonzero" >&2; cat "$D/write.log" >&2; exit 1; }
SB=$(ls "$D/.axverity-store/structure" | wc -l)
echo "    wrote $N records into $SB structure blocks"
[ "$SB" -gt 1 ] || bad "expected more than one structure block, got $SB"
if ( cd "$D" && "$RT" cold $N ) > "$D/cold.txt" 2>&1; then
  ok "all $(grep -c '  PASS' "$D/cold.txt") cold-start assertions, $(grep -m1 rebuild_records= "$D/cold.txt")"
  echo "    $(grep -m1 rebuild_ns= "$D/cold.txt")  $(grep -m1 rebuild_names= "$D/cold.txt")"
else
  bad "cold start failed"; grep -E 'FAIL|rebuild_' "$D/cold.txt" | sed 's/^/        /'
fi

# ── T2  cold start after a REAL RESTART ─────────────────────────────────────
# Two separate process lifetimes into one store. The structure generator is a
# pure function of the record index, so lifetime 2 writes the SAME n triples
# again: the record count must DOUBLE while every query answer stays identical.
# That separates "read both lifetimes" from "read only one" — a check on
# answers alone would pass even if half the store were never opened.
echo
echo "════════ T2  cold start after a real restart (two lifetimes)"
( cd "$D" && "$BIN" "$D/c.bin" $N ) > "$D/write2.log" 2>&1 \
  || { echo "FAIL: second lifetime exited nonzero" >&2; exit 1; }
SB2=$(ls "$D/.axverity-store/structure" | wc -l)
IDS=$(ls "$D/.axverity-store/structure" "$D/.axverity-store/payload" 2>/dev/null \
      | grep -o 'block-[0-9]*' | cut -d- -f2 | sort -n | tr '\n' ' ')
echo "    structure blocks now $SB2 (was $SB); union ids: $(echo $IDS | cut -c1-60)..."
if ( cd "$D" && "$RT" cold $N 2 ) > "$D/cold2.txt" 2>&1; then
  ok "cold start after restart: $(grep -m1 rebuild_records= "$D/cold2.txt") (doubled), all patterns unchanged"
else
  bad "cold start after restart failed"; grep -E 'FAIL|rebuild_' "$D/cold2.txt" | sed 's/^/        /'
fi

# ── T3  MIXED store: the rebuild reads BOTH streams ─────────────────────────
# This arm used to assert the opposite — that the rebuild read the structure
# stream alone and still got every triple. That premise was false and the
# assertion was a test of AXVERITY_SILENT_LOSS_FIX_V1's W1: S2 routes on SIZE
# (wp_write_step.m1:42-43), not on meaning, so "the payload blocks hold none of
# the graph" only held for a corpus whose triples are all under 32 bytes. This
# generator's are 8-14 B; a real consumer's are not, and every one of theirs was
# admitted, counted durable, and invisible.
#
# The arm is kept, not deleted, and it is kept POINTED THE OTHER WAY: the
# rebuild must read every record in both streams, and the payload blobs — which
# are random bytes, not triples — must be counted malformed rather than indexed
# or decoded into a panic. The malformed count is what proves the payload stream
# was actually read, so this is the arm that would catch a regression back to
# structure-only.
echo
echo "════════ T3  mixed store — both streams are read"
M="$T/mixed"; mkdir -p "$M"; pin_cap "$M"
MN=4000
"$FMTH" corpus "$M/c.bin" $MN mixed 7 > /dev/null
SREC=$("$FMTH" corpus-filter "$M/c.bin" "$M/struct.bin" le $THRESH | grep -o 'records=[0-9]*' | cut -d= -f2)
PREC=$((MN - SREC))
( cd "$M" && "$BIN" "$M/c.bin" $MN ) > "$M/write.log" 2>&1 \
  || { echo "FAIL: writer exited nonzero on mixed" >&2; exit 1; }
MS=$(ls "$M/.axverity-store/structure" | wc -l)
MP=$(ls "$M/.axverity-store/payload" | wc -l)
SBYTES=$(du -sb "$M/.axverity-store/structure" | cut -f1)
PBYTES=$(du -sb "$M/.axverity-store/payload" | cut -f1)
echo "    structure: $MS blocks / $SBYTES B ($SREC records)     payload: $MP blocks / $PBYTES B ($PREC records)"
( cd "$M" && timeout 300 "$RT" rebuild ) > "$M/rb.txt" 2>&1
GOT=$(grep -m1 -o 'rebuild_records=[0-9]*' "$M/rb.txt" | cut -d= -f2)
BADR=$(grep -m1 -o 'rebuild_malformed=[0-9]*' "$M/rb.txt" | cut -d= -f2)
NAM=$(grep -m1 -o 'rebuild_names=[0-9]*' "$M/rb.txt" | cut -d= -f2)
[ "${GOT:-0}" = "$MN" ] \
  && ok "every record in both streams was read: $GOT of $MN" \
  || bad "rebuilt $GOT records, expected all $MN across both streams"
[ "${BADR:-0}" = "$PREC" ] \
  && ok "the $PREC payload blobs are counted malformed, not indexed and not fatal" \
  || bad "$BADR malformed, expected exactly the $PREC payload blobs"
# Teeth: a blob is arbitrary bytes and bytes_to_text panics on invalid UTF-8, so
# "no panic" is a real assertion here and not a formality (see rt_dindex_rec.m1).
grep -q PANIC "$M/rb.txt" \
  && bad "the rebuild panicked decoding the payload stream" \
  || ok "no panic across $PREC random-byte records — the UTF-8 guard held"
[ "${NAM:-0}" -gt 0 ] \
  && ok "the structure records still index: $NAM names" \
  || bad "no names indexed — the structure stream was lost while adding the payload one"
echo "    structure is $(python3 -c "print(f'{100*$SBYTES/($SBYTES+$PBYTES):.1f}')")% of durable bytes; reading the other $(python3 -c "print(f'{100*$PBYTES/($SBYTES+$PBYTES):.1f}')")% costs ~2% of rebuild time, because name-index insertion dominates and not the scan (AXVERITY_SILENT_LOSS_FIX_V1 P6)"

# ── T4  strict parse rejects a leftover temp, on the READ side ──────────────
# A .tmp file is a PARTIALLY WRITTEN block. The writer must not let one vote in
# max+1; the reader must not decode one, or it indexes a truncated tail as
# records that were never durable. Three arms, so the pass is not vacuous.
echo
echo "════════ T4  the reader rejects a leftover temp file"
BASE=$(grep -m1 -o 'rebuild_records=[0-9]*' "$D/cold2.txt" | cut -d= -f2)
REAL=$(ls "$D/.axverity-store/structure/block-"*.bin | head -1)
cp "$REAL" "$D/.axverity-store/structure/block-0.bin.tmp.31337.4"
( cd "$D" && "$RT" rebuild ) > "$D/rb-temp.txt" 2>&1
GOT=$(grep -m1 -o 'rebuild_records=[0-9]*' "$D/rb-temp.txt" | cut -d= -f2)
SKIP=$(grep -m1 -o 'rebuild_skipped_entries=[0-9]*' "$D/rb-temp.txt" | cut -d= -f2)
[ "$GOT" = "$BASE" ] && ok "temp file IGNORED: still $GOT records, not $BASE + a block's worth" \
                     || bad "temp file was DECODED: $GOT records vs $BASE"
[ "${SKIP:-0}" -ge 1 ] && ok "and it was counted as a skipped entry ($SKIP)" \
                       || bad "the temp file was not reported as skipped"
rm -f "$D/.axverity-store/structure/block-0.bin.tmp.31337.4"
# The teeth: the SAME bytes named as a real block MUST be decoded, or arm one
# proves only that the reader ignores everything.
cp "$REAL" "$D/.axverity-store/structure/block-99999.bin"
( cd "$D" && "$RT" rebuild ) > "$D/rb-real.txt" 2>&1
GOT2=$(grep -m1 -o 'rebuild_records=[0-9]*' "$D/rb-real.txt" | cut -d= -f2)
[ "${GOT2:-0}" -gt "${BASE:-0}" ] && ok "control has teeth: the same bytes as block-99999.bin ARE decoded ($GOT2 > $BASE)" \
                                  || bad "a real block was ignored too — the temp arm proves nothing"
rm -f "$D/.axverity-store/structure/block-99999.bin"

# ── T5  point reads, and the durable name-index ────────────────────────────
echo
echo "════════ T5  point reads through the durable name-index"
( cd "$D" && "$RT" rid s0 ) > "$D/rid.txt" 2>&1
RID=$(grep -m1 -o 'rid=[0-9-]*' "$D/rid.txt" | cut -d= -f2)
REC=$(grep -m1 '^record=' "$D/rid.txt" | cut -d= -f2-)
LEN=$(grep -m1 -o 'len=[0-9-]*' "$D/rid.txt" | cut -d= -f2)
echo "    s0 -> RID $RID, len $LEN, record $(echo "$REC" | tr '\037' '/')"
[ "${RID:-0}" -ge 0 ] && ok "name s0 resolves to a durable RID" || bad "s0 did not resolve"
echo "$REC" | grep -q '^s0' && ok "the RID reads back a record that starts with s0" \
                            || bad "the record does not mention s0"
# A RID is one integer and decodes arithmetically — verify against the store.
python3 - "$D/.axverity-store" "$RID" <<'PY'
import pathlib, sys, struct
root, rid = pathlib.Path(sys.argv[1]), int(sys.argv[2])
# The stride derives from the capacity this store's blocks were written at —
# read the stamp the writer left, exactly as rt_rid_stride does, rather than
# repeating a literal that is only right at the default capacity.
# AXVERITY_EXTENT_WRITE_PATH step 5b — rid = (seq*2 + stream)*stride + offset,
# stride = block capacity in BYTES, offset = the record's varint start. The
# stream is IN the locator, so this resolves the directory instead of probing
# both, and the offset is a direct seek instead of an ordinal to count to.
stamp = root / "block_capacity"
stride = int(stamp.read_text().strip()) if stamp.exists() else 16384
roff, t = rid % stride, rid // stride
stream, blk = t % 2, t // 2
for d in (("structure", "payload")[stream],):
    f = root / d / f"block-{blk}.bin"
    if f.exists():
        # A direct seek: no scan, no counting. Three-byte prefixes are legal
        # (a record above 16383 B at a large block capacity).
        raw = f.read_bytes(); body = raw[:-8]
        if roff >= len(body):
            sys.exit(f"  FAIL  RID {rid} offset {roff} past the payload of block {blk}")
        b0 = body[roff]
        if b0 < 128:
            n, vl = b0, 1
        elif body[roff+1] < 128:
            n, vl = (b0 - 128) + body[roff+1] * 128, 2
        else:
            n, vl = (b0 - 128) + (body[roff+1] - 128) * 128 + body[roff+2] * 16384, 3
        rec = body[roff+vl:roff+vl+n]
        stream_name = ("structure", "payload")[stream]
        print(f"  PASS  RID {rid} = {stream_name} block {blk} offset {roff}, "
              f"independently decoded as {rec.decode().replace(chr(31),'/')}")
        sys.exit(0)
sys.exit(f"  FAIL  RID {rid} did not resolve in {('structure','payload')[stream]} block {blk}")
PY
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
# An unknown name must not resolve, or the index is answering from nothing.
( cd "$D" && "$RT" rid definitely_not_a_name ) > "$D/rid2.txt" 2>&1
RID2=$(grep -m1 -o 'rid=-\?[0-9]*' "$D/rid2.txt" | cut -d= -f2)
[ "${RID2:-0}" = "-1" ] && ok "an unknown name resolves to -1, not to a RID" \
                        || bad "an unknown name resolved to $RID2"

# ── NC  the cold suite, deliberately broken ─────────────────────────────────
echo
echo "════════ NC  the cold suite, deliberately broken"
NB="$T/nc"; rm -rf "$NB"; mkdir -p "$NB"; cp -r "$D/.axverity-store" "$NB/"
# Remove one structure block: the rebuild must notice fewer records.
VIC=$(ls "$NB/.axverity-store/structure/block-"*.bin | head -1)
rm -f "$VIC"
( cd "$NB" && "$RT" cold $N 2 ) > "$NB/cold.txt" 2>&1
if grep -q 'FAIL' "$NB/cold.txt"; then
  ok "dropping one structure block fails the cold suite: $(grep -m1 '  FAIL' "$NB/cold.txt" | cut -c1-64)"
else
  bad "the cold suite PASSED a store with a block removed — no teeth"
fi
# Corrupt a block's bytes: malformed records must be counted, not indexed.
rm -rf "$NB"; mkdir -p "$NB"; cp -r "$D/.axverity-store" "$NB/"
VIC=$(ls "$NB/.axverity-store/structure/block-"*.bin | head -1)
python3 -c "
import sys
p=sys.argv[1]; b=bytearray(open(p,'rb').read())
b[0]=0xFF; b[1]=0xFF   # a length prefix that runs past the payload limit
open(p,'wb').write(bytes(b))
" "$VIC"
( cd "$NB" && "$RT" rebuild ) > "$NB/rb.txt" 2>&1
MAL=$(grep -m1 -o 'rebuild_malformed=[0-9]*' "$NB/rb.txt" | cut -d= -f2)
[ "${MAL:-0}" -ge 1 ] && ok "a corrupt length prefix is counted as malformed ($MAL), not indexed" \
                      || bad "a corrupt block produced no malformed count — damage was indexed silently"

# ── T7  a SPANNING record is queryable, not merely durable ──────────────────
# AXVERITY_SPAN_RESTORE stage 3. A record too large for a block is written
# unframed across several, and the read tier has to classify each block by its
# own footer — a fragment block holds no framed records, and scanning one as
# though it did would decode raw body bytes as a length prefix. The claim that
# matters is not "it did not crash": it is that every NAME of the spanning
# record is in the index and nothing was counted malformed.
echo "════════ T7  spanning record indexed from its chain"
SP="$T/span"; mkdir -p "$SP/.axverity-store/config"
echo 16384    > "$SP/.axverity-store/config/block_capacity"
echo 3        > "$SP/.axverity-store/config/pool_depth"
echo 10000000 > "$SP/.axverity-store/config/max_record"
python3 -c "
import struct, sys
US = b'\x1f'
recs = [b'a'+US+b'knows'+US+b'b', b'c'+US+b'likes'+US+b'd',
        b'bigdoc'+US+b'hasbody'+US+(b'Z'*40000),
        b'e'+US+b'sees'+US+b'f']
with open(sys.argv[1],'wb') as f:
    for r in recs: f.write(struct.pack('<q', len(r))); f.write(r)
" "$SP/c.bin"
( cd "$SP" && "$BIN" "$SP/c.bin" 4 ) > "$SP/write.log" 2>&1 \
  || { bad "T7 writer exited nonzero"; cat "$SP/write.log" >&2; }
SPB=$(ls "$SP/.axverity-store/payload" | wc -l)
[ "$SPB" -ge 3 ] || bad "T7 expected the record to span >=3 payload blocks, got $SPB"
( cd "$SP" && "$RT" rid 4 ) > "$SP/rid.txt" 2>&1 || true
SPREC=$(grep -m1 -o 'rebuild_records=[0-9]*' "$SP/rid.txt" | cut -d= -f2)
SPBAD=$(grep -m1 -o 'rebuild_malformed=[0-9]*' "$SP/rid.txt" | cut -d= -f2)
SPNAM=$(grep -m1 -o 'rebuild_names=[0-9]*' "$SP/rid.txt" | cut -d= -f2)
if [ "$SPREC" = 4 ] && [ "$SPBAD" = 0 ] && [ "$SPNAM" = 12 ]; then
  ok "spanning record reassembled and indexed: $SPB payload blocks, records=$SPREC malformed=$SPBAD names=$SPNAM"
else
  bad "T7 spanning record not indexed: records=$SPREC (want 4) malformed=$SPBAD (want 0) names=$SPNAM (want 12)"
fi

# ── T8  a spanning record READS BACK through its locator ────────────────────
# T7 proves the NAMES reach the index. That is not the whole obligation: the
# contract says a spanning record is "indexed like any other, so it is
# queryable by every name it carries", and a name resolves to a RID whose
# whole purpose is to read the record back. A first fragment carries NO length
# prefix — its payload is raw body bytes — so a locator pointed at offset 0 of
# one is read by a decoder that has nothing to decode. The failure is silent:
# the first body byte parses as a varint and a short, wrong record is returned.
( cd "$SP" && "$RT" rid bigdoc ) > "$SP/rid-span.txt" 2>&1 || true
RIDLEN=$(grep -m1 -o 'len=[0-9-]*' "$SP/rid-span.txt" | cut -d= -f2)
RIDREC=$(grep -m1 '^record=' "$SP/rid-span.txt" | cut -d= -f2- | cut -c1-14)
if [ "${RIDLEN:-0}" = 40015 ] && [ "$RIDREC" = "$(printf 'bigdoc\037hasbody')" ]; then
  ok "the spanning record reads back through its RID: len=$RIDLEN, and it begins with its own subject"
else
  bad "T8 the RID does not read the spanning record: len=$RIDLEN (want 40015) head=$(echo "$RIDREC" | tr '\037' '/')"
fi

# ── T9  the window where a span is ONE block, at the SHIPPING capacity ───────
# A record spans when it cannot be FRAMED, which is not the same as "bigger
# than a block": the three-byte prefix tops out at 2097151, so at the default
# 4 MiB capacity every record from 2097152 up to the payload capacity spans
# while still FITTING one block. That chain has no full fragment at all. If the
# reader only recognises a chain by its first FULL fragment, such a record is
# admitted, fsynced, and indexed by nothing — the writer exits 0 and no count
# anywhere disagrees. This is the one arm run at the production capacity on
# purpose; every other store here is pinned small.
echo
echo "════════ T9  a one-block span at the 4 MiB default capacity"
OB="$T/oneblock"; mkdir -p "$OB/.axverity-store/config"
echo 4194304  > "$OB/.axverity-store/config/block_capacity"
echo 3        > "$OB/.axverity-store/config/pool_depth"
echo 20000000 > "$OB/.axverity-store/config/max_record"
OBLEN=3145728
python3 -c "
import struct, sys
US = b'\x1f'
big = b'doc3mb'+US+b'body'+US+(b'Q'*(int(sys.argv[2])-12))
assert len(big) == int(sys.argv[2])
recs = [b'a'+US+b'knows'+US+b'b', big, b'e'+US+b'sees'+US+b'f']
with open(sys.argv[1],'wb') as f:
    for r in recs: f.write(struct.pack('<q', len(r))); f.write(r)
" "$OB/c.bin" "$OBLEN"
( cd "$OB" && "$BIN" "$OB/c.bin" 3 ) > "$OB/write.log" 2>&1 \
  || { bad "T9 writer exited nonzero"; cat "$OB/write.log" >&2; }
( cd "$OB" && "$RT" rid doc3mb ) > "$OB/rid.txt" 2>&1 || true
OBREC=$(grep -m1 -o 'rebuild_records=[0-9]*' "$OB/rid.txt" | cut -d= -f2)
OBBAD=$(grep -m1 -o 'rebuild_malformed=[0-9]*' "$OB/rid.txt" | cut -d= -f2)
OBNAM=$(grep -m1 -o 'rebuild_names=[0-9]*' "$OB/rid.txt" | cut -d= -f2)
OBRID=$(grep -m1 -o 'rid=[0-9-]*' "$OB/rid.txt" | cut -d= -f2)
OBLN=$(grep -m1 -o 'len=[0-9-]*' "$OB/rid.txt" | cut -d= -f2)
if [ "$OBREC" = 3 ] && [ "$OBBAD" = 0 ] && [ "$OBNAM" = 9 ]; then
  ok "a $OBLEN B record that spans WITHOUT filling a block is indexed: records=$OBREC malformed=$OBBAD names=$OBNAM"
else
  bad "T9 one-block span not indexed: records=$OBREC (want 3) malformed=$OBBAD (want 0) names=$OBNAM (want 9)"
fi
if [ "${OBRID:-0}" -ge 0 ] && [ "${OBLN:-0}" = "$OBLEN" ]; then
  ok "and it reads back through its RID at full length ($OBLN B)"
else
  bad "T9 the RID does not read it back: rid=$OBRID len=$OBLN (want $OBLEN)"
fi

# ── ONE_TOUCH_THEN_WIRE ─────────────────────────────────────────────────────
echo
echo "════════ ONE_TOUCH_THEN_WIRE"
if "$HERE/experiments/format/check-hashes.sh" > "$T/hash.txt" 2>&1; then
  ok "$(cat "$T/hash.txt")"
else
  bad "THE WRITE PATH WAS TOUCHED AGAIN — this is a constraint violation"
  cat "$T/hash.txt" | sed 's/^/        /'
fi

echo
echo "READTIER DURABLE: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
