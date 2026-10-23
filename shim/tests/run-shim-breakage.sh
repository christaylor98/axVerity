#!/usr/bin/env bash
# The two ways the shim used to go down, now the two ways it refuses.
#
# Round 1 recorded these as reproductions of a panic: REBUILD on a store nobody
# had written folded a directory that did not exist, and a QUERY body that was
# not UTF-8 reached bytes_to_text. Both aborted the entry, the bridge respawned
# it onto a DIFFERENT ephemeral port, and the client that caused it hung until
# its own timeout (REPORT-SHIM.md R18/R19/R20).
#
# Round 2 guards both. This script now asserts the REFUSAL, and it asserts the
# three things that make a refusal different from a crash: an out-of-contract
# status on the connection the client is already holding, no respawn (exactly
# one bind for the process's whole life, so the port never moves), and a
# connection that still works afterwards.
#
# The last arm is the teeth. Refusing every byte >= 0x80 would pass both UTF-8
# arms and quietly narrow the surface to ASCII names, so a valid multi-byte
# name must be ACCEPTED, and the specific illegal sequences — overlong,
# surrogate, truncated — must each be caught on their own.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$HERE/.." && pwd)
FMTH="$ROOT/experiments/format/harness/target/release/fmth"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

start() {  # start <store-dir>  -> sets PORT, PID
  "$HERE/bin/axshim" "$1" 0 > "$1/shim.log" 2>&1 &
  PID=$!
  for _ in $(seq 1 60); do
    PORT=$(grep -m1 -o 'port=[0-9]*' "$1/shim.log" 2>/dev/null | cut -d= -f2)
    [ -n "${PORT:-}" ] && return
    sleep 0.05
  done
}

health() {  # health <store-dir> <label>
  local d="$1"; local label="$2"
  grep -q "PANIC\|panicked" "$d/shim.log" \
    && bad "$label: the entry panicked" \
    || ok  "$label: no panic — the guard answered instead of the runtime"
  local binds
  binds=$(grep -c "listening port=" "$d/shim.log")
  [ "$binds" = 1 ] \
    && ok  "$label: one bind for the process's life — no respawn, the port never moved" \
    || bad "$label: $binds binds — the entry respawned onto a new port"
}

# ── R1  REBUILD against a store that has never been written ─────────────────
echo "════════ R1  REBUILD on a fresh store"
D1="$T/fresh"; mkdir -p "$D1"
start "$D1"
PYTHONPATH="$HERE/tests" python3 - "$PORT" > "$D1/client.txt" 2>&1 <<'PY'
import sys
from axclient import Conn, OUT_OF_CONTRACT
c = Conn(int(sys.argv[1]), timeout=5)
try:
    st, body = c.rebuild()
    print("REPLY", st, body)
    # v2.0: QUERY is gated on freshness and the REBUILD above was refused, so
    # this legitimately answers status 1 STALE. The arm asks whether the
    # CONNECTION survived a refusal — but "any reply" is not the assertion:
    # exactly two replies are in contract here and the grep names both.
    st2, cnt, rows = c.query(0)
    print("STILL_UP", st2, str(cnt).split()[0] if st2 else cnt)
except Exception as e:
    print("HUNG", type(e).__name__)
PY
kill $PID 2>/dev/null; wait $PID 2>/dev/null
grep -q "^REPLY 1 NOSTORE" "$D1/client.txt" \
  && ok "REBUILD on a fresh store is refused out-of-contract: $(grep -m1 '^REPLY' "$D1/client.txt" | cut -c9-70)..." \
  || bad "R1: expected a status-1 NOSTORE refusal, got: $(head -1 "$D1/client.txt")"
# RATCHET_TIGHTENS_ONLY. This was `STILL_UP 0` and briefly became `STILL_UP `,
# which passes on ANY status including a future regression. The v2.0-correct set
# is exactly two replies: status 0 (the gate is open), or status 1 whose body
# begins STALE (the REBUILD above was refused, so it never opened). Nothing else
# is in contract and nothing else passes.
if grep -qE "^STILL_UP (0 |1 STALE)" "$D1/client.txt"; then
  ok "and the SAME connection still serves the next op: $(grep -m1 '^STILL_UP' "$D1/client.txt")"
else
  bad "R1: expected 'STILL_UP 0 ...' or 'STILL_UP 1 STALE', got: $(grep -m1 '^STILL_UP' "$D1/client.txt" || echo '<no reply>')"
fi
health "$D1" "R1"

# ── R2  a QUERY body that is not UTF-8 ──────────────────────────────────────
echo
echo "════════ R2  QUERY carrying a non-UTF-8 name"
D2="$T/live"; mkdir -p "$D2"
"$FMTH" corpus "$T/a.bin" 200 structure 1 > /dev/null
( cd "$D2" && "$ROOT/build/wp-slice" "$T/a.bin" 200 ) > /dev/null 2>&1
start "$D2"
PYTHONPATH="$HERE/tests" python3 - "$PORT" > "$D2/client.txt" 2>&1 <<'PY'
import sys
from axclient import Conn, vi_enc

c = Conn(int(sys.argv[1]), timeout=5)
print("REBUILD", c.rebuild()[0])

def probe(label, raw):
    body = bytes([1]) + b"1\x1f" + raw + b"\x1f\x1f"
    c.s.sendall(vi_enc(len(body)) + body)
    p = c.recv_frame()
    print(label, p[0], p[1:].decode("utf-8", "replace")[:40])

try:
    probe("BARE_FF",   b"\xff\xfe")            # not a lead byte at all
    probe("OVERLONG",  b"\xc0\x80")            # 2-byte encoding of U+0000
    probe("SURROGATE", b"\xed\xa0\x80")        # U+D800, not a scalar value
    probe("TRUNCATED", b"\xc3")                # lead byte, continuation missing
    st, cnt, rows = c.query(1, "s0")
    print("STILL_UP", st, cnt)
    st, cnt, rows = c.query(1, "ünïcode")   # valid 2-byte sequences
    print("UNICODE_OK", st, cnt)
    # AXVERITY_SHIM_BRIDGE_PRIMS_V1: the 2-byte arm above is not enough on its
    # own. A guard that accepted C2..DF and rejected E0..F4 would pass it and
    # still narrow the surface, so every remaining width gets its own arm.
    st, cnt, rows = c.query(1, "€_euro")      # 3-byte, E2 82 AC
    print("UNICODE3_OK", st, cnt)
    st, cnt, rows = c.query(1, "\U00010348_gothic")  # 4-byte, F0 90 8D 88
    print("UNICODE4_OK", st, cnt)
    st, cnt, rows = c.query(1, "\u007f\u0080\u07ff\u0800\uffff\U0010ffff")  # every width boundary
    print("UNICODE_EDGE_OK", st, cnt)
except Exception as e:
    print("HUNG", type(e).__name__)
PY
kill $PID 2>/dev/null; wait $PID 2>/dev/null
for arm in BARE_FF OVERLONG SURROGATE TRUNCATED; do
  grep -q "^$arm 1 MALFORMED" "$D2/client.txt" \
    && ok "$arm refused out-of-contract before bytes_to_text" \
    || bad "R2/$arm: expected a status-1 MALFORMED refusal, got: $(grep -m1 "^$arm" "$D2/client.txt")"
done
grep -q "^STILL_UP 0 4" "$D2/client.txt" \
  && ok "and the SAME connection still answers a real query (4 rows for s0)" \
  || bad "R2: the connection did not survive four refusals"
grep -q "^UNICODE_OK 0" "$D2/client.txt" \
  && ok "a VALID multi-byte name is accepted, not refused — the guard validates UTF-8, it does not require ASCII" \
  || bad "R2: a valid UTF-8 name was refused; the guard has narrowed the surface to ASCII"
for arm in UNICODE3_OK UNICODE4_OK UNICODE_EDGE_OK; do
  grep -q "^$arm 0" "$D2/client.txt" \
    && ok "$arm — accepted; the guard is not width-limited either" \
    || bad "R2/$arm: a valid UTF-8 name was refused: $(grep -m1 "^$arm" "$D2/client.txt")"
done
health "$D2" "R2"

echo
echo "SHIM REFUSALS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
