import sys; sys.path.insert(0,'wire-harness')
from axwire import Client
from shimctl import Shim
sh=Shim(".axverity-store/wire-harness/dup").start()
c=Client(sh.port)
c.admit([("a","p","b"),("c","q","d")]); print("wm",c.rebuild(),"rows",len(c.query(0)))
c.admit([("a","p","b")]);               print("wm",c.rebuild(),"rows",len(c.query(0)))
c.admit([("a","p","b"),("a","p","b")]); print("wm",c.rebuild(),"rows",len(c.query(0)))
print("mask7 (a,p,b) ->", c.query(7,"a","p","b"))
c.close(); sh.stop()
