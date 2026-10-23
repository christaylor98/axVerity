import socket
HOST,PORT="127.0.0.1",47311
def leb(n):
    out=bytearray()
    while True:
        b=n&0x7f;n>>=7
        if n: out.append(b|0x80)
        else: out.append(b);break
    return bytes(out)
res={}
for op in range(256):
    try:
        s=socket.create_connection((HOST,PORT),timeout=2); s.settimeout(0.35)
        s.sendall(leb(1)+bytes([op]))
        got=b""
        try:
            while True:
                c=s.recv(4096)
                if not c: break
                got+=c
        except socket.timeout: pass
        s.close()
    except Exception as e:
        got=b"<EXC:"+str(e).encode()+b">"
    key=got
    res.setdefault(key,[]).append(op)
for k,v in sorted(res.items(), key=lambda kv: kv[1][0]):
    show=k[:80]
    txt="".join(chr(x) if 32<=x<127 else "." for x in show)
    rng = v if len(v)<=12 else f"{len(v)} opcodes: {v[:6]}...{v[-3:]}"
    print(f"{rng}\n    {show.hex(' ')}\n    |{txt}|")
