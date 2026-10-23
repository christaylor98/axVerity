import sys; sys.path.insert(0,'wire-harness')
from axwire import Client
from shimctl import Shim
sh=Shim(".axverity-store/wire-harness/mdump").start()
c=Client(sh.port)
c.admit([("s1","p","x"),("s2","q","y")]); c.rebuild()
r=c.query_raw(0)
print("status",r.status); print("text repr:",repr(r.text)); print("hex:",r.text.encode().hex(' '))
r1=c.query_raw(1,"s1")
print("mask1 repr:",repr(r1.text))
c.close(); sh.stop()
