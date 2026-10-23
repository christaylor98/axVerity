# AXVERITY_DURABLE_FORMAT_V1 — P0 + P1 + P2 report

Machine: 32-core Linux 6.1, ext4 on NVMe. Every durable measurement is the
real `fs_write_raw` barrier (temp + fsync + rename + parent-dir fsync,
`bytes_io.rs:83-98`), and every M1 number is M1 through the real bridge.

Raw CSVs: `.axverity-store/fmt/p1/*.csv` (framing) and `.axverity-store/fmt/p2/*.csv`
(block id, separation).

---

## P0 — baseline and harness

### Write path hashed, untouched

15 files (`lib/wp_*.m1` ×10, `src/*.m1` ×5) hashed at P0 start into
`write-path-hashes.txt`. `check-hashes.sh` re-verifies:

```
WRITE_PATH_UNTOUCHED: all 15 files byte-identical to the P0 baseline
```

### Cost baseline, reproduced in the shipping substrate

The intent's 8.89 ms figure came from `experiments/blockid`, a Rust
hand-replica of `write_durable()`. Re-measured through the real `wp-slice`
binary, 300 blocks × 5 runs:

| measure | value | method |
|---|---|---|
| wall clock / block | **9.097 ms** | total process time ÷ N, no instrumentation at all |
| ack-path median | **9.038 ms** | `wp_wait_durable` per-block wait, the existing opt-in instrument |
| fsyncs per block | **2.0000** | `strace -c`, 600 fsyncs / 300 blocks, counted not assumed |

The Rust replica was accurate to 2.3%. **The substrate baseline is 9.10 ms /
2.00 fsyncs**, and that is what every candidate below is compared against.

### The harness has teeth

`p0-negative-control.sh` — 10 of 10. Built with the real unmodified write
path, then broken one property at a time:

| control | required outcome | result |
|---|---|---|
| intact store | PASS | ✓ |
| F0 record-framing claim | reported unrecoverable | ✓ |
| truncate a block | FAIL | ✓ stream bytes differ |
| flip one payload byte | FAIL | ✓ stream bytes differ |
| drop a block | FAIL | ✓ not dense from 0 at position 35 |
| swap two blocks | FAIL | ✓ stream bytes differ |
| **restart: run 2 over run 1** | FAIL | ✓ block-0.bin overwritten, run 1 unverifiable |
| real SIGKILL mid-write | writer dies of signal 9 | ✓ 20 of 400 blocks durable |

The restart control is the important one: it catches the exact defect this
intent exists to fix, using the shipping binary, with no modification.

**A control caught a flaw in the harness itself on first run.** The two-run
overwrite test originally used two `structure` corpora with different seeds —
but `structure` is a pure function of the record index and ignores the seed
(deliberately: it mirrors `rt_pop_step.m1`). Both runs wrote identical bytes,
so the overwrite was invisible. Fixed by using a content-varying distribution;
the property is now documented at the generator.

---

## P1 — framing

### T7 — record-size distribution (decides whether F3 applies)

100k records each. Synthetic — there is no production workload to sample, and
saying so is part of the result. `structure` is the shape the read tier was
actually measured against (`rt_pop_step.m1`).

| corpus | min | p50 | p90 | p99 | max | distinct lengths | F3 padding waste at W=max |
|---|---|---|---|---|---|---|---|
| structure | 8 | 15 | 16 | 16 | 16 | 9 | **5.6%** |
| mixed | 8 | 16 | 733 | 6717 | 8190 | 5461 | **95.7%** |

**F3 is applicable to a structure-only stream and inapplicable to a mixed
one.** That is not an aesthetic judgement — it is 5.6% versus 95.7% waste, and
it is the first measured argument in favour of structure/payload separation
(S1/S2), which is what would let a stream be structure-only in the first
place. Separation is a P2 question; this is P1 evidence bearing on it.

### T1a — round trip, write in one process, decode in another

Independent Rust decoder, no shared code with the M1 writers.

| corpus | cap | candidate | blocks | durable bytes | overhead B/record | verdict |
|---|---|---|---|---|---|---|
| structure-50k (15.1 B mean) | 4096 | **F0** | 174 | 712,512 | **0.03** | PASS **stream only** |
| | | **F1v** varint | 187 | 762,616 | **1.03** | **PASS** |
| | | **F1f** fixed u32 | 224 | 912,912 | **4.04** | **PASS** |
| | | **F2** trailing dir | 224 | 913,808 | **4.05** | **PASS** |
| | | **F3** slots W=20 | 246 | 1,001,968 | **5.82** | **PASS** |
| mixed-5k (354 B mean) | 16384 | **F0** | 114 | 1,858,275 | 0.18 | PASS **stream only** |
| | | **F1v** | 129 | 1,864,289 | **1.39** | **PASS** |
| | | **F1f** | 130 | 1,878,403 | 4.21 | **PASS** |
| | | **F2** | 130 | 1,878,923 | 4.31 | **PASS** |
| | | **F3** slots W=8192 | **5000** | **41,000,000** | **7828.53** | PASS |

F0's record claim is not a failure to decode — it is unrecoverable *by
construction*. Count, order and length of records do not exist in the durable
bytes. F0 carries a byte stream and nothing else.

**On a 15-byte record, a flat 4-byte prefix is a 27% tax and a varint is 7%.**

**F3 on an unbounded distribution costs 22× the bytes and 22× the blocks.** It
round-trips correctly and is catastrophically expensive — a loser with a
number, not an opinion.

### Oversize records — a real limit of every framed candidate, measured

No framed candidate can span a block. At `cap=4096` against the mixed corpus
(max record 8176):

```
f1f  blocks=131  records_too_large=49  VERIFY FAIL: record count 1951 != corpus 2000
f1v  blocks=131  records_too_large=49  VERIFY FAIL: record count 1951 != corpus 2000
f2   blocks=131  records_too_large=49  VERIFY FAIL: record count 1951 != corpus 2000
```

The probes skip such a record and count it rather than truncating or silently
widening, so the failure is loud. F0 has no such limit — it chunks through a
record without noticing, which is the same property that loses it framing.
**`cap` must exceed the largest record** for F1/F2/F3 as built. Record
spanning was not a declared candidate and has not been built.

### T1b — round trip across a REAL restart (two process lifetimes)

10,000 records, first half written by one process, second half by a second
process launched after the first exited. `seq` mints from 0 in both, which is
the live path's B0 behaviour (`mem_controller.m1:46`).

| candidate | blocks after | verdict |
|---|---|---|
| F0 | 33 | FAIL — stream bytes differ |
| F1f | 22 | FAIL — record count 5000 != corpus 10000 |
| F1v | 18 | FAIL — record count 5000 != corpus 10000 |
| F2 | 22 | FAIL — record count 5000 != corpus 10000 |
| F3 | 25 | FAIL — record count 5000 != corpus 10000 |

**Every framing candidate fails the primary test.** Run 2's `block-0.bin`
lands on run 1's, and exactly half the corpus survives. This is not a defect
in any framing scheme — it is proof that **framing alone does not deliver
round-trip across restart**, and that the block-id question (P2) is load-
bearing for the intent's primary success criterion, not a secondary concern.

### T2 — crash correctness, by real SIGKILL at unaligned points

4 trials per candidate, kill delay randomised over 20–400 ms, real signal 9 to
a live writer. Surviving prefix required to be byte-exact.

| candidate | trials | killed mid-write | prefix byte-exact | temp files left | truncated targets | density broken |
|---|---|---|---|---|---|---|
| F0 | 4 | 4 | **4** | 3 | **0** | **0** |
| F1f | 4 | 4 | **4** | 3 | **0** | **0** |
| F1v | 4 | 4 | **4** | 1 | **0** | **0** |
| F2 | 4 | 4 | **4** | 2 | **0** | **0** |
| F3 | 4 | 4 | **4** | 3 | **0** | **0** |

Two findings, both independent of which framing wins:

1. **No candidate ever left a truncated or corrupt durable block.** The
   temp+fsync+rename+dir-fsync protocol means a target file is either fully
   there or not there. A crash loses the tail; it never corrupts the head.
2. **A crash does leave `.tmp.<pid>.<n>` files, and nothing sweeps them.**
   9 across 20 trials. This is the surface the earlier block-id work already
   flagged — "naive parse broke density (the temp file voted)" — now confirmed
   to exist in the real substrate, not just the Rust replica. It is a direct
   input to P2's B1 resolver, which must parse strictly.

### T3 — per-record framing cost in nanoseconds (packing only, no fsync)

fsync is 9 ms and would bury any framing difference, so packing is timed in
isolation.

| candidate | 1k | 10k | 100k | mixed 5k | linear? |
|---|---|---|---|---|---|
| F0 | 16 | 3 | **2** | 18 | n/a — F0 does no per-record work at all |
| F1f | 291 | 294 | **286** | 335 | flat |
| F2 | 338 | 306 | **322** | 342 | flat |
| F3 | 373 | 307 | **299** | 772 | flat |
| F1v | 424 | 368 | **364** | 399 | flat |

ns per record. Every candidate is flat from 1k to 100k — the packing loops are
linear, measured, not argued. (They hold no list and name none, so there is no
`Value::List` to deep-copy; the numbers confirm it.)

F0's 2 ns/record is not a framing cost — its loop runs once per *block*, doing
one large `mem_copy_raw`. It does no per-record work because it does no
framing.

**F1v's varint arithmetic costs ~78 ns/record more than F1f's flat store.** At
100k records that is 7.8 ms of packing — against the 333 ms of fsync that
F1v's 37 fewer blocks save. The arithmetic is free in every sense that matters.

Framing packing is **1.4%** of a durable run (28.7 ms of packing against
2043 ms total at 100k records / 224 blocks).

### T4 — write cost per durable block, against 9.10 ms / 2.00 fsyncs

| candidate | corpus | blocks | ms/durable block | total ms | fsyncs/block |
|---|---|---|---|---|---|
| F0 | structure-50k | 174 | 8.942 | 1555.9 | 2.0000 |
| F1v | structure-50k | 187 | 8.771 | **1640.2** | 2.0000 |
| F1f | structure-50k | 224 | 9.122 | 2043.3 | 2.0000 |
| F2 | structure-50k | 224 | 9.189 | 2058.4 | 2.0000 |
| F3 | structure-50k | 246 | 9.056 | 2227.8 | 2.0000 |
| F0 | mixed-5k | 114 | 9.288 | 1058.8 | 2.0000 |
| F2 | mixed-5k | 130 | 9.366 | 1217.6 | 2.0000 |
| F1f | mixed-5k | 130 | 9.569 | 1244.0 | 2.0000 |
| F1v | mixed-5k | 129 | 9.752 | 1258.0 | 2.0000 |
| F3 | mixed-5k | 5000 | 9.141 | **45704.4** | 2.0000 |

**No candidate regresses per-block cost.** Every one sits in the 8.77–9.75 ms
band around the 9.10 ms baseline, and every one costs exactly 2.00 fsyncs —
no candidate buys anything with an extra barrier.

**The cost of framing is entirely block count, not block cost.** Against F0 on
the structure corpus: F1v +7.5%, F1f/F2 +31.3%, F3 +43.2% total wall clock,
all of it fsyncs for the extra blocks the overhead bytes force.

### Negative control on the framed candidates

20 of 20. Every framed store, broken five ways (`truncate`, `flip`, `drop`,
`reorder`, `shiftlen` — a length prefix bumped by one, which shifts every
boundary after it), failed verification every time.

---

## What P1 settles, and what it does not

**Settled by measurement:**

- F0 cannot frame records. Not "does not" — cannot; the information is absent.
- F1v is the cheapest framing that works: 1.03 B/record on 15-byte records
  versus 4.04 for F1f and 4.05 for F2, at +7.5% total write cost versus F0's
  +0% and F1f/F2's +31.3%.
- F1f and F2 cost the same bytes (4.04 vs 4.05 B/record) and nearly the same
  time. F2's claim is a read-side one — one tail seek gives every boundary
  without touching payload — and **P1 did not measure the read side.**
- F3 is applicable only to a bounded distribution: 5.6% waste on structure,
  95.7% and 22× the blocks on mixed.
- Every framing candidate holds the 2.00-fsync barrier and the ~9.1 ms block.
- Crashes never corrupt a durable block; they leave uncollected temp files.

**Not settled, and needs P2:**

- **Round trip across restart fails for all five.** It is a block-id property.
- F2 versus F1v cannot be decided on write-side numbers — they differ on
  read-side boundary access, which is the same axis structure/payload
  separation lives on.
- Whether structure/payload separation changes any of the above, including
  whether it makes F3 viable by making the stream bounded.

**Not built, not claimed:** record spanning across blocks. It was not a
declared candidate. Without it, `cap` must exceed the largest record for
F1/F2/F3.


---

## P2 — block id and structure/payload separation

One sweep, `p2-blockid-separation.sh`. Framing held fixed at F1v so a
difference between candidates is a difference in the thing under test.

### T1 — PRIMARY: round trip across two real restarts

One 9,000-record corpus, written by **three consecutive process lifetimes**,
decoded by a fourth.

| scheme | block files | first seq per run | verdict |
|---|---|---|---|
| **B0** mint from 0 | 11 | 0, 0, 0 | **FAIL** — 3000 of 9000 records survive |
| **B1** max+1 strict | 32 | 0, 10, 21 | **PASS** |
| **B2** per-run dir | 32 | 0, 0, 0 | **PASS** |
| **B3** leased range | 32 | 0, 256, 512 | **FAIL** — not dense; position 10 holds id 256 |

**B1 and B2 deliver the intent's primary success criterion. B0 and B3 do not.**

B3's failure is not data loss — every record is on disk and readable. It fails
*density*: each run abandons the unused remainder of its lease, so the id
sequence has holes. The continuation footer asserts block k is followed by
k+1, and any replay using "first missing file" as its frontier stops at the
first hole. Density is a requirement here, not a preference.

### T2 — crash matrix: real SIGKILLs, then restart, repeatedly

3 rounds per scheme. Each round spawns a real writer, SIGKILLs it at a
randomised unaligned point, and restarts. A **collision** is a block path a
later run replaced — detected by inode change, so it fires whether or not the
bytes differ.

| scheme | rounds | killed | **collisions** | density broken | temp files left | ids left unused |
|---|---|---|---|---|---|---|
| **B0** | 3 | 3 | **22** | 0 | 5 | 0 |
| **B1** | 3 | 3 | **0** | 0 | 0 | 0 |
| **B2** | 3 | 3 | **0** | 0 | 5 | n/a (per-run namespace) |
| **B3** | 3 | 3 | **0** | **1** | 3 | **483** |

B0 reissued 22 ids across 3 crash-restart rounds. B1 and B2 reissued none and
stayed dense. B3 never collided — the reservation is taken before use — and
paid for it with 483 abandoned ids after 3 crashes.

**Two harness defects were caught here by the controls, not by inspection.**
The collision detector originally compared content hashes and reported *zero*
collisions for B0, because B0 rewrites `block-0.bin` from the same corpus with
byte-identical content. Inode comparison is the correct probe. Separately, the
"unused ids" metric was computed as max-id + 1 − file-count, which is
meaningless in B2's per-run namespace and came out **negative**. Both are the
same failure mode as the P0 corpus-seed slip: a measurement that agreed with
the truth by accident.

### T5 — startup id-resolution cost, in M1 through the real bridge

| scheme | entries folded @1k / 10k / 100k | resolve time @1k | @10k | @100k |
|---|---|---|---|---|
| **B0** | 0 / 0 / 0 | 0.017 ms | 0.015 ms | **0.015 ms** |
| **B1** | 1k / 10k / 100k | 1.77 ms | 18.1 ms | **195.3 ms** |
| **B2** | 1 / 3 / 25 | 0.074 ms | 0.081 ms | **0.190 ms** |
| **B3** | 0 / 0 / 0 | 10.8 ms | 24.5 ms | **29.1 ms** |

B1 is linear in the number of durable blocks — 1.77 → 18.1 → 195.3 ms is
1.00× / 10.2× / 110× against 1× / 10× / 100× of population. `foreach` behaves
as the list-fold finding requires; there is no quadratic term. Extrapolating
the measured slope puts B1 at **~2 s at 1M blocks**, consistent with the
2.76 s the earlier probe measured directly.

B2 folds over run directories instead of blocks, so its 100k-block cost is
**0.19 ms — 1,028× cheaper than B1's**.

B3's resolve is O(1) in population but costs a durable write: 10.8–29.1 ms,
i.e. one to three fsync pairs, and it is the **most expensive resolve at 1k
and 10k**, only overtaking B1 somewhere past 10k blocks.

### T4 — write cost per durable block, against 9.10 ms / 2.00 fsyncs

| scheme | lease | blocks | ms/durable block | total ms | fsyncs total | fsyncs/block |
|---|---|---|---|---|---|---|
| **B0** | — | 72 | 9.881 | 711.5 | 144 | **2.0000** |
| **B1** | — | 72 | 10.182 | 733.1 | 144 | **2.0000** |
| **B2** | — | 72 | 9.282 | 668.3 | 144 | **2.0000** |
| **B3** | 1 | 72 | **18.104** | 1303.5 | 290 | **4.0278** |
| **B3** | 16 | 72 | 9.493 | 683.5 | 154 | 2.1389 |
| **B3** | 256 | 72 | 9.163 | 659.7 | 146 | 2.0278 |

**This answers the intent's open question.** A durable block-id scheme costs
an fsync only if it reserves per block: B3 at lease 1 is **18.10 ms and 4.03
fsyncs — a 99% regression**, which reproduces the earlier hand-replica's
18.x ms almost exactly, now through the bridge's own barrier. Amortised over
16 ids the cost is 4%, over 256 ids it is 0.7% and inside the run-to-run
spread.

**B0, B1 and B2 add no fsync at all: exactly 2.0000 per block, identical to
the baseline.** B1 and B2 pay only at startup, once.

### S0 / S1 / S2 — separation, write side

10,000 mixed records: 7,958 structure (104 KB) and 2,042 payload (3.57 MB).
Routing is by size at a 32-byte threshold — the distribution is cleanly
bimodal (structure ≤ 31 B, payload ≥ 64 B), so a size threshold and a type tag
select the same records without changing the corpus format.

| candidate | stream | blocks | durable bytes | ms | verdict |
|---|---|---|---|---|---|
| **S0** | combined | 256 | 3,684,948 | 2372 | PASS |
| **S1** | structure | 7 | 112,333 | 80 | PASS |
| | payload | 251 | 3,572,631 | 2322 | PASS |
| **S2** | structure | 7 | 112,333 | 73 | PASS |
| | payload | 251 | 3,572,631 | 2415 | ids 7..257, no overlap |

**Separation costs nothing on the write side.** 258 blocks split versus 256
combined — two extra blocks, from each stream rounding up its own last partial
block. Total time is within run-to-run noise. Both streams round-trip
independently against their own filtered corpora.

S2 differs from S1 only in that the payload stream continues the structure
stream's id space (ids 7..257), so a structure record can name a payload
location with a single id and no second mapping. That costs nothing and is
observably non-overlapping.

### T6 — structure-only replay vs scanning everything, MEASURED

| candidate | scanned | blocks opened | bytes read | records decoded | scan ms |
|---|---|---|---|---|---|
| **S0** | everything (structure interleaved with payload) | 256 | 3,684,948 | 10,000 | **54.36** |
| **S1** | structure stream only | 7 | 112,333 | 7,958 | **2.33** |
| **S2** | structure stream only | 7 | 112,333 | 7,958 | **2.16** |

**Separation makes structure replay 23–25× faster and reads 33× fewer bytes,
opening 37× fewer blocks.**

This is *not* the ~1000× the earlier arithmetic predicted, and the difference
is worth stating plainly: the ratio is set by the structure fraction of the
corpus, which here is 2.8% of bytes. The earlier figure came from disk rates
against a 640 GB / 5 GB estimate, not from a measurement of this system. **The
real number on a measured workload is 23×**, and it scales with whatever the
structure/payload byte ratio actually turns out to be.

**A real bug was found here, and only by S0.** The M1 scanner panicked with
`mem_read_int_raw: offset must be >= 0, got -83`. `mem_read_int_raw` returns a
*signed* i64, and `int_mod` on a negative left operand returns a negative
remainder — so any block whose bytes at a record boundary had the top bit set
decoded a negative length and walked the cursor backwards off the front of the
buffer. S1's structure stream never triggered it because its records are ASCII
and never set the top bit. **Only the interleaved control had payload bytes
random enough to expose it.** Fixed by taking the low 16 bits explicitly. This
is a hazard for any future M1 code decoding binary through `mem_read_int_raw`.

### Negative control on the P2 suites

6 of 6, after two harness defects were found and fixed:

| control | result |
|---|---|
| collision detector fires on B0 | ✓ (22 collisions) |
| collision detector silent on B1 / B2 / B3 | ✓ ✓ ✓ |
| scanner reports fewer records after a dropped block | ✓ 6806 < 7958 |
| round trip still FAILS under B0 | ✓ |

---

## P2 summary — what the numbers say

**Block id.** B1 and B2 both pass the primary test and both are crash-clean
over real kills with zero collisions and no density breaks. They differ only
in startup: at 100k blocks B1 costs 195 ms and grows linearly, B2 costs
0.19 ms and grows with run count. B0 collides 22 times in 3 crash rounds. B3
never collides but breaks density — 483 abandoned ids after 3 crashes — and at
lease 1 it costs 18.10 ms/block and 4.03 fsyncs, a 99% regression; only at
lease ≥ 256 does it come inside the baseline spread.

**Separation.** Free on the write side (258 blocks vs 256, time within noise)
and 23× cheaper on structure replay, reading 33× fewer bytes. S1 and S2 are
indistinguishable on every measured axis; S2's shared id space additionally
lets a structure record reference a payload block by id alone, with no second
mapping and no measured cost. Separation is also what would make F3 viable at
all: P1 measured F3 at 5.6% waste on a structure-only stream and 95.7% on a
mixed one.

**Everything still holds.** Write path byte-identical to the P0 baseline
(`WRITE_PATH_UNTOUCHED`), slice test green, no WAL, no lock, no second writer,
`readtier/` untouched.
