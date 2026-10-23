# AXVERITY_SHIM_BRIDGE_PRIMS_V1 — two primitives, and ADMIT

**All four verbs are green. R15 and R22 are closed, exactly two primitives were
added, and no file in `readtier/`, `lib/`, `src/`, `lib_coreir/` or
`registries/axverity-*` changed.**

```
  shim conformance   27 passed, 0 failed      (was 23)
  shim refusals      15 passed, 0 failed      (was 12)
  shim unknowns      22 characterised, 0 unexpected   (new)
  bridge lib tests  296 passed, 0 failed      (9 of them new)
  write-path slice   ALL PASS
  read-tier durable  14 passed, 0 failed
  check-hashes.sh    WRITE_PATH_UNTOUCHED: all 22 files byte-identical
```

**Round 2 of this intent** (the maintainer's review) fixed an undocumented fourth result
band, added the ADMIT frame-count check, and landed §5.8's third error class.
Those changes are marked ▲ below.

Blast radius, the whole of it:

```
  axRegistry/     axis-bridge.axreg                    +2 fn entries
  axis-codegen-bridge-rs/ runtime/process.rs, runtime/bytes_io.rs, emit/rust_05.rs
  axVerity/      shim/ only — 12 files touched, 3 deleted, 5 added
```

---

## 1. P1 — the two primitives (T1)

`403 -> 405` fn entries in `axis-bridge.axreg`. Two added, zero removed, zero
changed. They follow the TCP block in every respect it has: synchronous
blocking leaf fns, no channels coupling, `identity = sha256(name_utf8)`, a
`gap:` marker naming what could not be built without them.

```axreg
fn proc_run        in (Text, TextList)  out Int   effect fullIo
fn bytes_is_utf8   in (Bytes)           out Bool  effect pure
```

### What was kept out of Rust

`proc_run` spawns, waits, and reports. That is all of it. No shell, no retry, no
timeout, no argv assembly, no environment, no output capture, no working
directory, and no classification of the result into anybody's error taxonomy —
every one of those is a decision, and all of them are in `sh_admit.m1`. The
child inherits the caller's cwd, which is why **R16 stays closed**: one process,
one store, and the store is where the shim already stands. A chdir primitive was
never reached for.

`bytes_is_utf8` is a **predicate**, not a lossy or validating converter. The
converter already exists and answers the question by panicking; what was missing
was the question. A `bytes_to_text_checked` returning `""` on invalid input was
considered and rejected — it makes an empty body and a malformed body
indistinguishable, which is a decision about error reporting.

### The one judgement call, stated rather than buried

A `wait` can end three ways and an `Int` has to carry all three. The bands are
disjoint and documented rather than collapsed:

```
   0 ..= 255    the child exited; this is its exit code
  -1 ..= -64    killed by a signal; this is -signum
       -256     could not be started at all
       -257  ▲  ended, and the OS named neither an exit code nor a signal
  -65 ..= -255  RESERVED, never returned
```

Exit codes are `0..=255` and signals `1..=64`, so nothing overlaps. This is
reporting what the OS said, not deciding what it means.

▲ **The fourth band is a fix, and the bug is worth recording.** The first
version documented three bands and quietly returned **-255** for "ended, no
reason given" — inside no band, one away from -256, and `sh_admit` tested
equality against -256, so -255 fell through and would have reached a client as
`WRITER killed by signal 255`. A signal that does not exist. The one place an
encoding has to be airtight is the place it was not, and the failure mode was a
lie rather than an error. It is `-257` now, documented, with its own arm in
`sh_admit`, and a unit test asserts the four bands are mutually exclusive and
that **-255 stays in the reserved gap** so reintroducing it fails the suite. The
case is unreachable on unix — `status()` waits for termination, so `WIFEXITED`
or `WIFSIGNALED` always holds — and is the whole of the non-unix fallback.

A failed spawn returns rather than panicking, following `tcp_connect`'s own `-1`
precedent (net.rs:535) — the same class of "the thing you asked for is not
there", and panicking on it would hand the shim back the crash round 2 spent its
whole budget removing.

**No third primitive was added.** Two were wanted and not taken; both are
reported in §6.

Nine bridge unit tests pin the behaviour, including a 65,536-case sweep
asserting that `bytes_is_utf8` and `bytes_to_text` agree on **every** two-byte
input — the arm that catches a guard drifting stricter than the converter it
guards.

## 2. P2 — the validator swap (T2)

`sh_utf8_ok`, `sh_u8_more` and `sh_u8_step` are gone: **86 lines** of M1 walking
the Unicode lead/continuation table one byte at a time, because M1 has no
byte-width load. The shim went from 22 domain fns to 19. `sh_byte_at` stays — it
still reads the opcode byte.

The call site is now one expression, and the refusal is unchanged: same status,
same message, same connection.

**15/15, up from 12/12.** The original twelve are all still there and all still
pass. The three new ones exist because the 2-byte arm was not enough on its own:
a guard accepting `C2..DF` and rejecting `E0..F4` would have passed it and still
narrowed the surface. So every remaining width now has its own arm.

```
  PASS  BARE_FF / OVERLONG / SURROGATE / TRUNCATED  refused before bytes_to_text
  PASS  the SAME connection still answers a real query (4 rows for s0)
  PASS  a VALID multi-byte name is accepted, not refused
  PASS  UNICODE3_OK / UNICODE4_OK / UNICODE_EDGE_OK — accepted; not width-limited
  PASS  no panic, and one bind for the process's life  (both arms)
```

## 3. P3 — ADMIT (T3)

`sh_admit` stages the batch, spawns `build/wp-slice <tmp> <count>`, waits, and
answers with what the writer did.

**The writer path arrives as `argv[3]`**, resolved to an absolute path by
`bin/axshim` *before* the cd — after the cd a relative path would resolve
against the store rather than the repo. The shim logs it at startup.

**The temp file is one fixed path**, `.axverity-store/admit.tmp`, overwritten per
admission. It used to be `admit-<seq>.tmp`, one per ADMIT, which leaked a file
per call. The bridge has no file-removal primitive and adding one would be a
third primitive, which this intent forbids outright — so the leak is bounded to
exactly one file instead. See R23. It is written only *after* the framing check
passes, so a refused batch stages nothing.

### ▲ The count is checked against the body, not trusted

`sh_frames` walks the staged body and counts the record frames it actually
holds; a disagreement with the client's count is refused before anything is
written and before the writer is spawned.

```
  MALFORMED count=2 body holds 3 records          out-of-contract
  MALFORMED admit body is not a framed record stream
```

The body is self-delimiting — `repeat { i64 little-endian length, bytes }` — so
how many records it holds is a **fact about the bytes**, not a claim the client
makes about them. Counting is not reordering, coalescing or splitting, so §5.2
property 5 is untouched, and the precedent was already set by the UTF-8 guard,
which validates a body before letting it through. Framing consistency is
transport's job and had never been anyone's.

Exact fit is required: reaching the end of the body mid-frame is `-1`, not a
short count. A zero-length frame is legal and counted — the writer emits one for
a zero-length record, and refusing it would narrow the accepted surface for a
reason the format does not have.

**What it costs.** A refused ADMIT does receive, scan and reply and nothing else,
which bounds the scan from above with the transfer included:

| frames | median | per frame |
|---|---|---|
| 10,000 | 3.1 ms | 306 ns |
| 100,000 | 29.9 ms | 299 ns |
| 300,000 | 91.3 ms | 304 ns |

Flat and linear. On a 300,000-record batch that is 91 ms against a 3.03 s write —
**3.0%**, paid once, to convert silent data loss into a refusal.

### Result to wire status (§5.8, ▲ now four classes)

| `proc_run` | wire | why |
|---|---|---|
| `0` | 0, `ok admitted=N bytes=M` | the writer ran and finished |
| `> 0` | 1, `WRITER exit=N ...` | the writer rejected the batch; retrying these bytes will not help — §5.8's own test, applied honestly |
| `-1..-64` | 2, `WRITER killed by signal N` | a signal; a retry may well succeed |
| `-256` | 3 ▲, `NOWRITER could not start <path>` | the client's bytes were fine and retrying will not help |
| `-257` | 3 ▲, `NOWRITER ... no exit code and no signal` | same class, different fact |

▲ **`SERVER_FAULT` is new.** Two classes could not carry three facts. A missing
writer binary is not out-of-contract (the client's bytes were fine) and is not
transient (retrying will not help), and a client routing on status alone retried
it forever. Round 1 of this intent argued a distinguishing *prefix* was enough;
it is not — **the class is what clients route on**.

### The result

A 500-record mixed corpus, one writer binary, two fresh stores — one fed by
ADMIT over TCP, one by running `build/wp-slice` directly:

```
  PASS  ADMIT of a 500-record mixed corpus into a fresh store: ok admitted=500 bytes=154819
  PASS  the durable blocks are byte-identical to the direct invocation:
        11 blocks, 151481 B across both streams — the wire added nothing
  PASS  and the comparison can fail: one record fewer produces different blocks
```

The last line is not decoration. Without it the arm above proves only that two
things are equal, not that the comparison could ever have said otherwise.

**A test bug came out with it.** Round 2's conformance framed ADMIT's records
LEB128 — the *durable* format, not the writer's input format, which is
`repeat { i64 little-endian length, bytes }` (`wp_write_step.m1:96` advances the
cursor by `8+len`). Nothing caught it because nothing ever fed those bytes to a
writer. That is precisely the class of defect a staged-and-refused verb hides,
and it is why "the batch lands byte-identical" was a weaker claim in round 2
than it sounded.

## 4. P4 — the two unknowns, characterised (T6, T7)

`shim/tests/run-shim-unknowns.sh`, 13 arms. **Both unknowns were expected to be
about hangs. Neither is.**

### T6 — a count that does not match the body

Measured **before** the guard of §3 existed. This is the finding that produced
the guard, so it is recorded as history rather than as current behaviour:

| claimed | sent | wire | store |
|---|---|---|---|
| 3 | 3 | `0  ok admitted=3` | 3 triples |
| **2** | 3 | **`0  ok admitted=2`** | **2 triples, 0 malformed** |
| 5 | 3 | `0  ok admitted=5` | 3 triples + zero-length frames |
| 50 | 3 | `2  WRITER killed by signal 11` | nothing |

**A count one too low was silent data loss acknowledged as success.** The client
was told status 0. One record was simply not there, and nothing was malformed, so
no reader could tell.

**The predicted hang was not reachable through argv.** CLAUDE.md §6b's deadlock
is about the *block* count reaching four consumers on `wp-block-count`; the
counting pass and the real pass are the same `loop_count` over the same `nrec`
with the cursors rewound, so they cannot disagree about it however wrong `nrec`
is. What a wrong count corrupts is which records get read, not how many blocks
are promised. A far-too-high count walks off the staged input and decodes
garbage as a length — `mem_copy_raw: ... len=-5520287182306148352`, a panic in
`wp_write_step`, which the bridge respawns in place until the process dies of
`SIGSEGV`. The shim reported that and survived it.

▲ **All four rows are now refusals**, and the suite asserts them:

```
  PASS  count=2  is REFUSED out-of-contract, naming both numbers:
                 'MALFORMED count=2 body holds 3 records'
  PASS  count=2  wrote NOTHING — the guard runs before the temp file and
                 before the spawn, so a refused batch stages nothing
  PASS  count=2  and the same connection still serves the next op
        (same three arms for count=5 and count=50)
  PASS  a body that is not a framed record stream is refused with its OWN
        message, not conflated with a count mismatch
```

▲ **The hazard itself is unchanged, and one arm exists to say so.** The guard
closes the wire; it does not fix the writer. Invoked directly, `build/wp-slice`
still takes the count on trust:

```
  PASS  THE WRITER IS UNCHANGED: invoked directly with a low count it still
        silently writes 2 of 3 records and exits 0. The guard closes the WIRE,
        not the hazard — anyone invoking build/wp-slice by hand still owns it
```

Without that arm this section would read as "the wrong-count problem is solved",
which is not what was done.

### ▲ T6c — the writer is not there at all

```
  wire   3  NOWRITER could not start /tmp/.../no-such-writer
  PASS   a missing writer is SERVER_FAULT (3), not transient and not
         out-of-contract: the client's bytes were fine and retrying will not help
  PASS   and the shim survived it with the connection still serving
```


### T6b — a writer failure is distinguishable at the wire

```
  status 1  WRITER exit=1 the writer rejected this batch; retrying the same bytes will not help
  writer:   FATAL records_too_large=1 cap=16376
  PASS      and the same connection still serves the next op after it
```

Distinguishable from a shim refusal by prefix (`WRITER` vs `MALFORMED`/`NOSTORE`),
sharing the status class. **The intent's first unknown is settled in the
affirmative** — with a caveat that becomes amendment 1.

### T7 — the writer killed mid-batch

`SIGKILL` at 40% of a 300,000-record batch:

```
  wire     status 2  WRITER killed by signal 9
  store    121 blocks, 120435 of 300000 triples, 0 malformed, ids dense 0..120
  read tier  REBUILD and QUERY both succeed; 120435 rows
```

**The batch lands as a structurally intact prefix.** Not all-or-nothing, and not
damaged: a block becomes durable only after its fsync, so a kill truncates
*between* blocks and never inside one. There are no id gaps and no malformed
records. The read tier sees a smaller store, not a broken one.

**Retrying the whole batch converges — and is not free:**

```
  retry -> 0  ok admitted=300000
  store    428 blocks / 300000 triples / 0 malformed
  a clean run of the same corpus is 307 blocks
  => 1981703 B (39.5%) of duplicated durable records
```

The triple **set** is right because the projection is set-valued. The **bytes**
are not: the store is append-only and B1 resolves ids as max+1, so the first
attempt's prefix is rewritten rather than replaced. So "transient, retry" is
honest advice about correctness and misleading about cost.

## 5. Contract amendments — reviewed and settled

Two of the original five were resolved by building rather than by writing.

1. ▲ **§5.8 gains a third class, `SERVER_FAULT`. ACCEPTED AND IMPLEMENTED.**
   "The client's bytes were fine and retrying will not help" is neither of the
   first two. A distinguishing prefix was not enough — the class is what clients
   route on, and a client routing on status alone retried a missing writer
   binary forever. Exercised end to end by T6c.

2. ▲ **~~ADMIT's count is trusted from the wire~~ — WITHDRAWN, the check was
   built.** The fork this raised (either write "count correctness is a consumer
   obligation whose violation is undetectable" into the contract, or authorise a
   check) is gone: the body is self-delimiting and the check costs 3.0% of a
   300,000-record write. There is no obligation to write down, because there is
   nothing left for a consumer to get wrong at the wire. §3 has the mechanism
   and the measurement.

3. **ADMIT is at-least-once at the byte level, exactly-once at the triple-set
   level.** Accepted as written. It is not atomic and does not claim to be. A
   failed batch leaves a readable prefix; a retry converges semantically and
   duplicates durable bytes (38.9% measured). §4.1 should say so.

4. **The writer is a deployment parameter.** Accepted as written. `bin/axshim`
   supplies its absolute path as `argv[3]`. A consumer running the shim owns
   that, the same way it owns the store root.

5. **One temp file per store is left behind.** Accepted as written.
   `.axverity-store/admit.tmp` survives the last admission because nothing can
   delete it. Invisible to both tiers by construction — the writer's max+1 scan
   reads `structure/` and `payload/`, the rebuild reads `structure/` alone — but
   an artefact the contract should name rather than let a consumer discover.

6. **§5.4 / §5.5, many concurrent readers.** Stands from round 2. Not delivered
   and not deliverable by a single-threaded shim.

7. **§5.2 property 3 vs the naming seam.** Stands from round 2. The distinction
   that makes it work — read the tier's published reverse map per op, never
   hold, cache or invent — is still not in the text.


## 6. Reaches — reported, not taken

- **R15 — CLOSED.** `proc_run`.
- **R22 — CLOSED.** `bytes_is_utf8`.
- **R16 — unchanged.** No chdir primitive, and none needed: the child inherits
  the shim's cwd. `bin/axshim` still does the `cd` and `exec`s.
- **R21 — logged and left, per instruction.** `sh_rebuild` still names
  `.axverity-store/structure` in order to decline a call that would panic, which
  is a second copy of a path that lives in `rt_dblk_path.m1` and `rt_rebuild.m1`.
  The clean fix is one existence check inside `rt_rebuild.m1`, which is frozen.
- **R23 — no file-removal primitive. NEW, DECLINED.** It would have
  been a third primitive for one bounded file per store, invisible to both
  tiers. Cosmetic. The temp file is a fixed path instead, so the leak is one
  file per store rather than one per admission.
- **R24 — no non-blocking spawn, so ADMIT cannot be bounded in time. NEW,
  DECLINED as ahead-of-condition.** `proc_run` blocks until the child
  exits and the accept loop is single-threaded, so a writer that never
  terminates would wedge the shim for every client. No input tried in P4
  produced one — every crash terminated — and a timeout in Rust would be policy
  in the wrong layer.

## 7. Reproduce

```sh
cd ~/dev/axis-codegen-bridge-rs && cargo build --release && cargo test --release --lib
cd ~/dev/axVerity
scripts/build.sh && scripts/build-readtier.sh && shim/build-shim.sh
shim/tests/run-shim-conformance.sh     # 27 passed
shim/tests/run-shim-breakage.sh        # 15 passed
shim/tests/run-shim-unknowns.sh        # 22 characterised
experiments/format/check-hashes.sh     # WRITE_PATH_UNTOUCHED
```
