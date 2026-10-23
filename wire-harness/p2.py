"""P2 — round trip. THE_CLIENT_KNOWS_ONLY_WHAT_IT_SENT: every expectation
below is computed from the harness's own record of what it admitted."""
import sys; sys.path.insert(0,'wire-harness')
from axwire import Client, US, OutOfContract
from shimctl import Shim
from harness import arm, Finding, dump, summary

ROOT = "tmp/wire-harness/p2"

CORPUS = [
    ("alpha", "kind",      "module"),
    ("alpha", "owns",      "beta"),
    ("alpha", "owns",      "gamma"),
    ("beta",  "kind",      "function"),
    ("beta",  "calls",     "gamma"),
    ("gamma", "kind",      "function"),
    ("gamma", "calls",     "beta"),
    ("delta", "kind",      "module"),
    ("delta", "owns",      "epsilon"),
    ("epsilon", "kind",    "function"),
    ("epsilon", "calls",   "beta"),
    ("zeta",  "supersedes","alpha"),
]

# the harness's own oracle, computed only from CORPUS
def expect(pattern, s, v, t):
    def m(x):
        return ((pattern[0] == "_" or x[0] == s) and
                (pattern[1] == "_" or x[1] == v) and
                (pattern[2] == "_" or x[2] == t))
    return {x for x in CORPUS if m(x)}

PROBES = [("alpha","owns","beta"), ("beta","kind","function"),
          ("gamma","calls","beta"), ("zeta","supersedes","alpha"),
          ("delta","owns","epsilon"), ("nosuch","nosuch","nosuch")]

PATTERNS = ["___","s__","_v_","s v".replace(" ","")+"_", "__t","s_t","_vt","svt"]
PATTERNS = ["___","s__","_v_","sv_","__t","s_t","_vt","svt"]   # bit0=s bit1=v bit2=t

def main():
    sh = Shim(ROOT).start()
    try:
        run(sh)
    finally:
        sh.stop()

def run(sh):
    print("P2 — round trip against the harness's own sent-record", flush=True)
    c = Client(sh.port)

    @arm("P2", "admit-corpus")
    def a_admit():
        txt = c.admit(CORPUS)
        assert "admitted=%d" % len(CORPUS) in txt, txt
        return txt
    a_admit()

    @arm("P2", "rebuild-watermark-counts-what-was-sent")
    def a_rb():
        w = c.rebuild()
        assert w == str(len(CORPUS)), f"rebuild said {w!r}, harness sent {len(CORPUS)}"
        return f"watermark {w} == {len(CORPUS)} records sent"
    a_rb()

    @arm("P2", "enumerate-all-equals-what-was-sent",
         "§3.1 mask 0 _ _ _")
    def a_all():
        got = set(c.query(0, "", "", ""))
        want = set(CORPUS)
        assert got == want, (f"missing {sorted(want-got)} / unexpected {sorted(got-want)}")
        return f"{len(got)} triples, exact"
    a_all()

    @arm("P2", "duplicates-are-preserved",
         "§2.2 append-only: an identical triple admitted twice must appear twice")
    def a_dup():
        raw = c.query(0, "", "", "")
        assert len(raw) == len(CORPUS), f"{len(raw)} rows for {len(CORPUS)} records"
        return "corpus has no duplicates; multiset check deferred to P2/duplicate-admit"
    a_dup()

    # -- the eight patterns, bitwise mapping as observed on the wire
    for mask in range(8):
        pat = PATTERNS[mask]
        def make(mask=mask, pat=pat):
            @arm("P2", f"pattern-{pat}-mask{mask}",
                 "bit0=s bit1=v bit2=t, as observed")
            def a():
                bad = []
                for (s, v, t) in PROBES:
                    qs = s if pat[0] == "s" else ""
                    qv = v if pat[1] == "v" else ""
                    qt = t if pat[2] == "t" else ""
                    got = set(c.query(mask, qs, qv, qt))
                    want = expect(pat, qs or None, qv or None, qt or None) if False else \
                           {x for x in CORPUS
                            if (pat[0] != "s" or x[0] == qs)
                            and (pat[1] != "v" or x[1] == qv)
                            and (pat[2] != "t" or x[2] == qt)}
                    if got != want:
                        bad.append(f"({s},{v},{t}) -> missing {sorted(want-got)} "
                                   f"unexpected {sorted(got-want)}")
                assert not bad, "; ".join(bad)
                return f"{len(PROBES)} probes exact"
            return a
        make()()

    @arm("P2", "contract-mask-table-is-wrong",
         "§3.1 publishes mask 2 == _ _ t; §10 item 2 lists this as untested")
    def a_masktable():
        # a consumer that follows §3.1 asks for in-edges of 'beta' with mask 2
        got = set(c.query(2, "", "", "beta"))
        want_per_contract = {x for x in CORPUS if x[2] == "beta"}
        assert want_per_contract, "probe is not discriminating"
        if got == want_per_contract:
            return "§3.1's table holds"
        actual = set(c.query(4, "", "", "beta"))
        raise Finding(
            "§3.1 publishes mask 2 = '_ _ t' (in-edges of t). On the wire mask 2 is "
            "'_ v _'. A consumer following the published table asks query(2, t='beta') "
            f"and receives {sorted(got)} — it wanted {sorted(want_per_contract)}. The "
            "answer is not an error, it is an empty result set with status ok, so the "
            "consumer sees 'beta has no in-edges' and keeps going. The real in-edge "
            f"mask is 4: query(4, t='beta') -> {sorted(actual)}. §10 item 2 lists this "
            "mapping as an untested prediction; it is now settled and it is WRONG. "
            "Masks are bitwise — bit0 s, bit1 v, bit2 t — and §3.1's list of the "
            "'four patterns a real consumer exercises' names three of the four "
            "incorrectly numbered.")
    a_masktable()

    @arm("P2", "masks-outside-0..7-are-not-refused")
    def a_badmask():
        rs = {}
        for k in (8, 99, -1, "frog"):
            r = c.query_raw(k, "", "", "")
            if r.ok:
                c.consume_results(r.text)
            rs[str(k)] = r
        r8, r99, rneg, rtxt = rs["8"], rs["99"], rs["-1"], rs["frog"]
        st = {"8": r8.status, "99": r99.status, "-1": rneg.status, "frog": rtxt.status}
        if all(v == 1 for v in st.values()):
            return "all refused out-of-contract"
        raise Finding(
            f"Masks outside 0..7 are not refused: statuses {st}, replies "
            f"{ {'8':r8.text,'99':r99.text,'-1':rneg.text,'frog':rtxt.text} }. "
            "A malformed mask is a §5.8 out-of-contract condition — the client is "
            "wrong — but it answers ok with a result set. A consumer with an "
            "off-by-one in its mask constant gets silence, not a bug report.")
    a_badmask()

    @arm("P2", "stable-across-N-rebuild-cycles",
         "§8 acceptance: identical result sets over the full corpus across N rebuilds")
    def a_cycles():
        base = None
        for i in range(5):
            w = c.rebuild()
            snap = tuple(sorted(set(c.query(0, "", "", ""))))
            if base is None:
                base = (w, snap)
            else:
                assert w == base[0], f"cycle {i}: watermark drifted {base[0]} -> {w}"
                assert snap == base[1], f"cycle {i}: result set drifted"
        assert set(base[1]) == set(CORPUS)
        return f"5 rebuild cycles, watermark {base[0]}, {len(base[1])} triples, identical"
    a_cycles()

    @arm("P2", "duplicate-admit-appears-twice",
         "§2.2 there is no update and no delete")
    def a_dup2():
        before = c.query(0, "", "", "")
        c.admit([("alpha", "owns", "beta")])
        c.rebuild()
        after = c.query(0, "", "", "")
        n_before = sum(1 for x in before if x == ("alpha", "owns", "beta"))
        n_after = sum(1 for x in after if x == ("alpha", "owns", "beta"))
        if n_after == n_before + 1:
            return f"({n_before} -> {n_after}) duplicate preserved, as append-only requires"
        raise Finding(
            f"An identical triple re-admitted moved the row count from {n_before} to "
            f"{n_after}. §2.2 says ingest is immutable and append-only with no update "
            "and no delete, so the second admission must be a second row. If the store "
            "de-duplicates, a consumer cannot count events, and 'append-only' is not "
            "what a consumer gets.")
    a_dup2()

    c.close()

if __name__ == "__main__":
    main()
    dump("wire-harness/findings/p2.json")
    print("P2:", summary())
