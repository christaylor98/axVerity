#!/usr/bin/env bash
# Shim conformance run — AXVERITY_SHIM_BUILD_V1, turn 5.
#
# The claim under test is contract §8's: the transport must produce identical
# results to the linked tiers over the same corpus, or it has semantics of its
# own. Three legs, so no leg is its own reference:
#
#   oracle      tests/oracle.py, decoding the durable blocks in Python
#   in-process  readtier/build/rt-driver, linking the tiers directly
#   wire        tests/axclient.py, over TCP to the shim
#
# oracle == in-process is asserted by rt-driver's own cold suite; oracle == wire
# is asserted here per binding pattern. Both legs green is wire == in-process
# with every hop checked, rather than the shim being compared to itself.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$HERE/.." && pwd)
BIN="$ROOT/build/wp-slice"
RT="$ROOT/readtier/build/rt-driver"
FMTH="$ROOT/experiments/format/harness/target/release/fmth"
SHIM="$HERE/build/axshim-bin"

for b in "$BIN" "$RT" "$SHIM"; do
  [ -x "$b" ] || { echo "FAIL: $b not built" >&2; exit 1; }
done
[ -x "$FMTH" ] || ( cd "$ROOT/experiments/format/harness" && cargo build --release -q )

T=$(mktemp -d); trap 'kill %1 2>/dev/null; rm -rf "$T"' EXIT
D="$T/store"; mkdir -p "$D"
N=6000
N2=6400

# CAP IS PINNED SMALL, ON PURPOSE. R17 below proves the tier RE-READS its
# name<->id map per operation instead of caching one, and to prove that it must
# first make the ids MOVE — which it does by writing a corpus the store already
# holds, so that fs_list_dir's LEXICOGRAPHIC fold order (block-10 before
# block-2) renumbers almost everything. That needs a store of MANY blocks.
#
# When the production default went from 16 KiB to 4 MiB this whole ~90 KB corpus
# became ONE block per lifetime, block-0 then block-1, lexicographic order equal
# to numeric order, and nothing renumbered. R17's own setup check caught it and
# said so ("the arm below cannot fail, so it proves nothing") — the assertion
# after it was still passing, vacuously. That is the test losing its subject,
# not the tier regressing.
#
# Same fix, same reason, as tests/run-readtier-durable-test.sh T1. The 4 MiB
# default is exercised end to end by `CAP=4194304 tests/run-slice-test.sh` and
# by T9 of the readtier durable suite; block SIZE is not a question this file
# asks, and no assertion here depends on the capacity's value.
CAP=${CAP:-16384}
mkdir -p "$D/.axverity-store/config"
echo "$CAP" > "$D/.axverity-store/config/block_capacity"

echo "════════ populate: $N structure records, one writer lifetime"
"$FMTH" corpus "$T/a.bin" $N structure 1 > /dev/null
( cd "$D" && "$BIN" "$T/a.bin" $N ) > "$T/w1.log" 2>&1 \
  || { echo "FAIL: writer exited nonzero" >&2; cat "$T/w1.log" >&2; exit 1; }
echo "    $(ls "$D/.axverity-store/structure" | wc -l) structure blocks"

echo
echo "════════ leg 1  in-process == corpus arithmetic (rt-driver cold)"
if ( cd "$D" && "$RT" cold $N ) > "$T/cold.txt" 2>&1; then
  echo "  PASS  $(grep -c '  PASS' "$T/cold.txt") in-process assertions green"
else
  echo "  FAIL  the in-process leg is red; the wire comparison would be meaningless"
  grep -E 'FAIL' "$T/cold.txt" | head -5 | sed 's/^/        /'
  exit 1
fi

echo
echo "════════ leg 2+3  oracle == wire, over the shim"
"$HERE/bin/axshim" "$D" 0 > "$T/shim.log" 2>&1 &
SHIM_PID=$!
for _ in $(seq 1 100); do
  PORT=$(grep -m1 -o 'port=[0-9]*' "$T/shim.log" 2>/dev/null | cut -d= -f2)
  [ -n "${PORT:-}" ] && break
  sleep 0.05
done
[ -n "${PORT:-}" ] || { echo "FAIL: shim never announced a port"; cat "$T/shim.log"; exit 1; }
echo "    shim pid $SHIM_PID on port $PORT, store $D"

PYTHONPATH="$HERE/tests" python3 "$HERE/tests/conformance.py" "$PORT" "$D" "$T" "$N" "$N2" "$FMTH" "$BIN"
RC=$?
kill $SHIM_PID 2>/dev/null
exit $RC
