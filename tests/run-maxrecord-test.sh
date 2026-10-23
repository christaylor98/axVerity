#!/usr/bin/env bash
# REQ-6: max_record policy (config/max_record, default 65536); refusal names the limit; nothing written.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AXSHIM="$ROOT/shim/bin/axshim"
[ -x "$AXSHIM" ] || { echo "FAIL: $AXSHIM not built" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 - "$T" "$AXSHIM" <<'PY'
import subprocess, sys, time, socket, os
store, exe = sys.argv[1], sys.argv[2]
def start():
    t = socket.socket(); t.bind(("127.0.0.1", 0)); port = t.getsockname()[1]; t.close()
    p = subprocess.Popen([exe, store, str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    for _ in range(100):
        try: socket.create_connection(("127.0.0.1", port), 1).close(); break
        except OSError: time.sleep(0.1)
    s = socket.create_connection(("127.0.0.1", port), 5); s.settimeout(30)
    return p, s
def rd(s, n):
    b = b""
    while len(b) < n:
        d = s.recv(n - len(b))
        if not d: raise EOFError
        b += d
    return b
def frame(s):
    n = 0; sh = 0
    while True:
        c = rd(s, 1)[0]; n |= (c & 0x7f) << sh; sh += 7
        if not c & 0x80: break
    return rd(s, n)
def send(s, pl):
    n = len(pl); h = b""
    while True:
        c = n & 0x7f; n >>= 7
        if n: h += bytes([c | 0x80])
        else: h += bytes([c]); break
    s.sendall(h + pl)
def rec(n):
    pad = n - 2; return b"a" * (pad // 2) + b"\x1f" + b"b" * (pad - pad // 2 - 0) [:0] + b"" if False else b"s" + b"\x1f" + b"v" + b"\x1f" + b"x" * (n - 4)
def admit(s, recs):
    b = b"\x03" + bytes([len(recs)])
    for r in recs: b += len(r).to_bytes(8, "little") + r
    send(s, b); return frame(s)
def rebuild(s): send(s, b"\x02"); return frame(s)
def count(s):
    send(s, b"\x01" + b"0\x1f\x1f\x1f"); h = frame(s)
    n = int(h[1:]) if h[0] == 0 else -1
    for _ in range(max(n, 0)): frame(s)
    return h
fails = 0
def chk(ok, msg):
    global fails
    print(("ok   " if ok else "FAIL ") + msg[:200]); fails += not ok
p, s = start()
try:
    r = admit(s, [rec(65536)]); chk(r[0] == 0, f"(a) 65536 admitted {r[:80]!r}")
    base = rebuild(s)
    r = admit(s, [rec(65537)]); chk(r[0] == 1 and b"max_record=65536" in r, f"(a) 65537 refused {r[:120]!r}")
    chk(rebuild(s) == base, "(c) watermark unchanged")
finally:
    p.kill()
os.makedirs(store + "/.axverity-store/config", exist_ok=True)
open(store + "/.axverity-store/config/max_record", "w").write("1000000\n")
p, s = start()
try:
    r = admit(s, [rec(900000)]); chk(r[0] == 0, f"(b) 900000 admitted {r[:80]!r}")
    chk(rebuild(s)[0] == 0, "(b) rebuild")
    h = count(s); chk(h[0] == 0 and h[1:] == b"2", f"(b) queryable {h!r}")
    r = admit(s, [rec(1000001)]); chk(r[0] == 1 and b"max_record=1000000" in r, f"(b) over refused {r[:120]!r}")
finally:
    p.kill()
sys.exit(1 if fails else 0)
PY
