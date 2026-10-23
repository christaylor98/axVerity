#!/usr/bin/env bash
# REQ-3: shim stores any triple; owns/kind/supersedes are ordinary; no ownership check. (a)-(d) per requirement.
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
def admit(recs):
    b = b"\x03" + bytes([len(recs)])
    for r in recs: b += len(r).to_bytes(8, "little") + r
    send(b); return frame()
def rebuild():
    send(b"\x02"); return frame()
def q0():
    send(b"\x01" + b"0\x1f\x1f\x1f"); h = frame()
    n = int(h[1:]) if h[0] == 0 else -1
    return [frame() for _ in range(max(n, 0))], h
def qm(mask, args):
    send(b"\x01" + mask + args); h = frame()
    return h, [frame() for _ in range(int(h[1:]) if h[0] == 0 else 0)]
try:
    r = admit([b"r/code\x1fowns\x1fn1", b"n1\x1fkind\x1fNode", b"n2\x1fkind\x1fNode"])
    chk(r[0] == 0 and b"admitted=3" in r, f"(a) admit {r!r}")
    r = rebuild(); chk(r[0] == 0, f"rebuild {r!r}")
    h, rows = qm(b"6", b"\x1f\x1fowns\x1fn1")
    chk(h[0] == 0 and rows == [b"\x00r/code\x1fowns\x1fn1"], f"(b) {h!r} {rows!r}")
    h, rows = qm(b"6", b"\x1f\x1fowns\x1fn2")
    chk(h[0] == 0 and rows == [], f"(c) {h!r} {rows!r}")
    r = admit([b"r/a\x1fowns\x1fn1", b"r/b\x1fowns\x1fn1"]); chk(r[0] == 0, f"(d) admit {r!r}")
    rebuild(); h, rows = qm(b"6", b"\x1f\x1fowns\x1fn1")
    chk(sorted(rows) == sorted([b"\x00r/code\x1fowns\x1fn1", b"\x00r/a\x1fowns\x1fn1", b"\x00r/b\x1fowns\x1fn1"]), f"(d) rows {rows!r}")
finally:
    p.kill()
sys.exit(1 if fails else 0)
PY
