#!/usr/bin/env bash
# REQ-15: every file the write path or shim creates for a store is under <store>/.axverity-store/.
# In a clean store dir: run tests/run-slice-test.sh, then one ADMIT through the shim; the files
# created outside .axverity-store/ (store dir, TMPDIR, and the source tree minus build outputs) must be none.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AXSHIM="$ROOT/shim/bin/axshim"
[ -x "$AXSHIM" ] || { echo "FAIL: $AXSHIM not built" >&2; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"; [ -n "${SP:-}" ] && kill $SP 2>/dev/null' EXIT
mkdir "$W/store" "$W/tmp"
touch "$W/marker"; sleep 1
TMPDIR="$W/tmp" bash "$ROOT/tests/run-slice-test.sh" > "$W/slice.log" 2>&1 || { echo "FAIL: slice test"; tail -5 "$W/slice.log"; exit 1; }
PYTHONPATH="$ROOT/shim/tests" python3 - "$W/store" "$AXSHIM" <<'PY' || exit 1
import subprocess, sys, time, socket
from axclient import Conn, US
store, exe = sys.argv[1], sys.argv[2]
t = socket.socket(); t.bind(("127.0.0.1", 0)); port = t.getsockname()[1]; t.close()
p = subprocess.Popen([exe, store, str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
try:
    for _ in range(100):
        try: socket.create_connection(("127.0.0.1", port), 1).close(); break
        except OSError: time.sleep(0.1)
    c = Conn(port) if True else None
    b = US.join(["a", "b", "c"]).encode()
    st, body = c.admit(1, len(b).to_bytes(8, "little") + b)
    print("admit:", st, body)
    sys.exit(0 if st == 0 else 1)
finally:
    p.kill()
PY
OUT=$( { find "$W/store" -type f -not -path "$W/store/.axverity-store/*"
         find "$W/tmp" -type f
         find "$ROOT" \( -path "$ROOT/.git" -o -path "$ROOT/build" -o -path "$ROOT/shim/build" -o -path "$ROOT/tmp" -o -path "$ROOT/.axt-tmp" -o -path "$ROOT/.axchat" -o -path '*/target' -o -path "$ROOT/shim/bin" \) -prune -o -type f -newer "$W/marker" -print; } 2>/dev/null )
N=$(find "$W/store/.axverity-store" -type f | wc -l)
echo "files under .axverity-store: $N"
if [ -n "$OUT" ] || [ "$N" -eq 0 ]; then echo "FAIL: outside .axverity-store:"; echo "$OUT"; exit 1; fi
echo "STORE FILES TEST PASS"
