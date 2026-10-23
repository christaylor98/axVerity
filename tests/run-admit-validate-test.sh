#!/usr/bin/env bash
# REQ-2: ADMIT batch record validation: (a) valid ok, (b) 4-field record refused w/ position, nothing written, (c) 0xFF refused, (d) empty fields legal.
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
try:
    r = admit([b"alpha\x1fknows\x1fbeta"]); chk(r[0] == 0, f"(a) admit {r!r}")
    r = rebuild(); chk(r[0] == 0, f"rebuild {r!r}"); w0 = r
    send(b"\x01" + b"7\x1falpha\x1fknows\x1fbeta"); h = frame(); rows = [frame() for _ in range(int(h[1:]))]
    chk(h[0] == 0 and rows == [b"\x00alpha\x1fknows\x1fbeta"], f"(a) mask7 {h!r} {rows!r}")
    r = admit([b"x\x1fy\x1fz", b"a\x1fb\x1fc\x1fd", b"p\x1fq\x1fr"])
    chk(r[0] == 1 and (b"2" in r[1:] or b"1" in r[1:]), f"(b) refused {r!r}")
    r = rebuild(); chk(r == w0, f"(b) watermark same {r!r} vs {w0!r}")
    rows, h = q0(); chk(len(rows) == 1, f"(b) mask0 count {len(rows)}")
    r = admit([b"a\x1fb\x1fc", b"\xff\x1fb\x1fc"]); chk(r[0] == 1 and b"2" in r[1:], f"(c) refused {r!r}")
    r = rebuild(); chk(r == w0, f"(c) watermark same {r!r}")
    rows, h = q0(); chk(len(rows) == 1, f"(c) mask0 count {len(rows)}")
    r = admit([b"\x1f\x1f"]); chk(r[0] == 0, f"(d) admit {r!r}")
    rebuild(); rows, h = q0()
    chk(b"\x00\x1f\x1f" in rows, f"(d) rows {rows!r}")
finally:
    p.kill()
sys.exit(1 if fails else 0)
PY
