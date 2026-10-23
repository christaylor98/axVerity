#!/usr/bin/env bash
# REQ-8: QUERY gate: STALE until a successful REBUILD; ADMIT re-closes; restart closes.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AXSHIM="$ROOT/shim/bin/axshim"
[ -x "$AXSHIM" ] || { echo "FAIL: $AXSHIM not built" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 - "$T" "$AXSHIM" <<'PY'
import subprocess, sys, time, socket
store, exe = sys.argv[1], sys.argv[2]
US="\x1f"; fails=0
def chk(ok,msg):
    global fails
    print(("ok   " if ok else "FAIL ")+msg); fails += not ok
def start():
    t=socket.socket(); t.bind(("127.0.0.1",0)); port=t.getsockname()[1]; t.close()
    p=subprocess.Popen([exe,store,str(port)],stdout=subprocess.DEVNULL,stderr=subprocess.STDOUT)
    for _ in range(100):
        try: socket.create_connection(("127.0.0.1",port),1).close(); break
        except OSError: time.sleep(0.1)
    s=socket.create_connection(("127.0.0.1",port),5); s.settimeout(10)
    return p,s
def rd(s,n):
    b=b""
    while len(b)<n:
        d=s.recv(n-len(b))
        if not d: raise EOFError
        b+=d
    return b
def frame(s):
    n=0;sh=0
    while True:
        c=rd(s,1)[0]; n|=(c&0x7f)<<sh; sh+=7
        if not c&0x80: break
    return rd(s,n)
def send(s,pl):
    n=len(pl); l=b""
    while True:
        b=n&0x7f; n>>=7; l+=bytes([b|(0x80 if n else 0)])
        if not n: break
    s.sendall(l+pl)
def q(s):
    send(s,b"\x01"+US.join(["0","","",""]).encode()); return frame(s)
def admit(s,r):
    e=r.encode(); send(s,b"\x03"+bytes([1])+len(e).to_bytes(8,"little")+e); return frame(s)
def noextra(s):
    s.settimeout(0.3)
    try: return s.recv(1)==b""
    except socket.timeout: return True
    finally: s.settimeout(10)
p,s=start()
try:
    r=admit(s,"a"+US+"b"+US+"c"); chk(r[0]==0,f"seed admit {r!r}")
    send(s,b"\x02"); r=frame(s); chk(r[0]==0,"seed rebuild")
finally: p.kill()
p,s=start()
try:
    h=q(s); chk(h[0]==1 and h[1:].startswith(b"STALE"),f"(a) fresh server STALE {h!r}")
    chk(noextra(s),"(a) single frame, no row stream")
    send(s,b"\x02"); r=frame(s); chk(r[0]==0,"rebuild ok")
    h=q(s); chk(h[0]==0,f"(b) after rebuild status 0 {h!r}")
    for _ in range(int(h[1:])): frame(s)
    r=admit(s,"d"+US+"e"+US+"f"); chk(r[0]==0,"admit ok")
    h=q(s); chk(h[0]==1 and h[1:].startswith(b"STALE"),f"(c) after admit STALE {h!r}")
    send(s,b"\x02"); frame(s)
    h=q(s); chk(h[0]==0,"reopened by rebuild")
finally: p.kill(); p.wait()
p,s=start()
try:
    h=q(s); chk(h[0]==1 and h[1:].startswith(b"STALE"),f"(d) after restart STALE {h!r}")
finally: p.kill()
sys.exit(1 if fails else 0)
PY
