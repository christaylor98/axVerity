#!/usr/bin/env bash
# REQ-13: wire framing. (a) '06 01 30 1f 1f 1f' on a rebuilt 2-triple store -> '02 00 32' + 2 row frames;
# (b) connect-and-wait receives no bytes; (c) wire-harness run-all has no ERROR arms.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AXSHIM="$ROOT/shim/bin/axshim"
[ -x "$AXSHIM" ] || { echo "FAIL: $AXSHIM not built" >&2; exit 1; }
# Prerequisites are gitignored build products; fail fast, not with ConnectionRefused.
for b in "$ROOT/build/wp-slice" "$ROOT/shim/build/axshim-bin"; do
  [ -x "$b" ] || { echo "FAIL: $b missing. Build first: make test-prereqs" >&2; exit 1; }
done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PYTHONPATH="$ROOT/shim/tests:$ROOT/wire-harness" python3 - "$T" "$AXSHIM" <<'PY'
import subprocess, sys, time, socket
from axclient import Conn
store, exe = sys.argv[1], sys.argv[2]
t = socket.socket(); t.bind(("127.0.0.1", 0)); port = t.getsockname()[1]; t.close()
p = subprocess.Popen([exe, store, str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
for _ in range(100):
    try: socket.create_connection(("127.0.0.1", port), 1).close(); break
    except OSError: time.sleep(0.1)
fails = 0
def rd(s, n):
    b = b""
    while len(b) < n:
        d = s.recv(n - len(b))
        if not d: raise EOFError
        b += d
    return b
try:
    # (b) no greeting
    s = socket.create_connection(("127.0.0.1", port)); s.settimeout(1.0)
    try: got = s.recv(16)
    except socket.timeout: got = b""
    s.close(); ok = got == b""
    print(("ok   " if ok else "FAIL ") + f"no greeting: {got!r}"); fails += not ok
    # (a)
    us = b"\x1f"
    recs = [b"a"+us+b"b"+us+b"c", b"d"+us+b"e"+us+b"f"]
    body = b"".join(len(r).to_bytes(8, "little") + r for r in recs)
    c = Conn(port, timeout=10)
    print("admit", c.raw(b"\x03\x02" + body))
    print("rebuild", c.raw(b"\x02")); c.close()
    s = socket.create_connection(("127.0.0.1", port)); s.settimeout(10)
    s.sendall(bytes([5, 1, 0x30, 0x1f, 0x1f, 0x1f]))
    head = rd(s, 3)
    ok = head == b"\x02\x00\x32"
    rows = []
    if ok:
        for _ in range(2):
            n = rd(s, 1)[0]; rows.append(rd(s, n))
    ok = ok and all(r.count(us) == 2 for r in rows) and len(rows) == 2
    print(("ok   " if ok else "FAIL ") + f"query head {head.hex()} rows {rows}"); fails += not ok
    s.close()
finally:
    p.kill()
sys.exit(1 if fails else 0)
PY
rc=$?
if [ $rc -eq 0 ]; then
  # The harness writes tmp/wire-harness/** and wire-harness/findings/**, both tracked:
  # run it in a scratch root (copied wire-harness, everything else symlinked) so the
  # test cannot modify or delete tracked files.
  S="$T~"; mkdir -p "$S/tmp"
  for e in "$ROOT"/* "$ROOT"/.[!.]*; do
    case "$(basename "$e")" in tmp|wire-harness|.git) continue;; esac
    [ -e "$e" ] && ln -s "$e" "$S/"
  done
  cp -r "$ROOT/wire-harness" "$S/wire-harness"
  out=$(cd "$S" && timeout 280 bash wire-harness/run-all.sh 2>&1); hr=$?
  echo "$out" | grep -E '^TOTAL|^  !!'
  { [ $hr -eq 0 ] && echo "$out" | grep -q '^TOTAL:' && ! echo "$out" | grep -E '^TOTAL:' | grep -qE 'ERROR=[1-9]|FAIL=[1-9]'; } || rc=1
fi
[ $rc -eq 0 ] && echo "WIRE TEST PASS" || echo "WIRE TEST FAIL"; exit $rc
