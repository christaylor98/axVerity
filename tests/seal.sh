#!/usr/bin/env bash
# AXVERITY_W2_ADMIT_HANDLE_V1 — G6 SEAL. One script, one verdict line.
#
# Clean slate, full rebuild chain, every suite in order, plus two arms this
# gate adds. NO BENCHMARK RUNS AND NO TIMING IS PRINTED
# (NO_BENCHMARKS_PRE_BAKEOFF): experiments/perf/perf.sh is deliberately not
# invoked, and each suite's output is captured to a log with only its verdict
# line surfaced, so no sub-suite's own seconds reach this script's output.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
LOG=$(mktemp -d); trap 'rm -rf "$LOG"' EXIT

SUITES=0; FAILED=""
say(){ printf '%s\n' "$*"; }
step(){ printf '  %-34s %s\n' "$1" "$2"; }

# per-arm lines: every "  PASS  x" / "  FAIL  x" line a suite printed -> "PASS <suite>/x"
arms(){ sed -nE 's/^[[:space:]]+(PASS|FAIL)[[:space:]]+(.*)$/\1 '"$1"'\/\2/p' "$LOG/$1.txt" | sed 's/^/    /'; }

# run <label> <verdict-grep> <cmd...>
run(){
  local label="$1"; local pat="$2"; shift 2
  SUITES=$((SUITES+1))
  if "$@" > "$LOG/$label.txt" 2>&1; then
    step "$label" "$(grep -E "$pat" "$LOG/$label.txt" | tail -1)"
    arms "$label"
  else
    step "$label" "FAILED"
    [ -z "$FAILED" ] && FAILED="$label"
    grep -E "FAIL|ERROR|error" "$LOG/$label.txt" | head -3 | sed 's/^/        /'
    arms "$label"
  fi
}

say "════════ clean slate"
pkill -f 'axverity-pg[_]server' 2>/dev/null
rm -rf "$ROOT/.axverity-store"
step "store removed" "$([ -e "$ROOT/.axverity-store" ] && echo PRESENT || echo gone)"

say "════════ rebuild chain"
for d in ~/dev/axis-lang ~/dev/axis-codegen-bridge-rs; do
  if ( cd "$d" && cargo build --release ) > "$LOG/$(basename "$d").txt" 2>&1; then
    step "$(basename "$d")" "built"
  else
    step "$(basename "$d")" "FAILED"; [ -z "$FAILED" ] && FAILED="cargo:$(basename "$d")"
  fi
done
for b in scripts/build.sh scripts/build-readtier.sh shim/build-shim.sh; do
  if ./"$b" > "$LOG/$(basename "$b").txt" 2>&1; then
    step "$b" "built"
  else
    step "$b" "FAILED"; [ -z "$FAILED" ] && FAILED="$b"
  fi
done

say "════════ write-path ratchet"
# NO per-arm lines, on purpose: check-hashes is one baseline ratchet (every write-path file
# byte-identical to the P10 baseline) with a single verdict line, not a set of arms.
run check-hashes 'WRITE_PATH_' experiments/format/check-hashes.sh

say "════════ the handle"
for h in no-global-id handle-form ids-vs-ls handle-roundtrip; do
  run "$h" '(passed, [0-9]+ failed|PASS|FAIL)' "experiments/handle/$h.sh"
done

say "════════ suites"
# NO per-arm lines, on purpose: run-slice-test.sh prints one 'ALL PASS' verdict, no arm list.
run slice     'ALL PASS|FAIL'        tests/run-slice-test.sh
run crash     'CRASH SUITE'          tests/run-crash-test.sh
run readtier  'READTIER DURABLE'     tests/run-readtier-durable-test.sh
run shim-conformance 'SHIM CONFORMANCE' shim/tests/run-shim-conformance.sh
run shim-breakage    'SHIM REFUSALS'    shim/tests/run-shim-breakage.sh
run shim-unknowns    'SHIM UNKNOWNS'    shim/tests/run-shim-unknowns.sh
run arms      'TOTAL:'               wire-harness/run-all.sh

# NO per-arm lines for arm A / arm B, on purpose: each is one counted arm (2 of the 54) with its
# own verdict line; arm A's 10 steps are one pass, arm B is asserted by handle-roundtrip above.
# The 'arms' suite (wire-harness) prints PASS lines only for its PASS arms; its FINDING arms
# print in another format and are left as they were.
say "════════ G6 arm A — the whole contract in one pass"
SUITES=$((SUITES+1))
if python3 - > "$LOG/armA.txt" 2>&1 <<'PY'
import sys, os, shutil, time, threading, subprocess, signal, glob
sys.path.insert(0, "wire-harness")
from shimctl import Shim
from axwire import Client, parse_handle, Transient

BASE = ".axverity-store/seal/armA"
shutil.rmtree(BASE, ignore_errors=True)
root = os.path.abspath(BASE)
CFG = {"max_record": 64, "block_capacity": 16384}
A = [("docA", "kind", "note")]

def die(m):
    print("ARM-A FAIL:", m); sys.exit(1)

sh = Shim(root, config=CFG).start()
c = Client(sh.port, timeout=180.0)

# ── admit -> the handle parses, and an empty stream is ABSENT ──────────────
rA = c.admit(A)
hA = parse_handle(rA)
if not hA:                       # G6 item 7: EVERY successful admission parses
    die(f"a successful admission yielded an empty handle: {rA!r} — count-0 "
        "streams are dropped, so this is indistinguishable from range=unavailable")
if "structure" not in hA or hA["structure"][1] != 1:
    die(f"a one-record batch did not report exactly one structure block: {rA!r}")
if "payload" in hA:
    die(f"a batch with no oversize record reported a payload range: {rA!r} — "
        "an empty stream must be absent, not zero")
first = hA["structure"][0]

# ── query without rebuild -> STALE ─────────────────────────────────────────
q = c.query_raw(0)
if q.ok:
    n = c.consume_results(q.text)
    die(f"QUERY before any REBUILD answered status 0 with {n} rows")
if not q.text.startswith("STALE"):
    die(f"QUERY refused with {q.status} {q.text!r}, not STALE")

# ── rebuild -> ok ; query -> the exact row set ─────────────────────────────
if c.rebuild() != "1":
    die("REBUILD did not report the one admitted record")
rows = set(c.query(0))
if rows != set(A):
    die(f"QUERY after REBUILD returned {sorted(rows)}, expected {sorted(set(A))}")

# ── T1: admit referencing the first handle ─────────────────────────────────
ref = f"blk:structure:{first}"
rB = c.admit([("docB", "kind", "note"), ("docB", "supersedes", ref)])
if not parse_handle(rB):
    die(f"the referencing admission yielded an empty handle: {rB!r}")
c.rebuild()
sup = {t for s, v, t in c.query(2, "", "supersedes", "")}
if sup != {ref}:
    die(f"the supersedes edge did not carry the handle: {sorted(sup)}")
c.close(); sh.stop()

# ── restart -> STALE -> rebuild -> exact ───────────────────────────────────
sh = Shim(root, fresh=False, config=CFG).start()
c = Client(sh.port, timeout=180.0)
q = c.query_raw(0)
if q.ok:
    n = c.consume_results(q.text)
    die(f"a restarted server answered status 0 with {n} rows before rebuilding")
if not q.text.startswith("STALE"):
    die(f"restarted server refused with {q.text!r}, not STALE")
c.rebuild()
after = set(c.query(0))
expect = set(A) | {("docB", "kind", "note"), ("docB", "supersedes", ref)}
if after != expect:
    die(f"after restart+rebuild: {sorted(after)} != {sorted(expect)}")

# ── SIGKILL the writer mid-batch -> status 2 -> STALE ──────────────────────
before_blocks = len(glob.glob(f"{root}/.axverity-store/*/block-*.bin"))
out = {}
def killer():
    for _ in range(600):
        r = subprocess.run(["pgrep", "-P", str(sh.proc.pid)], capture_output=True, text=True)
        if r.stdout.strip():
            out["child"] = int(r.stdout.split()[0]); break
        time.sleep(0.01)
    else:
        out["err"] = "the writer never became a child of the shim"; return
    time.sleep(0.10)
    try:
        os.kill(out["child"], signal.SIGKILL); out["killed"] = out["child"]
    except ProcessLookupError:
        out["err"] = "the writer finished before it could be killed"

th = threading.Thread(target=killer); th.start()
rk = c.admit_raw([(f"k{i:05d}", "p", "v") for i in range(60000)])
th.join()
if "killed" not in out:
    die(f"could not kill the writer mid-batch: {out}")
if rk.status != 2:
    die(f"a killed writer surfaced as status {rk.status}: {rk.text!r}")
after_blocks = len(glob.glob(f"{root}/.axverity-store/*/block-*.bin"))
if after_blocks <= before_blocks:
    die(f"the kill left no new durable block ({before_blocks} -> {after_blocks})")
q = c.query_raw(0)
if q.ok:
    n = c.consume_results(q.text)
    die(f"QUERY answered status 0 with {n} rows after a killed writer left "
        f"{after_blocks - before_blocks} new durable blocks unindexed")
if not q.text.startswith("STALE"):
    die(f"post-kill QUERY refused with {q.text!r}, not STALE")

# ── oversize -> status 1 naming max_record ─────────────────────────────────
ro = c.admit_raw([("x" * 200, "y", "z")])
if ro.status != 1:
    die(f"an oversize record was not refused: {ro!r}")
if "max_record=64" not in ro.text:
    die(f"the oversize refusal did not name the limit: {ro.text!r}")

# ── opcode 4 -> UNKNOWN ────────────────────────────────────────────────────
r4 = c._call(bytes([4]) + b"41")
if r4.status != 1 or not r4.text.startswith("UNKNOWN opcode 4"):
    die(f"opcode 4 answers {r4.status} {r4.text!r} — the deleted verb is reachable")

c.close(); sh.stop()
print("ARM-A PASS: 10 steps, every refusal a refusal")
PY
then
  step "arm A" "$(tail -1 "$LOG/armA.txt")"
else
  step "arm A" "FAILED"; [ -z "$FAILED" ] && FAILED="armA"
  tail -3 "$LOG/armA.txt" | sed 's/^/        /'
fi

say "════════ G6 arm B — T4"
SUITES=$((SUITES+1))
# T4 is already asserted, in full, by experiments/handle/handle-roundtrip.sh:
# a handle taken before a real SIGKILL, then restart and replay, and every
# block it names compared by sha256 afterwards, plus a disjointness check on
# the replayed batch's ids. It is run above rather than written a second time.
if grep -q "byte-identical after the kill and the replay" "$LOG/handle-roundtrip.txt" 2>/dev/null; then
  step "arm B" "T4 already asserted by handle-roundtrip.sh — run above, not rewritten"
else
  step "arm B" "FAILED"; [ -z "$FAILED" ] && FAILED="armB"
fi

ARMS=$(python3 -c "import json;print(len(json.load(open('wire-harness/findings/all.json'))))" 2>/dev/null || echo 0)
ARMS=$((ARMS + 2))
BAD=$(python3 -c "
import json,collections
c=collections.Counter(r['status'] for r in json.load(open('wire-harness/findings/all.json')))
print(c['FAIL']+c['ERROR'])" 2>/dev/null || echo 1)

say ""
if [ -z "$FAILED" ] && [ "$BAD" = 0 ]; then
  echo "SEAL: PASS  $SUITES suites, $ARMS arms, 0 FAIL, 0 ERROR"
  exit 0
else
  echo "SEAL: FAIL  ${FAILED:-wire-harness arms: $BAD FAIL/ERROR}"
  exit 1
fi
