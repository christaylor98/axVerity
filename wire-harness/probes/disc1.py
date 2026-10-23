import sys, os; sys.path.insert(0,'wire-harness')
from wp import *
from shimctl import Shim

ROOT=".axverity-store/wire-harness/disc"

def trial(label, sender, timeout=8.0):
    sh=Shim(ROOT).start()
    try:
        p=Probe(sh.port,timeout=timeout)
        sender(p)
        g=p.drain(); p.close()
        # liveness after
        p2=Probe(sh.port,timeout=2.0); p2.send_raw(frame(bytes([4]))); live=p2.drain(); p2.close()
    finally:
        sh.stop()
    print(f"--- {label}\n  reply {len(g)}B: {show(g,200) if g else '(none)'}\n  server-still-answers: {bool(live)}")
    return g

trial("A admit count=0 (one frame)", lambda p: p.send_raw(frame(bytes([3])+leb(0))))
trial("B admit count=1 + 3 strings (one frame)", lambda p: p.send_raw(frame(bytes([3])+leb(1)+s_("a")+s_("b")+s_("c"))))
trial("C admit count=1 + one blob 'a b c'", lambda p: p.send_raw(frame(bytes([3])+leb(1)+s_("a b c"))))
