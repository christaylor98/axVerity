# AXVERITY_FORMAT_LAND_AND_WIRE_V1 — P0, P1, P2 (end of Pass 1)

Machine: 32-core Linux 6.1, ext4 on NVMe. Every durable measurement is the real
`fs_write_raw` barrier (temp + fsync + rename + parent-dir fsync,
`bytes_io.rs:83-98`), and every M1 number is M1 through the real bridge.

Selections implemented, unchanged from the P2 gate: **F1v** varint framing,
**B1** max+1 strict block ids, **S2** separate streams over one shared id space.

---

## P0 — the int_mod hazard, fixed at the primitive

`int_div` and `int_mod` were Rust's `/` and `%`, which truncate toward zero and
return a **negative remainder** for a negative left operand. M1 has no
byte-width load: the only way to read a byte is `mem_read_int_raw`, an 8-byte
**signed** read. A decoder on a record boundary therefore pulls in the seven
bytes after it, and any of them setting the top bit makes the word negative.
`int_mod(v, 256)` then returned a negative "byte", which was used as a varint
length and added to the read cursor, driving it below zero.

Both are now **Euclidean** (`div_euclid` / `rem_euclid`).

**Both, not just the remainder.** For a power-of-two divisor Euclidean division
*is* an arithmetic shift and Euclidean remainder *is* a bit mask, so
`int_mod(int_div(v, 256^k), 256)` extracts byte `k` of `v`'s two's-complement
representation correctly at every `k`. Fixing only the remainder would leave
every byte above the lowest silently wrong on a negative word — the same
hazard, half-fixed.

**Blast radius was checked, not assumed.** Every pre-existing call site in both
M1 trees takes a non-negative left operand, where Euclidean and truncated agree
exactly. No existing caller changed behaviour.

### The negative control (`experiments/intmod-m1/`)

All 256 byte values through a real record boundary in real raw memory.

| | truncated `/` `%` | Euclidean |
|---|---|---|
| byte values checked | 256 | 256 |
| **failures** | **128** | **0** |
| first failing byte | 128, decoded as −128 | — |
| `0xAD` decodes to | **−83** | **173** |
| raw word read | −5931894172722287187 | *identical* |
| exit | 1 | 0 |

Failures are exactly the 128 top-bit-set values; the 0..127 half passes in both
columns, which is the control's own control. The **raw word is identical in
both** — the read never changed, only the extraction.

End to end, decoding a 2000-record mixed store with random payload bytes and
the old call-site workaround removed:

| | truncated | Euclidean |
|---|---|---|
| outcome | **panics, never terminates** — `offset must be >= 0, got -50`, respawned | completes |
| records | — | **2000 / 2000 in 9.68 ms** |

Non-regression across all three consumers of the shared crate: **506 bridge
tests**, write-path slice test ALL PASS, read tier **98/98**.

---

## P1 — the combination, proven in `experiments/`

The prior round measured F1v, B1 and S2 separately and each passed. Two
interactions are visible only with all three on at once:

- S2 keeps two stream directories but **one** id space, so B1's max+1 must scan
  the **union**. Reading one directory re-mints ids the other holds — the B0
  defect reached from a different direction.
- Under S1 each stream is dense from 0. Under S2 **neither is**: block *k* lives
  in whichever stream filled first. Density is a property of the union, and a
  per-directory check fails a correct store while passing a collided one.

The prior S2 measurement ran the probe twice with a hand-fed starting id, which
exercises neither. P1 runs one process filling both streams from one counter.

**22 of 22.**

| test | result |
|---|---|
| **T1** three clean lifetimes, decoded by a fourth process | first seq **0, 9, 20**; **1200/1200** records byte-exact; union dense 0..29 |
| **T3 PRIMARY** three real SIGKILLs, resumed, fourth lifetime completes | **3000/3000** records byte-exact; union dense 0..71 |
| **T4** strict parse rejects temps (3 arms) | `block-999.bin.tmp.31337.4` ignored (resolved 5); the same id as `block-999.bin` **does** move it to 1000; a block in the other stream moves it to 778 |
| **T5** oversized records at cap=4096 | 35 counted, exit non-zero, verifier independently fails it, same corpus passes at cap=16384 |
| **T2** crash | head survives intact; **zero reissued ids** over 4 real SIGKILLs |
| **NC** collision / hole / misroute | each caught |

### Finding: the two streams have different durable frontiers

They seal independently, so a crash leaves them at different points. Measured
across three kills: structure **0, 0, 0** while payload reached **30, 58, 89**.
Resuming both from one global corpus index re-writes whatever the ahead stream
already holds, so the P1 probe resumes **per stream**. The real write path never
replays input, so this is a property of replaying a fixed corpus, not of the
format.

### Three test defects, caught by results rather than by reading

- Cumulative rather than per-lifetime record counts recovered **1272 records
  from a 1200-record corpus** — `loop_count` does not stop at input exhaustion.
- Piping probe output into `grep -m1` **hangs forever**: grep exits at the first
  match, the probe takes EPIPE, and its panic handler respawns the entry.
- The misroute control was passing on the **density** check, reporting "caught"
  while testing something else. It now asserts the routing message itself.

---

## P2 — THE SINGLE TOUCH

### What changed, with hashes

**9 of the 15 baseline files changed; 6 are byte-identical; 7 files were added.**

| file | P0 | after P2 | why |
|---|---|---|---|
| `src/hot_mem_write.m1` | `5f9ae2936717` | `3d7c3108eb77` | input is now a record stream; adds the counting pass |
| `lib/wp_write_step.m1` | `374a8f94d4ec` | `da839ca41fb6` | **F1v lands here** — framing replaces fixed chunking, plus S2 routing |
| `src/mem_controller.m1` | `493f319a3bc5` | `6822b098cad7` | **B1 lands here** — seq seeded from `wp_bid_resolve`, not `Int(0)` |
| `lib/wp_mem_controller_step.m1` | `0cd1e44f643f` | `3d62ef8928fc` | length and stream arrive with the seal signal instead of being derived |
| `lib/wp_flusher_step.m1` | `762a1b7ec236` | `f52a4aada333` | **S2 lands here** — stream directory; **plus the P3 publish point** |
| `src/flusher.m1` | `ffacee2901ac` | `383ab2237914` | two stream dirs; watermark seeded `first-1` |
| `src/disk_controller.m1` | `6bbfeb82caee` | `d6eb5916cf1f` | block count from a channel |
| `src/ack_bench.m1` | `51dbcadac85c` | `a16beb3d1a59` | absolute seqs; block count from a channel |
| `lib/wp_block_capacity.m1` | `e362b1c4e0ab` | `7b1d161b0174` | 64 → 16384 (`CAP_EXCEEDS_LARGEST_RECORD`) |
| `lib/wp_footer_size.m1` | `87a5d9d8fa30` | *unchanged* | |
| `lib/wp_disk_controller_step.m1` | `8e7db074fcb8` | *unchanged* | |
| `lib/wp_wait_durable{,_more,_step}.m1` | | *unchanged* | |
| `lib/wp_ack_bench_step.m1` | `390cd55daa67` | *unchanged* | |

Added: `wp_stream_threshold`, `wp_bid_parse`, `wp_bid_scan_step`,
`wp_bid_resolve`, `wp_seal_stream`, `wp_flush_tail`, `wp_count_step`.

The P2 baseline is recorded in `write-path-hashes-p2.txt`. `check-hashes.sh`
now checks against it by default and `--p0` still prints what the touch did.

### Why the block count moved to a channel

Under fixed chunking the block count was `ceil(input_size / PCAP)` and every
thread took it from argv. Under F1v it depends on how records pack and how they
route, so `hot_mem_write` computes it with a **counting pass over the real
packer** (`dry=1`: same code, same arithmetic, claims no pool block, signals
nothing) and publishes one copy per consumer. Using the same fn for both passes
is the point — a separately written estimator could disagree, and a count one
too low leaves three threads blocked forever.

### The publish point for P3

`wp-durable-block` carries `[seq, stream, len]` after every durable write. It is
a **depth-1 latest-value mailbox**: trimmed to empty before every send, so it
can never fill and can never stall the writer, at any channel capacity, with
nothing listening. `bchan_send` blocks when full and M1 has no non-blocking
send, so a naive publish channel with no consumer would deadlock the flusher —
a publish point that stalls the writer would be worse than none.

It is a liveness hint, not a log. The durable store is the source of truth; P3
rebuilds from the structure directory and uses this only to know something just
landed.

### Two defects found during the landing

**The real pass was hash-consed out of existence.** The counting pass and the
real pass were two textually identical `loop_count(nrec, sptr, wp_write_step)`
calls, and `loop_count` is declared `effect pure` + `deterministic true`, so
**CCall CSE merged them into one**. The counting pass ran, the real pass
silently did not exist, and all five threads parked in `bchan_take` forever with
no error. `wp_count_step` exists to make the two calls distinguishable.

**The durable watermark was seeded −1.** `wp_flusher_step` advances it with a
plain CAS from `seq-1`, which is safe because blocks eject in strict FIFO order
— but under B1 a run no longer starts at seq 0. On a store whose next id is 36,
a cell seeded −1 makes the first CAS expect 35, find −1, fail silently, and
every `wp_wait_durable` caller blocks forever. The second lifetime of the
round-trip test deadlocked in exactly that way. It is now seeded `first-1`; −1
was never a sentinel, it was `first-1` for the only run that could exist before
restarts worked.

### Acceptance test — ALL PASS

```
input: 1500 records, CAP=16384 PCAP=16376 THRESH=32
PASS EJECTION_IN_RUN: 36 block files ejected (structure=1 payload=35)
PASS FOOTER_CHAIN_CORRECT: 36 blocks, ids 0..35, chain unbroken across both streams
PASS SLICE_ROUNDTRIP: structure_records=1219/1219 payload_records=281/281
PASS ROUND_TRIP_ACROSS_RESTART: run 2 minted from 36, union dense 0..72, no id reissued
PASS ROUND_TRIP_ACROSS_RESTART: structure_records=2431/2431 payload_records=569/569
PASS OVERSIZE_FAILS_LOUDLY: FATAL records_too_large=1 cap=16376 and exit non-zero
PASS PUBLISH_POINT: wp-durable-block published with no consumer, writer never stalled
```

`PASSTHROUGH_PROBE` is gone as written — the first block's payload is no longer
the first N input bytes, because every record now carries a varint ahead of it.
What it tested (dispatch does not transform record bytes) is covered by the
byte-identical record compare in `SLICE_ROUNDTRIP`, which is strictly stronger.

Decoding is done by `experiments/format/harness` (`fmth verify-s2`), an
independent Rust implementation written before this format landed and sharing
no code with the M1 writer.

### Crash suite — 8 of 8, with teeth

| | |
|---|---|
| 3 of 3 writers died of a real SIGKILL mid-write | PASS |
| **zero ids reissued** across 3 crash-restart rounds (inode identity) | PASS |
| union dense 0..11 across both streams, no id in both | PASS |
| every surviving block decodes — no truncated or corrupt block | PASS |
| NC1 same id in both streams → caught | PASS |
| NC2 hole in the union → caught | PASS |
| NC3 truncated block → caught | PASS |

Collisions are detected by **inode identity**, not content hashing: a reissued
id always lands on a new inode because `fs_write_raw` renames a fresh temp over
the target. Content hashing reports *zero* collisions for mint-from-zero, which
reissues 22, because that scheme rewrites the same corpus to the same bytes.

### COST_BASELINE_HELD

10,000 mixed records → 249 durable blocks, 5 runs, fresh store each time.

| measure | baseline | landed | delta |
|---|---|---|---|
| wall clock / durable block | 9.097 ms | **9.005 ms** | **−1.0%** |
| ack-path median | 9.038 ms | **8.970 ms** | **−0.8%** |
| **fsyncs / block** | 2.0000 | **2.0000** | **0** — 498 fsyncs / 249 blocks, counted with strace |

**No regression** — but see the correction below on how precisely that can be
said. The fsync count is exactly identical, which is the part that IS resolvable.

> **Correction (added after a drift check).** The "−1.0%" above is over-precise
> and should not be read as the format being faster. Both 9.097 and 9.005 are
> medians of five runs taken on ONE occasion each, and the BETWEEN-session
> spread was never measured. It has since been measured: three independent
> sessions on the same unchanged binary, minutes apart on a quiet machine, gave
> session medians of **8.959 / 9.655 / 9.318 ms — a 7.8% spread**. Any delta
> smaller than that is not resolvable, which includes both the −1.0% claimed
> here and a +3.9% observed later. The honest statement is: **wall-clock cost is
> unchanged within a measurement precision of about ±8%, and the fsync count is
> exactly 2.0000, which is not a statistical claim at all.**
>
> The methodological lesson is the one this project keeps re-learning: a number
> reported to three decimals from a single session invites a comparison the
> measurement cannot support. `experiments/format/drift-check.sh` exists to
> supply the between-session spread before any future cost claim is made.

The one cost the format **adds** is B1's startup resolve, paid once per run, off
the hot path:

| durable blocks in store | total run |
|---|---|
| 0 | 12.60 ms |
| 1,000 | 14.51 ms |
| 5,000 | 20.23 ms |

≈1.5–1.9 ms per 1,000 blocks, linear, consistent with the 1.77 ms/1k measured in
the probe. Extrapolated to 1M blocks that is ~2 s — a once-per-restart cost, and
the price of keeping a RID one integer.

### RID_IS_ONE_INTEGER

`seq` is a plain `Int` at every point it exists: incremented with `int_add`,
formatted with `int_to_str` into `block-<seq>.bin`, compared with `int_sub` for
the watermark. The filename carries **no stream component** — the stream selects
the directory, not the identity — and the union across both directories is dense
in `seq` alone. No compound key anywhere.

---

## What Pass 1 settles, and what it does not

**Settled:**

- Records round-trip across a real process restart in the landed write path.
- The int_mod hazard is fixed at the primitive, shown to fail before the fix.
- Write cost is not regressed: 9.005 ms and exactly 2.0000 fsyncs.
- The write path was touched exactly once, and the diff is hashed.
- A RID is one integer.
- The publish point exists and cannot stall the writer.

**Not settled, and belongs to Pass 2:**

- Whether the read tier can actually be wired through `wp-durable-block` and the
  stream directories **without a second write-path touch**. The tap exists and is
  safe; nothing has consumed it yet.
- Cold rebuild cost from the structure stream at realistic population.
- Whether the durable name-index's per-entry cost is acceptable — the RAM tier
  measured 2.4 KB/triple, ~30x above what the capacity arithmetic assumed.

**Not built, not claimed:** record spanning across blocks. `cap` must exceed the
largest record, and a record above it fails loudly.

---

# P3, P4 — Pass 2

## P3 — the read tier, wired

### The unknown is answered: no second write-path touch

The intent's open question was whether the read tier could be wired without
touching the write path again — "the fan-out tap does not exist; the pipeline
is fixed --entries threads over static bchan channels."

It can, and the reason is that **it does not need a tap**. The durable store is
a shared artefact, not a channel. `rt_rebuild` reads
`.axverity-store/structure/` directly. `check-hashes.sh` runs as part of the
durable suite and reports all 22 write-path files byte-identical to the P2
baseline, so the claim cannot quietly rot.

The `wp-durable-block` publish point landed in P2 is unconsumed and stays that
way. It is a liveness hint for a future incremental indexer; nothing in P3
needs it, because a rebuild reads the store.

### A RID is one integer, and it names a record

```
rid = block * 16384 + ordinal    block = rid / 16384    ord = rid % 16384
```

Packed arithmetically, decoded with two divisions, no stored mapping anywhere.
This is precisely what B1 bought over a scheme that resolved **1,028× faster**:
with a dense flat block namespace one integer still names one record. Under a
per-run namespace the block would already have been a `(run, seq)` pair before
the ordinal was added.

The stride is asserted at scan time. An ordinal reaching it would alias two
records onto one RID, silently and permanently, so it fails loudly instead.
The suite decodes a RID independently in Python and checks it names the same
record the read tier returned.

### Results — 14/14 durable, 98/98 RAM unchanged

| test | result |
|---|---|
| **T1** cold start, 6000 records / 5 blocks | 18/18 assertions in a process that never saw the writer; 3007 names; all eight patterns against the corpus's own arithmetic, plus an absent triple and an unknown name |
| **T2** after a real restart | 10 blocks; records **double to 12000** while every query answer is unchanged |
| **T3** mixed store | rebuilt exactly the **3236 structure records**, ignored all **95 payload blocks**, zero malformed. Structure is 3.3% of durable bytes |
| **T4** leftover `.tmp` | ignored and counted as skipped; the **same bytes** named `block-99999.bin` **are** decoded, so arm one is not vacuous |
| **T5** point read | `s0` → RID 0 → `s0/v0/t0`, independently decoded from the raw block; an unknown name returns −1 |
| **NC** | dropping a block fails the cold suite; a corrupt length prefix is counted malformed, not indexed |

T2 is the one worth dwelling on. The structure generator is a pure function of
the record index, so lifetime 2 writes the *same* triples again. The record
count must double while every answer stays identical — which separates "read
both lifetimes" from "read only one" in a way neither a count check nor an
answer check could alone.

### Two decisions

**Decoding goes through raw memory, not the Bytes API.** `Value::Bytes` is a
plain `Vec<u8>` with no structural sharing, and `bytes_get` is declared
`vec![Bytes, Int]` with its argument emitted as `.clone()` — so per-byte access
copies the whole block and a scan is O(N²). This is the list-fold finding's
twin in the Bytes family, and it is worth recording as such: the same defect
shape, a different type. A block is staged once with one `mem_write_raw` and
never named again.

**The scan is `loop_while`, not `loop_count`.** A block records no record
count; the file's own length is the terminator, which is what lets blocks be
variable-length and unpadded. The only *safe* `loop_count` bound is one
iteration per payload byte, i.e. ~16,000 no-op iterations per block regardless
of contents — which would have made the cold-rebuild measurement a measurement
of the bound. `loop_while` clones its accumulator every iteration, so the
accumulator is the scratch **pointer** and the block stays in raw memory.

---

## P4 — measured

Each population is written by a real `wp-slice` process and read by a separate
`rt-driver` process that never saw the writer.

### T9 — cold rebuild, linear across two decades

| n | blocks | durable bytes | names | rebuild | ns/record | B/triple |
|---|---|---|---|---|---|---|
| 1,000 | 1 | 16,224 | 507 | 32.4 ms | 32,370 | 16 |
| 10,000 | 9 | 145,288 | 5,007 | 343 ms | 34,348 | 14 |
| 100,000 | 99 | 1,616,008 | 50,007 | 3.66 s | 36,607 | 16 |

10× population costs **10.61×** then **10.66×**. Extrapolating puts 1M at
**~37 s — extrapolated, not measured**, and consistent with the RAM tier's own
34 s build at 1M.

**Cold rebuild is not a disk cost.** Pure RAM ingest on this machine is
28,730 ns/triple; the rebuild is 34,348 ns/record at the same population.
Reading and decoding durable bytes is the remaining **~3.5 µs, about 11%**. The
other 89% is the ingest it feeds — `rt_insert_names`, unchanged.

### Per-pattern latency after a cold rebuild

| pattern | cold 1k | cold 10k | cold 100k | RAM (W5) |
|---|---|---|---|---|
| `S??` | 46,327 | 46,981 | 45,771 | 46,462 |
| `??T` | 47,911 | 49,046 | 48,349 | 48,593 |
| `SV?` | 14,110 | 14,248 | 13,649 | 13,666 |
| `?VT` | 14,407 | 14,548 | 14,270 | 14,068 |
| `S?T` | 14,289 | 14,186 | 14,270 | 13,721 |
| `SVT` | 9,601 | 9,529 | 9,567 | 9,202 |
| `?V?` per result | 10,372 | 9,897 | — | 9,779 |
| `???` per result | 11,199 | 10,808 | — | 10,509 |

Flat across 100×, and matching the RAM column. Nothing in a projection
remembers where its triples came from.

### T10 — bytes/triple durable, reported only

**14–16 B/triple on disk**, against **1,664 B/triple resident** at 10k and
1,950 at 100k. Durable is **~120× cheaper per triple than resident**. The
capacity ceiling the RAM tier hit (2.4 KB/triple, ~30× above what the capacity
arithmetic assumed) is a RAM constraint, not a storage one. No fix attempted
here, as instructed.

### Point reads — and the read-side case F2 was waiting for

Block 0, fixed ordinal, so locating the file costs the same in every row:

| ordinal | ns/read |
|---|---|
| 0 | 15,917 |
| 200 | 213,348 |
| 400 | 407,909 |
| 800 | 803,916 |

Linear at **~985 ns per record skipped** on a **~16 µs** fixed cost. F1v frames
each record with a length and nothing else, so reaching record *k* means
decoding the *k* before it. A full `name → RID → bytes` round trip measures
**478–593 µs**, population-independent — it depends on records-per-block, not
on store size.

**T12's trigger condition is now met.** F2's trailing directory was rejected on
write-side numbers with its claim explicitly recorded as untested: "one tail
seek gives every boundary without touching payload, and P1 did not measure the
read side." The read side is now measured. A directory would replace the
k × 985 ns walk with a seek — roughly the 16 µs fixed cost, about **50× at the
mean ordinal**, and the advantage grows with block capacity. **This is a
measurement, not a proposal.** Re-opening F2 is the intent owner's decision.

**A defect this measurement caught.** The first ordinal sweep came back *flat*
at ~1.17 ms for every ordinal, which reads like a fixed cost dominating. It was
not: mode-1 scans had no early exit and walked the whole block after finding
their record. The flatness was the signature. With the exit, ordinal 0 is
**73× faster** (15.9 µs vs 1.17 ms) and the linear shape appears. A rising cost
was the expected result; a flat one is what exposed the bug.

---

## What remains open

- **F2's trailing directory** — the read-side case is now measured, ~50× on
  point reads at the mean ordinal. T12's condition is met; the decision is not
  mine.
- **Index checkpointing (T11)** — the durable name-index is rebuilt on cold
  start, not persisted. At 100k records that is 3.66 s per restart. Stable ids
  now make a checkpoint + bounded replay possible; it was explicitly deferred.
- **Bytes/triple resident** — 1,664–1,950 B/triple, ~20× above the ~80 B the
  capacity arithmetic assumed. Reported, not fixed, as instructed.
- **`wp-durable-block` is unconsumed** — the tap exists and is proven not to
  stall the writer, but nothing incremental uses it yet. A rebuild reads the
  store instead.
- **Record spanning** — still not built and still not claimed. `cap` must
  exceed the largest record; one above it fails loudly.
