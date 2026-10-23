"""P1 — the client library: connect, the verbs, the status classes.
Nothing about data is asserted here. What IS asserted is that the surface
the contract publishes is the surface the wire presents."""
import sys; sys.path.insert(0,'wire-harness')
from wp import Probe, frame, leb, show
from axwire import Client, OutOfContract, Transient, Unclassified, US
from shimctl import Shim
from harness import arm, Finding, RESULTS, dump, summary

ROOT = "tmp/wire-harness/p1"

def main():
    sh = Shim(ROOT).start()
    try:
        run(sh)
    finally:
        sh.stop()

def run(sh):
    print("P1 — client library and published surface", flush=True)

    @arm("P1", "connect", "a consumer can open a connection")
    def a_connect():
        c = Client(sh.port); c.close()
        return f"connected on port {sh.port}"
    a_connect()

    @arm("P1", "no-server-greeting",
         "§5.9 says the wire version is negotiated at handshake")
    def a_greet():
        p = Probe(sh.port, timeout=1.0)
        g = p.drain(); p.close()
        if g:
            return f"server greets with {g!r}"
        raise Finding(
            "The server sends nothing on connect and accepts operations with no "
            "handshake at all. §5.4 establishes the ROLE at handshake and §5.9 "
            "negotiates the PROTOCOL VERSION at handshake. Neither exists on the "
            "wire. A client cannot discover the server's major version, and a "
            "server cannot refuse a major version it does not implement (§5.9).")
    a_greet()

    @arm("P1", "three-verbs-reachable", "§5.7 ops, minus LEASE and DURABLE")
    def a_verbs():
        c = Client(sh.port)
        seen = {}
        for op, name in ((1, "QUERY"), (2, "REBUILD"), (3, "ADMIT")):
            r = c._call(bytes([op]) + (b"0" + US.encode()*3 if op == 1 else b""))
            seen[name] = (r.status, r.text[:40])
        gone = c._call(bytes([4]))
        c.close()
        assert gone.status == 1 and gone.text.startswith("UNKNOWN opcode"), (
            f"opcode 4 still answers something: {gone.status} {gone.text!r} — "
            "DURABLE was removed at contract v2.0 and must not be reachable")
        seen["4 (was DURABLE)"] = (gone.status, gone.text[:40])
        return "; ".join(f"{k} -> status {v[0]} {v[1]!r}" for k, v in seen.items())
    a_verbs()

    @arm("P1", "LEASE-absent",
         "§5.6: the exclusive write lease is the structural enforcement of §4.2")
    def a_lease():
        # every opcode outside 1..3 answers UNKNOWN opcode; there is no fourth verb
        unknown = []
        for op in [0, 4, 5, 6, 7, 8, 76, 108]:
            c = Client(sh.port)
            r = c._call(bytes([op])); c.close()
            if r.status == 1 and r.text.startswith("UNKNOWN opcode"):
                unknown.append(op)
        if len(unknown) != 8:
            return f"some of {unknown} were not UNKNOWN — a fourth verb may exist"
        raise Finding(
            "The op set is exactly {1 QUERY, 2 REBUILD, 3 ADMIT}. "
            "Every other opcode answers 'UNKNOWN opcode N'. LEASE (§5.7) does not "
            "exist on the wire. §5.6 makes the exclusive write lease the mechanism "
            "that 'makes §4.2 unbreakable over the wire instead of merely stated' — "
            "so the single-writer rule is, on this wire, merely stated. Nothing "
            "refuses a second writer at handshake; see P5/second-writer.")
    a_lease()

    @arm("P1", "status-classes-encoding",
         "§5.8 names two classes normatively but does not encode them")
    def a_status():
        # THE PROBE HAS TO REACH status 0. When opcode 4 went away this became
        # a bare REBUILD, which on a fresh store answers NOSTORE — so the arm
        # recorded "ok=1" and then, two sentences later, "the mapping used by
        # this harness — 0 ok, 1 out-of-contract". It contradicted its own
        # evidence while its text stayed correct. Admit first, so REBUILD has a
        # store to rebuild and the ok class is genuinely observed.
        c = Client(sh.port)
        c.admit([("p1status", "p1v", "p1t")])
        ok = c._call(bytes([2])).status          # REBUILD over a written store
        bad = c._call(bytes([200])).status
        c.close()
        assert ok == 0, f"the ok probe observed status {ok}, so this arm's evidence is broken again"
        assert bad == 1, f"the out-of-contract probe observed status {bad}"
        raise Finding(
            f"Observed status bytes: ok={ok}, malformed/unknown-op={bad}. §5.8 makes "
            "the ok / out-of-contract / transient distinction normative but publishes "
            "no encoding for it, so a consumer cannot write the discriminator §7.6 "
            "obliges it to write ('treat an out-of-contract error as a bug, never as "
            "a retry') without reverse-engineering the byte. The mapping used by this "
            "harness — 0 ok, 1 out-of-contract — was recovered from the socket, not "
            "read from the contract.")
    a_status()

    @arm("P1", "framing-is-two-encodings",
         "§5.11 T5: 'One encoding in the project, not two'")
    def a_framing():
        raise Finding(
            "Two length encodings are in use on one wire. The op/reply frame is a "
            "LEB128 varint length (§5.11 T5, F1v). The records inside an ADMIT body "
            "are framed with a FIXED 8-BYTE LITTLE-ENDIAN length — verified by "
            "sweeping u8/u16le/u16be/u32le/u32be/u64le/u64be/newline/NUL/raw against "
            "the server: only u64-little-endian is accepted, every other framing "
            "answers 'MALFORMED admit body is not a framed record stream'. T5 chose "
            "one encoding precisely to avoid this, and neither encoding is published.")
    a_framing()

    @arm("P1", "record-and-field-encoding-unpublished",
         "what a record IS on the wire")
    def a_rec():
        raise Finding(
            "The contract never says what an ADMIT record contains. It is "
            "UTF-8 s + 0x1f + v + 0x1f + t — recovered by admitting eight candidate "
            "encodings (3xLEB128, newline, 0x1f, space, tab, NUL, 3xu64, "
            "count+3xLEB128) into one store and seeing which one QUERY could "
            "afterwards see: only the 0x1f form parsed. The other seven were accepted "
            "by ADMIT with 'ok admitted=1' and then were invisible to every query — "
            "silently swallowed, never rejected. A consumer that guesses wrong loses "
            "data with an ok on the wire.")
    a_rec()

    @arm("P1", "ADMIT-returns-a-block-id-range-per-stream",
         "§4.5 / §5.7: ADMIT count,records -> block id range")
    def a_admitret():
        # Through contract v1.0 this was a FINDING: §5.7 published "ADMIT ->
        # block id range" and the wire returned a record count and a byte count,
        # so §4.5's two-phase write had nothing to read back.
        #
        # It landed at v2.0 as ONE RANGE PER STREAM, which is what exists: ids
        # are dense per STREAM (§2.1), structure/block-N and payload/block-N
        # both exist and differ, and no global id was ever available to return.
        from axwire import parse_handle
        c = Client(sh.port)
        txt = c.admit([("p1s", "p1v", "p1t")])
        h = parse_handle(txt)
        # A second, larger batch: the range must MOVE, and it must not restart.
        txt2 = c.admit([("p1s2", "p1v2", "p1t2"), ("z" * 40, "z" * 40, "z" * 40)])
        h2 = parse_handle(txt2)
        c.close()
        assert h, f"no block-id range in {txt!r} — §4.5 is unimplemented again"
        assert "structure" in h, f"a small triple produced no structure block: {txt!r}"
        assert h["structure"][1] == 1, f"a one-record batch claimed {h['structure'][1]} blocks: {txt!r}"
        assert "payload" not in h, (
            f"a batch with no oversize record reported a payload range: {txt!r} — "
            "a stream that produced nothing must carry count 0, and count 0 must "
            "not read as block 0")
        assert "payload" in h2, f"a 120-byte record produced no payload block: {txt2!r}"
        sf, sc = h["structure"]; sf2, sc2 = h2["structure"]
        assert sf2 == sf + sc, (
            f"structure range did not advance: {h} then {h2} — the second batch's "
            "first id must be the first batch's first + count")
        return (f"ADMIT -> {txt!r} then {txt2!r}; parsed {h} then {h2}. The range "
                "advances by exactly the block count and an empty stream is absent, "
                "not zero")
    a_admitret()

if __name__ == "__main__":
    main()
    dump("wire-harness/findings/p1.json")
    print("P1:", summary())
