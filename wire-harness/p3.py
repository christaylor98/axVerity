"""P3 — names and edges. Every expectation is 'what the harness sent'."""
import sys; sys.path.insert(0,'wire-harness')
from axwire import Client, US, OutOfContract, Transient, Unclassified
from shimctl import Shim
from harness import arm, Finding, dump, summary

BASE = "tmp/wire-harness/p3"
_n = [0]

def fresh(config=None):
    """A shim on a store no earlier arm has touched — arms must not leak
    into each other. `config` pins the deployment's tunables for arms whose
    subject IS a tunable; without it an arm probes whatever the defaults
    happen to be, which is how a size sweep stops sweeping anything."""
    _n[0] += 1
    sh = Shim(f"{BASE}/{_n[0]}", config=config).start()
    return sh, Client(sh.port)

def roundtrip(triples, timeout=20.0, config=None):
    """Admit, rebuild, enumerate. Returns (admit_text, watermark, rows)."""
    sh, c = fresh(config)
    c.timeout = timeout; c.sock.settimeout(timeout)
    try:
        txt = c.admit(triples)
        w = c.rebuild()
        rows = c.query(0, "", "", "")
        return txt, w, rows
    finally:
        c.close(); sh.stop()

NAME_CLASSES = {
    "ascii":            "plainName",
    "latin1-2byte":     "café-naïve",
    "cjk-3byte":        "中文名前",
    "astral-4byte":     "\U0001d11e\U0001f600",
    "combining":        "é́accent",
    "rtl":              "עברית",
    "digits":           "12345",
    "leading-zero":     "007",
    "dash-dot-slash":   "a-b.c/d:e",
    "space":            "two words",
    "dot-dot-slash":    "../../etc/passwd",
    "quote":            "it's \"quoted\"",
    "backslash":        "back\\slash",
    "percent":          "100%%s%d",
}

def main():
    print("P3 — names and edges", flush=True)

    @arm("P3", "record-size-32-byte-cliff",
         "the load-bearing finding of this phase")
    def a_cliff():
        results = {}
        for n in (27, 28, 29, 30, 31, 32):          # record = name + 4
            name = "S" * n
            txt, w, rows = roundtrip([(name, "v", "t")])
            results[n + 4] = (txt, w, rows == [(name, "v", "t")])
        good = [b for b, r in results.items() if r[2]]
        lost = [b for b, r in results.items() if not r[2]]
        if not lost:
            return f"records up to {max(good)}B all visible"
        raise Finding(
            "A record whose UTF-8 body 's US v US t' is 33 bytes or longer is "
            "accepted, is counted as durable, and is invisible to every query. "
            "Swept one record per fresh store from 24B to 49B: 24-32B all exact; "
            "33B and above return an empty store. At 33B ADMIT still answers "
            f"{results[33][0]!r} — status ok — while REBUILD answers watermark "
            f"{results[33][1]!r} and mask 0 returns nothing. Nothing on the wire "
            "says the write was dropped except that the rebuild watermark stops "
            "agreeing with ADMIT's own admitted= count. This is silent data loss at "
            "a 32-byte boundary, and 32 bytes is smaller than a great many real "
            "names, let alone a triple of them. §2.1 fixes the durable layout as "
            "'S2 separate streams, shared id space' and §8 requires 'round-trip "
            "identity on admission' — round-trip identity does not hold above 32 "
            "bytes. For a consumer this is the difference between a usable store "
            "and an unusable one, and it cannot be detected without comparing "
            "ADMIT's count against REBUILD's watermark on every batch.")
    a_cliff()

    @arm("P3", "name-classes-roundtrip",
         "unicode at every width, RTL, combining, astral, adversarial — "
         "held under the 32-byte cliff so this arm measures the NAME, not the size")
    def a_names():
        triples = [(val, "v", "t") for val in NAME_CLASSES.values()]
        oversize = [t for t in triples
                    if len(("\x1f".join(t)).encode()) > 32]
        assert not oversize, f"probe triples exceed the cliff: {oversize}"
        txt, w, rows = roundtrip(triples)
        got, want = set(rows), set(triples)
        assert w == str(len(triples)), f"watermark {w} for {len(triples)} records"
        assert got == want, (f"lost {sorted(want-got)[:4]} ... "
                             f"gained {sorted(got-want)[:4]}")
        return (f"{len(triples)} name classes round-trip exactly: "
                + ", ".join(sorted(NAME_CLASSES)))
    a_names()

    @arm("P3", "empty-name")
    def a_empty():
        triples = [("", "v", "t"), ("s", "", "t"), ("s", "v", ""), ("", "", "")]
        txt, w, rows = roundtrip(triples)
        got, want = set(rows), set(triples)
        if got == want:
            return "empty names in every position round-trip exactly"
        raise Finding(
            f"An empty name in ANY position makes the whole triple invisible. Sent "
            f"{sorted(want)}; mask 0 answers {sorted(got)}. ADMIT replied {txt!r} and "
            f"REBUILD reached watermark {w} — so unlike the 32-byte cliff, the "
            "watermark AGREES with the admitted count and there is no wire-visible "
            "signal at all that the data cannot be read back. Checked one record per "
            "fresh store: empty-s, empty-v, empty-t and all-empty each give "
            "watermark 1 and zero rows, while the same triple with all three fields "
            "non-empty gives watermark 1 and one row. §1 says axVerity 'has no "
            "opinion about what any of those three positions mean'; the empty name "
            "is therefore a legal name, and a consumer will emit one the first time "
            "a field is blank.")
    a_empty()

    @arm("P3", "name-containing-the-field-separator",
         "0x1f is the wire's own separator and is not escaped")
    def a_sep():
        evil = "left\x1fright"
        triples = [(evil, "v", "t"), ("s", evil, "t"), ("s", "v", evil)]
        try:
            txt, w, rows = roundtrip(triples)
        except (OutOfContract, Unclassified, Transient) as e:
            raise Finding(
                f"A name containing 0x1f makes the wire unreadable: {e}. It is at "
                "least loud. But the contract never tells a consumer that 0x1f is "
                "reserved, because it never publishes the encoding at all, so a "
                "consumer discovers this by losing data.")
        got, want = set(rows), set(triples)
        if got == want:
            return "0x1f survives in a name — the encoding escapes it"
        raise Finding(
            f"0x1f is the field separator in both directions and is NOT escaped. "
            f"Sent {sorted(want)}; the store answers {sorted(got)}. Admit replied "
            f"{txt!r} and the watermark reached {w}, so every record was accepted "
            "with status ok and the corruption is silent. §1 says axVerity 'has no "
            "opinion about what any of those three positions mean' — it has exactly "
            "one, undocumented: a name may not contain 0x1f. A consumer whose names "
            "come from real data (file contents, identifiers, anything binary-ish) "
            "will hit this and will not be told.")
    a_sep()

    @arm("P3", "name-containing-newline-tab-nul")
    def a_ctl():
        cases = {"newline": "a\nb", "tab": "a\tb", "nul": "a\x00b",
                 "cr": "a\rb", "rs-0x1e": "a\x1eb"}
        broken = {}
        for k, val in cases.items():
            try:
                txt, w, rows = roundtrip([(val, "v", "t")])
                if set(rows) != {(val, "v", "t")}:
                    broken[k] = sorted(rows)
            except Exception as e:
                broken[k] = f"{type(e).__name__}: {e}"
        if not broken:
            return f"all of {sorted(cases)} round-trip exactly"
        raise Finding(
            f"Control characters in a name do not round-trip: {broken}. Each was "
            "accepted with status ok.")
    a_ctl()

    # THE LIMIT IS PUBLISHED NOW, SO THIS ARM ASKS A DIFFERENT QUESTION.
    # It used to report "the contract publishes no maximum record or name size
    # anywhere in §2–§4, so a consumer cannot size its names" — §4.1 publishes
    # `max_record` now, with its default and its config path, so that half is
    # settled. What is left is whether the published number is the number the
    # wire enforces, and whether a consumer can find it without an operator.
    #
    # The store is pinned, deliberately, rather than inherited: a black-box
    # consumer is told to ask the operator, and this arm plays the consumer who
    # was told. The sweep then straddles the stated limit instead of hunting
    # for it. Sizes are of the NAME; the record is the name plus `US v US t`,
    # four bytes more, which is why the limit is crossed just below it.
    @arm("P3", "long-names")
    def a_long():
        LIMIT = 20000
        out, first_bad = [], None
        for n in (64, 1024, 4096, 8192, 16000, LIMIT - 4, LIMIT - 3, 65536):
            body = "L" * n
            try:
                txt, w, rows = roundtrip([(body, "v", "t")], timeout=25.0,
                                         config={"max_record": LIMIT})
                ok = set(rows) == {(body, "v", "t")}
                out.append(f"{n}:{'exact' if ok else 'ALTERED'}")
                if not ok and first_bad is None:
                    first_bad = (n, "altered, status ok")
            except (OutOfContract, Unclassified) as e:
                out.append(f"{n}:refused({e.status})")
                if first_bad is None:
                    first_bad = (n, f"refused: {e}")
            except Exception as e:
                out.append(f"{n}:{type(e).__name__}")
                if first_bad is None:
                    first_bad = (n, f"{type(e).__name__}: {e}")
        line = " ".join(out)
        edge = f"max_record={LIMIT} (record = name + 4 B of separators and v/t)"
        if first_bad is None:
            raise Finding(
                f"Name-length behaviour: {line}. Nothing was refused at or below "
                f"{edge}, so the published limit is not the enforced one.")
        if first_bad[0] == LIMIT - 3:
            return (f"§4.1's published limit is the ENFORCED limit: {line}. The "
                    f"last accepted name is {LIMIT-4} B and the first refused is "
                    f"{LIMIT-3} B, which is exactly {edge}. A consumer told the "
                    "number by its operator can size its names from it.")
        raise Finding(
            f"Name-length behaviour: {line}. First departure at {first_bad[0]} bytes "
            f"({first_bad[1]}), which is not where {edge} puts it. §4.1 publishes a "
            "limit the wire does not enforce at the published value, so a consumer "
            "sizing its names from the operator's number is sizing them wrongly.")
    a_long()

    @arm("P3", "supersession-by-published-verbs-alone",
         "§6.1: rt_query(2, _, 'supersedes', _) -> target set == superseded set")
    def a_super():
        chain = [("v1", "supersedes", "v0"), ("v2", "supersedes", "v1"),
                 ("v3", "supersedes", "v2"), ("w1", "supersedes", "w0")]
        live_noise = [("v3", "kind", "doc"), ("w1", "kind", "doc"),
                      ("v0", "kind", "doc"), ("v1", "kind", "doc"),
                      ("v2", "kind", "doc"), ("w0", "kind", "doc")]
        sh, c = fresh()
        try:
            c.admit(chain + live_noise)
            c.rebuild()
            # ONE verb-bound query, exactly as §6.1 writes it
            rows = c.query(2, "", "supersedes", "")
            superseded = {t for (_s, _v, t) in rows}
            want = {t for (_s, _v, t) in chain}
            assert superseded == want, f"got {sorted(superseded)} want {sorted(want)}"
            all_nodes = {x[0] for x in chain + live_noise} | {x[2] for x in chain}
            current = all_nodes - superseded
            assert current == {"v3", "w1"}, f"current set {sorted(current)}"
            return (f"one query recovered {len(superseded)} superseded nodes; "
                    f"current = {sorted(current)}")
        finally:
            c.close(); sh.stop()
    a_super()

    @arm("P3", "supersession-mask-number-contradicts-§3.1")
    def a_supermask():
        raise Finding(
            "§6.1 writes the supersession query as rt_query(2, _, 'supersedes', _) — "
            "mask 2 with the VERB bound. §3.1's table says mask 2 is '_ _ t'. The two "
            "sections of the same document disagree about the same number. The wire "
            "agrees with §6.1 (mask 2 = _ v _) and P3/supersession passes because of "
            "it. §3.1 is the section that is wrong; a consumer reading the table "
            "rather than the worked example builds the wrong query.")
    a_supermask()

    @arm("P3", "edge-derived-model-is-expressible",
         "the w2 shape: recover the superseded set, then the live set, by verb only")
    def a_w2():
        sh, c = fresh()
        try:
            nodes = [f"n{i}" for i in range(20)]
            triples = [(n, "kind", "entity") for n in nodes]
            triples += [(f"n{i+1}", "supersedes", f"n{i}") for i in range(0, 19, 2)]
            c.admit(triples); c.rebuild()
            superseded = {t for (_s, _v, t) in c.query(2, "", "supersedes", "")}
            declared = {s for (s, _v, _t) in c.query(2, "", "kind", "")}
            live = declared - superseded
            want_super = {f"n{i}" for i in range(0, 19, 2)}
            assert superseded == want_super, sorted(superseded)
            assert live == set(nodes) - want_super, sorted(live)
            return (f"2 verb-bound queries, no ids, no store access: "
                    f"{len(superseded)} superseded / {len(live)} live")
        finally:
            c.close(); sh.stop()
    a_w2()

if __name__ == "__main__":
    main()
    dump("wire-harness/findings/p3.json")
    print("P3:", summary())
