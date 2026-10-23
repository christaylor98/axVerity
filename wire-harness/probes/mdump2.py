import sys, struct; sys.path.insert(0,'wire-harness')
from wp import *
from shimctl import Shim
US=b"\x1f"
def rec(b): return struct.pack("<Q",len(b))+b
def triple(s,v,t): return rec(s.encode()+US+v.encode()+US+t.encode())
sh=Shim(".axverity-store/wire-harness/mdump2").start()
def raw(body,label,timeout=2.0):
    p=Probe(sh.port,timeout=timeout); p.send_raw(frame(body)); g=p.drain(); p.close()
    print(f"{label}: {len(g)}B\n   {g.hex(' ')}\n   {repr(g)}",flush=True); return g
corpus=[("s1","p","x"),("s1","q","y"),("s2","p","x")]
b=bytes([3])+leb(len(corpus))
for c in corpus: b+=triple(*c)
raw(b,"ADMIT")
raw(bytes([2]),"REBUILD")
raw(bytes([1])+b"0\x1f\x1f\x1f","QUERY mask0")
raw(bytes([1])+b"1\x1fs1\x1f\x1f","QUERY mask1 s1")
raw(bytes([1])+b"3\x1fs1\x1fp\x1f","QUERY mask3 s1 p")
raw(bytes([1])+b"9\x1f\x1f\x1f","QUERY mask9")
sh.stop()
