import socket, sys, time

HOST, PORT = "127.0.0.1", 47311

def dump(b):
    return " ".join(f"{x:02x}" for x in b) + "   |" + "".join(chr(x) if 32<=x<127 else "." for x in b) + "|"

def probe(payload, label, wait=0.6):
    s = socket.create_connection((HOST, PORT), timeout=3)
    s.settimeout(wait)
    got = b""
    if payload is not None:
        s.sendall(payload)
    try:
        while True:
            c = s.recv(4096)
            if not c: break
            got += c
    except socket.timeout:
        pass
    s.close()
    print(f"--- {label}: sent {len(payload) if payload else 0}B, got {len(got)}B")
    if got: print("   ", dump(got[:200]))
    return got

# A: pure connect, say nothing. Does the server greet?
probe(b"", "A/silent-connect")

def leb(n):
    out=bytearray()
    while True:
        b=n&0x7f; n>>=7
        if n: out.append(b|0x80)
        else: out.append(b); break
    return bytes(out)

def f(s):
    b=s.encode(); return leb(len(b))+b

probe(leb(3)+b"XYZ", "B/leb-frame-XYZ")
probe(b"XYZ\n", "C/line-XYZ")
probe(f("LEASE")+f("acquire")+f("READ"), "D/leb LEASE acquire READ")
probe(b"LEASE acquire READ\n", "E/line LEASE acquire READ")
probe(f("READ"), "F/leb READ")
probe(b"READ\n", "G/line READ")
probe(f("1")+f("READ"), "H/leb 1 READ")
probe(b"HELLO 1 READ\n", "I/line HELLO 1 READ")
