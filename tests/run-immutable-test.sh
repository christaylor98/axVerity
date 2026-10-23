#!/usr/bin/env bash
# REQ-11: append-only/immutable storage; identical re-admit adds a durable
# record but QUERY stays a set.
#  (a) admit 'a<US>b<US>c' twice -> REBUILD watermark +2, QUERY mask 7 = 1 row
#  (b) every block that existed before a later ADMIT hashes the same after.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AXSHIM="$ROOT/shim/bin/axshim"
[ -x "$AXSHIM" ] || { echo "FAIL: $AXSHIM not built" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"; [ -n "${SP:-}" ] && kill $SP 2>/dev/null' EXIT
PYTHONPATH="$ROOT/shim/tests" python3 - "$T" "$AXSHIM" <<'PY'
import pathlib, subprocess, sys, time, hashlib, re
from axclient import Conn, US
store = pathlib.Path(sys.argv[1]); store.mkdir(exist_ok=True)
log = (store/"shim.log").open("w")
import socket as _s
_t=_s.socket(); _t.bind(("127.0.0.1",0)); PORT=_t.getsockname()[1]; _t.close()
p = subprocess.Popen([sys.argv[2], str(store), str(PORT)], stdout=log, stderr=subprocess.STDOUT)
port = PORT
for _ in range(100):
    try:
        import socket; socket.create_connection(("127.0.0.1", port), 1).close(); break
    except OSError: time.sleep(0.1)
fails = 0
def chk(ok, msg):
    global fails
    print(("ok   " if ok else "FAIL ") + msg)
    if not ok: fails += 1
def rec(s, v, t):
    b = US.join([s, v, t]).encode()
    return len(b).to_bytes(8, "little") + b
def blocks():
    out = {}
    for f in (store/".axverity-store").glob("*/block-*"):
        if f.is_file(): out[str(f.relative_to(store))] = hashlib.sha256(f.read_bytes()).hexdigest()
    return out
def wm(body):
    m = re.search(r"(\d+)", body); return int(m.group(1)) if m else -1
try:
    c = Conn(port, timeout=30)
    st, b = c.admit(1, rec("a","b","c")); chk(st == 0, f"first admit: {b}")
    st, b = c.rebuild(); w0 = wm(b); chk(st == 0, f"rebuild: {b}")
    h0 = blocks(); chk(len(h0) > 0, f"{len(h0)} durable block(s) before 2nd admit")
    st, b = c.admit(1, rec("a","b","c")); chk(st == 0, f"identical re-admit: {b}")
    st, b = c.rebuild(); w1 = wm(b); chk(st == 0 and w1 == w0 + 1, f"watermark {w0} -> {w1} (+1 per re-admit)")
    st, b = c.admit(1, rec("d","e","f")); chk(st == 0, f"later admit: {b}")
    st, b = c.rebuild(); w2 = wm(b); chk(w2 == w1 + 1, f"watermark {w1} -> {w2}")
    st, n, rows = c.query(7, "a", "b", "c")
    chk(st == 0 and n == 1 and rows == [("a","b","c")], f"mask 7 a,b,c -> {n} row(s) (set semantics)")
    st, n, rows = c.query(0)
    chk(st == 0 and n == 2, f"mask 0 -> {n} rows (a-b-c once, d-e-f)")
    h1 = blocks()
    chk(all(h1.get(k) == v for k, v in h0.items()), "pre-existing block bytes hash identically after later ADMITs")
    chk(len(h1) > len(h0), f"re-admit appended new blocks ({len(h0)} -> {len(h1)})")
finally:
    p.kill()
sys.exit(1 if fails else 0)
PY
rc=$?; [ $rc -eq 0 ] && echo "IMMUTABLE TEST PASS" || echo "IMMUTABLE TEST FAIL"; exit $rc
