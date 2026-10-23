#!/usr/bin/env bash
# REQ-16: first contact on a never-admitted store. (a) REBUILD -> status 1 'NOSTORE', QUERY -> status 1 'STALE'
# (current behaviour; Option 2 text not supplied); (b) ADMIT 1 record + REBUILD -> watermark 1, QUERY mask 0 -> 1 row.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AXSHIM="$ROOT/shim/bin/axshim"
[ -x "$AXSHIM" ] || { echo "FAIL: $AXSHIM not built" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 - "$T" "$AXSHIM" <<'PY'
import subprocess, sys, time, socket
store, exe = sys.argv[1], sys.argv[2]
t = socket.socket(); t.bind(("127.0.0.1", 0)); port = t.getsockname()[1]; t.close()
p = subprocess.Popen([exe, store, str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
for _ in range(100):
    try: socket.create_connection(("127.0.0.1", port), 1).close(); break
    except OSError: time.sleep(0.1)
s = socket.create_connection(("127.0.0.1", port), 5); s.settimeout(10)
def rd(n):
    b = b""
    while len(b) < n:
        d = s.recv(n - len(b))
        if not d: raise EOFError
        b += d
    return b
def frame():
    n = 0; sh = 0
    while True:
        c = rd(1)[0]; n |= (c & 0x7f) << sh; sh += 7
        if not c & 0x80: break
    return rd(n)
def send(pl):
    assert len(pl) < 128; s.sendall(bytes([len(pl)]) + pl)
fails = 0
def chk(ok, msg):
    global fails
    print(("ok   " if ok else "FAIL ") + msg); fails += not ok
try:
    send(b"\x02"); r = frame()
    chk(r[0] == 1 and r[1:].startswith(b"NOSTORE"), f"(a) REBUILD fresh: {r!r}")
    send(b"\x01" + b"0"); r = frame()
    chk(r[0] == 1 and r[1:].startswith(b"STALE"), f"(a) QUERY fresh: {r!r}")
    rec = b"a\x1fb\x1fc"
    send(b"\x03\x01" + len(rec).to_bytes(8, "little") + rec); r = frame()
    chk(r[0] == 0, f"ADMIT: {r!r}")
    send(b"\x02"); r = frame()
    chk(r[0] == 0 and b"1" in r[1:], f"(b) REBUILD watermark: {r!r}")
    send(b"\x01" + b"0"); h = frame()
    n = int(h[1:]) if h[0] == 0 else -1
    rows = [frame() for _ in range(max(n, 0))]
    chk(n == 1 and len(rows) == 1, f"(b) QUERY mask 0: head {h!r} rows {rows!r}")
finally:
    p.kill()
sys.exit(1 if fails else 0)
PY
