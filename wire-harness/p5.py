"""P5 — adversarial. Characterisation, not remediation."""
import sys, time, threading, socket, struct; sys.path.insert(0,'wire-harness')
from axwire import (Client, US, leb128, OutOfContract, Transient, Unclassified,
                    encode_record)
from shimctl import Shim
from harness import arm, Finding, dump, summary

BASE = "tmp/wire-harness/p5"
SMALL = [("a1","p","x1"),("a2","p","x2"),("a3","q","x3")]

def main():
    print("P5 — adversarial", flush=True)

    # ---------------------------------------------------------- status classes
    @arm("P5", "status-classes-reachable",
         "§5.8: ok / out-of-contract / transient must not share a code")
    def a_status():
        # max_record pinned so "oversize" MEANS oversize. This probe used to
        # send a 20,000-byte record and inherit whatever the deployment's limit
        # was; once that reached 65536 the record became ORDINARY and the map
        # recorded 'oversize-record': 0 — an arm about status classes silently
        # not exercising a status class.
        sh = Shim(f"{BASE}/status", config={"max_record": 4096}).start()
        c = Client(sh.port)
        seen = {}
        try:
            # v2.0: opcode 4 is gone, so the cheap always-answers probe is an
            # unassigned opcode, and the ok probe has to earn its freshness.
            c.admit(SMALL); c.rebuild()
            seen["ok/REBUILD"] = c.rebuild_raw().status
            q = c.query_raw(0, "", "", "")
            seen["ok/QUERY"] = q.status
            if q.ok:
                c.consume_results(q.text)
            seen["stale/QUERY"] = (c.admit_raw(SMALL).status,
                                   c.query_raw(0, "", "", "").status)[1]
            seen["unknown-opcode"] = c._call(bytes([200])).status
            seen["bad-admit-count"] = c._call(bytes([3])).status
            seen["lying-count"] = c.admit_raw(SMALL, count=99).status
            seen["oversize-record"] = c.admit_raw([("Z"*8000, "v", "t")]).status
            seen["empty-store-REBUILD"] = c.rebuild_raw().status
        finally:
            c.close()
        # transient: the only way to reach it is to destroy the connection
        c2 = Client(sh.port, timeout=2.0)
        c2.admit(SMALL); c2.rebuild()
        sh.kill()
        try:
            c2.query(0); seen["killed-server"] = "no error"
        except Transient as e:
            seen["killed-server"] = f"connection-level Transient ({e.text})"
        except Exception as e:
            seen["killed-server"] = f"{type(e).__name__}"
        c2.close()
        codes = {v for k, v in seen.items() if isinstance(v, int)}
        raise Finding(
            f"Reachable status bytes: {sorted(codes)}. Full map: {seen}. Only two "
            "codes exist on the wire — 0 ok and 1 for everything the client got "
            "wrong. There is no transient status byte: the only transient condition "
            "reachable is the socket dying, which a client learns from the socket, "
            "not from the protocol. That satisfies §5.8's 'they must not share an "
            "error code' by accident rather than by design — and it means a server "
            "that wants to report a recoverable, in-band condition (busy, rebuild in "
            "progress, writer unavailable) has no code to report it with, and would "
            "have to reuse 1, which §7.6 forbids the consumer from retrying. No "
            "server-fault class is distinguishable either: an internal failure and a "
            "malformed client request are the same byte.")
    a_status()

    # ---------------------------------------------------------- availability
    @arm("P5", "ADMIT-with-count-zero-wedges-the-server",
         "one client, one frame, no reply ever again — for every connection")
    def a_wedge():
        sh = Shim(f"{BASE}/wedge").start()
        c = Client(sh.port, timeout=4.0)
        try:
            c.admit(SMALL); c.rebuild()
            assert set(c.query(0)) == set(SMALL)
            hung = False
            try:
                c._call(bytes([3]) + leb128(0))       # ADMIT, count = 0
            except Transient:
                hung = True
            c.close()
            # is the SERVER still alive for anyone else?
            others = []
            for i in range(2):
                c2 = Client(sh.port, timeout=3.0)
                try:
                    c2._call(bytes([200]))
                    others.append("answered")
                except Transient:
                    others.append("no reply")
                finally:
                    c2.close()
            if not hung and all(o == "answered" for o in others):
                return "count=0 is answered and the server stays available"
            raise Finding(
                f"ADMIT with count=0 never replies (client timed out: {hung}) and the "
                f"server stops answering EVERY subsequent connection ({others}). The "
                "process stays alive and the port stays open, so a supervisor sees a "
                "healthy server. One frame from one client — two bytes of body — "
                "denies service to every reader and writer until the process is "
                "restarted. §4.1 says 'a batch of one is legal'; it does not say a "
                "batch of zero is fatal. §5.8 has no code for this and the client "
                "gets no answer at all, so a consumer cannot even tell it caused it.")
        finally:
            sh.stop()
    a_wedge()

    @arm("P5", "truncated-frame-is-survived",
         "a client that promises a frame, sends part of it and dies")
    def a_trunc():
        sh = Shim(f"{BASE}/trunc").start()
        try:
            s = socket.create_connection(("127.0.0.1", sh.port), timeout=3)
            s.sendall(bytes([50]) + b"\x01abc")       # promises 50, sends 4
            s.close()                                  # and vanishes
            out = []
            for i in range(2):
                c = Client(sh.port, timeout=3.0)
                try:
                    c._call(bytes([200])); out.append("answered")
                except Transient:
                    out.append("no reply")
                finally:
                    c.close()
            if all(o == "answered" for o in out):
                return "a truncated frame is survived; later connections answered"
            raise Finding(
                f"A client that promises a 50-byte frame, sends 4 and disconnects "
                f"leaves the server unable to answer anyone: {out}. There is no read "
                "timeout and no per-connection isolation, so any client crash mid-send "
                "is a whole-server outage. §5.5 permits N concurrent readers over one "
                "server; one of them dying at the wrong moment takes the rest down.")
        finally:
            sh.stop()
    a_trunc()

    # ---------------------------------------------------------- concurrency
    @arm("P5", "second-concurrent-connection",
         "ONE_CONNECTION_AT_A_TIME_IS_A_FINDING_NOT_A_DESIGN")
    def a_conc():
        sh = Shim(f"{BASE}/conc").start()
        try:
            a = Client(sh.port, timeout=8.0)
            a.admit(SMALL); a.rebuild()
            t0 = time.time()
            b = socket.create_connection(("127.0.0.1", sh.port), timeout=5)
            connect_s = time.time() - t0
            # P0-B: this was opcode 4 (DURABLE) and survived the v2.0 migration
            # unmigrated — the only live call site left. 200 is unassigned and
            # always answers, which is what a liveness probe needs.
            b.sendall(leb128(1) + bytes([200]))
            b.settimeout(3.0)
            served_while_open = True
            try:
                b.recv(64)
            except socket.timeout:
                served_while_open = False
            if served_while_open:
                a.close(); b.close()
                return (f"a second connection is served concurrently "
                        f"(connect {connect_s:.3f}s)")
            a.close()
            b.settimeout(5.0)
            t1 = time.time()
            try:
                got = b.recv(64)
                delay = time.time() - t1
                tail = (f"and is served {delay:.3f}s after the first connection "
                        f"closes, with {got!r}")
            except socket.timeout:
                tail = "and is still not served 5s after the first closes"
            b.close()
            # how many will the kernel hold before anyone is refused?
            c0 = Client(sh.port, timeout=5.0); c0._call(bytes([200]))
            held = []
            for i in range(8):
                try:
                    held.append(socket.create_connection(
                        ("127.0.0.1", sh.port), timeout=2))
                except OSError:
                    break
            n_open = len(held) + 1
            c0.close()
            for x in held:
                x.close()
            raise Finding(
                "The shim serves exactly ONE connection at a time. A second "
                f"connection's connect() returns immediately ({connect_s:.3f}s) and "
                "the client may send a request, but it receives nothing at all while "
                f"the first connection is open — {tail}. {n_open} connections were "
                "held open simultaneously and none was refused; they simply queue, "
                "invisibly, forever. §5.4 publishes 'READ — many concurrent "
                "connections permitted' and §5.5 publishes 'N readers over one server "
                "process sharing one RAM tier ... read connections may be pooled, "
                "multiplexed, and load-balanced freely'. None of that is true here. "
                "A serialised server is a legitimate design and this harness does not "
                "call it broken — but it is not the design the contract publishes, "
                "and the failure mode it produces is the worst available shape: not a "
                "refusal, not an error, not a queue the client can see, but silence. "
                "A pooled consumer — which §5.5 explicitly invites — hangs, and its "
                "first symptom is a timeout with no message.")
        finally:
            sh.stop()
    a_conc()

    @arm("P5", "an-idle-open-connection-blocks-every-other-client")
    def a_idle():
        sh = Shim(f"{BASE}/idle").start()
        try:
            seed = Client(sh.port, timeout=5.0)
            seed.admit(SMALL); seed.rebuild(); seed.close()
            idle = socket.create_connection(("127.0.0.1", sh.port), timeout=5)
            c = Client(sh.port, timeout=3.0)
            try:
                c._call(bytes([200]))
                blocked = False
            except Transient:
                blocked = True
            finally:
                c.close()
            idle.close()
            # LIVENESS IS THE QUESTION, so the assertion is that a reply came
            # back — not which reply. Asserting status == 1 here would make a
            # future status-0 for unknown opcodes read as "not recovered", which
            # is a different fact than the one this arm reports.
            #
            # `is not None` was the first attempt and CANNOT FAIL: _call either
            # returns a Reply or raises. A vacuous assertion recorded as PASS is
            # the defect RATCHET_TIGHTENS_ONLY exists to stop, reached from the
            # other side. The raise is the negative case, so it has to be caught.
            c2 = Client(sh.port, timeout=5.0)
            try:
                c2._call(bytes([200]))
                recovered = True
            except Transient:
                recovered = False
            finally:
                c2.close()
            if not blocked:
                return "an idle connection does not block others"
            raise Finding(
                "A client that opens a connection and never sends a byte stops the "
                "server answering anyone else, indefinitely — no timeout, no refusal, "
                f"no error. Service resumed the moment the idle socket closed "
                f"(recovered: {recovered}). §5.11 T6 leaves lease expiry open and "
                "recommends 'explicit release plus disconnect detection only, no "
                "timeout, until a real deadlock is observed'. This is that deadlock, "
                "and it needs no lease and no writer to reach: any connection, held "
                "by any client, read or write, is enough. On an untrusted network "
                "(§10 item 11) it is a one-line denial of service.")
        finally:
            sh.stop()
    a_idle()

    @arm("P5", "two-WRITE-connections-are-accepted-then-serialised",
         "§4.2 exactly one writer; §5.6 a second WRITE is refused at handshake")
    def a_twowriters():
        sh = Shim(f"{BASE}/two").start()
        try:
            n = 12
            left  = [(f"L{i}", "p", f"x{i}") for i in range(n)]
            right = [(f"R{i}", "q", f"y{i}") for i in range(n)]
            errs, order = [], []
            def w(batch, tag):
                try:
                    c = Client(sh.port, timeout=25.0)
                    order.append(f"{tag}-open")
                    for i in range(0, n, 3):
                        c.admit(batch[i:i+3])
                    order.append(f"{tag}-done")
                    c.close()
                except Exception as e:
                    errs.append(f"{tag}: {type(e).__name__}: {e}")
            t = [threading.Thread(target=w, args=(left, "L")),
                 threading.Thread(target=w, args=(right, "R"))]
            [x.start() for x in t]; [x.join(60) for x in t]
            c = Client(sh.port, timeout=25.0)
            wm = c.rebuild(); rows = set(c.query(0)); c.close()
            sent = set(left) | set(right)
            missing, extra = sent - rows, rows - sent
            raise Finding(
                "Two connections asked to write to one store at the same time and "
                f"neither was refused (errors: {errs or 'none'}). There is no LEASE "
                "verb on the wire (P1/LEASE-absent), so there is nothing to refuse "
                "with. What happens instead is that the second connection is accepted "
                "and then held until the first closes — the interleaving observed was "
                f"{order}. §5.6 rules out exactly this: a second WRITE must be "
                "'refused at handshake, not queued, not multiplexed, NOT "
                "accepted-then-serialised', and §5.6 explains why in the consumer's "
                "own terms — 'a consumer that pools writers finds out at connect "
                "time, loudly, on the first attempt, rather than discovering a "
                "corrupted block-id sequence later'. Here it finds out at no time and "
                "not loudly. Serialisation happens to have kept this run clean "
                f"(watermark {wm}, {len(rows)} rows, {len(missing)} missing, "
                f"{len(extra)} unsent) but that is a property of the accept loop, not "
                "a guarantee the contract can rest §4.2 on: it holds only while one "
                "server process is the only path to the store, and §5.5 explicitly "
                "permits 'multiple server processes over one store'. Two shims on one "
                "store is two writers with nothing between them.")
        finally:
            sh.stop()
    a_twowriters()

    @arm("P5", "reader-cannot-read-while-a-writer-holds-a-connection",
         "§5.5 / §10 item 9")
    def a_readwrite():
        sh = Shim(f"{BASE}/rw").start()
        try:
            w = Client(sh.port, timeout=25.0)
            w.admit(SMALL); w.rebuild()
            obs, errs = [], []
            def reader():
                # v2.0: the writer's admissions stale the projection, so this
                # read may legitimately be REFUSED. The arm asks whether a
                # reader is SERVED AT ALL while a writer holds a connection, so
                # any reply — ok or refusal — counts as served, and only silence
                # is the finding.
                try:
                    c = Client(sh.port, timeout=6.0)
                    r = c.query_raw(0)
                    if r.ok:
                        c.consume_results(r.text)
                    obs.append(r.status)
                    c.close()
                except Exception as e:
                    errs.append(f"{type(e).__name__}: {e}")
            th = threading.Thread(target=reader); th.start()
            for i in range(15):
                w.admit([(f"n{i}", "p", f"m{i}")])
            th.join(30)
            held_open_result = (obs, errs)
            w.close()                       # release, then the reader can work
            # G5 item 7 asked whether 3 -> 18 rows was a leaking fixture. It is
            # not: SMALL is 3 triples and the loop above admits 15 more DISTINCT
            # ones, so the store holds exactly 18. The old 3 was the STALE
            # projection — the query ran with no REBUILD after those 15 admits,
            # so it reported the pre-batch snapshot. The number is asserted here
            # rather than narrated, so a real leak would fail instead of reading
            # as a bigger number in a detail string.
            c = Client(sh.port, timeout=10.0)
            c.rebuild()
            after = len(c.query(0)); c.close()
            assert after == len(SMALL) + 15, (
                f"the store holds {after} rows, expected {len(SMALL) + 15} — "
                "QUERY answers a SET and every triple admitted here is distinct, "
                "so any other number means the fixture leaked state")
            if obs and not errs:
                return (f"a reader was served while a writer held its connection: "
                        f"reply statuses {obs}; after release {after} rows")
            raise Finding(
                "A reader could not be served at all while another connection was "
                f"open for writing: {held_open_result[1]}. §5.5 publishes 'N readers "
                "over one server process sharing one RAM tier' and §10 item 9 asks "
                "whether concurrent readers against a live-appending store observe "
                "torn state. That question cannot arise here, because concurrent "
                "readers do not exist: the second connection is not served until the "
                "first closes. §10 item 9 is therefore not answered by this build — "
                "it is made unreachable. Once the writer released its connection the "
                f"reader's query returned {after} rows.")
        finally:
            sh.stop()
    a_readwrite()

    # ---------------------------------------------------------- int_mod
    @arm("P5", "high-bit-payloads-across-record-boundaries",
         "T9 / the int_mod negative-remainder question, asked at the wire")
    def a_intmod():
        sh = Shim(f"{BASE}/intmod").start()
        c = Client(sh.port, timeout=30.0)
        try:
            # names whose UTF-8 carries bytes across the whole 0x80..0xFF range,
            # at every record length that fits under the 32-byte cliff, so a
            # record boundary lands at every alignment relative to an 8-byte read.
            hi = "".join(chr(0x80 + i) for i in range(0x40))      # 2-byte forms
            hi += "".join(chr(0x800 + 0x40 * i) for i in range(0x20))  # 3-byte
            hi += "".join(chr(0x10000 + 0x1000 * i) for i in range(0x10))  # 4-byte
            triples, k = [], 0
            for L in range(1, 13):
                for rep in range(4):
                    s = "".join(hi[(k + j) % len(hi)] for j in range(L)); k += 1
                    v = "".join(hi[(k + j) % len(hi)] for j in range(1 + rep)); k += 1
                    t = "".join(hi[(k + j) % len(hi)] for j in range(1 + (rep ^ 1))); k += 1
                    if len((s + US + v + US + t).encode()) <= 32:
                        triples.append((s, v, t))
            triples = list(dict.fromkeys(triples))
            assert len(triples) > 20, f"only {len(triples)} probes fit"
            c.admit(triples)
            wm = c.rebuild()
            rows = set(c.query(0))
            want = set(triples)
            missing, extra = want - rows, rows - want
            byte_hist = sorted({b for tr in triples
                                for b in (US.join(tr)).encode()})
            if not missing and not extra and wm == str(len(triples)):
                return (f"{len(triples)} records whose bodies span byte values "
                        f"0x{min(byte_hist):02x}..0x{max(byte_hist):02x} "
                        f"({len([b for b in byte_hist if b >= 0x80])} distinct bytes "
                        "with the top bit set) round-trip exactly at every record "
                        "length that fits. The int_mod negative-remainder defect is "
                        "NOT observable at the wire on this build.")
            raise Finding(
                f"High-bit payloads do not round-trip: {len(missing)} of "
                f"{len(triples)} missing, {len(extra)} unexpected, watermark {wm}. "
                f"Examples missing: {sorted(missing)[:3]}. Every probe body carries "
                "bytes with the top bit set at a record boundary, which is the shape "
                "the int_mod negative-remainder defect corrupts.")
        finally:
            c.close(); sh.stop()
    a_intmod()

    @arm("P5", "corpus-at-a-working-size",
         "T10 — the envelope a consumer actually needs")
    def a_scale():
        sh = Shim(f"{BASE}/scale").start()
        c = Client(sh.port, timeout=120.0)
        try:
            n = 3000
            triples = [(f"s{i}", ["p", "q", "r"][i % 3], f"t{i % 500}")
                       for i in range(n)]
            over = [x for x in triples if len(US.join(x).encode()) > 32]
            assert not over, "probe corpus crosses the 32-byte cliff"
            t0 = time.time(); c.admit(triples); t1 = time.time()
            wm = c.rebuild(); t2 = time.time()
            rows = set(c.query(0)); t3 = time.time()
            want = set(triples)
            assert wm == str(n), f"watermark {wm} for {n} sent"
            assert rows == want, (f"{len(want-rows)} missing, {len(rows-want)} extra")
            # a bound query at scale
            sub = set(c.query(4, "", "", "t7"))
            wsub = {x for x in triples if x[2] == "t7"}
            assert sub == wsub, f"{len(sub)} vs {len(wsub)}"
            return (f"{n} triples: admit {t1-t0:.2f}s, rebuild {t2-t1:.2f}s, "
                    f"enumerate {t3-t2:.2f}s, exact; a _ _ t query at scale exact "
                    f"({len(wsub)} rows)")
        finally:
            c.close(); sh.stop()
    a_scale()

if __name__ == "__main__":
    main()
    dump("wire-harness/findings/p5.json")
    print("P5:", summary())
