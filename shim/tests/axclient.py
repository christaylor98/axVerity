#!/usr/bin/env python3
"""axclient — a conformance client for the confined shim.

Deliberately written against the WIRE, not against the shim's source: it
re-implements F1v framing from the contract's description (T5, "varint length
prefix, same as the durable format") so that a framing bug in the shim shows up
as a disagreement rather than as two copies of the same mistake.
"""
import socket, sys

US = "\x1f"
OP_QUERY, OP_REBUILD, OP_ADMIT = 1, 2, 3
OP_GONE_DURABLE = 4          # removed at contract v2.0; kept so a test can prove it
# §5.8 status classes. SERVER_FAULT is the third class the shim's own P4
# measurements forced: "the client's bytes were fine and retrying will not
# help" is neither of the first two, and a client routing on status alone
# retried a missing writer binary forever.
OK, OUT_OF_CONTRACT, TRANSIENT, SERVER_FAULT = 0, 1, 2, 3


def vi_enc(n: int) -> bytes:
    out = bytearray()
    while True:
        g = n & 0x7F
        n >>= 7
        out.append(g | 0x80 if n else g)
        if not n:
            return bytes(out)


class Conn:
    def __init__(self, port, host="127.0.0.1", timeout=30.0):
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.buf = bytearray()

    def close(self):
        self.s.close()

    def _fill(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise EOFError("shim closed the connection")
            self.buf += chunk

    def recv_frame(self) -> bytes:
        # length prefix, one byte at a time — a varint has no fixed width
        i = 0
        while True:
            self._fill(i + 1)
            if self.buf[i] < 0x80:
                break
            i += 1
        n, shift = 0, 0
        for k in range(i + 1):
            n |= (self.buf[k] & 0x7F) << shift
            shift += 7
        hdr = i + 1
        self._fill(hdr + n)
        payload = bytes(self.buf[hdr:hdr + n])
        del self.buf[:hdr + n]
        return payload

    def send_frame(self, payload: bytes):
        self.s.sendall(vi_enc(len(payload)) + payload)

    def _reply(self):
        p = self.recv_frame()
        return p[0], p[1:].decode("utf-8", "replace")

    # ── the four verbs ──────────────────────────────────────────────────────
    def query(self, mask, s="", v="", t=""):
        body = US.join([str(mask), s, v, t]).encode()
        self.send_frame(bytes([OP_QUERY]) + body)
        st, head = self._reply()
        if st != OK:
            return st, head, []
        rows = []
        for _ in range(int(head)):
            rst, row = self._reply()
            if rst != OK:
                return rst, row, rows
            rows.append(tuple(row.split(US)))
        return OK, int(head), rows

    def rebuild(self):
        self.send_frame(bytes([OP_REBUILD]))
        return self._reply()

    def admit(self, count: int, records: bytes):
        self.send_frame(bytes([OP_ADMIT]) + vi_enc(count) + records)
        return self._reply()

    def durable(self):
        self.send_frame(bytes([OP_GONE_DURABLE]))
        return self._reply()

    def raw(self, payload: bytes):
        self.send_frame(payload)
        return self._reply()


if __name__ == "__main__":
    c = Conn(int(sys.argv[1]))
    print(c.rebuild())
    print(c.query(int(sys.argv[2]) if len(sys.argv) > 2 else 0)[:2])
