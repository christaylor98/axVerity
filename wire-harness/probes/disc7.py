import sys, struct; sys.path.insert(0,'wire-harness')
from wp import *
from shimctl import Shim
ROOT=".axverity-store/wire-harness/disc7"
US=b"\x1f"
def rec(b): return struct.pack("<Q",len(b))+b
def triple(s,v,t): return rec(s.encode()+US+v.encode()+US+t.encode())
sh=Shim(ROOT).start()
def t(label, body, timeout=4.0):
    p=Probe(sh.port,timeout=timeout); p.send_raw(frame(body)); g=p.drain(); p.close()
    print(f"{label:40s} -> {len(g):5d}B {''.join(chr(x) if 32<=x<127 else '~' for x in g)[:160]}", flush=True); return g
body=bytes([3])+leb(2)+triple("a","p","b")+triple("c","q","d")
t("ADMIT 2", body)
t("DURABLE bare", bytes([4]))
t("DURABLE '0'", bytes([4])+b"0")
t("DURABLE '2'", bytes([4])+b"2")
t("DURABLE '99'", bytes([4])+b"99")
t("DURABLE leb(2)", bytes([4])+leb(2))
print("--- multi-request on ONE connection ---")
p=Probe(sh.port,timeout=3.0)
p.send_raw(frame(bytes([2])))            # REBUILD
r1=p.drain()
p.send_raw(frame(bytes([1])+b"0\x1f\x1f\x1f"))  # QUERY all
r2=p.drain()
print("  req1:",''.join(chr(x) if 32<=x<127 else '~' for x in r1))
print("  req2:",''.join(chr(x) if 32<=x<127 else '~' for x in r2))
p.close()
print("--- pipelined (both written before reading) ---")
p=Probe(sh.port,timeout=3.0)
p.send_raw(frame(bytes([2]))+frame(bytes([1])+b"0\x1f\x1f\x1f"))
print("  ",''.join(chr(x) if 32<=x<127 else '~' for x in p.drain())); p.close()
sh.stop()
