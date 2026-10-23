"""
axwire — a client for the axVerity confined shim.

PROVENANCE OF EVERY BYTE IN THIS FILE
=====================================
AXVERITY_WIRE_CLIENT_HARNESS_V1 requires the framing be derived from
AXVERITY_CONSUMER_CONTRACT.v2.0, independently of the shim's own test suite.
No file under shim/ was read to write this module. Each framing decision below
is tagged:

  [CONTRACT §x]  stated in the contract document
  [WIRE]         not in the contract; recovered by black-box probing of the
                 socket (opcode sweep + encoding sweep). Every [WIRE] tag is a
                 gap in the published surface and is logged in FINDINGS.md.

Request frame
    LEB128(len) || body                       [CONTRACT §5.11 T5 "F1v varint
                                               length prefix"]
    body[0]  = opcode                         [WIRE]
    opcode 1 QUERY, 2 REBUILD, 3 ADMIT        [WIRE]
    there is no LEASE opcode                  [WIRE — contradicts §5.7]
    there is no DURABLE opcode                [CONTRACT §A.9 v2.0 — removed]
    there is no handshake and no version      [WIRE — contradicts §5.4, §5.9]

Reply frame
    LEB128(len) || status || text             [WIRE]
    status 0 = ok, 1 = out-of-contract        [WIRE — §5.8 names the classes
                                               but not their encoding]

QUERY   body[1:] = ASCII  mask US s US v US t                 [WIRE]
        reply is a MULTI-FRAME result stream                   [WIRE, matches
                                               §5.7 "result stream" / T3]
          frame 0     : status || ASCII count
          frames 1..N : status || s US v US t                  [WIRE]
REBUILD body[1:] = empty ; ok text = watermark                [WIRE]
ADMIT   body[1:] = LEB128(count) || record*                   [WIRE]
        record   = u64 LITTLE ENDIAN len || payload           [WIRE — a second
                                               length encoding on one wire,
                                               which §5.11 T5 exists to forbid]
        payload  = UTF-8  s US v US t                         [WIRE]
        ok text  = "ok admitted=N bytes=M structure=F,C payload=F,C"
                                                      [CONTRACT §4.5 v2.0]
        F,C is (first block id, block count) for that STREAM. C = 0 carries
        F = -1 and must not be read as block 0. A reply may instead carry
        "range=unavailable" with NO structure=/payload= keys, which means the
        write landed and the range could not be reported — treat a MISSING key
        as no handle, never as zero.

QUERY is gated on freshness. A QUERY issued before the connection's server
process has completed a REBUILD, or after any ADMIT since the last one,
answers status 1 with a body beginning "STALE".   [CONTRACT §3.1 v2.0]
Route on the status byte, never on that text.

Opcode 4 was DURABLE through contract v1.0. It is GONE in v2.0 and now answers
"UNKNOWN opcode 4" like any other unassigned byte, because it answered `ok` to
every argument ever put to it and a consumer was entitled to read that as a
durability guarantee.                                 [CONTRACT §A.9 v2.0]

US is 0x1f, ASCII UNIT SEPARATOR. It is the field separator in both directions
and it is not escaped.                                        [WIRE]
"""
import socket, struct

US = "\x1f"
USB = b"\x1f"

OP_QUERY, OP_REBUILD, OP_ADMIT = 1, 2, 3

ST_OK, ST_OUT_OF_CONTRACT, ST_TRANSIENT, ST_SERVER_FAULT = 0, 1, 2, 3
ST_NAMES = {0: "ok", 1: "out-of-contract", 2: "transient", 3: "server-fault"}


class WireError(Exception):
    """Any non-zero status, or a wire-level failure."""
    def __init__(self, status, text):
        self.status = status
        self.text = text
        super().__init__(f"[{ST_NAMES.get(status, status)}] {text}")


class OutOfContract(WireError):
    """§5.8: the client is wrong. Retrying will not help and must not be tried."""


class Transient(WireError):
    """§5.8: connection loss / server restart. Retry is legitimate."""


class ServerFault(WireError):
    pass


class Unclassified(WireError):
    """A status byte the contract does not name."""


def _raise(status, text):
    cls = {ST_OUT_OF_CONTRACT: OutOfContract,
           ST_TRANSIENT: Transient,
           ST_SERVER_FAULT: ServerFault}.get(status, Unclassified)
    raise cls(status, text)


# ---------------------------------------------------------------- framing
def leb128(n):
    if n < 0:
        raise ValueError("LEB128 length may not be negative")
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | 0x80 if n else b)
        if not n:
            return bytes(out)


def _read_leb128(sock_read):
    shift = 0
    val = 0
    while True:
        b = sock_read(1)
        if not b:
            raise Transient(ST_TRANSIENT, "connection closed mid length prefix")
        c = b[0]
        val |= (c & 0x7F) << shift
        if not c & 0x80:
            return val
        shift += 7
        if shift > 63:
            raise Unclassified(-1, "length prefix does not terminate")


def parse_handle(reply_text):
    """The ADMIT reply's block-id range -> {stream: (first, count)}.

    §4.5, landed at contract v2.0. Ids are dense PER STREAM (§2.1), so a handle
    is (stream, first, count) and there is no global id to collapse it into.
    A stream that produced no block is ABSENT from the result rather than
    present as zero, and so is every key when the server reports
    `range=unavailable` — a caller checks membership, it does not default."""
    out = {}
    for tok in reply_text.split():
        k, _, v = tok.partition("=")
        if k in ("structure", "payload") and "," in v:
            first, _, count = v.partition(",")
            try:
                first, count = int(first), int(count)
            except ValueError:
                continue
            if count > 0:
                out[k] = (first, count)
    return out


def encode_record(s, v, t):
    """One ADMIT record: u64le length over a US-joined UTF-8 triple."""
    payload = (s + US + v + US + t).encode("utf-8")
    return struct.pack("<Q", len(payload)) + payload


class Reply:
    __slots__ = ("status", "text")

    def __init__(self, status, text):
        self.status = status
        self.text = text

    @property
    def ok(self):
        return self.status == ST_OK

    def __repr__(self):
        return f"Reply({ST_NAMES.get(self.status, self.status)}, {self.text!r})"


# ---------------------------------------------------------------- client
class Client:
    """One TCP connection to a shim. Not thread-safe, deliberately:
    §5.6's write role is an exclusive lease, and a client that hides
    concurrency behind a lock is the shape that breaks §4.2."""

    def __init__(self, port, host="127.0.0.1", timeout=30.0):
        self.host, self.port, self.timeout = host, port, timeout
        try:
            self.sock = socket.create_connection((host, port), timeout=timeout)
        except OSError as e:
            raise Transient(ST_TRANSIENT, f"connect failed: {e}") from None
        self.sock.settimeout(timeout)
        self._buf = b""

    # -- raw i/o
    def _recv_exact(self, n):
        while len(self._buf) < n:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                raise Transient(ST_TRANSIENT,
                                f"no reply within {self.timeout}s") from None
            except OSError as e:
                raise Transient(ST_TRANSIENT, f"recv failed: {e}") from None
            if not chunk:
                raise Transient(ST_TRANSIENT, "server closed the connection")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def _call(self, body):
        try:
            self.sock.sendall(leb128(len(body)) + body)
        except OSError as e:
            raise Transient(ST_TRANSIENT, f"send failed: {e}") from None
        return self._read_frame()

    def _read_frame(self):
        n = _read_leb128(self._recv_exact)
        frame = self._recv_exact(n)
        if not frame:
            raise Unclassified(-1, "empty reply frame")
        return Reply(frame[0], frame[1:].decode("utf-8", "replace"))

    def pending(self):
        """Bytes already received but not yet consumed. Non-zero after a
        desynchronising exchange; the arms use it to detect stream drift."""
        return len(self._buf)

    # -- verbs
    def query_raw(self, mask, s="", v="", t=""):
        body = bytes([OP_QUERY]) + f"{mask}{US}{s}{US}{v}{US}{t}".encode("utf-8")
        return self._call(body)

    def consume_results(self, head_text):
        """Read and discard the result frames a QUERY head announced. A raw
        caller MUST do this or the next reply it reads is a stale triple."""
        try:
            n = int(head_text.strip())
        except ValueError:
            return 0
        for _ in range(n):
            self._read_frame()
        return n

    def query(self, mask, s="", v="", t=""):
        """-> list of (s, v, t). Order is the server's; callers compare as sets.

        The declared count is used to size the read and is then checked against
        what actually arrived. A mismatch is raised, never trimmed: a silent
        trim is how a framing defect survives a green test."""
        head = self.query_raw(mask, s, v, t)
        if not head.ok:
            _raise(head.status, head.text)
        try:
            n = int(head.text.strip())
        except ValueError:
            raise Unclassified(-1,
                f"query head frame is not a count: {head.text!r}") from None
        out = []
        for i in range(n):
            fr = self._read_frame()
            if not fr.ok:
                _raise(fr.status, fr.text)
            parts = fr.text.split(US)
            if len(parts) != 3:
                raise Unclassified(-1,
                    f"result frame {i} carries {len(parts)} fields, not 3: "
                    f"{fr.text!r}")
            out.append(tuple(parts))
        return out

    def rebuild_raw(self):
        return self._call(bytes([OP_REBUILD]))

    def rebuild(self):
        r = self.rebuild_raw()
        if not r.ok:
            _raise(r.status, r.text)
        return r.text.strip()

    def admit_raw(self, triples, count=None):
        n = len(triples) if count is None else count
        body = bytes([OP_ADMIT]) + leb128(n)
        for tr in triples:
            body += encode_record(*tr)
        return self._call(body)

    def admit(self, triples, count=None):
        r = self.admit_raw(triples, count)
        if not r.ok:
            _raise(r.status, r.text)
        return r.text

    def admit_handle(self, triples, count=None):
        """-> {stream: (first, count)} for the blocks this batch produced.

        An empty dict is a legitimate answer only if the server reported
        `range=unavailable`; every successful admission produces at least one
        block. See parse_handle."""
        return parse_handle(self.admit(triples, count))

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()
