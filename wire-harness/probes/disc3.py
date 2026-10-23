import sys, struct; sys.path.insert(0,'wire-harness')
from wp import *
from shimctl import Shim
ROOT=".axverity-store/wire-harness/disc"
sh=Shim(ROOT).start()
def t(label, body, timeout=2.0):
    global sh
    p=Probe(sh.port,timeout=timeout); p.send_raw(frame(body)); g=p.drain(); p.close()
    txt="".join(chr(x) if 32<=x<127 else "." for x in g)
    print(f"{label:34s} -> {len(g):4d}B {txt[:80]}", flush=True)
    if not g:
        sh.stop(); sh=Shim(ROOT).start()   # wedged: fresh server
    return g
payloads = {
 "u8":      lambda b: bytes([len(b)])+b,
 "u16le":   lambda b: struct.pack("<H",len(b))+b,
 "u16be":   lambda b: struct.pack(">H",len(b))+b,
 "u32le":   lambda b: struct.pack("<I",len(b))+b,
 "u32be":   lambda b: struct.pack(">I",len(b))+b,
 "u64le":   lambda b: struct.pack("<Q",len(b))+b,
 "u64be":   lambda b: struct.pack(">Q",len(b))+b,
 "nl":      lambda b: b+b"\n",
 "nul":     lambda b: b+b"\x00",
 "raw":     lambda b: b,
}
recs = {"abc": b"abc", "a.b.c": b"a\x00b\x00c", "3xleb": leb(1)+b"a"+leb(1)+b"b"+leb(1)+b"c"}
for pn,pf in payloads.items():
    for rn,rb in recs.items():
        t(f"{pn}({rn})", bytes([3])+leb(1)+pf(rb))
sh.stop()
