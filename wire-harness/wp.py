"""Low-level wire probe: send raw request frames, dump raw replies.
Nothing here knows anything the socket did not tell it."""
import socket

def leb(n):
    out=bytearray()
    while True:
        b=n&0x7f;n>>=7
        if n: out.append(b|0x80)
        else: out.append(b);break
    return bytes(out)

def s_(t):
    b=t.encode('utf-8') if isinstance(t,str) else t
    return leb(len(b))+b

def frame(body):
    return leb(len(body))+body

class Probe:
    def __init__(self, port, host="127.0.0.1", timeout=0.6):
        self.s=socket.create_connection((host,port),timeout=5)
        self.s.settimeout(timeout)
    def send_raw(self,b): self.s.sendall(b)
    def drain(self):
        got=b""
        try:
            while True:
                c=self.s.recv(65536)
                if not c: break
                got+=c
        except socket.timeout: pass
        return got
    def close(self):
        try: self.s.close()
        except Exception: pass

def show(b, n=400):
    b=b[:n]
    return b.hex(' ')+"\n     |"+"".join(chr(x) if 32<=x<127 else "." for x in b)+"|"

def one(port,body,label,timeout=0.6):
    p=Probe(port,timeout=timeout)
    p.send_raw(frame(body))
    g=p.drain(); p.close()
    print(f"--- {label}  (req body {len(body)}B) -> {len(g)}B")
    if g: print("    ",show(g))
    return g
