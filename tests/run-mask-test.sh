#!/usr/bin/env bash
# REQ-7: all eight binding patterns exact vs an oracle over a 12-triple corpus; masks outside 0..7 refused (status 1).
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
US = "\x1f"
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
    n = len(pl); l = b""
    while True:
        b = n & 0x7f; n >>= 7
        l += bytes([b | (0x80 if n else 0)])
        if not n: break
    s.sendall(l + pl)
fails = 0
def chk(ok, msg):
    global fails
    print(("ok   " if ok else "FAIL ") + msg); fails += not ok
corpus = [("a","knows","b"),("b","knows","c"),("c","knows","a"),("v2","supersedes","v1"),
 ("v3","supersedes","v2"),("v4","supersedes","v3"),("r","owns","n1"),("r","owns","n2"),
 ("n1","kind","Node"),("n2","kind","Node"),("a","kind","Node"),("x","knows","n1")]
assert len(corpus) == 12
def oracle(m, a, b, c):
    return {r for r in corpus if (not m&1 or r[0]==a) and (not m&2 or r[1]==b) and (not m&4 or r[2]==c)}
def query(m, a="", b="", c=""):
    send(b"\x01" + US.join([m, a, b, c]).encode()); h = frame()
    if h[0] != 0: return h, None
    n = int(h[1:]); rows = [frame() for _ in range(n)]
    return h, {tuple(r[1:].decode().split(US)) for r in rows}, n
try:
    body = b"\x03" + bytes([12])
    for r in corpus:
        e = US.join(r).encode(); body += len(e).to_bytes(8, "little") + e
    send(body); r = frame(); chk(r[0] == 0 and b"admitted=12" in r, f"admit {r!r}")
    send(b"\x02"); r = frame(); chk(r[0] == 0, f"rebuild {r!r}")
    args = ("a", "knows", "n1")
    for m in range(8):
        res = query(str(m), *args)
        got = res[1]; want = oracle(m, *args)
        chk(got == want and res[2] == len(want), f"mask {m}: missing={sorted(want-got)} unexpected={sorted(got-want)}")
    res = query("2", "", "supersedes", "")
    chk(res[1] == {r for r in corpus if r[1] == "supersedes"} and len(res[1]) == 3, "mask 2 v=supersedes -> all 3 supersedes edges")
    res = query("4", "", "", "n1")
    chk(res[1] == {r for r in corpus if r[2] == "n1"} and len(res[1]) == 2, "mask 4 t=n1 -> n1's in-edges")
    res = query("2", "", "", "n1")
    chk(res[1] == set(), "mask 2 with only t supplied -> 0 rows (not an in-edge query)")
    for m in ["8", "9", "10", "255", "a", "-1", ""]:
        h = query(m, "a", "knows", "b")[0]
        chk(h[0] == 1, f"mask {m!r} refused: {h!r}")
    h, rows, n = query("0")
    chk(h[0] == 0 and n == 12, "still serving after refusals")
finally:
    p.kill()
sys.exit(1 if fails else 0)
PY
