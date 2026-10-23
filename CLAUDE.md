# CLAUDE.md — axVerity (new write-path vertical)

These are the working notes for this repo: the rules, measured costs and
traps already found. Read them before changing the code.

This repo is a **fresh, standalone vertical**. It exists to build and test
the smallest slice of a NEW axVerity write path, governed by the
`AXVERITY_WRITE_PATH_SLICE_V1` intent (authorized 2026-08-13). It is
deliberately **not** a port, refactor, or extension of the earlier
prototype's `graphcore/` tree — no file, fn, registry entry, or bridge
builtin from that tree may be read, ported, reused, or depended on here.
Legacy-reuse check: if you find yourself importing/copying anything from
the earlier prototype, stop.

The M1 language, its compiler, and the codegen bridge are **shared
infrastructure** (separate sibling repos, not part of this project):

- Compiler: `~/dev/axis-lang/target/release/axis`
  (NOT `~/.local/bin/axis` — that's a stub).
- Pipeline YAMLs:
  `~/dev/axis-lang/axis-surface-m1-config/{m1-lexer.yaml,m1-parse.yaml,m1-ast.yaml,m1-normalize.yaml}`
- Registries (in load order): `axis-bridge.axreg`, `gen-working.axreg`,
  `m1-builtins.axreg` from `~/dev/axRegistry/`, plus
  this repo's own `registries/axverity-working2.axreg`.
- Codegen bridge crate (Rust-resident builtins):
  `~/dev/axis-codegen-bridge-rs`.

Using shared infra (the compiler, the bridge's generic runtime
primitives, the shared registries) is fine and expected — that is not
"legacy reuse." Legacy reuse means depending on anything specific to
the earlier prototype's `graphcore/` M1 source, registry entries, or
bridge builtins that were written for it (e.g. `pg_hotblk_*`, `gr_*`,
anything postgres-shaped). `hotblk_get`/`hotblk_set` in particular are
bridge-generic code but a single global register built specifically for
graphcore's path (its own doc comment says so) — avoid them here; use
the fully generic `cell_new_raw`/`cell_load_raw`/`cell_cas_raw` instead.

---

## 0. Storage: single-folder rule (hard constraint)

**All axVerity DB data — every file this project's write path ever
creates — lives under exactly one folder: `.axverity-store/` at the
repo root.** No file belonging to the store may be written anywhere
else (no scattering across the repo, no writing into `/tmp` for
anything durable, no per-feature subfolders elsewhere). The folder name
itself was left to the implementer's choice (2026-08-13); this name is
now fixed for this repo — do not rename it without checking with the
maintainer first, since every path in the build/test scripts will
assume it.

`.axverity-store/` is gitignored (it's data, not source) — same policy
the old repo applied to `.axverity/`.

## 1. M1 entry-point convention (hard constraint, inherited)

Same as the old repo's contract, restated because it's a compiler-level
fact, not a project convention:

- axlang M1 has no `main()`. The compiler is hostile to it. Never write
  `fn main()`.
- Split every command into a **domain fn** (`lib/<name>.m1`, typed
  payload in, typed value out, no argv, no CLI I/O) and a thin
  **executable outer** (`src/<name>.m1`,
  `fn <name>_main(argv: TextList) -> Unit`, does argv/file/stdout I/O,
  calls the domain fn). This split is forced by the bridge's §5b
  xbundle resolver: a fn calling another fn defined in the *same*
  compilation unit fails with `UNRESOLVED_XBUNDLE`. One fn per file.

## 2. M1 syntax gotchas (verified against the compiler/bridge, inherited)

- Every literal is a typed constructor: `Int(1)`, `Text("x")`,
  `Unit()`, `Bool(false)` — no bare literals.
- A fn body whose tail is a bare `let`-bound variable does NOT emit as
  a CoreIR node (the bridge picks `node_<last>`, and a bare VarRef
  isn't one) — wrap it in an identity CCall, e.g.
  `str_concat(addr, Text(""))` for a Text tail,
  `bool_or(Bool(false), Bool(false))` for a Bool tail. Same applies to
  a bare literal tail when preceded by any other statement.
- `if`/`else` branches CAN contain `let` bindings, including discarded
  side-effecting ones (`let _ = eff()`) — this was fixed upstream
  2026-07-15 and applies here too. Effects in an untaken branch do not
  fire — **at the top level of a fn body**. See the next bullet.
- **An `if` NESTED INSIDE ANOTHER BRANCH executes its untaken side**
  (measured 2026-08-23, `AXVERITY_EXTENT_WRITE_PATH` step 5a; **a compiler
  fix is in flight — re-measure before relying on this bullet**). Moving the
  flusher's eject body wholesale into an `else` made its own depth-1 trim a
  nested `if`, and the untaken `bchan_take("wp-durable-block")` ran against
  an empty queue. The flusher blocked on its FIRST block, presenting exactly
  like backpressure:

  ```
  TRACE f: about to trim, durable-block len=0     # then never returns
  ```

  A fn CALL in a branch IS evaluated lazily. So while this holds: **branch to
  a fn, never to a block that contains another `if`.** Because `Value` is not
  a legal M1 surface type for a fn parameter (nor a return type — both
  verified against the compiler), a list-shaped payload reaches such a fn
  through a channel rather than as an argument; `wp-flush-live` is that
  handoff for `wp_flusher_step` -> `wp_flusher_eject`/`wp_flusher_eos`.

  The workaround is correct whether or not the compiler is fixed, so the
  split can stay. What changes once the fix lands is that new code no longer
  has to be written this way — verify with a probe, do not assume.

  **WORKAROUND ACTIVE.** `AXVERITY_EXTENT_WRITE_PATH` 5b-5f are being written
  under this rule rather than waiting on the fix, because the fix is in flight
  with no committed date and four sequenced steps depend on it — including the
  Slice-4 frame, which now gates the pool deletion. The reversal is mechanical
  and one-directional, so proceeding costs only churn.

  **Revert scope is grep-able, not a list:** every affected site carries the
  marker `NESTED_IF_WORKAROUND` in its header, tagged `FORCED` (has its own
  `if`s and genuinely cannot be inlined into a branch),
  `split-counterpart` (no `if`s; exists only so the dispatch has two fns), or
  `dispatch` (the fn that chooses between them). Only `FORCED` sites are
  load-bearing after the fix; the rest can be inlined back at will.

  ```
  grep -rl NESTED_IF_WORKAROUND lib/
  ```

  The `wp-flush-live` channel exists solely to carry a `Value` into a `FORCED`
  fn, since `Value` is not a legal parameter type; it retires with the split.
- `str_after(s, delim)` returns `""` (not `s` unchanged) when `delim`
  isn't found — verify against
  `axis-codegen-bridge-rs/src/runtime/str_ops.rs` before relying on
  either behavior.
- `Text("\n")` does NOT decode to a newline byte at runtime (lexer
  escape bug, last checked against the old repo). Use
  `chr(Int(10))` and `str_concat` it in.
- CCall CSE hash-consing merges identical calls only when the callee is
  declared `effect pure` + `deterministic true`. Declare effects
  honestly in the registry or a genuinely effectful call can get
  silently deduped.
- Concurrency, durability ordering, memory management, and performance
  machinery belong in the bridge, never in `.m1` source (this repo
  inherits that discipline explicitly per the governing intent's
  `M1_DECLARATIVE` hard-limit). If a slice needs threading beyond the
  single write path, that's a bridge change, not M1.

Always rebuild both `axis-lang` and
`axis-codegen-bridge-rs` (`cargo build --release`) after any change to
either, and relink — stale binaries silently keep old behavior.

## 3. Registry pattern (inherited)

Every `lib/*.m1` fn needs an entry in `registries/axverity-working2.axreg`:

```axreg
fn <name>
  identity 0x<sha256(utf8("<name>"))>
  kind leaf
  in (<T1>, <T2>, ...)
  out <T>
  effect pure | fullIo
  deterministic true | false
  idempotent true | false
end
```

Identity is `sha256` of the **name string alone** — contract/signature
don't participate. Compute with `echo -n "<name>" | sha256sum`.

Primitive/list types (`Unit`, `Int`, `Text`, `Bool`, `Bytes`, `Value`,
`TextList`, ...) are already declared in `axis-bridge.axreg` and
co-fed with every invocation — do NOT redeclare them in the local
registry (verified against the currently-live `graphcore.axreg` and
`spike.axreg`, both of which omit a type block; the old repo's
now-deleted legacy tree apparently did redeclare them, but that's not
the current pattern).

## 4. Build invocation

`scripts/build.sh` is the source of truth once it exists. It follows
the same two-stage shape as every other M1 project here: compile each
`lib/*.m1` to `lib_coreir/<name>.coreir`, then compile+link each
`src/*.m1` via `axis-codegen-bridge build ... --lib-dir lib_coreir
--exe`. Always pass all four pipeline YAMLs and all four `--reg`s
(bridge, gen, m1-builtins, local) — there are no defaults.

## 5. Git workflow

Single `main` branch, no feature branches, no PRs — this is a
one-developer(-plus-AI) repo. Commit directly to `main`.

`main` tracks `origin/main`. Commit and push only when the maintainer
asks; the push target no longer needs checking, the decision to push
still does.

## 6. Governing intent

`AXVERITY_WRITE_PATH_SLICE_V1` built the original vertical: input bytes
→ passthrough `write` dispatch → hotframe → seal → rotate through a
3-block pool → eject to a file under `.axverity-store/`. Pool size is
exactly 3, chosen so ejection is provably observable in one short run.

`AXVERITY_FORMAT_LAND_AND_WIRE_V1` (2026-08-18) landed a durable record
format on top of it, in a single authorized touch of the write path:

- **F1v** — every record carries a LEB128 length prefix
  (`wp_write_step.m1`). The input is now a length-prefixed RECORD
  stream and `argv[2]` is a RECORD count, not a block count.
- **B1** — block ids resolve to max+1 over the durable store, strict
  parse (`wp_bid_resolve.m1`, seeded in `mem_controller.m1`). This is
  what makes records survive a restart; seq used to be seeded `Int(0)`
  every run and run 2 overwrote run 1.
- **S2** — two stream directories, `.axverity-store/structure/` and
  `.axverity-store/payload/`, routed by size at
  `wp_stream_threshold` (32 B).

  **THE "ONE SHARED ID SPACE" SENTENCE THAT USED TO STAND HERE IS FALSE
  AND IS THE REASON THIS PARAGRAPH IS NOW LONG.** It said the two
  directories shared one id space, that neither was dense alone but the
  UNION was, and that a RID is one integer because `block-<seq>.bin`
  carries no stream component. All three stopped being true when
  `AXVERITY_EXTENT_WRITE_PATH` 5d moved file naming into slablock, which
  mints a sequence PER HANDLE and therefore per stream. `structure/block-0.bin`
  and `payload/block-0.bin` both exist, with different sizes and different
  hashes; the union is a MULTISET, not an id space, and it never recovers
  one. Each directory is dense on its own — the exact inverse of what this
  bullet claimed. Contract §2.1 was corrected 2026-08-26; this was not, and
  a governing intent (`AXVERITY_W2_ADMIT_HANDLE_V1`) was authored the next
  day on the strength of the old sentence and had to stop at a hard limit
  built on it.

  A RID is still ONE INTEGER, but it is composite:
  `rid = (seq*2 + stream)*stride + offset`, stride = the stamped block
  capacity (`readtier/lib/rt_rid_stride.m1` — read its header, it records
  the measurement that forced the stream in).

  `mem_controller`'s own `seq` is a GLOBAL counter still, seeded max+1 over
  the union by `wp_bid_resolve` — so its seed is computed over a multiset
  and it **reissues ids across restarts whenever the two streams have
  unequal block counts**. It names no file and nothing durable depends on
  it; it is an ordering value. Do not present it to a consumer as a block
  id. Reproduction, 5 assertions from a clean slate:
  `experiments/handle/no-global-id.sh`.
- Block capacity was raised to 16384 here (from 64): no framed record may
  span a block, and one that cannot fit an empty block is rejected
  loudly. **The default is 4194304 now** and the ceiling no longer
  follows the capacity — `AXVERITY_SIZE_THRESHOLD_RECONCILE` measured the
  curve and found the three-byte length prefix tops out at 2097151, so
  the largest storable record is `min(capacity - 11, 2097151)`. See
  section 9 and `lib/wp_block_capacity.m1`.
- **`wp-durable-block`** is the read tier's publish point: a depth-1
  latest-value mailbox carrying `[seq, stream, len]`. Depth-1 is
  load-bearing — `bchan_send` blocks when full and M1 has no
  non-blocking send, so an unconsumed publish channel would deadlock
  the flusher.

Tests: `tests/run-slice-test.sh` (round-trip across restart) and
`tests/run-crash-test.sh` (real SIGKILLs, id integrity). Cost is held at
9.005 ms/durable block and exactly 2.0000 fsyncs. Full report in
`experiments/format/REPORT-LAND.md`.

Read-side cost is gated by `experiments/perf/perf.sh` against
`experiments/perf/baseline.tsv`: index counts exactly, ns per indexed
record within ±25%. Its `w2-struct` arm is a W1 canary — a
structure-only read of a w2-shaped store must index **0 of 13,000**. Do
not rebaseline to make a red gate green without establishing what
moved.

`AXVERITY_SILENT_LOSS_FIX_V1` (2026-08-20) closed three silent-loss
defects the wire harness found. The one that matters architecturally:
**the cold rebuild reads BOTH streams, and S2's "structure-only replay
is 23-25x faster" justification is retired.** That number was a raw
block-scan result worth ~2% inside `rt_rebuild`, measured on a corpus
whose triples are all 8-14 bytes — so the size split and the type split
coincided by construction and the defect could not appear. On realistic
data the old rebuild read 0 of 13,000 records. `lib/wp_flusher_step.m1:36`
still carries the false comment and is frozen; do not re-derive S2's
rationale from it. Full measurement:
`experiments/silentloss/FINDING-S2-RATIONALE.md`.

Ledger, multi-method routing, WAL, locking and multi-writer remain
explicitly out of scope. Nothing is done until a repeatable test asserts
it — a green compile is not completion.

## 6b. Two traps this write path already fell into

**Identical `loop_count` calls get hash-consed away.** `loop_count` is
declared `effect pure` + `deterministic true`, so two textually
identical `loop_count(n, sptr, f)` expressions merge into ONE. The
packer runs twice (a counting pass, then the real one) and the real
pass silently ceased to exist — all five threads parked in
`bchan_take` forever, with no error. `wp_count_step` exists solely to
make the two calls distinguishable. Perturbing an argument instead
relies on the perturbation not being folded away, which is the same
bet.

**A CAS chain has to start from a real value.** The durable watermark
was seeded `-1` and advanced by `cell_cas_raw(cell, seq-1, seq)`. That
worked only while every run started at seq 0. Under B1 a run starting
at 36 makes the first CAS expect 35, find -1, fail SILENTLY, and every
`wp_wait_durable` caller blocks forever. It is seeded `first-1` now.

## 7. Folding a large list in M1: use `foreach`, never `loop_count` + peek

Recorded by `M1_LIST_FOLD_FINDING_CLOSEOUT_V1` (2026-08-17), closing
`M1_VALUE_ALLOCATION_STRATEGY_BAKEOFF_V1`.

**The rule.** Folding a list by driving `loop_count` over an index and
peeking the list out of a channel/accumulator on each iteration is
**O(N²)**, not O(N). Every M1 expression that *names* a list emits a
`.clone()` at the call site, and `Value::List` is a plain `Vec<Value>`
with no structural sharing — so each mention is an O(N) deep copy. The
idiom names the list twice per iteration, giving 2N deep copies. Use
`foreach` instead: it moves the elements and never names the list
inside the loop body, so it is linear.

**The numbers** (from the bake-off's completed rounds; do not re-derive):

| shape | `loop_count` + peek | `foreach` |
|---|---|---|
| 100k entries, total | **369 s** | **252 ms** |
| 1k entries, per entry | **33,441 ns** | **1,207 ns** |

`foreach` is flat at ~1.2–1.4 µs/entry from 1k through 1M, with no
runtime change required — it is already correct today.

**The write path is SAFE and must NOT be changed.** `wp_*.m1`,
`mem_controller.m1`, `flusher.m1` and friends use the quadratic idiom on
**2–4 element** lists, where 2N deep copies of a 4-element `Vec` is
invisible, and no fold runs on the hot path at all. Once this rule is
written down the write path *will* look like it needs the `foreach`
treatment applied. It does not. Leave it. Rewriting working, measured
code to satisfy a documentation entry is the failure mode this section
is trying to prevent — the rule governs code **not yet written**.

**Where it will actually bite.** The name-index and adjacency
projections fold over large lists. They must use `foreach` from the
first line, not be written the easy way and fixed later.

**Reproduction path.** `experiments/blockid-m1/` and the bake-off probe
directories are preserved as the reproduction for every number above.
Do not delete them.

**Rejected remedies, so they are not re-proposed.** Making the payload
cheap to clone (a shared, root-owned `Value::List` buffer) does remove
the quadratic — 1,902× at 100k, flat to 1M on unchanged M1 source — but
it regresses the shape the write path actually uses: **+70.1% at 4
elements, +108.2% at 8**, and it leaked **250.5 bytes per list
construction**, unbounded in construction count. It was rejected. A
reference-counted-but-not-atomic payload (`Rc`) is worse than slow: it
is undefined behaviour here, because a `Value::List` genuinely crosses
three OS threads per write-path iteration. See the mechanism section in
`axis-codegen-bridge-rs/CLAUDE.md`.

## 8. Binary decoding in M1: reading a byte (hazard, and the fix)

Recorded by `AXVERITY_FORMAT_LAND_AND_WIRE_V1` / P0 (2026-08-18),
hard-limit `FIX_INT_MOD_FIRST`.

**The hazard.** M1 has no byte-width load. The only way to read a byte
is `mem_read_int_raw`, which is an **8-byte signed i64** read, followed
by arithmetic to pick the byte out. So a decoder positioned at a record
boundary necessarily pulls in the seven bytes *after* it, and if any of
those sets the top bit, the word reads back **negative**.

`int_div`/`int_mod` used to be Rust's `/` and `%`, which truncate toward
zero and therefore return a **negative remainder** for a negative left
operand. The negative "byte" was then used as a varint length and added
to the read cursor, which walked it **backwards off the front of the
buffer**:

```
mem_read_int_raw: offset must be >= 0, got -83     # 0xAD decoded as 173-256
```

It surfaced only because one probe corpus had random payload bytes. An
ASCII structure stream never sets the top bit and never triggers it — so
this is exactly the class of bug that stays hidden until real payload
data arrives.

**The fix, at the primitive.** `int_div` and `int_mod` are now
**Euclidean** (`div_euclid` / `rem_euclid`) in
`axis-codegen-bridge-rs/src/runtime/arith.rs`. A remainder is always in
`[0, |y|)`, so a decoded byte is always a byte.

**Both were changed, deliberately.** For a power-of-two divisor,
Euclidean division is exactly an arithmetic shift and Euclidean
remainder is exactly a bit mask, so

```
int_mod(int_div(v, 256^k), Int(256))     // byte k of v, correct for every k
```

extracts byte `k` of `v`'s two's-complement representation correctly at
**every** position, negative `v` included. Fixing only the remainder
would have left `int_div` rounding toward zero, so any byte above the
lowest would still decode silently wrong — the same hazard, half-fixed.

**Blast radius was checked, not assumed.** Every pre-existing
`int_div`/`int_mod` call site in both M1 trees takes a non-negative left
operand (loop indices, lengths, elapsed-time deltas, and a hash kept in
range by construction). Euclidean and truncated agree exactly on
non-negative operands, so no existing caller's behaviour changed. The
write-path slice test, the read tier's 98 assertions and the bridge's
unit tests were all green before and after. (That suite was 75 tests at
the time; it is 314 as of AXVERITY_BRIDGE_GLUE_OPT_SWEEP_V1. The count is
deliberately not restated here — it moves with every bridge intent, and
the claim that matters is "all green", not the cardinality.)

**Do not re-add call-site corrections.** The old idiom
`int_mod(int_add(int_mod(v, m), m), m)` was a workaround for this defect
and has been removed from `fx_scan_rec.m1`. Leaving such a correction in
place hides whether the primitive is actually fixed. Decode with plain
`int_mod`/`int_div` and rely on the Euclidean contract.

**Reproduction.** `experiments/intmod-m1/` sweeps all 256 byte values
through a real record boundary in real raw memory. Truncated: **128
failures**, first at byte 128, `0xAD` → `-83`. Euclidean: **0 failures**,
`0xAD` → `173`. End to end, decoding a 2000-record mixed store with
random payload: truncated **panics and never terminates**
(`offset must be >= 0, got -50`), Euclidean decodes **2000/2000 in
9.7 ms**. Do not delete this directory.

---

## 9. Block size: what is measured, so it is not re-derived

Recorded by `AXVERITY_SIZE_THRESHOLD_RECONCILE` (2026-08-25). Full report
and the five scripts that produce every number:
`experiments/threshold/REPORT-THRESHOLD.md` + `experiments/threshold/e1..e5`.
Measured on the shipping `build/wp-slice` and the shared bridge's
`chunk_file`; 256 MiB payload per point, 3 runs, median. **Do not
re-measure these to answer a design question — read them.**

**Capacity is the dominant variable in this write path, by two orders of
magnitude.** It is also, simultaneously, the record ceiling, the fill
knob, and (through a manifest) the largest addressable blob. One number
doing four jobs is why it kept getting argued about.

| capacity | MB/s | ms/block | fsyncs/block | fill (4 KiB records) |
|---|---|---|---|---|
| 16 KiB | **2.5** | 4.678 | 3.00 | 75.1% |
| 256 KiB | 41.5 | 5.930 | 3.00 | 98.4% |
| 1 MiB | 104.8 | 9.469 | 3.00 | 99.3% |
| 4 MiB | **177.2** | 22.228 | 3.00 | 98.5% |
| 16 MiB | 217.7 | 69.165 | 3.00 | 94.2% |

`ms/block = 5.14 + 4.02 x MiB`; fixed cost equals transfer cost at
**1.28 MiB**. **fsyncs per block are a flat 3.00 at every capacity**, so
total fsyncs = payload / capacity — that is the whole mechanism behind
the 71x. The three are: data fsync, dir fsync (which makes the `.part`
NAME durable), rename, dir fsync. The middle one durably names a file
`slab_open` **discards on recovery**; it looks removable and is a third
of the dominant cost, but removing an fsync needs
`tests/run-crash-test.sh` behind it, not a throughput table.

**Record size does NOT matter, between 256 B and 1 MiB.** 5.32-5.82
ns/byte across that whole range — a +-9% band. Per-record cost only
bites below 256 B: **1.56x at 64 B, 3.94x at 16 B**. So no size fork
anywhere in 256 B..1 MiB can be justified by this write path's own cost.

**Where large records DO cost: quantization.** No record may span a
block, so the block tail is wasted when record size approaches capacity:
98.5% fill at <= cap/256, 97.0% at cap/64, 92.8% at cap/16, and **74.4%
at cap/4** (the varint pushes the fourth record past the footer, so three
fit where four nearly did). **Rule: largest expected record <= cap/64.**

**The 32 B S2 threshold is cost-neutral and mislabeled.** A bimodal
corpus driving both streams lands between the two single-stream runs at
the best fill of the three — each stream seals only when its own buffer
fills, so interleaving never forces a premature seal. But the per-byte
cost knee is at **256 B**, an order of magnitude above 32 B. Keep it or
drop it on other grounds; do not describe it as a cost boundary.

**The chunker is cheap; its manifest is the constraint.** `chunk_file`
(shared bridge, FastCDC) runs at ~950 MB/s = 1.1 ns/byte — ~21% on top
of a 4 MiB-capacity write, noise against a 16 KiB one. A file at or below
the average chunk size yields **exactly one chunk**, so any blob fork
must sit at or above the average or it buys a scan that cannot pay.
A manifest is an ordinary RECORD and inherits the ceiling, which gives

```
max blob ~= cap^2 / 288      (chunks and manifest both records)
```

**READ THE PREMISE BEFORE USING THIS NUMBER.** It holds only if chunks
and the manifest are stored as RECORDS IN BLOCKS — i.e. only if there is
no separate blob regime. **The recorded design says there IS one**, and
under it this whole calculation is moot: a blob lives in blob storage,
and what the block regime holds is a REFERENCE, which is tens of bytes
and fits anything. See "Two regimes" below. The arithmetic is kept
because it correctly prices the one-regime shortcut, and because it is
what makes that shortcut unattractive: 908 KiB at a 16 KiB capacity,
3.55 GiB at 1 MiB, saturating at **14.2 GiB** for any capacity at or
above 2 MiB (past which the framing ceiling, not the capacity, binds).

## Blob storage is not part of this system (decided 2026-08-25)

**The graph DB has NO relationship to blob storage.** It is an entirely
different mechanism and it is the APP's to build and run. This is not
"loosely coupled" or "referenced opaquely" — there is no blob concept in
the graph at all. axVerity stores triples. If an app writes a triple one
of whose terms it privately treats as a handle to something elsewhere,
that is a triple like any other: storage neither knows nor cares, gains
no reference type, and provides no metadata slot. The design would be
byte-for-byte identical if blob storage did not exist.

**axVerity's responsibility ends at storage and retrieval of records.**
Its one data-model commitment is that a record is a triple. Everything
above that — what a term means, what is worth keeping, what gets
decomposed into nodes and edges, what a document is — is the app's, and
lives in the application, outside axVerity entirely.
This is the same rule `wp_stream_threshold` already states for routing
("keeps the write path free of any knowledge of what a record MEANS")
and the same reason F1v frames with a length prefix rather than a schema.

**So the net requirement on axVerity from the entire blob question is
NONE.** No blob path, no chunker wiring, no reference type, no manifest
record, no metadata provision, no GC, and no size threshold. A 3 GB video
is not a large record and is not this system's problem. The capacity work
in this section stands on its own throughput evidence and has nothing to
do with blobs.

**Do not re-derive a blob tier here.** It has been proposed, built and
deleted more than once. The recorded three-tier model (small inline /
medium paged / large content-addressed, from the earlier prototype's
design notes) and Landing B's 1 MiB fork are HISTORY, useful for what they measured,
not a backlog item for this repo.

**What this repo's measurements say about that threshold**, at the 4 MiB
block, fill = stored / (blocks x capacity):

| record | cap/N | fill |
|---|---|---|
| 8 KiB | cap/512 | 97.7% |
| 64 KiB | cap/64 | 97.0% |
| 500 KB | cap/8 | **96.9%** |
| 1 MiB | cap/4 | 74.4% |
| 2 MiB | cap/2 | 50.0% |

So fill does not bite until cap/4. Inline is CHEAP well past the
recorded 4-8 KB — that number was chosen when a block was 64 bytes and
then 16 KiB, and the block has since grown 256x. The hard bound is
2097151 (framing), so **10 MB is not a candidate for an inline
threshold at all** — anything above 2 MiB must be a blob whatever else
is decided. And below ~64 KiB the blob regime buys only reclaimability,
never dedup, because a file at or below the average chunk size yields
exactly one chunk.

**And the threshold question does not belong to storage either.** Where
an app puts a value is the app's call with the app's knowledge. What
storage says is only this: a record is at most 2097151 bytes; above that
it is refused loudly. That is the whole of it.

**Content-defined chunking earns its cost; fixed-size does not.** Dedup
as a share of a revised 16 MiB blob: CDC holds **88-99.5%** across every
edit shape tested. Fixed-size at the same width drops to **0.0%** on a
one-byte prepend and **50%** on a mid-file insert — every boundary
shifts. Smaller averages dedup better (99.5% vs 88.0% at avg 64K vs 1M)
but produce more chunks, a bigger manifest, and therefore a *smaller*
addressable blob. That is the real trade in choosing the average.

**Wiring hazard.** `chunk_file` does not terminate its last line, so
`wc -l` reports a single-chunk manifest as **zero chunks**. A manifest
parser must not depend on a trailing newline.

**One thing left open, deliberately.** This per-block fit is ~2x the
fixed term and ~4x the slope of `experiments/extent/REPORT-STEP123.md`
(`2.32 ms + 1.08 ms/MiB`, crossing ~2.2 MiB). Same machine, different
code — that was the step-1-3 prototype, this is the shipping slablock
path. The gap is recorded, not explained, and is NOT claimed here as a
regression.

**The 4 MiB default, and the ceiling that stopped following it**
(third authorized touch, 2026-08-25 — baseline P6). The default is
`4194304`. But the length prefix emits at most three bytes, with byte2 =
`len/16384` written raw, so it is a legal LEB128 terminator only while
`len <= 2097151`. At 16384 that was unreachable; at 4 MiB it is, and the
window is 2097142 bytes wide. Demonstrated before the fix: a 3145728-byte
record wrote the prefix `0x80 0x80 0xC0`; `rt_dscan_step` reads b2 as a
raw byte and recovers it exactly, a conforming LEB128 reader (the
independent harness, and what this format's own doc claims) demands a
fourth byte and mis-decodes — **writer exit 0, no FATAL: accepted and
unreadable.** `wp_write_step` now bounds admission at 2097151, which is
not merely safe but *honest*: below it byte2 < 128, so the raw-byte form
and conforming LEB128 are the same bytes and all four decoders agree.

**So the rule is `largest record = max_record`** — policy, and nothing
structural underneath it. `lib/wp_max_record.m1`, configurable at
`.axverity-store/config/max_record`, default 65536, chosen on what is
efficient for this system: fill is >=97% at or below cap/64 = 64 KiB and
cliffs to 74.4% at cap/4; and a record is a triple of NAMES the read tier
indexes, so a 500 KB term is a document and the graph is not where
documents live. Raising is free, lowering after data exists is a
migration, so the default errs small.

**RECORD SPANNING IS BACK** (`AXVERITY_SPAN_RESTORE`, baseline P7,
`experiments/continuation/FORMAT-SPAN.md`). A record too large for a
block, or too long for the three-byte prefix, is no longer refused — it
is written UNFRAMED across consecutive blocks of its own stream. The
original write path did this before F1v made records atomic; the trade
F1v made was never necessary, because record identity and spanning
conflict only if ONE length prefix must describe the whole record.

The 8-byte footer carries it: `-1` still means no continuation, and
otherwise `flags*2^32 + taillen` with bit0 "begins with continuation
payload", bit1 "continues into the next block of this stream", and bit2
"this block IS one complete unframed record". The
next block is IMPLICIT — a continuation is always the next sequence in
the same stream, so nothing stores a pointer, which is what dissolves
the objection that retired the original chain. Total length is DERIVED
by walking the chain, never stored — that is what keeps the three-byte
prefix sufficient with no varint anywhere expressing 3 GB. Verified: a
10485760-byte record spanned three blocks and reassembled byte-identical
from the durable bytes and footers alone.

**THE THREE FLAG BITS ARE INDEPENDENT — never test `flags >= 2`.** bit2
was added by the P8 follow-up and the reason is worth keeping: a record
spans when it cannot be FRAMED, which is not the same question as whether
it FITS. The three-byte prefix stops at 2097151, so at the 4 MiB default
every record from 2097152 up to the payload capacity spans while still
fitting one block — a chain with NO full fragment. Flagged `1` it would
claim to finish a record nothing began, and a reader classifying blocks by
their own footers indexes nothing: measured at 3145728 bytes,
`rebuild_records=2` of 3 and `rid=-1` for every name it carried, writer
exit 0. Flag 4 is what that block gets. `flags >= 2` reads "2 or 3" as
"continues" and silently swallows 4, which is `>= 2` and does not
continue — test bit1 for continuation, and `flags == 2 || flags == 4` for
"begins a record". Held by `SPAN_ONE_BLOCK` (slice test) and T9
(readtier).

**Framed fragments were measured against and rejected.** At a 4 MiB
block a framed fragment caps at 2097151+3 into a 4194296 payload — one
per block, 50% wasted; packing two per block creates an ambiguity
per-block flags cannot resolve (`[frag_a][frag_b]` still continuing vs
`[tail][normal]` already ended carry identical flags).

**The read tier reassembles a spanning record and indexes it** —
`rt_dblk_scan` classifies each block by its own footer, `rt_span_index`
walks the chain and rebuilds the record before indexing, and the locator
is the ordinary shape (first block, offset 0). Two passes, because
nothing stores the total length: `rt_span_count` walks footers only, then
`rt_span_copy` fills a buffer sized from that walk. Verified on a
40015-byte triple across three 16 KiB blocks — records=4, malformed=0,
names=12, asserted as T7 in `tests/run-readtier-durable-test.sh`. So
accepted-means-queryable holds at every configuration.

**A LOCATOR AT A SPANNING RECORD IS NOT A FRAME — `rt_read_rid` reads the
footer first.** The locator is deliberately the ordinary shape, but offset
0 of a first fragment has NO length prefix: the payload is raw body bytes.
Decoding one anyway is silent, and it was — a 10 MB record indexed under
three names read back as `len=100` and 100 bytes of its own body, because
the subject's first character happened to be `d` (0x64). `rt_read_rid` and
`rt_read_rid_len` read the 8-byte footer before they trust the offset now,
and hand a spanning record to `rt_span_text` / `rt_span_total`, which walk
the chain. One extra pread on the framed path, against a wrong answer
nothing downstream could detect. T8 holds it.

**`rt_span_footer` reads 8 bytes, and that must stay true.** It seeks to
`stride - 8` — every block a chain continues INTO is exactly the capacity,
by construction — and falls back to a whole read only for a SHORT block,
which can only be a chain's terminator. It used to `fs_read_bytes` the
whole file to find its own end, which made `rt_span_count`'s "one 8-byte
read per block rather than a whole block" false by a factor of the block
size.

**`rt_span_copy` clamps its copy to what `rt_span_count` counted** (scratch
slot 144). Pass one sizes a continuing block from the capacity STAMP and
pass two from the staged file's own length — the same number for every
block this writer produces, but two sources of truth for one fact, where a
disagreement would be a heap overflow rather than a wrong answer.

**Reassembly holds one whole RECORD in RAM.** `rt_dblk_scan` is careful to
hold one block at a time so peak memory tracks block size; `rt_span_index`
breaks that for spanning records, and since `max_record` is policy with
nothing structural under it, that is where a deployment can make the
rebuild's memory its own problem. Deliberately not capped — refusing to
index what the writer accepted is the failure this whole line of work
exists to remove.

**The 16384 literals in `wp_cap_stamp`'s orphan check and
`rt_rid_stride`'s fallback are the LEGACY value** for stores written
before the stamp existed. They are not copies of the default and must
not be updated with it.
