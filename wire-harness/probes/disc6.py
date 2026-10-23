import sys, struct; sys.path.insert(0,'wire-harness')
from wp import *
from shimctl import Shim
ROOT=".axverity-store/wire-harness/disc6"
US=b"\x1f"
def rec(b): return struct.pack("<Q",len(b))+b
def triple(s,v,t): return rec(s.encode()+US+v.encode()+US+t.encode())
sh=Shim(ROOT).start()
def t(label, body, timeout=4.0):
    p=Probe(sh.port,timeout=timeout); p.send_raw(frame(body)); g=p.drain(); p.close()
    txt="".join(chr(x) if 32<=x<127 else "~" for x in g)
    print(f"{label:46s} -> {len(g):5d}B {txt[:220]}", flush=True); return g
corpus=[("s1","p","x"),("s1","q","y"),("s2","p","x"),("s2","r","z"),("s3","p","y")]
body=bytes([3])+leb(len(corpus))
for c in corpus: body+=triple(*c)
t("ADMIT corpus(5)", body)
t("REBUILD", bytes([2]))
enc = {
 "leb(mask) only":            lambda m,s,v,tt: leb(m),
 "leb(mask)+leb-strs":        lambda m,s,v,tt: leb(m)+s_(s)+s_(v)+s_(tt),
 "leb(mask)+u64-strs":        lambda m,s,v,tt: leb(m)+rec(s.encode())+rec(v.encode())+rec(tt.encode()),
 "US text mask/s/v/t":        lambda m,s,v,tt: f"{m}\x1f{s}\x1f{v}\x1f{tt}".encode(),
 "US text s/v/t (no mask)":   lambda m,s,v,tt: f"{s}\x1f{v}\x1f{tt}".encode(),
 "u64(mask)+US text":         lambda m,s,v,tt: struct.pack("<Q",m)+f"{s}\x1f{v}\x1f{tt}".encode(),
}
for name,f in enc.items():
    t(f"[{name}] mask1 s=s1", bytes([1])+f(1,"s1","",""))
    t(f"[{name}] mask3 s=s1 v=p", bytes([1])+f(3,"s1","p",""))
sh.stop()
