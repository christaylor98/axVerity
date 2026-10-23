import sys; sys.path.insert(0,'wire-harness')
from axwire import Client
from shimctl import Shim
BASE=".axverity-store/wire-harness/size"
def one(triples, tag):
    sh=Shim(f"{BASE}/{tag}").start(); c=Client(sh.port)
    try:
        t=c.admit(triples); w=c.rebuild(); rows=c.query(0)
        return t,w,rows
    finally:
        c.close(); sh.stop()
print("== payload-size visibility sweep (one record per store) ==")
for n in range(20,46):
    s="S"*n
    payload=len(s.encode())+1+1+1+1  # s US v US t  with v='v', t='t'
    t,w,rows=one([(s,"v","t")], f"n{n}")
    vis = rows==[(s,"v","t")]
    print(f"  name={n:3d}  record={payload:3d}B  watermark={w}  rows={len(rows)}  exact={vis}"
          + ("" if vis else f"  got={rows[:1]}"), flush=True)
