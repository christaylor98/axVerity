#!/usr/bin/env python3
"""The wire half of the conformance run. Called by run-shim-conformance.sh."""
import pathlib, re, socket, struct, subprocess, sys, threading, time

from axclient import Conn, OK, OUT_OF_CONTRACT, vi_enc
import oracle

port, store, tmp, n, n2, fmth, wpslice = (
    int(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]),
    int(sys.argv[4]), int(sys.argv[5]), sys.argv[6], sys.argv[7],
)
STORE = store / ".axverity-store"

PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  PASS  {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {msg}")


def write_lifetime(corpus, count):
    subprocess.run([wpslice, str(corpus), str(count)], cwd=store, check=True,
                   capture_output=True)


trips, mal = oracle.load(STORE)
id2name, name2id = oracle.idmap(STORE)
print(f"    oracle: {len(trips)} distinct triples, {mal} malformed, "
      f"{len(id2name)} distinct names")

c = Conn(port)
st, body = c.rebuild()
if st == OK:
    ok(f"REBUILD over the wire returned {body}")
else:
    bad(f"REBUILD returned status {st}: {body}")

# ── the eight binding patterns ──────────────────────────────────────────────
# Round 1 needed an id->name map recovered on the test side to make these
# compare; the shim now reads the tier's own reverse map per row (sh_name3), so
# the comparison is verbatim against the oracle's names.
s0, v0, t0 = sorted(trips)[0]
PATTERNS = [
    (0, "", "", "", "_ _ _  enumerate all"),
    (1, s0, "", "", "s _ _  out-edges of s"),
    (2, "", v0, "", "_ v _  verb only"),
    (3, s0, v0, "", "s v _  value of verb v on s"),
    (4, "", "", t0, "_ _ t  in-edges of t"),
    (5, s0, "", t0, "s _ t  verbs between s and t"),
    (6, "", v0, t0, "_ v t"),
    (7, s0, v0, t0, "s v t  membership"),
]
for mask, s, v, t, label in PATTERNS:
    st, cnt, rows = c.query(mask, s, v, t)
    if st != OK:
        bad(f"mask {mask} ({label}): status {st}: {cnt}")
        continue
    want = oracle.answer(trips, mask, s, v, t)
    got = set(rows)
    if got == want and cnt == len(want):
        ok(f"mask {mask}  {label}  — {cnt} rows, identical to the oracle")
    else:
        bad(f"mask {mask}  {label}  — wire {len(got)} rows (count said {cnt}), "
            f"oracle {len(want)}; only-wire={len(got - want)} only-oracle={len(want - got)}")

# ── §4.6 visibility: a stale reader is not an inconsistent reader ───────────
print("\n════════ visibility — the store advances underneath a live connection")
subprocess.run([fmth, "corpus", str(tmp / "b.bin"), str(n2), "structure", "1"],
               check=True, capture_output=True)
write_lifetime(tmp / "b.bin", n2)
trips2, _ = oracle.load(STORE)
print(f"    second writer lifetime landed; oracle is now {len(trips2)} triples")

st, cnt, rows = c.query(0)
if st == OK and set(rows) == trips:
    ok(f"same QUERY before REBUILD still answers the OLD prefix ({cnt} rows) — "
       "staleness is the tier's, not smoothed over")
else:
    bad(f"pre-rebuild QUERY returned {cnt} rows, expected the old {len(trips)}")

st, body = c.rebuild()
st2, cnt2, rows2 = c.query(0)
if st2 == OK and set(rows2) == trips2 and len(trips2) != len(trips):
    ok(f"the identical QUERY after REBUILD answers {cnt2} rows — it reached the "
       "tiers both times, so the shim holds no result state (§5.2 property 2)")
else:
    bad(f"post-rebuild QUERY returned {cnt2} rows, expected {len(trips2)}")

# ── R17: the reverse map is read per op, never carried ──────────────────────
# Two identical QUERYs with the tier's id assignment CHANGED between them. The
# answer is the same triples both times, so a shim that cached the map would
# still return the right cardinality and the wrong names — which is exactly the
# failure this arm exists to catch, and why an identical-twice check on its own
# would not catch it.
#
# The assignment is made to move by writing a corpus the store already holds:
# no new triples, but more blocks, and the fold order is fs_list_dir's
# LEXICOGRAPHIC one (io.rs:141), so block-10 walking before block-2 renumbers
# almost everything.
print("\n════════ R17 — the reverse map is re-read per op")
st, cntA, rowsA = c.query(2, "", v0, "")
mapA = dict(id2name)
before = len(list(STORE.glob("structure/block-*.bin")))

st, cntA2, rowsA2 = c.query(2, "", v0, "")
if st == OK and set(rowsA) == set(rowsA2) and cntA == cntA2:
    ok(f"two identical QUERYs in one connection agree ({cntA} rows)")
else:
    bad(f"two identical QUERYs disagreed: {cntA} vs {cntA2}")

write_lifetime(tmp / "a.bin", n)          # already-present triples, new blocks
st, body = c.rebuild()
after = len(list(STORE.glob("structure/block-*.bin")))
id2name, name2id = oracle.idmap(STORE)
trips3, _ = oracle.load(STORE)

moved = sum(1 for k in mapA if id2name.get(k) != mapA[k])
if trips3 == trips2:
    ok(f"the extra lifetime added {after - before} blocks and no new triples "
       f"({len(trips3)} unchanged)")
else:
    bad(f"the extra lifetime changed the triple set: {len(trips2)} -> {len(trips3)}")

if moved:
    ok(f"and it renumbered the tier's id space: {moved} of {len(mapA)} ids now "
       "name a different thing")
else:
    bad("the id assignment did not move — the arm below cannot fail, so it "
        "proves nothing")

st, cntB, rowsB = c.query(2, "", v0, "")
want = oracle.answer(trips3, 2, "", v0, "")
if st == OK and set(rowsB) == set(rowsA) == want:
    ok(f"the identical QUERY still answers the same {cntB} NAMES across the "
       "renumbering — the map was re-read, not carried")
else:
    bad(f"names drifted across the renumbering: {len(set(rowsB) - set(rowsA))} "
        f"rows differ from before, {len(set(rowsB) ^ want)} differ from the oracle")

# ── ADMIT — R15 closed (AXVERITY_SHIM_BRIDGE_PRIMS_V1) ─────────────────────
# Round 2 could stage the batch and no more: M1 could not express the spawn, so
# the verb answered NOPRIM. proc_run closes that, and the arms below are what
# "closed" has to mean — not that a call returns 0, but that the bytes the wire
# carried reach the durable store unchanged and become queryable.
#
# The body is the WRITER'S input format — repeat { i64 little-endian length,
# that many bytes } — because §5.2 property 5 makes the transport a carrier.
# Round 2's test framed these records LEB128, which is the DURABLE format, not
# the writer's input; nothing caught it because nothing ever fed them to the
# writer. That is the class of bug a staged-and-refused verb hides.
print("\n════════ ADMIT — the writer runs")


def corpus_bytes(records):
    """The writer's input framing (fmth's corpus_write, harness/src/main.rs:67).
    Written here from the format's description rather than shared with the
    harness, so a disagreement shows up as a failure rather than as two copies
    of one mistake — same discipline as axclient's F1v."""
    out = b""
    for r in records:
        out += len(r).to_bytes(8, "little") + r
    return out


recs = corpus_bytes([f"s{i}\x1fvNEW\x1ft{i}".encode() for i in range(3)])
st, body = c.admit(3, recs)
if st == OK and body.startswith("ok admitted=3"):
    ok(f"ADMIT spawned the writer and it exited 0: {body}")
elif st == OUT_OF_CONTRACT and body.startswith("NOPRIM"):
    bad("ADMIT is still refusing for a missing primitive — proc_run did not land")
else:
    bad(f"ADMIT failed: status {st}: {body}")

staged = STORE / "admit.tmp"
if staged.exists() and staged.read_bytes() == recs:
    ok(f"the batch reached the writer byte-identical, staged at {staged.name} "
       f"({len(recs)} B) — the transport did not transform it")
else:
    bad("the staged batch is missing or was rewritten")

st, body = c.rebuild()
st, cnt, rows = c.query(3, "s0", "vNEW", "")
if st == OK and cnt == 1 and set(rows) == {("s0", "vNEW", "t0")}:
    ok("a triple only ADMIT could have written is queryable after REBUILD — "
       "the verb wrote, it did not merely stage")
else:
    bad(f"the admitted triple is not in the store: status {st}, {cnt} rows, {rows[:2]}")
id2name, name2id = oracle.idmap(STORE)      # the REBUILD moved the id space

# ── T3: ADMIT == a direct invocation, byte for byte ────────────────────────
# The claim R15 has to settle is that going through the wire changes nothing
# about what lands. Two fresh stores, one corpus, one writer binary: one gets it
# by ADMIT, the other by running build/wp-slice directly. Every durable block in
# both streams is then compared byte for byte. Fresh stores because B1 resolves
# block ids as max+1 over what is already there, so a shared store would make
# the two runs disagree on ids for a reason that is not the wire's.
#
# THE CORPUS IS TRIPLES ONLY, AND IT STRADDLES THE 32-BYTE THRESHOLD.
# It used to be fmth's `mixed`, which is 80% triples and 20% random blobs. The
# blobs are gone because AXVERITY_SILENT_LOSS_FIX_V1 made ADMIT refuse a record
# that is not valid UTF-8 carrying exactly two 0x1f separators, and a random
# blob's separator count is random — so the wire no longer carries one at all.
# Appendix A.8 always said the wire's payload is `s US v US t`; it is enforced
# now rather than described, and blobs reach the store only through a direct
# build/wp-slice invocation.
#
# What must NOT be lost with them is the two-stream coverage: S2 routes on SIZE
# at 32 bytes (wp_write_step.m1:42-43), so a corpus of short triples alone would
# land entirely in structure/ and this arm would stop proving anything about the
# payload stream. Half the triples here are deliberately over the threshold, so
# both directories are populated and the byte-identity claim still spans both.
def t3_triples(n):
    """n triples, alternating short (<=32 B) and long (>32 B), deterministic."""
    out = bytearray()
    for i in range(n):
        if i % 2:
            rec = f"concept/knowledge-graph/entity-{i:06d}\x1fsupersedes\x1f" \
                  f"concept/knowledge-graph/entity-{(i + 1) % n:06d}".encode()
        else:
            rec = f"s{i // 4}\x1fv{i % 7}\x1ft{i % 97}".encode()
        out += struct.pack("<Q", len(rec)) + rec
    return bytes(out)


print("\n════════ ADMIT == direct invocation (T3)")
AXSHIM = pathlib.Path(__file__).resolve().parent.parent / "bin" / "axshim"
NT = 500
t3corpus = tmp / "t3.bin"
t3raw = t3_triples(NT)
t3corpus.write_bytes(t3raw)

direct = tmp / "t3-direct"
direct.mkdir(parents=True, exist_ok=True)
subprocess.run([wpslice, str(t3corpus), str(NT)], cwd=direct, check=True,
               capture_output=True)

viashim = tmp / "t3-viashim"
viashim.mkdir(parents=True, exist_ok=True)
t3log = (viashim / "shim.log").open("w")
t3proc = subprocess.Popen([str(AXSHIM), str(viashim), "0"], stdout=t3log,
                          stderr=subprocess.STDOUT)
t3port = None
for _ in range(200):
    txt = (viashim / "shim.log").read_text()
    if "port=" in txt:
        t3port = int(txt.split("port=")[1].split()[0])
        break
    time.sleep(0.05)

if t3port is None:
    bad("T3: the second shim never announced a port")
else:
    c3 = Conn(t3port, timeout=120)
    st3, body3 = c3.admit(NT, t3raw)
    c3.close()
    if st3 == OK:
        ok(f"ADMIT of a {NT}-record triples corpus straddling the 32 B threshold "
           f"into a fresh store: {body3}")
    else:
        bad(f"T3 ADMIT returned status {st3}: {body3}")
t3proc.terminate()
t3proc.wait()


def durable_blocks(root):
    out = {}
    for stream in ("structure", "payload"):
        d = root / ".axverity-store" / stream
        for f in (sorted(d.glob("block-*.bin")) if d.is_dir() else []):
            out[f"{stream}/{f.name}"] = f.read_bytes()
    return out


da, db = durable_blocks(direct), durable_blocks(viashim)
nbytes = sum(len(v) for v in da.values())
if da and da == db:
    ok(f"the durable blocks are byte-identical to the direct invocation: "
       f"{len(da)} blocks, {nbytes} B across both streams — the wire added nothing")
elif not da:
    bad("T3: the direct invocation produced no durable blocks; the arm proves nothing")
else:
    differ = [k for k in set(da) & set(db) if da[k] != db[k]]
    bad(f"T3: durable blocks differ — only-direct={sorted(set(da) - set(db))[:3]} "
        f"only-shim={sorted(set(db) - set(da))[:3]} content-differs={differ[:3]}")

# Negative control: the comparison above must be capable of failing. A corpus
# one record short lands different bytes, so an arm that passed no matter what
# would show up here.
short = tmp / "t3-short"
short.mkdir(parents=True, exist_ok=True)
subprocess.run([wpslice, str(t3corpus), str(NT - 1)], cwd=short, check=True,
               capture_output=True)
if durable_blocks(short) != da:
    ok("and the comparison can fail: one record fewer produces different blocks")
else:
    bad("a short corpus produced identical blocks — the T3 arm is vacuous")

# AXVERITY_W2_ADMIT_HANDLE_V1 G3 — DURABLE was DELETED at contract v2.0. It
# answered `ok` to every argument ever put to it, so a consumer was entitled to
# read it as a durability guarantee it never made (W7). The assertion is now
# that the verb is GONE, not that it answers: opcode 4 must be indistinguishable
# from any other unassigned byte.
st, body = c.durable()
if st == OUT_OF_CONTRACT and body.startswith("UNKNOWN opcode 4"):
    ok(f"DURABLE is gone -> status {st} {body!r}")
else:
    bad(f"opcode 4 still answers {st} {body!r} — the verb that claimed a "
        f"durability wait is still reachable")

# ── error classes ───────────────────────────────────────────────────────────
print("\n════════ error classes (§5.8)")
st, body = c.raw(bytes([0x09]))
if st == OUT_OF_CONTRACT:
    ok(f"an unknown opcode is out-of-contract, not transient: {body}")
else:
    bad(f"unknown opcode returned status {st}: {body}")

# ── negative controls — the arms above must be capable of failing ───────────
print("\n════════ negative controls")

# 1. The rows are names, and rendering them was not a no-op: the same rows in
#    the tier's id space are a different set. If the read tier ever starts
#    answering in names, this goes red and sh_name3 should be deleted.
st, cnt, rows = c.query(1, s0, "", "")
raw_ids = {tuple(name2id[x] for x in r) for r in rows}
if rows and all(x in name2id for r in rows for x in r) and raw_ids != set(rows):
    ok(f"rows are names, not ids: {rows[0]} on the wire, {sorted(raw_ids)[0]} "
       "in the tier's id space")
else:
    bad(f"rows did not render: wire {rows[:1]}, ids {sorted(raw_ids)[:1]}")

# 2. A name the store does not hold must answer empty, not error and not match.
st, cnt, rows = c.query(1, "definitely_not_a_name", "", "")
if st == OK and cnt == 0:
    ok("an unknown name answers zero rows — the render path is not inventing "
       "names for ids that were never minted")
else:
    bad(f"an unknown name returned status {st} with {cnt} rows")

# 3. Confinement property 1: the shim's source names only published read-tier
#    fns. A private symbol here means confinement already failed (§8).
src = "".join(f.read_text() for f in
              sorted(pathlib.Path(__file__).resolve().parent.parent.glob("*/*.m1")))
named = {x.rstrip("( ") for x in re.findall(r"\brt_[a-z0-9_]+\s*\(", src)}
allowed = {"rt_query", "rt_out_count", "rt_out_at", "rt_rebuild", "rt_nidx_name_of"}
if named and named <= allowed:
    ok(f"the shim names {len(named)} read-tier fns and every one is published: "
       f"{sorted(named)}")
else:
    bad(f"the shim reaches below the published surface: {sorted(named - allowed)}")

# ── serialisation: the shim IS the single-writer guarantee ──────────────────
print("\n════════ serialisation — one operation in flight")
order = []
lock = threading.Lock()


def second_client():
    s = socket.create_connection(("127.0.0.1", port), timeout=30)
    s.sendall(vi_enc(1 + len(recs) + len(vi_enc(3))) + bytes([3]) + vi_enc(3) + recs)
    s.recv(1)                       # blocks until the shim gets to this conn
    with lock:
        order.append("B-served")
    s.close()


th = threading.Thread(target=second_client)
th.start()
time.sleep(0.5)                     # B is connected and has sent, but conn A is open
with lock:
    early = list(order)
c.admit(3, recs)                    # A does more work on its still-open connection
with lock:
    mid = list(order)
c.close()
th.join(timeout=30)
with lock:
    final = list(order)

if early == [] and mid == [] and final == ["B-served"]:
    ok("a second ADMIT gets no byte until the first connection is done — "
       "serialised by the accept loop, with no lease to acquire or leak")
else:
    bad(f"the second ADMIT was served concurrently: early={early} mid={mid} final={final}")

print(f"\nSHIM CONFORMANCE: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
