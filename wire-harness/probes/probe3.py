import sys; sys.path.insert(0,'wire-harness')
from wp import *
P=47311
one(P, bytes([3])+leb(0), "A: single frame [3,count=0]", timeout=6.0)
# hypothesis: op frame, then a separate body frame
p=Probe(P,timeout=6.0); p.send_raw(frame(bytes([3]))); p.send_raw(frame(leb(0)))
print("B: frame(op3) then frame(count0) ->", show(p.drain())); p.close()
# hypothesis: op frame then records as their own frames
p=Probe(P,timeout=6.0)
p.send_raw(frame(bytes([3])+leb(1)))
p.send_raw(frame(s_("a")+s_("b")+s_("c")))
print("C: frame(op3,count1) then frame(3 strings) ->", show(p.drain())); p.close()
