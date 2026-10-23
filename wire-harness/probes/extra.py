import sys, time; sys.path.insert(0,'wire-harness')
from axwire import Client, US
from shimctl import Shim
def run(triples, tag, timeout=300):
    sh=Shim(f".axverity-store/wire-harness/x/{tag}").start(); c=Client(sh.port,timeout=timeout)
    try:
        t0=time.time(); c.admit(triples); t1=time.time()
        wm=c.rebuild(); t2=time.time()
        rows=set(c.query(0)); t3=time.time()
        want=set(triples)
        print(f"{tag}: n={len(triples)} admit={t1-t0:.2f}s rebuild={t2-t1:.2f}s "
              f"enum={t3-t2:.2f}s wm={wm} exact={rows==want} missing={len(want-rows)} extra={len(rows-want)}",flush=True)
    finally:
        c.close(); sh.stop()
# T10 — the published envelope, ~13k triples
n=13000
run([(f"s{i}", ["p","q","r","w"][i%4], f"t{i%2000}") for i in range(n)], "13k")
# high-bit content at scale: every record body carries top-bit bytes
hi=[chr(0x80+i) for i in range(0x40)]+[chr(0x800+0x40*i) for i in range(0x20)]+[chr(0x10000+0x1000*i) for i in range(0x10)]
tr=[]
for i in range(4000):
    L=1+(i%6)
    s="".join(hi[(i+j)%len(hi)] for j in range(L))
    v=hi[(i*7)%len(hi)]
    t="".join(hi[(i*3+j)%len(hi)] for j in range(1+(i%3)))
    if len((s+US+v+US+t).encode())<=32: tr.append((s,v,t))
tr=list(dict.fromkeys(tr))
run(tr,"hibit-scale")
