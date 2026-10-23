#!/usr/bin/env bash
# P4 of AXVERITY_SHIM_BRIDGE_PRIMS_V1 — characterisation, not remediation.
#
# The intent carried two unknowns about ADMIT once the spawn existed: what a
# wrong record count does (predicted: a hang), and what a writer killed
# mid-batch leaves behind. Both are measured here, and the answers are asserted
# so that a later change shows up as a diff.
#
# Nothing in this run is a fix. The wrong-count hazard in particular is left
# exactly as found: the count is the client's and the writer trusts it.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$HERE/.." && pwd)
BIN="$ROOT/build/wp-slice"
FMTH="$ROOT/experiments/format/harness/target/release/fmth"

for b in "$BIN" "$FMTH" "$HERE/build/axshim-bin"; do
  [ -x "$b" ] || { echo "FAIL: $b not built" >&2; exit 1; }
done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PYTHONPATH="$HERE/tests" python3 "$HERE/tests/unknowns.py" \
  "$ROOT" "$T" "$FMTH" "$BIN" "$HERE/bin/axshim"
