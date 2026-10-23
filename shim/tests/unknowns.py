#!/usr/bin/env python3
"""P4 characterisation — AXVERITY_SHIM_BRIDGE_PRIMS_V1.

This file CHARACTERISES two behaviours the intent left open. It is not a fix and
must not become one: each arm asserts what was OBSERVED, so that a later change
to the writer, the shim or the contract shows up as a diff rather than as a
silent shift in what ADMIT does.

  U1  ADMIT with a count that does not match the body.
  U2  the writer killed mid-batch, and whether the batch can be retried.

Both were expected to be about hangs. Neither is.
"""
import os, pathlib, signal, subprocess, sys, threading, time

from axclient import Conn, OK, OUT_OF_CONTRACT, TRANSIENT, SERVER_FAULT
import oracle

def served(st, second):
    """Did the connection SERVE the next op — not: did it answer `ok`.

    §10 item 17. These probes asked the liveness question with `st2 == OK`,
    which was the same question until contract v2.0 put a freshness gate in
    front of QUERY (§3.1). A QUERY issued with no REBUILD now answers
    `status 1 STALE`, which is a served connection giving a correct refusal —
    and every one of these probes issues exactly that QUERY, on a store its own
    arm has just refused to write to. Measured: 22 characterised / 0 unexpected
    before the gate, 17 / 5 after, all five the same conflation.

    RATCHET_TIGHTENS_ONLY: this is a RE-SPECIFICATION, not a relaxation. The
    v2.0-correct set is exactly two replies and both are named — status 0, or
    status 1 whose body begins STALE. A dead connection raises before it gets
    here, a hang is caught by the caller's timeout, and any other status still
    fails. This is the same re-specification run-shim-breakage.sh's R1 arm
    received at G5 item 8a, applied to the sites that arm did not name.

    `second` is Conn.query's second element: the row COUNT when st is OK, and
    the reply BODY otherwise.
    """
    if st == OK:
        return True
    return st == OUT_OF_CONTRACT and str(second).startswith("STALE")


root, tmp, fmth, wpslice, axshim = (
    pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]),
    sys.argv[3], sys.argv[4], sys.argv[5],
)
PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  PASS  {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {msg}")


def note(msg):
    print(f"  ....  {msg}")


def corpus_bytes(records):
    return b"".join(len(r).to_bytes(8, "little") + r for r in records)


# THE TUNABLES ARE PINNED, ON PURPOSE, AND NOT AT THEIR DEFAULTS.
#
# Every probe here is about the WIRE — how a writer failure, a kill, or a retry
# surfaces to a consumer. None of them is a question about block size or about
# what this deployment chooses to accept. But two of them had silently stopped
# asking their question when the production default went from 16 KiB to 4 MiB
# and max_record was published at 65536:
#
#   U1b  fed a 20,000-byte triple to mean "oversize". At a 4 MiB block and a
#        65536 policy limit that record is ORDINARY — it was admitted, and the
#        arm measured nothing. The capability it guards (a writer failure being
#        distinguishable at the wire from a shim refusal) was never lost, only
#        the probe.
#   U2   kills the writer at 40% of a reference run's wall time to catch it
#        MID-batch. At 4 MiB the same corpus is a couple of blocks and the run
#        is dominated by teardown rather than by streaming, so 40% is past the
#        last durable byte and the whole batch landed — "partial prefix" with
#        nothing partial about it.
#
# Both are the test losing its subject, not the shim regressing. Pinning makes
# each probe state the precondition it depends on instead of inheriting one.
# The shipping defaults are exercised end to end by
# `CAP=4194304 tests/run-slice-test.sh` and by T9 of the readtier durable suite.
CAP = os.environ.get("CAP", "16384")
MAXREC = os.environ.get("MAX_RECORD", "16000")


def start(store, writer=None):
    """A shim on `store`, returning (proc, port). One process, one store.
    `writer` overrides argv[3], which is how the SERVER_FAULT arm points the
    shim at a binary that is not there."""
    store.mkdir(parents=True, exist_ok=True)
    cfg = store / ".axverity-store" / "config"
    cfg.mkdir(parents=True, exist_ok=True)
    (cfg / "block_capacity").write_text(CAP + "\n")
    (cfg / "max_record").write_text(MAXREC + "\n")
    log = (store / "shim.log").open("w")
    cmd = [axshim, str(store), "0"] + ([str(writer)] if writer else [])
    p = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
    for _ in range(200):
        txt = (store / "shim.log").read_text()
        if "port=" in txt:
            return p, int(txt.split("port=")[1].split()[0])
        time.sleep(0.05)
    p.kill()
    raise RuntimeError("the shim never announced a port")


def store_state(store):
    d = store / ".axverity-store" / "structure"
    blocks = sorted(d.glob("block-*.bin"), key=lambda f: int(f.name[6:-4])) if d.is_dir() else []
    ids = [int(b.name[6:-4]) for b in blocks]
    gaps = [i for i in range(ids[0], ids[-1] + 1) if i not in set(ids)] if ids else []
    trips, mal = oracle.load(store / ".axverity-store")
    return {
        "blocks": len(blocks),
        "bytes": sum(b.stat().st_size for b in blocks),
        "ids": ids, "gaps": gaps, "triples": len(trips), "malformed": mal,
    }


# ── U1  a count that does not match the body ────────────────────────────────
# P4 measured this BEFORE sh_frames existed, and the finding is why sh_frames
# exists. hot_mem_write.m1 takes the RECORD count as argv[2] and drives
# loop_count with it (:82, :107). Nothing between the socket and that loop
# checked it against the body, so:
#
#     claimed  sent   wire                          store
#     3        3      0  ok admitted=3              3 triples
#     2        3      0  ok admitted=2              2 triples, 0 malformed
#     5        3      0  ok admitted=5              3 triples + zero-length frames
#     50       3      2  WRITER killed by signal 11  nothing
#
# The row that mattered was the second: silent data loss acknowledged as
# success, with nothing malformed for any reader to catch. The intent had
# predicted a HANG here and there is none — the counting pass and the real pass
# are the same loop_count over the same nrec with the cursors rewound, so they
# cannot disagree about the block count however wrong nrec is. What a wrong
# count corrupts is which records get read.
#
# The body is self-delimiting, so the shim now counts frames and refuses a
# mismatch before spawning anything. These arms assert the REFUSAL. The arm at
# the end of this section asserts that the underlying writer behaviour is
# unchanged — masked at the transport, not fixed in the store.
print("════════ U1  ADMIT with a count that does not match the body")
recs3 = [f"s{i}\x1fvW\x1ft{i}".encode() for i in range(3)]
raw3 = corpus_bytes(recs3)

U1 = [
    ("correct",   3,  "the batch as sent",                       True),
    ("too_low",   2,  "one record fewer than the body holds",    False),
    ("too_high",  5,  "two records more than the body holds",    False),
    ("way_high", 50,  "far past the end of the staged input",    False),
]
observed = {}
for label, claimed, what, expect_ok in U1:
    d = tmp / f"u1-{label}"
    p, port = start(d)
    try:
        c = Conn(port, timeout=20)
        st, body = c.admit(claimed, raw3)
        st2, cnt2, _ = c.query(0)          # does the connection survive?
        c.close()
        reply, survived = (st, body), served(st2, cnt2)
    except Exception as e:                 # a hang would land here
        reply, survived = ("HUNG", type(e).__name__), False
    alive = p.poll() is None
    p.kill()
    p.wait()
    s = store_state(d)
    staged = (d / ".axverity-store" / "admit.tmp").exists()
    observed[label] = (reply, s, survived, staged)
    note(f"count={claimed:<3} ({what})")
    note(f"        wire: {reply}")
    note(f"        store: {s['triples']} triples, {s['blocks']} blocks, "
         f"{s['malformed']} malformed; staged={staged}; "
         f"shim {'survived' if alive else 'DIED'}")

(st, body), s, survived, staged = observed["correct"]
if st == OK and s["triples"] == 3:
    ok("a correct count admits all three records and answers ok")
else:
    bad(f"the control arm is broken: {st} {body}, {s['triples']} triples")

for label, claimed in (("too_low", 2), ("too_high", 5), ("way_high", 50)):
    (st, body), s, survived, staged = observed[label]
    if st == "HUNG":
        bad(f"{label} HUNG — no arm should be able to, the guard runs before the spawn")
        continue
    if st == OUT_OF_CONTRACT and body.startswith(f"MALFORMED count={claimed} body holds 3 records"):
        ok(f"count={claimed} is REFUSED out-of-contract, naming both numbers: {body!r}")
    else:
        bad(f"count={claimed} was not refused as expected: status {st}: {body!r}")
    if s["triples"] == 0 and s["blocks"] == 0 and not staged:
        ok(f"count={claimed} wrote NOTHING — the guard runs before the temp file "
           "and before the spawn, so a refused batch stages nothing")
    else:
        bad(f"count={claimed} left {s['triples']} triples / {s['blocks']} blocks / staged={staged}")
    if survived:
        ok(f"count={claimed} — and the same connection still serves the next op")
    else:
        bad(f"count={claimed} — the connection did not survive the refusal: the "
            "next op answered neither status 0 nor status 1 STALE")

# A body that is not a framed record stream at all, as distinct from one whose
# count is merely wrong. These must not collapse into the same message.
d = tmp / "u1-unframed"
p, port = start(d)
c = Conn(port, timeout=20)
st, body = c.admit(1, b"\x03\x00\x00")        # three bytes, no i64 length
c.close(); p.kill(); p.wait()
note(f"unframed body: ({st}, {body!r})")
if st == OUT_OF_CONTRACT and "not a framed record stream" in body:
    ok("a body that is not a framed record stream is refused with its OWN "
       "message, not conflated with a count mismatch")
else:
    bad(f"an unframed body was not distinguished: {st} {body!r}")

# The hazard itself is UNCHANGED — the guard masks it at the transport, it does
# not fix the writer. This is the arm that stops the section above reading as
# "the wrong-count problem is solved".
bypass = tmp / "u1-bypass"
bypass.mkdir(parents=True, exist_ok=True)
(bypass / "c.bin").write_bytes(raw3)
subprocess.run([wpslice, str(bypass / "c.bin"), "2"], cwd=bypass, check=True,
               capture_output=True)
byp = store_state(bypass)
note(f"writer invoked DIRECTLY with count=2 on a 3-record corpus: "
     f"{byp['triples']} triples, {byp['malformed']} malformed")
if byp["triples"] == 2 and byp["malformed"] == 0:
    ok("THE WRITER IS UNCHANGED: invoked directly with a low count it still "
       "silently writes 2 of 3 records and exits 0. The guard closes the WIRE, "
       "not the hazard — anyone invoking build/wp-slice by hand still owns it")
else:
    bad(f"the direct-invocation control did not reproduce: {byp['triples']} triples")

# ── U1b  the writer rejecting the batch on its own terms ────────────────────
# The one exit>0 path the writer actually has: a record too large for an empty
# block (wp_write_step's CAP_EXCEEDS_LARGEST_RECORD, hot_mem_write's
# proc_exit(1)). This is what makes "the writer failed" distinguishable at the
# wire from a shim refusal — the intent's first unknown.
#
# THE OVERSIZE RECORD IS A TRIPLE. It used to be b"X" * 20000, which carries no
# separators, and AXVERITY_SILENT_LOSS_FIX_V1 made the shim refuse such a record
# before the writer is spawned — so that probe stopped reaching the path it
# exists to reach, and started measuring the shim's own refusal instead. The
# capability was never lost, only the probe: an oversize TRIPLE passes the
# separator check, reaches the writer, and is rejected by CAP_EXCEEDS_LARGEST_
# RECORD exactly as before. One record changed; the claim is unchanged, and the
# arm is still the thing that distinguishes a writer failure from a shim one.
#
# WHAT MAKES IT OVERSIZE IS NOW POLICY, NOT THE BLOCK. AXVERITY_SPAN_RESTORE
# retired both structural bounds — a record too large for a block, or too long
# for the three-byte prefix, SPANS rather than being refused — so the only thing
# left that refuses is wp_max_record, which this store pins to MAXREC. The
# record below is sized against that, not against the capacity.
print("\n════════ U1b  the writer rejects the batch (exit > 0)")
big = corpus_bytes([b"s0\x1fvW\x1ft0",
                    b"s1\x1fvW\x1f" + b"X" * (int(MAXREC) + 4000),
                    b"s2\x1fvW\x1ft2"])
d = tmp / "u1-oversize"
p, port = start(d)
c = Conn(port, timeout=30)
st, body = c.admit(3, big)
st2, cnt, _ = c.query(0)
c.close()
p.kill()
p.wait()
note(f"wire: ({st}, {body!r})")
if st == OUT_OF_CONTRACT and body.startswith("WRITER exit="):
    ok("a writer failure is DISTINGUISHABLE at the wire from a shim refusal: "
       "same status class, different prefix (WRITER exit= vs MALFORMED/NOSTORE)")
else:
    bad(f"the writer's rejection did not surface as expected: {st} {body!r}")
if served(st2, cnt):
    ok("and the same connection still serves the next op after it")
else:
    bad(f"the connection did not survive a writer failure: status {st2} {cnt!r} — "
        "expected status 0, or status 1 STALE")
fatal = [l for l in (d / "shim.log").read_text().split("\n") if "FATAL" in l]
note(f"writer said: {fatal[:1]}")

# ── U1c  the writer is not there at all (SERVER_FAULT) ──────────────────────
# The third §5.8 class, exercised end to end. Before it existed this came back
# as transient, and a client routing on status alone would retry a missing
# binary forever — the class is what clients route on, not the prefix.
print("\n════════ U1c  the writer binary is missing (§5.8 SERVER_FAULT)")
d = tmp / "u1-nowriter"
p, port = start(d, writer=tmp / "no-such-writer")
c = Conn(port, timeout=30)
st, body = c.admit(3, raw3)
st2, cnt2, _ = c.query(0)
c.close()
alive = p.poll() is None
p.kill()
p.wait()
note(f"wire: ({st}, {body!r})")
if st == SERVER_FAULT and body.startswith("NOWRITER could not start"):
    ok("a missing writer is SERVER_FAULT (3), not transient and not "
       "out-of-contract: the client's bytes were fine and retrying will not help")
elif st == TRANSIENT:
    bad("a missing writer still reports transient — the third class did not land")
else:
    bad(f"a missing writer reported status {st}: {body!r}")
if alive and served(st2, cnt2):
    ok("and the shim survived it with the connection still serving")
else:
    bad(f"the shim did not survive a missing writer: alive={alive}, query "
        f"{st2} {cnt2!r} — expected status 0, or status 1 STALE")

# ── U2  the writer killed mid-batch ─────────────────────────────────────────
print("\n════════ U2  the writer killed mid-batch, and the retry")
N = int(os.environ.get("U2_RECORDS", "300000"))
corpus = tmp / "u2.bin"
subprocess.run([fmth, "corpus", str(corpus), str(N), "structure", "3"],
               check=True, capture_output=True)
raw = corpus.read_bytes()

clean = tmp / "u2-clean"
clean.mkdir(parents=True, exist_ok=True)
# The reference run is what `full` — and therefore the kill instant — is
# calibrated from, so it must be written at the SAME capacity as the run that
# gets killed. Calibrating against a different cost curve is how the kill
# drifted past the last durable byte.
_cfg = clean / ".axverity-store" / "config"
_cfg.mkdir(parents=True, exist_ok=True)
(_cfg / "block_capacity").write_text(CAP + "\n")
(_cfg / "max_record").write_text(MAXREC + "\n")
t0 = time.time()
subprocess.run([wpslice, str(corpus), str(N)], cwd=clean, check=True,
               capture_output=True)
full = time.time() - t0
ref = store_state(clean)
note(f"reference: an uninterrupted run of the same corpus takes {full:.1f}s and "
     f"lands {ref['blocks']} blocks / {ref['bytes']} B / {ref['triples']} triples")

killed = tmp / "u2-killed"
p, port = start(killed)
outcome = {}


def killer():
    def leaf(pid):
        # the shim is wrapper -> axshim-front.py -> axshim-bin -> writer:
        # descend to the deepest descendant (the writer, once ADMIT runs it)
        r = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True)
        kids = r.stdout.split()
        return leaf(int(kids[0])) if kids else pid

    for _ in range(600):                      # wait for proc_run's child
        cand = leaf(p.pid)
        try:
            cmd = open(f"/proc/{cand}/cmdline", "rb").read()
        except OSError:
            cmd = b""
        if cand != p.pid and b"axshim" not in cmd and cmd:
            child = cand
            break
        time.sleep(0.02)
    else:
        outcome["err"] = "the writer never became a child of the shim"
        return
    time.sleep(full * 0.4)                    # mid-batch, not at either end
    try:
        os.kill(child, signal.SIGKILL)
        outcome["killed"] = child
    except ProcessLookupError:
        outcome["err"] = "the writer finished before it could be killed"


th = threading.Thread(target=killer)
th.start()
c = Conn(port, timeout=300)
st, body = c.admit(N, raw)
th.join()
st2, rb = c.rebuild()
st3, cnt, _ = c.query(0)
part = store_state(killed)
note(f"wire: ({st}, {body!r}); kill: {outcome}")
note(f"store: {part['blocks']} blocks / {part['bytes']} B / {part['triples']} "
     f"triples / {part['malformed']} malformed; ids {part['ids'][:1]}..{part['ids'][-1:]}")

if "killed" not in outcome:
    bad(f"U2 could not kill the writer mid-batch: {outcome} — the arms below prove nothing")
else:
    if st == TRANSIENT and body.startswith("WRITER killed by signal"):
        ok(f"a killed writer surfaces as transient with the signal named: {body!r}")
    else:
        bad(f"a killed writer surfaced as status {st}: {body!r}")

    if 0 < part["triples"] < ref["triples"]:
        ok(f"the batch lands as a PARTIAL PREFIX: {part['triples']} of "
           f"{ref['triples']} triples, not all-or-nothing")
    else:
        bad(f"expected a partial prefix, got {part['triples']} of {ref['triples']}")

    if part["malformed"] == 0 and not part["gaps"] and part["ids"][:1] == [0]:
        ok("and the prefix is STRUCTURALLY INTACT: 0 malformed records, block "
           f"ids dense 0..{part['ids'][-1]}, no gaps — a block becomes durable "
           "only after its fsync, so a kill truncates between blocks, never "
           "inside one")
    else:
        bad(f"the prefix is damaged: {part['malformed']} malformed, "
            f"{len(part['gaps'])} id gaps, ids start at {part['ids'][:1]}")

    if st2 == OK and st3 == OK and cnt == part["triples"]:
        ok(f"REBUILD and QUERY both succeed over the partial store ({cnt} rows) "
           "— the read tier sees a smaller store, not a broken one")
    else:
        bad(f"the read tier could not read the partial store: rebuild {st2}, query {st3} {cnt}")

    # The retry. This is the arm that decides whether §5.8's transient class is
    # honest advice for a killed writer.
    st4, body4 = c.admit(N, raw)
    c.rebuild()
    st5, cnt5, _ = c.query(0)
    after = store_state(killed)
    note(f"retry: ({st4}, {body4!r}); store now {after['blocks']} blocks / "
         f"{after['bytes']} B / {after['triples']} triples")
    if st4 == OK and after["triples"] == ref["triples"] and after["malformed"] == 0:
        ok(f"RETRYING THE WHOLE BATCH CONVERGES: {after['triples']} triples, "
           "0 malformed, ids still dense — so 'transient' is honest advice")
    else:
        bad(f"the retry did not converge: status {st4}, {after['triples']} of "
            f"{ref['triples']} triples, {after['malformed']} malformed")

    dup = after["bytes"] - ref["bytes"]
    if dup > 0 and after["blocks"] > ref["blocks"]:
        ok(f"but it is NOT free: the store now holds {after['blocks']} blocks "
           f"against {ref['blocks']} for one clean run — {dup} B "
           f"({100.0 * dup / ref['bytes']:.1f}%) of duplicated durable records. "
           "The store is append-only and B1 is max+1, so the first attempt's "
           "prefix is rewritten, not replaced. The triple SET is right because "
           "the projection is set-valued; the BYTES are not")
    else:
        bad(f"expected duplicated bytes after a retry, got {dup} B and "
            f"{after['blocks']} vs {ref['blocks']} blocks")
c.close()
p.kill()
p.wait()

print(f"\nSHIM UNKNOWNS: {PASS} characterised, {FAIL} unexpected")
sys.exit(1 if FAIL else 0)
