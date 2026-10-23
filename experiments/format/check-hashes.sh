#!/usr/bin/env bash
# ONE_TOUCH_THEN_WIRE gate.
#
# Re-hashes the write-path files and diffs them against a recorded baseline.
#
#   check-hashes.sh          -> against the P10 baseline (the default now)
#   check-hashes.sh --p2     -> against the format-land baseline
#   check-hashes.sh --p0     -> against the original P0 baseline
#
# AXVERITY_DURABLE_FORMAT_V1 used this to prove the write path was untouched
# through its P0-P2. AXVERITY_FORMAT_LAND_AND_WIRE_V1 spent the single touch in
# its own P2 — 9 of the 15 baseline files changed and 7 were added — so the
# baseline moved with it. From P2 to P4 a nonzero exit against the P2 baseline
# is a constraint violation: it means the read tier could not be wired without
# touching the write path a second time, which is the thing this gate exists to
# catch.
#
# AXVERITY_EXTENT_WRITE_PATH spent a SECOND authorized touch (step by step) and moved the baseline to P5. AXVERITY_SIZE_THRESHOLD_
# RECONCILE spent a THIRD (2026-08-25) retiring the 16 KiB default block
# for 4 MiB, moving it to P6. AXVERITY_SPAN_RESTORE spent a FOURTH the same day
# ("restore it") bringing record spanning back, moving it to P7 — seven files,
# each justified in that file's header. It spent a FIFTH, its own follow-up, to
# close the hole P7 left: a record that spans WITHOUT filling a block produced a
# chain with no first fragment, and was admitted, fsynced and indexed by nothing
# (P8, one code change plus three comment-only files). `--p0`, `--p2`, `--p5`,
# `--p6` and `--p7` still print what each earlier touch did.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
if [ "${1:-}" = "--p0" ]; then
  BASE="$HERE/write-path-hashes.txt";    LABEL="P0"
elif [ "${1:-}" = "--p2" ]; then
  BASE="$HERE/write-path-hashes-p2.txt"; LABEL="P2"
elif [ "${1:-}" = "--p5" ]; then
  BASE="$HERE/write-path-hashes-p5.txt"; LABEL="P5"
elif [ "${1:-}" = "--p6" ]; then
  BASE="$HERE/write-path-hashes-p6.txt"; LABEL="P6"
elif [ "${1:-}" = "--p7" ]; then
  BASE="$HERE/write-path-hashes-p7.txt"; LABEL="P7"
elif [ "${1:-}" = "--p8" ]; then
  BASE="$HERE/write-path-hashes-p8.txt"; LABEL="P8"
elif [ "${1:-}" = "--p9" ]; then
  BASE="$HERE/write-path-hashes-p9.txt"; LABEL="P9"
else
  BASE="$HERE/write-path-hashes-p10.txt"; LABEL="P10"
fi

cd "$ROOT"
CUR=$(sha256sum lib/wp_*.m1 src/*.m1)
REF=$(grep '^[0-9a-f]' "$BASE")

if [ "$CUR" = "$REF" ]; then
  echo "WRITE_PATH_UNTOUCHED: all $(echo "$REF" | wc -l) files byte-identical to the $LABEL baseline"
  exit 0
fi

echo "WRITE_PATH_CHANGED — diff vs $LABEL baseline (- = $LABEL, + = now):" >&2
diff <(echo "$REF") <(echo "$CUR") >&2 || true
exit 1
