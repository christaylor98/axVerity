import sys, struct; sys.path.insert(0,'wire-harness')
from wp import *
from shimctl import Shim
ROOT=".axverity-store/wire-harness/disc4"
def rec(b): return struct.pack("<Q",len(b))+b
sh=Shim(ROOT).start()
def t(label, body, timeout=4.0):
    p=Probe(sh.port,timeout=timeout); p.send_raw(frame(body)); g=p.drain(); p.close()
    txt="".join(chr(x) if 32<=x<127 else "." for x in g)
    print(f"{label:40s} -> {len(g):5d}B {txt[:160]}", flush=True); return g
# admit three candidate triple encodings, distinguishable
r1 = leb(2)+b"s1"+leb(2)+b"v1"+leb(2)+b"t1"
r2 = b"s2\x00v2\x00t2"
r3 = b"s3 v3 t3"
r4 = b"s4\tv4\tt4"
t("ADMIT 4 candidate encodings", bytes([3])+leb(4)+rec(r1)+rec(r2)+rec(r3)+rec(r4))
t("REBUILD", bytes([2]))
for lbl,body in [
  ("QUERY leb(0) only",        bytes([1])+leb(0)),
  ("QUERY leb(0)+3 empty strs",bytes([1])+leb(0)+s_("")+s_("")+s_("")),
  ("QUERY bare",               bytes([1])),
]:
    t(lbl, body)
sh.stop()
