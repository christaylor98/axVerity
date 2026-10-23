import sys, struct; sys.path.insert(0,'wire-harness')
from wp import *
from shimctl import Shim
ROOT=".axverity-store/wire-harness/disc5"
def rec(b): return struct.pack("<Q",len(b))+b
sh=Shim(ROOT).start()
def t(label, body, timeout=4.0):
    p=Probe(sh.port,timeout=timeout); p.send_raw(frame(body)); g=p.drain(); p.close()
    txt="".join(chr(x) if 32<=x<127 else "." for x in g)
    print(f"{label:44s} -> {len(g):5d}B {txt[:200]}", flush=True); return g
cands = {
 "3leb":   leb(2)+b"aa"+leb(2)+b"bb"+leb(2)+b"cc",
 "nlsep":  b"dd\nee\nff",
 "us":     b"gg\x1fhh\x1fii",
 "sp":     b"jj kk ll",
 "tab":    b"mm\tnn\too",
 "nul":    b"pp\x00qq\x00rr",
 "3u64":   struct.pack("<Q",2)+b"ss"+struct.pack("<Q",2)+b"tt"+struct.pack("<Q",2)+b"uu",
 "cnt3leb":leb(3)+leb(2)+b"vv"+leb(2)+b"ww"+leb(2)+b"xx",
}
body=bytes([3])+leb(len(cands))
for v in cands.values(): body+=rec(v)
t("ADMIT 8 candidates", body)
t("REBUILD", bytes([2]))
for m in range(9):
    t(f"QUERY mask={m}", bytes([1])+leb(m))
t("QUERY mask=99", bytes([1])+leb(99))
t("QUERY mask=0 +3 names", bytes([1])+leb(0)+s_("aa")+s_("bb")+s_("cc"))
t("QUERY mask=1 +3 names", bytes([1])+leb(1)+s_("aa")+s_("bb")+s_("cc"))
sh.stop()
