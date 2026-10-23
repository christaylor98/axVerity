#!/usr/bin/env bash
# scripts/axv-store acceptance test.
#
# The util's whole job is the three things a bare `mkdir` gets silently wrong,
# so those are what is asserted — plus one arm proving the bare mkdir really
# does work, because a util that claims to be required when it is not is worse
# than no util.
#
# Every arm goes through the WIRE (wire-harness/axwire.py, the reference
# client), never by reading the store directory, because that is how a consumer
# will meet it.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
AXV="$HERE/scripts/axv-store"
[ -x "$HERE/build/wp-slice" ]        || { echo "FAIL: build/wp-slice not built — run scripts/build.sh" >&2; exit 1; }
[ -x "$HERE/shim/bin/axshim" ]       || { echo "FAIL: shim/bin/axshim not built — run shim/build-shim.sh" >&2; exit 1; }

T=$(mktemp -d)
# A leaked shim holds its port for the life of the machine and the next run of
# this test collides with it, so every store this test serves is registered for
# teardown as it is created. Globbing "$T"/* missed the nested proj/a and
# proj/b and leaked two.
SERVED=()
serve_and_track() {   # serve_and_track <dir> <port>
  SERVED+=("$1")
  "$AXV" serve "$1" --port "$2" --detach >/dev/null
}
cleanup() {
  local d
  for d in "${SERVED[@]:-}"; do
    [ -n "$d" ] && "$AXV" stop "$d" >/dev/null 2>&1 || true
  done
  rm -rf "$T"
}
trap cleanup EXIT

# A port nobody else in this repo's suites uses (shimctl.py counts from 29400).
# NOT `p=$(port)` — a command substitution runs in a SUBSHELL, so the counter
# never advances in the parent and every arm gets the same port. That mistake
# was made here first: two arms then pointed at ONE shim, the second connection
# shared its store and requests were answered in arrival order (contract §5.4,
# concurrent serving; see tests/run-concurrent-test.sh) and the run
# hung with no error. It is also what made `serve` grow its port-in-use check.
PORT=${PORT:-29811}   # below ip_local_port_range (32768+): a busy ephemeral client port made 47812 collide
next_port() { PORT=$((PORT + 1)); }

rt() {   # rt <dir> <port> — admit two triples, rebuild, query them back
  python3 - "$2" <<'PY'
import sys, os
sys.path.insert(0, os.environ["HERE"] + "/wire-harness")
import axwire
c = axwire.Client(int(sys.argv[1]))
h = c.admit_handle([("alice", "knows", "bob"), ("alice", "age", "30")])
c.rebuild()
rows = c.query(1, "alice", "", "")
c.close()
assert sorted(rows) == sorted([("alice","knows","bob"), ("alice","age","30")]), rows
print("handle=%s" % (h,))
PY
}
export HERE

# ── FRESH_STORE_ROUNDTRIP ──────────────────────────────────────────────────
# init, serve, admit, rebuild, query — the path a new consumer takes on day one.
D="$T/fresh"; next_port; P=$PORT
"$AXV" init "$D" >/dev/null
serve_and_track "$D" "$P"
H=$(rt "$D" "$P")
"$AXV" stop "$D" >/dev/null
echo "PASS FRESH_STORE_ROUNDTRIP: init -> serve -> admit -> rebuild -> query, $H"

# ── KNOBS_REACH_THE_WRITER ─────────────────────────────────────────────────
# The knobs are not decoration: a store initialised at a non-default capacity
# must be STAMPED at it by the first write. This is the one that is
# irreversible if it is wrong, so it is checked against the store's own stamp.
D="$T/knobs"; next_port; P=$PORT
"$AXV" init "$D" --block-capacity 262144 --max-record 4096 --pool-depth 4 >/dev/null
serve_and_track "$D" "$P"
rt "$D" "$P" >/dev/null
"$AXV" stop "$D" >/dev/null
GOT=$(tr -d '[:space:]' < "$D/.axverity-store/block_capacity")
if [ "$GOT" = "262144" ]; then
  echo "PASS KNOBS_REACH_THE_WRITER: --block-capacity 262144 stamped as 262144"
else
  echo "FAIL KNOBS_REACH_THE_WRITER: stamp is $GOT, wanted 262144" >&2; exit 1
fi

# ── MAX_RECORD_IS_ENFORCED ─────────────────────────────────────────────────
# --max-record 4096 above must be the limit the WIRE refuses at, and the
# refusal must name it (contract v2.0 §4.1 / A.8). Otherwise the knob was
# written to a file nothing reads.
D2="$T/knobs2"; next_port; P=$PORT
cp -r "$D" "$D2"
serve_and_track "$D2" "$P"
OUT=$(python3 - "$P" <<'PY'
import sys, os
sys.path.insert(0, os.environ["HERE"] + "/wire-harness")
import axwire
c = axwire.Client(int(sys.argv[1]))
r = c.admit_raw([("s", "v", "t" * 9000)])
print(("ADMITTED " if r.ok else "REFUSED ") + ("status=%d %s" % (r.status, r.text)))
c.close()
PY
)
"$AXV" stop "$D2" >/dev/null
case "$OUT" in
  *max_record=4096*) echo "PASS MAX_RECORD_IS_ENFORCED: $OUT" ;;
  *) echo "FAIL MAX_RECORD_IS_ENFORCED: wanted a refusal naming max_record=4096, got: $OUT" >&2; exit 1 ;;
esac

# ── CAPACITY_CHANGE_REFUSED ────────────────────────────────────────────────
# The store above holds blocks stamped at 262144. Re-initialising it at another
# capacity must refuse HERE, with the reason — not silently rewrite config/ and
# leave the writer to FATAL, and not re-stamp.
if "$AXV" init "$D" --block-capacity 1048576 >"$T/cap.out" 2>&1; then
  echo "FAIL CAPACITY_CHANGE_REFUSED: init exited 0 re-capacitying a store with blocks" >&2
  cat "$T/cap.out" >&2; exit 1
fi
if grep -q 'fixed for the life of a store' "$T/cap.out" &&
   [ "$(tr -d '[:space:]' < "$D/.axverity-store/config/block_capacity")" = "262144" ]; then
  echo "PASS CAPACITY_CHANGE_REFUSED: refused with the reason, and config/block_capacity is untouched"
else
  echo "FAIL CAPACITY_CHANGE_REFUSED: refused, but not for the right reason or config was written anyway" >&2
  cat "$T/cap.out" >&2; exit 1
fi

# ── RECAP_EMPTY_STORE_ALLOWED ──────────────────────────────────────────────
# The mirror of the arm above: an EMPTY store has handed out no RIDs, so
# changing its capacity protects nothing and must be permitted.
D="$T/empty"
"$AXV" init "$D" --block-capacity 262144 >/dev/null
"$AXV" init "$D" --block-capacity 1048576 >/dev/null
if [ "$(tr -d '[:space:]' < "$D/.axverity-store/config/block_capacity")" = "1048576" ]; then
  echo "PASS RECAP_EMPTY_STORE_ALLOWED: an empty store re-capacities freely"
else
  echo "FAIL RECAP_EMPTY_STORE_ALLOWED: config was not updated on an empty store" >&2; exit 1
fi

# ── TWO_SERVERS_REFUSED ────────────────────────────────────────────────────
# There is no lease (contract v2.0 §5.6, deleted) — single-writer is the
# consumer's obligation. This is not a lock and does not claim to be one; it
# catches the accident that would otherwise produce two unguarded writers.
D="$T/dup"; next_port; P=$PORT; next_port; P2=$PORT
"$AXV" init "$D" >/dev/null
serve_and_track "$D" "$P"
if "$AXV" serve "$D" --port "$P2" --detach >"$T/dup.out" 2>&1; then
  "$AXV" stop "$D" >/dev/null
  echo "FAIL TWO_SERVERS_REFUSED: a second shim started over the same store" >&2
  cat "$T/dup.out" >&2; exit 1
fi
grep -q 'One server per store' "$T/dup.out" || {
  echo "FAIL TWO_SERVERS_REFUSED: refused for the wrong reason" >&2; cat "$T/dup.out" >&2; exit 1; }
# ...and stopping restores service rather than wedging the store.
"$AXV" stop "$D" >/dev/null
serve_and_track "$D" "$P2"
rt "$D" "$P2" >/dev/null
"$AXV" stop "$D" >/dev/null
echo "PASS TWO_SERVERS_REFUSED: second start refused, and stop-then-start serves again"

# ── SEPARATE_STORES_ARE_SEPARATE ───────────────────────────────────────────
# "Create new storeS in a project" is the actual request: two stores under one
# project directory must not see each other's rows.
A="$T/proj/a"; B="$T/proj/b"; next_port; PA=$PORT; next_port; PB=$PORT
"$AXV" init "$A" >/dev/null
"$AXV" init "$B" >/dev/null
serve_and_track "$A" "$PA"
serve_and_track "$B" "$PB"
python3 - "$PA" "$PB" <<'PY'
import sys, os
sys.path.insert(0, os.environ["HERE"] + "/wire-harness")
import axwire
a = axwire.Client(int(sys.argv[1])); b = axwire.Client(int(sys.argv[2]))
a.admit([("only-in-a", "p", "o")]); a.rebuild()
b.admit([("only-in-b", "p", "o")]); b.rebuild()
ra = a.query(0); rb = b.query(0)
a.close(); b.close()
assert ra == [("only-in-a", "p", "o")], ra
assert rb == [("only-in-b", "p", "o")], rb
PY
"$AXV" stop "$A" >/dev/null; "$AXV" stop "$B" >/dev/null
echo "PASS SEPARATE_STORES_ARE_SEPARATE: two stores in one project, no bleed"

# ── BARE_MKDIR_STILL_WORKS ─────────────────────────────────────────────────
# The util adds config, safety and a launch line. It does not add a required
# step, and this asserts that so nobody later "fixes" the tiers to depend on it.
D="$T/bare"; next_port; P=$PORT
mkdir -p "$D"
"$HERE/shim/bin/axshim" "$D" "$P" "$HERE/build/wp-slice" >"$T/bare.log" 2>&1 &
BARE=$!
for _ in $(seq 1 100); do
  (exec 3<>/dev/tcp/127.0.0.1/"$P") 2>/dev/null && { exec 3<&- 3>&-; break; }
  sleep 0.1
done
rt "$D" "$P" >/dev/null
kill "$BARE" 2>/dev/null || true; wait "$BARE" 2>/dev/null || true
echo "PASS BARE_MKDIR_STILL_WORKS: a plain mkdir + axshim round-trips; the util is convenience, not a dependency"

# ── STATUS_REPORTS_WHAT_IS_THERE ───────────────────────────────────────────
S=$("$AXV" status "$T/knobs")
echo "$S" | grep -q 'stamped block_capacity: 262144' || { echo "FAIL STATUS: no stamp" >&2; echo "$S" >&2; exit 1; }
echo "$S" | grep -q 'config/max_record: 4096'        || { echo "FAIL STATUS: no max_record" >&2; echo "$S" >&2; exit 1; }
echo "$S" | grep -qE 'blocks: structure=[1-9]'       || { echo "FAIL STATUS: no blocks" >&2; echo "$S" >&2; exit 1; }
echo "$S" | grep -q 'shim: not running'              || { echo "FAIL STATUS: shim state wrong" >&2; echo "$S" >&2; exit 1; }
echo "PASS STATUS_REPORTS_WHAT_IS_THERE: stamp, config, per-stream block counts, server state"

echo "ALL PASS"
