#!/usr/bin/env bash
# REQ-4: ADMIT all-or-nothing; count must match records; count 0 refused.
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
def admitc(c, recs):
    b = b"\x03" + bytes([c])
    for r in recs: b += len(r).to_bytes(8, "little") + r
    send(b); return frame()
def wm(): 
    r = rebuild(); return r
try:
    r = admitc(2, [b"a\x1fb\x1fc", b"d\x1fe\x1ff"])
    chk(r[0] == 0 and b"admitted=2" in r, f"(a) {r!r}")
    base = wm(); chk(base[0] == 0, f"rebuild {base!r}")
    r = admitc(3, [b"g\x1fh\x1fi", b"j\x1fk\x1fl"])
    chk(r[0] == 1, f"(b) mismatch {r!r}")
    after = wm(); chk(after == base, f"(b) watermark {base!r} -> {after!r}")
    rows, h = q0(); chk(h[0] == 0 and len(rows) == 2, f"(b) rows {h!r}")
    r = admitc(0, [])
    chk(r[0] == 1, f"(c) zero {r!r}")
    chk(wm() == base, "(c) rebuild normal")
    rows, h = q0(); chk(h[0] == 0 and len(rows) == 2, f"(c) query normal {h!r}")
finally:
    p.kill()
sys.exit(1 if fails else 0)
PY
