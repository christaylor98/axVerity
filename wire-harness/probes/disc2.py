import sys; sys.path.insert(0,'wire-harness')
from wp import *
from shimctl import Shim
ROOT=".axverity-store/wire-harness/disc"
def trial(label, body, timeout=8.0):
    sh=Shim(ROOT).start()
    try:
        p=Probe(sh.port,timeout=timeout); p.send_raw(frame(body)); g=p.drain(); p.close()
        p2=Probe(sh.port,timeout=2.0); p2.send_raw(frame(bytes([4]))); live=bool(p2.drain()); p2.close()
    finally: sh.stop()
    print(f"--- {label}\n  {len(g)}B {show(g,160) if g else '(none)'}   live={live}")
    return g
rec3 = s_("a")+s_("b")+s_("c")
trial("D count=3, three frames a|b|c", bytes([3])+leb(3)+s_("a")+s_("b")+s_("c"))
trial("E count=1, one frame containing 3 sub-frames", bytes([3])+leb(1)+s_(rec3))
trial("F count=1, one frame 'a\\0b\\0c'", bytes([3])+leb(1)+s_(b"a\x00b\x00c"))
trial("G count=1, one frame 'a\\tb\\tc'", bytes([3])+leb(1)+s_("a\tb\tc"))
trial("H count=1, one frame 'a b c'  (already tried) / count=1 frame 'abc'", bytes([3])+leb(1)+s_("abc"))
