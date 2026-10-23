"""P4 — lifecycle: visibility, refusal, restart, retry, store path."""
import sys, os, tempfile, time, threading, subprocess, signal, glob
sys.path.insert(0,'wire-harness')
from axwire import Client, US, OutOfContract, Transient, Unclassified
from shimctl import Shim
from waitblock import wait_new_block
from harness import arm, Finding, dump, summary

BASE = "tmp/wire-harness/p4"
SMALL = [("a1","p","x1"),("a2","p","x2"),("a3","q","x3")]   # all under the 32B cliff

def main():
    print("P4 — lifecycle", flush=True)

    @arm("P4", "a-stale-read-is-refused-not-answered",
         "§3.1 v2.0 freshness gate; AXVERITY_W2_ADMIT_HANDLE_V1 T2")
    def a_vis():
        # THE ARM T2 NAMES. Its bar is explicit and inverted from a normal one:
        # "an empty non-error result is a failure of this intent, not a passing
        # test". Through contract v1.0 this arm passed by observing that a
        # forgotten REBUILD left the row set UNCHANGED — correct staleness, and
        # completely silent. A consumer that never rebuilt at all read 0 rows
        # from a full store with status 0.
        sh = Shim(f"{BASE}/vis").start()
        c = Client(sh.port)
        try:
            cold = c.query_raw(0)
            assert not cold.ok, (
                f"a QUERY before this process ever rebuilt answered status "
                f"{cold.status} {cold.text!r} — benign-on-unknown")
            c.admit(SMALL[:2])
            c.rebuild()
            before = set(c.query(0))
            assert before == set(SMALL[:2]), before
            c.admit(SMALL[2:])                      # same connection, no rebuild
            mid = c.query_raw(0)                    # must NOT answer
            if mid.ok:
                n = c.consume_results(mid.text)
                raise Finding(
                    f"A QUERY issued after an ADMIT with no intervening REBUILD was "
                    f"ANSWERED, status 0, {n} rows. §4.6 makes a reader's view 'as of "
                    "their last rebuild', so the answer is stale by construction, and "
                    "nothing on the wire says so. This is the benign-on-unknown shape "
                    "the freshness gate exists to remove.")
            after_rb = c.rebuild()
            after = set(c.query(0))
            assert after == set(SMALL), after
            return (f"cold QUERY refused ({cold.text.split()[0]}); post-ADMIT QUERY "
                    f"refused (status {mid.status}, {mid.text.split()[0]}); after "
                    f"REBUILD {len(after)} rows exact, watermark {after_rb}. A "
                    "forgotten REBUILD is now loud, and it is the only thing that "
                    "clears the gate.")
        finally:
            c.close(); sh.stop()
    a_vis()

    @arm("P4", "a-restarted-server-refuses-until-it-rebuilds",
         "the gate is process state, not connection state")
    def a_restart_gate():
        # The half a per-connection or handshake gate cannot cover: a server
        # process that starts against a store SOMEBODY ELSE wrote holds an empty
        # projection and has been asked nothing. Every query against it would
        # otherwise be ok/0-rows over a full store.
        root = f"{BASE}/restartgate"
        sh = Shim(root).start()
        c = Client(sh.port)
        try:
            c.admit(SMALL); c.rebuild()
            assert set(c.query(0)) == set(SMALL)
        finally:
            c.close(); sh.stop()
        sh2 = Shim(root, fresh=False).start()
        c2 = Client(sh2.port)
        try:
            r = c2.query_raw(0)
            assert not r.ok, (
                f"a fresh server over a written store answered status {r.status} "
                f"{r.text!r} without rebuilding — an empty projection reported as "
                "the store")
            c2.rebuild()
            rows = set(c2.query(0))
            assert rows == set(SMALL), rows
            return (f"restart refused with {r.text.split()[0]}, then answered "
                    f"{len(rows)} rows exactly after one REBUILD")
        finally:
            c2.close(); sh2.stop()
    a_restart_gate()

    @arm("P4", "a-killed-writer-stales-the-projection",
         "AXVERITY_W2_ADMIT_HANDLE_V1 G5 item 1")
    def a_killgate():
        # THE DOOR THE GATE MISSED. §A.4 makes status 2 and 3 reachable only
        # when the writer is killed or cannot start, and a signal lands wherever
        # it lands — a killed writer leaves a structurally intact PREFIX, which
        # is durable data no REBUILD has seen. The gate was set on `good`, so
        # that path left it OPEN and the next QUERY answered status 0 from a
        # projection that predated the whole prefix.
        #
        # PASS = status 1 STALE. FAIL = status 0 at ANY row count, including 0:
        # a confident answer over a store that just advanced is the defect,
        # whatever number it carries.
        root = f"{BASE}/killgate"
        sh = Shim(root, config={"block_capacity": 16384}).start()
        c = Client(sh.port, timeout=120.0)
        out = {}
        try:
            c.admit([("seed", "p", "v")]); c.rebuild()
            before = len(glob.glob(f"{root}/.axverity-store/*/block-*.bin"))

            def killer():
                for _ in range(600):
                    r = subprocess.run(["pgrep", "-P", str(sh.proc.pid)],
                                       capture_output=True, text=True)
                    if r.stdout.strip():
                        out["child"] = int(r.stdout.split()[0]); break
                    time.sleep(0.01)
                else:
                    out["err"] = "the writer never became a child of the shim"; return
                # RACE FIX: a fixed sleep let the kill land before the writer had made
                # any block durable. Signal = the polled block-file count exceeds `before`
                # (a new block-*.bin exists), so the kill is mid-batch with a durable prefix.
                err = wait_new_block(root, before)   # 60 s, generous
                if err:
                    out["err"] = err; return
                try:
                    os.kill(out["child"], signal.SIGKILL); out["killed"] = out["child"]
                except ProcessLookupError:
                    out["err"] = "the writer finished before it could be killed"

            th = threading.Thread(target=killer); th.start()
            r = c.admit_raw([(f"k{i:05d}", "p", "v") for i in range(60000)])
            th.join()
            after = len(glob.glob(f"{root}/.axverity-store/*/block-*.bin"))

            assert "killed" in out, (
                f"could not kill the writer mid-batch ({out}); this arm proves nothing")
            assert r.status == 2, f"a killed writer surfaced as status {r.status}: {r.text!r}"
            assert after > before, (
                f"the kill left no new durable block ({before} -> {after}); the arm "
                "cannot distinguish the gate from an empty store")

            q = c.query_raw(0)
            if q.ok:
                n = c.consume_results(q.text)
                raise AssertionError(
                    f"QUERY answered status 0 with {n} rows after a killed writer left "
                    f"{after - before} new durable block(s) unindexed — benign-on-unknown "
                    "on the crash path")
            assert q.text.startswith("STALE"), (
                f"QUERY refused with {q.status} {q.text!r}, not STALE")
            return (f"SIGKILL mid-batch -> status 2 {r.text!r}; {before} -> {after} "
                    f"durable blocks; QUERY refused with {q.text.split()[0]}. The gate "
                    "is set on `bat` (a spawn was attempted), not on a clean exit")
        finally:
            c.close(); sh.stop()
    a_killgate()

    @arm("P4", "a-refused-ADMIT-writes-nothing",
         "§5.8 out-of-contract: malformed batch")
    def a_refuse():
        sh = Shim(f"{BASE}/refuse").start()
        c = Client(sh.port)
        try:
            c.admit(SMALL); c.rebuild()
            before_rows = set(c.query(0)); before_wm = c.rebuild()
            r = c.admit_raw(SMALL, count=len(SMALL) + 7)   # count lies
            assert r.status != 0, f"a lying count was ACCEPTED: {r.text!r}"
            after_wm = c.rebuild()
            after_rows = set(c.query(0))
            assert after_rows == before_rows, (
                f"refused batch changed the store: +{sorted(after_rows-before_rows)} "
                f"-{sorted(before_rows-after_rows)}")
            assert after_wm == before_wm, (
                f"refused batch moved the watermark {before_wm} -> {after_wm}")
            return (f"refusal status {r.status} {r.text!r}; store unchanged at "
                    f"{len(after_rows)} rows, watermark {after_wm}")
        finally:
            c.close(); sh.stop()
    a_refuse()

    @arm("P4", "connection-survives-a-refusal",
         "§5.8: a client that is wrong must still be able to proceed correctly")
    def a_after():
        sh = Shim(f"{BASE}/after").start()
        c = Client(sh.port)
        try:
            r = c.admit_raw(SMALL, count=99)
            assert r.status != 0
            c.admit(SMALL)                       # same connection, now correct
            c.rebuild()
            rows = set(c.query(0))
            assert rows == set(SMALL), rows
            return "the same connection admitted correctly after being refused"
        finally:
            c.close(); sh.stop()
    a_after()

    @arm("P4", "data-survives-a-shim-restart",
         "the durable artefact is the store, not the process")
    def a_restart():
        root = f"{BASE}/restart"
        sh = Shim(root).start(); c = Client(sh.port)
        try:
            c.admit(SMALL); w1 = c.rebuild()
            rows1 = set(c.query(0))
        finally:
            c.close(); sh.stop()
        sh2 = Shim(root, fresh=False).start(); c2 = Client(sh2.port)
        try:
            w2 = c2.rebuild()
            rows2 = set(c2.query(0))
            assert rows2 == rows1 == set(SMALL), f"{sorted(rows2)} vs {sorted(rows1)}"
            assert w2 == w1, f"watermark {w1} -> {w2} across restart"
            # and a second writer generation appends rather than overwrites
            c2.admit([("b1","p","y1")])
            c2.rebuild()
            rows3 = set(c2.query(0))
            assert rows3 == set(SMALL) | {("b1","p","y1")}, sorted(rows3)
            return (f"restart on the same store: {len(rows2)} rows, watermark {w2}, "
                    "identical; a post-restart admit appends without overwriting")
        finally:
            c2.close(); sh2.stop()
    a_restart()

    @arm("P4", "a-killed-shim-is-a-transient-error",
         "§5.8: connection loss is transient, retry is legitimate")
    def a_kill():
        root = f"{BASE}/kill"
        sh = Shim(root).start(); c = Client(sh.port, timeout=3.0)
        try:
            c.admit(SMALL); c.rebuild()
            sh.kill()
            try:
                c.query(0)
                cls = "no error at all"
            except Transient as e:
                cls = f"Transient: {e.text}"
            except OutOfContract as e:
                raise Finding(
                    f"A killed server is reported as OUT-OF-CONTRACT: {e.text}. §5.8 "
                    "says server restart and connection loss are TRANSIENT and retry "
                    "is legitimate, and §7.6 obliges a consumer to treat an "
                    "out-of-contract error as a bug and never retry it. A consumer "
                    "obeying both would stop on a recoverable failure.")
            except Exception as e:
                cls = f"{type(e).__name__}: {e}"
        finally:
            c.close()
        sh2 = Shim(root, fresh=False).start(); c2 = Client(sh2.port)
        try:
            c2.rebuild()
            rows = set(c2.query(0))
            assert rows == set(SMALL), sorted(rows)
        finally:
            c2.close(); sh2.stop()
        if not cls.startswith("Transient"):
            raise Finding(
                f"A killed server surfaces to the client as: {cls}. The client cannot "
                "distinguish it from any other socket failure because the wire has no "
                "transient status byte to carry — §5.8 makes the ok / out-of-contract "
                "/ transient split normative, but only the connection state, not the "
                "protocol, expresses transient. The retry did converge: after "
                f"restart the store still holds {len(SMALL)} rows exactly as sent.")
        return (f"kill during use -> {cls}; retry against a fresh server on the same "
                f"store recovers all {len(SMALL)} rows exactly")
    a_kill()

    @arm("P4", "store-path-is-honoured-not-CWD-relative",
         "§7.2 supply the store path, never assume CWD-relative resolution")
    def a_path():
        repo = os.getcwd()
        root = os.path.abspath(f"{BASE}/cwd")
        alt = tempfile.mkdtemp(prefix="axwire-cwd-")
        sh = Shim(root, cwd=alt, config={"max_record": 64}).start()
        c = Client(sh.port)
        try:
            c.admit(SMALL)
            w = c.rebuild()
            rows = set(c.query(0))
            assert rows == set(SMALL), (
                f"a shim started with CWD={alt} and store={root} answered "
                f"{sorted(rows)}")

            # G5 item 5. §4.1 now tells a consumer it may "read it out of the
            # refusal", and the relay travels through a file BOTH processes name
            # relatively. Two processes resolving one relative path differently
            # would degrade the relay to "named no reason" in exactly the
            # configuration §7.2 mandates — so the promise is asserted HERE,
            # where the CWD is foreign, not only where it is the store.
            r = c.admit_raw([("x" * 200, "y", "z")])
            assert r.status == 1, f"an oversize record was not refused: {r!r}"
            assert "max_record=64" in r.text, (
                f"the refusal did not name the configured limit from a foreign "
                f"CWD: {r.text!r} — §4.1's 'read it out of the refusal' is false "
                "in the one configuration §7.2 mandates")
            assert not os.path.exists(os.path.join(alt, ".axverity-store")), (
                f"the shim materialised a store under its launch CWD {alt}")
            assert not os.path.exists(os.path.join(repo, ".axverity-store",
                                                   "writer.err")), (
                "the writer's diagnostic landed under the repo, not the store")

            return (f"shim run from an unrelated CWD ({alt}) against an absolute "
                    f"store path: {len(rows)} rows, watermark {w}, exact; and the "
                    f"oversize refusal names max_record=64 from that same foreign "
                    "CWD — both processes resolve the store by the launcher's cd, "
                    "so there is one source and not two")
        finally:
            c.close(); sh.stop(); os.rmdir(alt) if not os.listdir(alt) else None
    a_path()

    @arm("P4", "empty-store-REBUILD-is-classified-out-of-contract")
    def a_nostore():
        sh = Shim(f"{BASE}/empty").start()
        c = Client(sh.port)
        try:
            r = c.rebuild_raw()
            if r.ok:
                return f"REBUILD on an empty store is ok: {r.text!r}"
            q = c.query_raw(0, "", "", "")
            if q.ok:
                c.consume_results(q.text)
            both = "" if q.ok else (
                " AND SINCE v2.0 THIS IS BOTH READ VERBS: QUERY on the same empty "
                f"store now answers status {q.status} {q.text.split()[0]!r} because "
                "the freshness gate starts closed and only a successful REBUILD "
                "opens it — and REBUILD refuses. A brand-new deployment therefore "
                "has NO read verb that answers ok until somebody admits. That is "
                "honest and it is not benign-on-unknown, but it is a narrowing this "
                "harness did not have before, and §A.7's advice to 'prefer QUERY, "
                "which answers ok with 0 rows on the same store' is now void.")
            raise Finding(
                f"REBUILD on a store nothing has been admitted to answers status "
                f"{r.status} — out-of-contract — with {r.text!r}. §5.8 defines "
                "out-of-contract as 'the client is wrong. Retrying will not help and "
                "must not be attempted', and §7.6 obliges the consumer to treat it as "
                "a bug. But an empty store is the normal starting state of every "
                "deployment and the condition clears the moment anyone admits, so "
                "retrying is exactly the right thing to do. A consumer that obeys "
                "§7.6 literally treats a brand-new store as a bug. Note also that "
                f"QUERY on the same empty store answers {q.text!r}, so "
                "two read verbs disagree about whether an empty store is an error. "
                "The message names '.axverity-store/structure' — a path relative to "
                "the server's CWD, not the store root the client's operator "
                "supplied — which sends a diagnosing consumer to the wrong directory.")
        finally:
            c.close(); sh.stop()
    a_nostore()

    @arm("P4", "no-verb-claims-a-durability-wait",
         "§A.9 v2.0: DURABLE removed rather than left answering ok")
    def a_durable():
        # v1.0 shipped DURABLE, which answered (0, 'ok') to every argument ever
        # put to it — including a watermark beyond anything admitted and a
        # non-numeric one. A wait that returns ok for a watermark that does not
        # exist is not a wait, and a consumer calling it was entitled to believe
        # it had one. The fix chosen was DELETION, not implementation: there is
        # nothing to wait for on a run-and-exit writer, and a verb with nothing
        # to do that answers ok anyway is the defect, not a stub of a feature.
        sh = Shim(f"{BASE}/dur").start()
        c = Client(sh.port)
        try:
            c.admit(SMALL); c.rebuild()
            answers = {}
            for wm in ("", "0", "1", "999999", "-5", "not-a-number"):
                r = c._call(bytes([4]) + wm.encode("utf-8"))
                answers[wm] = (r.status, r.text)
            distinct = {v for v in answers.values()}
            assert len(distinct) == 1, f"opcode 4 discriminates: {answers}"
            st, txt = distinct.pop()
            assert st == 1 and txt.startswith("UNKNOWN opcode"), (
                f"opcode 4 answers {st} {txt!r} — something still responds to the "
                "verb that used to claim a durability wait")
            return (f"opcode 4 answers ({st}, {txt!r}) for every argument tried "
                    f"({sorted(answers)}). No verb on this wire claims a durability "
                    "wait, so no consumer can mistake one for a guarantee. §4.3's "
                    "in-process wp_wait_durable is unchanged and remains settled by "
                    "strace, not by the wire.")
        finally:
            c.close(); sh.stop()
    a_durable()

if __name__ == "__main__":
    main()
    dump("wire-harness/findings/p4.json")
    print("P4:", summary())
