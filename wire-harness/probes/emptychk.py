import sys; sys.path.insert(0,'wire-harness')
from axwire import Client
from shimctl import Shim
BASE=".axverity-store/wire-harness/emp"
def one(triples, tag, mask=0):
    sh=Shim(f"{BASE}/{tag}").start(); c=Client(sh.port)
    try:
        t=c.admit(triples); w=c.rebuild(); rows=c.query(0)
        return t,w,rows
    finally:
        c.close(); sh.stop()
print("== empty field positions, one record per store ==")
cases={"empty-s":("","v","t"),"empty-v":("s","","t"),"empty-t":("s","v",""),
       "all-empty":("","",""),"normal":("s","v","t")}
for k,tr in cases.items():
    t,w,rows=one([tr],k)
    print(f"  {k:10s} admit={t!r} watermark={w} rows={rows}", flush=True)
print("== name classes, all short (<=32B records) ==")
classes={"ascii":"pl","latin1":"cafeé","cjk":"中文","astral":"\U0001d11e",
         "emoji":"\U0001f600","rtl":"עב","combining":"é","digits":"12",
         "space":"a b","dotdot":"../a","quote":"i'\"","backslash":"a\\b","percent":"1%s"}
for k,val in classes.items():
    tr=(val,"v","t")
    b=len((val+"\x1fv\x1ft").encode())
    t,w,rows=one([tr],"c-"+k)
    print(f"  {k:10s} {b:3d}B watermark={w} exact={rows==[tr]} rows={rows}", flush=True)
