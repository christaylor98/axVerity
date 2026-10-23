import sys; sys.path.insert(0,'wire-harness')
from axwire import Client
from shimctl import Shim
corpus=[("s1","p","x"),("s1","q","y"),("s2","p","x"),("s2","r","z"),("s3","p","y"),("s2","p","y")]
sh=Shim(".axverity-store/wire-harness/mchar").start()
c=Client(sh.port)
print(c.admit(corpus)); print("watermark",c.rebuild())
S=set(corpus)
pats={ "_ _ _":lambda s,v,t: S,
       "s _ _":lambda s,v,t: {x for x in S if x[0]==s},
       "_ v _":lambda s,v,t: {x for x in S if x[1]==v},
       "_ _ t":lambda s,v,t: {x for x in S if x[2]==t},
       "s v _":lambda s,v,t: {x for x in S if x[0]==s and x[1]==v},
       "s _ t":lambda s,v,t: {x for x in S if x[0]==s and x[2]==t},
       "_ v t":lambda s,v,t: {x for x in S if x[1]==v and x[2]==t},
       "s v t":lambda s,v,t: {x for x in S if x==(s,v,t)} }
probes=[("s2","p","x"),("s1","p","y"),("s2","p","y"),("s3","q","z")]
for m in range(9):
    ok=[]
    for name,f in pats.items():
        if all(set(c.query(m,*pr))==f(*pr) for pr in probes): ok.append(name)
    got=set(c.query(m,"s2","p","y"))
    print(f"mask {m}: consistent-with={ok or '(none)'}  | sample(s2,p,y)->{sorted(got)}")
c.close(); sh.stop()
