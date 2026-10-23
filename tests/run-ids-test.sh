#!/usr/bin/env bash
# REQ-9: ADMIT reply reports per-stream block-id ranges; checked against ls of the block dirs.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AXSHIM="$ROOT/shim/bin/axshim"
[ -x "$AXSHIM" ] || { echo "FAIL: $AXSHIM not built" >&2; exit 1; }
# Prerequisites are gitignored build products; fail fast, not with ConnectionRefused.
for b in "$ROOT/build/wp-slice" "$ROOT/shim/build/axshim-bin"; do
  [ -x "$b" ] || { echo "FAIL: $b missing. Build first: make test-prereqs" >&2; exit 1; }
done
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
import os,re
def ls():
    d=os.path.join(store,".axverity-store")
    return {k:set(os.listdir(os.path.join(d,k))) if os.path.isdir(os.path.join(d,k)) else set() for k in("structure","payload")}
def ids(names): 
    return sorted(int(m.group(1)) for n in names for m in [re.search(r"(\d+)",n)] if m)
p,s=start()
try:
    prev=None; ok=True
    shapes=[["a"+US+"b"+US+"c"*20][0:1] if False else ["x"+US+"y"+US+"z"],
            ["s"*100+US+"v"+US+"t"*200],
            ["p%d"%i+US+"q"+US+"r" for i in range(50)],
            ["big"+US+"v"+US+"B"*40000],
            ["m"+US+"n"+US+"o","M"+US+"N"+US+"O"*300]]
    r=None
    for i,sh in enumerate(shapes):
        before=ls()
        body=b"".join(len(x.encode()).to_bytes(8,"little")+x.encode() for x in sh)
        send(s,b"\x03"+bytes([len(sh)])+body); r=frame(s)
        t=r[1:].decode()
        after=ls()
        chk(r[0]==0 and "range=unavailable" not in t,f"shape{i} reply {t!r}")
        if i==0 and False: pass
        m=re.fullmatch(r"ok admitted=(\d+) bytes=(\d+) structure=(-?\d+),(\d+) payload=(-?\d+),(\d+)",t)
        chk(bool(m),f"shape{i} format")
        if not m: continue
        for k,(f,c) in (("structure",(int(m[3]),int(m[4]))),("payload",(int(m[5]),int(m[6])))):
            new=ids(after[k]-before[k])
            exp=list(range(f,f+c)) if c else []
            chk(new==exp and (c>0 or f==-1),f"shape{i} {k} range {f},{c} vs ls new {new}")
            if prev and c and k in prev: chk(f==prev[k],f"shape{i} {k} first {f} == prev first+count {prev[k]}")
            if c: prev=prev or {}; prev[k]=f+c
            elif False: pass
    # (a) empty store exact string
finally: p.kill()
import tempfile,shutil
store=tempfile.mkdtemp()
p,s=start()
try:
    r=frame_r=admit(s,"a"*5+US+"b"+US+"c"*6)
    chk(r==b"\x00ok admitted=1 bytes=22 structure=0,1 payload=-1,0",f"(a) {r!r}")
finally: p.kill(); shutil.rmtree(store,True)
sys.exit(1 if fails else 0)
PY
