#!/usr/bin/env bash
# REQ-12: closed wire op set. Sweep all 256 opcodes: only 1,2,3 may not answer
# status 1 'UNKNOWN opcode N'; opcode 4 with arg '41' -> status 1 'UNKNOWN opcode 4'.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AXSHIM="$ROOT/shim/bin/axshim"
[ -x "$AXSHIM" ] || { echo "FAIL: $AXSHIM not built" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PYTHONPATH="$ROOT/shim/tests" python3 - "$T" "$AXSHIM" <<'PY'
import pathlib, subprocess, sys, time, socket
from axclient import Conn
store = pathlib.Path(sys.argv[1])
t = socket.socket(); t.bind(("127.0.0.1", 0)); port = t.getsockname()[1]; t.close()
p = subprocess.Popen([sys.argv[2], str(store), str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
for _ in range(100):
    try: socket.create_connection(("127.0.0.1", port), 1).close(); break
    except OSError: time.sleep(0.1)
fails = 0
try:
    not_unknown = []
    for op in range(256):
        c = Conn(port, timeout=10)
        try:
            st, body = c.raw(bytes([op]) + (b"0\x1f\x1f\x1f" if op == 1 else b""))
        except Exception as e:
            st, body = None, f"ERR {e}"
        c.close()
        if not (st == 1 and body == f"UNKNOWN opcode {op}"):
            not_unknown.append(op)
    ok = not_unknown == [1, 2, 3]
    print(("ok   " if ok else "FAIL ") + f"opcodes not answering UNKNOWN: {not_unknown}")
    fails += not ok
    c = Conn(port, timeout=10)
    st, body = c.raw(bytes([4]) + b"41"); c.close()
    ok = st == 1 and body == "UNKNOWN opcode 4"
    print(("ok   " if ok else "FAIL ") + f"opcode 4 + '41' -> {st} {body!r}")
    fails += not ok
finally:
    p.kill()
sys.exit(1 if fails else 0)
PY
rc=$?; [ $rc -eq 0 ] && echo "OPCODE TEST PASS" || echo "OPCODE TEST FAIL"; exit $rc
