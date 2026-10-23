import sys, time, socket, threading; sys.path.insert(0,'wire-harness')
from axwire import Client, leb128, Transient
from shimctl import Shim
SMALL=[("a1","p","x1"),("a2","p","x2")]
sh=Shim(".axverity-store/wire-harness/conc2").start()
a=Client(sh.port,timeout=5.0); a.admit(SMALL); a.rebuild()
print("A: seeded, still open")
t0=time.time()
b=socket.create_connection(("127.0.0.1",sh.port),timeout=5)
print(f"B: connect() returned in {time.time()-t0:.3f}s")
body=bytes([4]); b.sendall(leb128(len(body))+body)
b.settimeout(3.0)
try:
    got=b.recv(100); print(f"B: replied while A open, {time.time()-t0:.3f}s: {got!r}")
except socket.timeout:
    print(f"B: NO reply while A open (waited 3.0s)")
    a.close(); print("A: closed")
    b.settimeout(5.0)
    t1=time.time()
    try:
        got=b.recv(100); print(f"B: replied {time.time()-t1:.3f}s after A closed: {got!r}")
    except socket.timeout:
        print("B: still no reply 5s after A closed")
b.close()
# how many connections can queue?
print("--- how deep does the queue go? ---")
c0=Client(sh.port,timeout=5.0); c0.durable_raw("")
socks=[]
for i in range(8):
    try:
        s=socket.create_connection(("127.0.0.1",sh.port),timeout=2); socks.append(s)
    except OSError as e:
        print(f"  connect #{i+2} refused: {e}"); break
else:
    print(f"  {len(socks)+1} connections open simultaneously, none refused")
c0.close()
for s in socks: s.close()
sh.stop()
