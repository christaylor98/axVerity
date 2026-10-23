# AXVERITY_CONSUMER_CONTRACT.v2.0

**Status:** **v2.0 PROPOSED, awaiting the Lead Architect's ratification.** The
wire it describes is live and its suites are green; the *ratification* is not
this document's to grant. Until it is granted, a consumer building against v1.0
is building against a wire that no longer exists — see §0.3.

**Why a major version.** §9 rule 1 permits obligations to be added and never
removed within a major version, and §5.9 says the same of ops. v2.0 REMOVES the
`DURABLE` op and deletes §5.6's lease clause, so it cannot be a revision. The
removals are authorised by `AXVERITY_W2_ADMIT_HANDLE_V1` (Lead Architect,
2026-08-26), whose `NO_AHEAD_OF_CONDITION_INFRA` rule is what they execute:
where a capability's triggering condition does not exist, the handler is
deleted rather than left answering.

**Previously:** **RATIFIED** 2026-08-20 as `AXVERITY_CONSUMER_CONTRACT.v1.0`.
Ratified by the Lead Architect under `AXVERITY_SILENT_LOSS_FIX_V1` / P10,
with §10 resolved: every claim is a settled fact with a citation, an open
question with what would settle it, a named not-implemented, or a named
outstanding obligation. §9's ratchet rules are now in force — §2–§5 cannot be
narrowed and §6 cannot be converted without a new major version.
**Authority:** the Lead Architect. Sole ratification authority.
**Supersedes:** nothing. First published consumer surface.
**Revised:** 2026-08-20 under `AXVERITY_SILENT_LOSS_FIX_V1`. See §0.1.
**Revised:** 2026-08-25 under `AXVERITY_SIZE_THRESHOLD_RECONCILE`,
`AXVERITY_SPAN_RESTORE` and its P8 follow-up. See §0.2.
**Major-versioned:** 2026-08-26 under `AXVERITY_W2_ADMIT_HANDLE_V1`. See §0.3.

---

## 0.3 What changed at v2.0 (2026-08-26)

One theme, applied four times: **a surface that does not know must not answer as
though it does.** Three of the four are removals or refusals, and the fourth
publishes a number the server already had.

| § | Was | Is |
|---|---|---|
| 3.1 / A.6 | a `QUERY` before any `REBUILD`, or after an `ADMIT`, answered `ok` with the rows the projection happened to hold — `0` on a store nobody had rebuilt | **refused, status 1, body `STALE …`.** A forgotten `REBUILD` was the one obligation in §7 whose breach produced a confident wrong answer instead of an error. The gate starts closed at process start, closes again on every successful `ADMIT`, and only a successful `REBUILD` opens it |
| 4.3 / 5.7 / A.9 | `DURABLE watermark -> ok` | **the op is GONE.** Opcode 4 answers `UNKNOWN opcode 4`. It answered `ok` to every argument ever put to it, including a watermark beyond anything admitted and a non-numeric one, and a consumer was entitled to read that as the durability guarantee §4.3 describes. There is nothing to wait for on a run-and-exit writer, so the verb is deleted rather than implemented |
| 5.6 | the write role is an exclusive lease, refused at handshake | **the clause is DELETED.** It described a refusal that nothing performed and that no consumer could observe. §4.2's single-writer rule is unchanged and is now stated as what it actually is: a consumer obligation, held structurally by the accept loop only while one server process is the only path to the store |
| 4.1 / A.8 | the oversize refusal did not name the limit; §4.1 said "ask the operator" | **the refusal names it.** The writer's own diagnostic (`records_too_large=N max_record=M`) is forwarded verbatim in the reply body. A consumer must still route on the **status byte**, not parse this text |

**And one obligation this document has owed since ratification is now met.**

| § | Was | Is |
|---|---|---|
| 4.5 / 5.7 / A.8 | `ADMIT` returned a record count and a byte count; §5.7 published "→ block id range" and §10 carried it as NOT IMPLEMENTED. §4.5's two-phase write had nothing to read back | **the reply carries the range, one per stream**: `structure=F,C payload=F,C`, `(first, count)`. A consumer can now reference what it wrote |

**It is per stream because that is what exists.** The work first STOPPED here: it
was governed by a hard limit locking `block_id` as "global, single-writer, dense
from 0 … returned, never redefined", and §2.1 — corrected one day earlier —
publishes that ids are dense **per stream**, with `structure/block-N` and
`payload/block-N` both existing and differing. The Lead Architect amended the
limit rather than the fact, on the grounds that a premise that was never true is
not a locked path being reopened, and that the read tier's locator has carried
the stream for months. Reproduced by `experiments/handle/no-global-id.sh`; the
form resolved to `(first, count)` by `experiments/handle/handle-form.sh`; the
published range checked against `ls` taken before and after each run, across
five corpus shapes, by `experiments/handle/ids-vs-ls.sh`.

**A prediction that came out half false, recorded because it shaped the work.**
The governing intent predicted that one returned handle would close both the
missing reference mechanism and the missing staleness comparator — "no second
mechanism is needed". The handle closes reference (T1, green). It does **not**
close staleness: nothing on the wire reports what a projection covers, so a
consumer holding `structure=0,1` has no value to compare it against. Staleness
is closed by the freshness gate above, which is a second mechanism. They were
two gaps, not one.

**One narrowing a consumer must see, stated plainly rather than buried.** On a
store nothing has ever been admitted to, **both** read verbs now refuse:
`REBUILD` with `NOSTORE` (unchanged) and `QUERY` with `STALE`, because the gate
starts closed and only `REBUILD` opens it. Through v1.0, `QUERY` answered `ok`
with `0` rows there and §A.7 recommended it for exactly that reason. A brand-new
deployment therefore has no read verb that answers `ok` until somebody admits.
Both refusals are honest and neither is benign-on-unknown, but this is a
narrowing, it is why v2.0 is a major version rather than a revision, and §10
carries it as an open item.

---

## 0.1 What changed in this revision

A black-box wire harness built strictly against this document
(`AXVERITY_WIRE_CLIENT_HARNESS_V1`, 50 arms) established that several sections
published something the wire did not do. Aspiration has been replaced with
measurement. Nothing here narrows an obligation; every change either corrects a
statement that was false or publishes something that was missing.

| § | Was | Is |
|---|---|---|
| 3.1 | mask 2 documented as `_ _ t` | the mask is **bitwise**: bit0 `s`, bit1 `v`, bit2 `t`. Mask 2 is `_ v _`; `_ _ t` is mask 4. §6.1 was always right and §3.1 was always wrong |
| 3.2 | — | the rebuild reads **both** durable streams. It read only one, and every record over 32 bytes was admitted, counted and invisible |
| 4.1 | a batch of one is legal | a batch of **zero** is refused, out of contract. It used to wedge the server permanently |
| 4.1 / A.8 | `payload = UTF-8 s US v US t`, described | **enforced.** A record that is not valid UTF-8 with exactly two separators is refused and nothing in the batch is written. A third separator used to be admitted, indexed, and returned as a four-field row that breaks a consumer's row parser |
| 5.4 / 5.5 | "many concurrent connections permitted", pooling and multiplexing invited | **one connection is served at a time.** A pooled consumer hangs |
| 5.7 | five verbs | four are on the wire. `LEASE` does not exist |
| 5.11 T5 | one frame encoding | two are in use. Recorded as two; reconciliation is still the Lead Architect's call |
| **A** | — | **new: the wire, byte for byte.** A consumer could not previously write a client from this document |

Also settled and unchanged in substance: an **empty name is a legal name** and
is stored and returned. §1 says axVerity has no opinion about what the three
positions mean, and a blank field is what a consumer emits the first time a
value is absent. It used to make the whole triple invisible.

---

## 0.2 What changed in this revision (2026-08-25)

`AXVERITY_SIZE_THRESHOLD_RECONCILE` measured the write path's block-size curve
and moved the default block from 16 KiB to 4 MiB (71x on durable throughput; the
mechanism is that fsyncs per block are flat at 3.00 regardless of block size, so
total fsyncs = payload / capacity). Two things a consumer can see followed.

| § | Was | Is |
|---|---|---|
| 4.1 | "every record is admitted **regardless of its size**" | **false, and now corrected.** There has always been a maximum; it was simply never published, so a consumer discovered it by being refused. It is now stated, with its three bounds and both knobs |
| 4.1 / A.8 | "up to the block capacity" | the limit is `min(max_record, block_capacity - 11, 2097151)`. Capacity stopped being the binding term: the format's length prefix caps a record at 2097151, and policy caps it at **65536** by default |
| 4.1 | — | **new: the limit is configurable and per-deployment.** A consumer must not hard-code it |
| 4.1 / A.8 | a record too large for a block is refused | it **spans** — written across consecutive blocks and reassembled on read. `block_capacity` no longer bounds a record at all, and neither does the framing. The only bound left is `max_record`, which is policy |
| A.8 | the refusal names the configured limit | **it does not.** The reply is `WRITER exit=1 …`; the limit is named only on the writer process's own stdout, which the server does not forward. The status, not the text, is the contract |
| 2.1 | `block id B1 … global`, `layout S2 … shared id space` | **corrected.** Ids are dense per STREAM. `structure/block-36.bin` and `payload/block-36.bin` both exist and differ. Already false at ratification |
| 2.1 | `format F1v varint length prefix` | **corrected.** A spanning record is written UNFRAMED; not every block begins with a varint |
| 3.1 / 3.2 | — | **new: a spanning record is queryable by every name it carries, and a locator resolves it.** Reassembly happens below §3 and is not a consumer concern |

**This is not a narrowing and does not need a major version under §9.** The
obligation it corrects was never met by any build: at ratification the wire
refused records above 16,373 bytes, which the harness recorded at the time
(`16000:exact 16384:refused(1)`). Publishing the real limit replaces an
aspiration with a measurement — the same category as every change in §0.1 — and
the effective limit **rose**, from 16,373 to 65,536, so nothing a working
consumer did stops working.

**Record spanning was restored the same day**, which is why the limit ended up
as policy alone rather than the three-term minimum this revision first
published. The original write path chunked an undelimited byte stream across
blocks and chained them; F1v traded that away for record identity, and the trade
turned out to be unnecessary — fragments carry no length prefix, so nothing has
to encode a large record's length in a varint. A record too large for a block,
or too long for the three-byte prefix, is written unframed across consecutive
blocks of its stream and reassembled from the blocks' own footers.

Spanning is durable, byte-recoverable and **queryable**: a 10 MB record was
reassembled from the durable bytes and footers alone, with no writer code and no
stored length, and a 40 KB triple spanning three blocks indexes every name it
carries (records=4, malformed=0, names=12). §2's obligation that an admitted
record is a returned record therefore holds at every setting of `max_record`,
which is what makes it safe to publish as a free knob.

That obligation was **published before it was true**, and the gap is recorded
here rather than quietly closed. Two defects, both found by review of the
landing rather than by any test, both silent:

- A record spans when it cannot be **framed**, which is not the same question
  as whether it **fits**. Above 2097151 bytes a record spans even inside one
  block, and such a chain has no leading fragment. The reader recognised a
  chain only by its leading fragment, so at the default 4 MiB capacity **every
  record from 2,097,152 bytes up to the payload capacity was accepted, fsynced
  and indexed by nothing** — writer exit 0, no count anywhere disagreeing.
  Measured at 3,145,728 bytes: 2 records rebuilt of 3, and no name resolving.
- A spanning record's locator pointed at a block with no length prefix at that
  offset, so reading the record back decoded its own first body byte as a
  length. A 10 MB record indexed under three names read back as 100 bytes.

Both are fixed and both now have tests that fail without the fix
(`SPAN_ONE_BLOCK`, and T8/T9). The obligation as stated stands; what did not
stand was the claim that it had been demonstrated. Publishing an obligation is
not evidence for it, and the tests that existed asserted counts and names,
neither of which can see either failure.

---

## 0. What this document is

axVerity publishes one surface. Consumers develop against this document, not
against axVerity's implementation, not against each other, and not against any
particular consumer's semantics.

This is a **ratchet surface**: forward-only. Once ratified, the obligations in
§2–§5 cannot be narrowed and the non-obligations in §6 cannot be converted into
obligations without a new major version. A consumer that needs something not in
the obligations is wrong until it proves otherwise under §9.

The purpose is that a new project can be built against axVerity without
negotiating with axVerity, and without axVerity growing a feature to accommodate
it.

---

## 1. Model

**The store owes data. The client owes semantics.**

axVerity stores triples — `(source, verb, target)` — durably and append-only,
and answers binding-pattern queries over them. It has no opinion about what any
of those three positions mean.

That sentence is the entire contract. Everything below is its consequences.

---

## 2. Obligations — the durable artefact

### 2.1 Store

A single directory, `.axverity-store/`, whose path is supplied by the consumer.

```
  format    F1v   varint length prefix, except where a record SPANS
  block id  B1    single-writer, dense from 0 PER STREAM, max+1 strict parse
  layout    S2    separate streams, each with its own id sequence
```

The durable format is fixed for the life of this contract version.

**Two corrections to the lines above, both to statements that were already
false when this document was ratified.** Neither changes what a consumer may
rely on through §3–§5, which is why this is a correction and not a §9 version
bump; both matter only to a consumer reading the store directly, which §6 does
not invite and §7 does not support.

- **Ids are dense per STREAM, not globally.** This document published "shared
  id space", and that stopped being true when the writer moved to per-handle
  sequences: `structure/block-36.bin` and `payload/block-36.bin` both exist,
  with different sizes and different contents. A reader that treats a block id
  as naming one file must also carry the stream, or it silently reads the wrong
  block — measured, and the reason a locator carries the stream today. The
  union of the two directories is **not** a dense id space and never recovers
  one; each directory is dense on its own.
- **Not every record carries a length prefix.** A record too large for a block,
  or too long for the three-byte prefix to express, is written **unframed**
  across consecutive blocks of its stream (§4.1). A block's own 8-byte footer
  says which case it is, and a reader that assumes a varint at offset 0 of
  every block will decode raw body bytes as a length. Blocks are
  self-describing precisely so that this is recoverable without reading
  neighbours.

**A consumer should not be parsing the durable format at all.** These lines
exist to name what the artefact IS, not to specify a second read path. §3 is
the read surface; the store's bytes are not a public API and this contract does
not version them independently of it.

**Not everything under `.axverity-store/` is durable data.** Three files at the
store root are working state, and they are named here because §2.1 is where the
layout is published and an undeclared file in a published layout is a gap, not
a detail. *(Placement proposed, not decided: §2.1 describes the durable
artefact, and these are explicitly not part of it — the Lead Architect may
prefer them in §5 with the transport that creates them.)*

| file | what it is |
|---|---|
| `admit.tmp` | one batch's records, staged for the writer. Overwritten by every admission; one file, not one per call. **Predates this version** and was undeclared before it |
| `writer.err` | the writer's own refusal diagnostic, one line, the text §4.1 and A.8 relay. **Truncated before every spawn**, so an EMPTY file means this run named no reason — never a previous run's reason |
| `admit.ids` | the block-id range the run produced, the four integers A.8 reports. **Truncated before every spawn**, same discipline |

None of the three is durable data, none is read by either tier, none survives a
meaning across admissions, and a consumer must not read, write or depend on any
of them — the wire is where their contents are published. They are invisible to
both directory folds: the writer's max+1 scan reads `structure/` and `payload/`,
and the rebuild reads `structure/`.

### 2.2 Immutability

Ingest is immutable; projection is additive. The hot path performs no durable
mutation. There is no update and no delete — at any layer, under any API, over
any transport, ever.

A consumer's notion of "changed" or "deleted" is expressed as further appends
and interpreted client-side. This is not a limitation to be worked around; it is
the property every other guarantee in this document rests on.

---

## 3. Obligations — read

### 3.1 Query

```
  rt_query(mask, s, v, t) -> named store
```

Results land in a named store, not in a consumer-language list. This is
load-bearing: list-shaped results are O(R²) under copy.

Eight binding patterns are servable. Three durable orderings prefix-serve all
eight:

```
  A(S,V,T)    B(V,T,S)    C(T,S,V)
```

Three is the combinatorial minimum. Not an implementation detail a consumer may
work around, and not a number that grows.

**The mask is a bit set, not an enumeration.** Bit 0 binds `s`, bit 1 binds
`v`, bit 2 binds `t`. An unbound position is ignored, and the argument supplied
for it is ignored with it.

**A query against a stale projection is refused, not answered (v2.0).** §4.6
makes a reader's view "as of their last rebuild" and §7 makes REBUILD-before-read
the consumer's obligation. A consumer that forgets it is now told so:

```
  status 1   STALE the RAM projection does not reflect the durable store — …
```

The projection is stale from the moment the serving process starts, and again
from every successful `ADMIT`. Only a successful `REBUILD` clears it. Route on
the status byte; the text is diagnostic, not contract.

This is a **refusal, not a repair**: the shim does not rebuild on your behalf.
§5.2 property 3 forbids the transport from smoothing §4.6's staleness over, and
an automatic rebuild would do exactly that — quietly, on a path whose cost §3.2
publishes as proportional to the whole store.

```
  mask 0    _ _ _      enumerate all
  mask 1    s _ _      out-edges of s
  mask 2    _ v _      every use of verb v
  mask 3    s v _      value of verb v on s
  mask 4    _ _ t      in-edges of t
  mask 5    s _ t      the verbs relating s to t
  mask 6    _ v t      in-edges of t under verb v
  mask 7    s v t      membership test for one triple
```

All eight are in the contract and all eight are exact — six independent probes
across a 12-triple corpus returned zero missing and zero unexpected rows for
every one of them.

> **Correction.** Earlier drafts of this section published mask 2 as `_ _ t`.
> That was wrong, and wrong silently: a consumer asking `query(2, t=…)` for
> in-edges binds the *verb* to a target name, matches nothing, and receives an
> empty set with status **ok** — from which it concludes the node has no
> in-edges and carries on. §6.1's worked example writes the supersession query
> as mask 2 with the verb bound and was always correct; §3.1 was the half that
> disagreed with the implementation. Settled by measurement, closing §10 item 2.

A mask outside 0–7 is **not** currently refused; it is served as though the
low three bits were all set. Do not rely on that — treat an out-of-range mask
as a bug in your own code, because the server will not tell you about it.

### 3.2 Rebuild

```
  rt_rebuild(store_path) -> RAM tier
```

The RAM tier is process-scoped scratch, rebuilt from the durable store on
demand. **Adjacency is a RAM projection, never durable.**

The rebuild reads **every durable stream** (§2.1), not a subset of them. This
is an obligation, not an implementation note: the store routes a record to one
stream or another by size, that routing is invisible to a consumer and carries
no meaning, and a rebuild that read one stream would silently omit whichever
records happened to land in the other. `ADMIT`'s `admitted=` count and the
watermark `REBUILD` returns count the same records.

**A record written across several blocks is rebuilt as one record**, indexed
under every name it carries and counted once in the watermark. Where a record's
bytes physically sit is below §2.1 and is not a consumer concern; the obligation
is that the rebuild's record count and `ADMIT`'s `admitted=` count agree
whatever the record sizes were. Held by T7 and T9 of
`tests/run-readtier-durable-test.sh`, the second at the shipping block size.

**Peak rebuild memory is a function of the LARGEST RECORD, not just of the
store.** Reassembling a record holds it whole, so a consumer that raises
`max_record` (§4.1) into the megabytes is also choosing the rebuild's memory
floor. This is the one place that setting has a cost beyond store space, and it
is not capped for you.

Not checkpointed, and will not become checkpointed under this contract version.
Consumers size accordingly:

```
  ~13k triples      sub-second, ~25 MiB
  ~1M triples       ~37 s, ~2.4 GB
```

A consumer operating past the cliff is outside this contract's design envelope
and should say so before building.

---

## 4. Obligations — write

### 4.1 Admission

Writes are **batch admission**: records plus an exact count, admitted by a
writer that runs and exits.

```
  wp_slice(records, count) -> block ids assigned
```

All-or-nothing per batch. Records are appended in the order given and receive
dense block ids from the global counter.

A batch of one is legal, and is the most expensive way to write anything —
see §4.4.

A batch of **zero** is not legal. `ADMIT` with a count of zero is refused
out of contract, and nothing is written and no watermark moves. A consumer with
nothing to admit does not call `ADMIT`.

**Every record in a batch must be a triple.** Valid UTF-8, carrying exactly two
`0x1f` separators — no more and no fewer. A record with a third separator is
not a triple whose target contains `0x1f`; the durable format has no escaping,
so there is no reading of those bytes under which it is one, and indexing it
would return a four-field row to a consumer expecting three (A.5). A batch
containing one is refused out of contract, naming the offending record's
position, and **nothing in it is written** — the refusal happens before the
batch is staged and before the writer runs. This is a narrowing of what
`ADMIT` accepts and it is deliberate: the alternative was accepting the record,
counting it, and never returning it.

**There is a maximum record size, and it is a setting, not a structural fact.**

```
  largest record = max_record          default 65536
```

Configurable at `.axverity-store/config/max_record`, freely, at any time. It is
**policy** — what a deployment chooses to accept — and there is no structural
bound underneath it. A record larger than a block is not refused: it **spans**,
written across consecutive blocks and reassembled on read.

**A consumer must not hard-code this number and must not assume 65536.** Ask
the operator, or read it out of the refusal: **since v2.0 the reply carries the
writer's own diagnostic verbatim** (A.8), so a batch refused for size names both
the offending count and the configured limit. This is a diagnostic, not a
discovery API — a consumer routes on the status byte and must not parse the
text, and a deployment may change the limit between one refusal and the next.

Two things a consumer should know about the neighbourhood of this setting:

- `block_capacity` (default 4194304, also configurable) no longer bounds a
  record. It is chosen when a store is created and fixed for its life, because
  record addresses derive from it, but it is a throughput and packing decision
  now, not a limit on what you may write.
- Raising `max_record` **above** the block payload capacity is what makes
  records span. That is a supported configuration: a spanning record is written
  across consecutive blocks, reassembled on read, and indexed like any other, so
  it is queryable by every name it carries. There is no size at which a record
  is accepted and then not returned.
- **What that last sentence rests on.** It was published before it was true and
  was false for two distinct reasons (§0.2, §10 item 13), so it is now carried
  by instruments rather than by assertion: `T9` writes a record at the shipping
  block size in the range that spans *without* filling a block, and `T8` reads
  a spanning record back through its locator. Both fail without their fix. A
  consumer relying on this obligation is relying on those.
- **Raising it also raises the rebuild's memory floor** (§3.2). Reassembly holds
  a record whole, and nothing caps it for you.

**Within the limit, nothing changes:** every record a batch carries is admitted,
and every one of them is returned by a subsequent query. There is no size at
which a record is accepted and then quietly not stored — a record either lands
or the batch is refused, loudly, with a reason. Over the limit, the batch is
refused and **nothing in it is written**.

### 4.2 Exactly one writer

**Single-writer-per-shard.** No WAL. No mutexes.

Two writers admitting to one store concurrently is undefined and will corrupt
the block-id sequence. axVerity does not enforce this inside the tiers — there
are no mutexes by design — so it is enforced **structurally at the transport**
(§5.6) and contractually by the consumer everywhere else (§7).

### 4.3 Durability

```
  wp_wait_durable(watermark)   opt-in, IN-PROCESS ONLY
```

Admission returns when records are written. Durability is a separate, opt-in
wait on a watermark. A consumer that does not wait has not been told its data
survives power loss, and must not claim it has.

Durability claims are settled by `strace`, not by mechanism argument.

**There is no durability verb on the wire, and v2.0 removed the one there was.**
`DURABLE` answered `ok` to every argument ever put to it — a watermark beyond
anything admitted, a negative one, a non-numeric one — so it was not a wait, and
a consumer calling it was entitled to believe it had one. It is deleted rather
than implemented, because on a run-and-exit writer there is nothing left to wait
for by the time a client can ask: the writer process has already exited, and
`ADMIT`'s status 0 is that fact. What a wire consumer therefore has is
`ADMIT` returning 0, and what it does NOT have is any statement about fsync. If
a deployment needs an ack that is settled by `strace`, that is a v2.1
obligation with an instrument, not a verb that answers `ok`.

### 4.4 The write cost model

**fsync count, not compute, is the write throughput ceiling.** The metric is
fsyncs-per-committed-row, and it is the number to quote in any performance claim
about this boundary.

Batch size is the consumer's primary tuning lever; per-object admission sits at
the worst end of it. A consumer with an interactive write surface either pays
the per-object fsync or queues and amortises. Both are supported. The contract
does not hide the difference.

### 4.5 Identity is assigned, not supplied

Block ids and RIDs are assigned at admission and are not knowable beforehand.

**`ADMIT` returns the block-id range its batch produced, one range per stream**
(v2.0). The two-phase write is therefore one round trip, not two: the reply IS
the read-back.

```
  ok admitted=N bytes=M structure=<first>,<count> payload=<first>,<count>
```

- `(first, count)` names the blocks `first … first+count-1` **in that stream**.
- **A stream that produced no block carries `count = 0` and `first = -1`.** It
  is `-1` and not `0` because `0` is a real block id in every store. A consumer
  reads the count first and must never read `first` when the count is zero.
- **There is no global id and the two ranges do not merge.** Ids are dense per
  stream (§2.1); `structure/block-4` and `payload/block-4` are different blocks.
  A handle is `(stream, first, count)` — carry the stream or you have nothing.
- A batch may produce blocks in both streams, and routing is by record size
  (§2.1), which is not something a consumer controls or should model.

**A handle names BLOCKS, not records.** A batch of one record is named exactly;
a batch of a thousand shares one range across all of them, so what a handle
references is the batch. A consumer that needs a specific record referenced
admits it alone, holds its handle, and admits the referencing records after.

**A reply may instead say `range=unavailable`, with the `structure=` and
`payload=` keys ABSENT.** It means the write landed and the range could not be
reported. The status stays `0`, because the write landed and every non-zero
status tells a client its write did not — a client that retries on this
duplicates durable records. Treat a **missing key as no handle, never as zero**.

**Identity is a name, and the name is the consumer's.** A block id is an
ordering and reference handle: a dense internal integer with no physical
meaning. It is **not** a content address, it is not stable under any future
compaction this document does not promise, and it is not a stable identifier a
consumer may persist as its own notion of identity. What a consumer persists is
its own naming; the handle is how it discovers where a batch landed, once.

A consumer needing identity knowable in advance derives it from its own naming.

### 4.6 Visibility

Readers see the store as of their last rebuild. Because ingest is immutable and
append-only, a stale reader is never an inconsistent reader — it has an older
complete prefix, not a corrupted view.

Consumers requiring freshness rebuild. No invalidation callback, no
subscription, no push.

---

## 5. Obligations — transport

### 5.1 axVerity owns the wire — the confined shim

axVerity ships **one** reference TCP transport — the **confined shim** — and it
is part of this contract.

This is deliberate and it is not about convenience. The single-writer term in
§4.2 is the hardest constraint in this document and the easiest to violate by
accident, because every conventional database transport does the opposite of
what it requires. Leaving remoting to consumers means N independent
implementations each rediscovering that, and some of them getting it wrong
silently against real data.

The shim is therefore the place where the contract stops being documented and
starts being **structural**.

Layering is preserved: the shim links the tiers in-process and ships alongside
them. It is not *in* them. The storage engine has no port, no session, no
protocol, and no listener. A consumer that links in-process gets exactly the
same surface with the shim absent.

### 5.2 Confinement (normative)

"Confined" is a set of testable properties, not a description of intent. The
shim SHALL:

1. **Consume only the published contract.** The shim reaches nothing below §2–§4
   — no private APIs, no tier internals, no back doors. It is bound by this
   document exactly as any other consumer is.
2. **Hold no state beyond the lease and connection bookkeeping.** No result
   caches, no derived indexes, no session-scoped stores, nothing that could
   answer a query without going to the tiers.
3. **Add no semantics.** No naming, currency, supersession, joins, content
   addressing, or any caching that changes visibility. §4.6 staleness is the
   tiers' property, not the shim's to smooth over.

   **Framing is not semantics, and the line is drawn here.** The shim counts a
   body's record frames, validates each record as UTF-8, and requires exactly
   two `0x1f` separators (§4.1). None of that is an opinion about what a name
   means, which is §1's territory and the consumer's. Each is a statement about
   whether the bytes *are a call at all*: a body whose frame count disagrees
   with its header is not a batch, and a record that is not `s US v US t` is not
   a triple, in the durable format as much as on the wire. The test is whether
   the shim could answer the question differently for two clients sending
   identical bytes. It cannot — so this is framing. Deciding that an empty name
   is illegal, or that `supersedes` is special, would be semantics, and the shim
   does neither.
4. **Expose a closed op set.** Five verbs (§5.7). Every one has an in-process
   counterpart. A verb with no counterpart means the shim has grown semantics.
5. **Not retry, reorder, coalesce or split** what a client sent. It carries
   calls; it does not decide about them.
6. **Not terminate policy.** No auth, no TLS, no tenancy, no routing, no
   quota. If those are needed they sit outside the shim, in front of it.

**The shim is the contract's own first consumer.** That is what makes the
confinement checkable rather than aspirational: if the shim ever needs something
the contract does not expose, the correct conclusion is that the *contract* is
short — not that the shim gets a private hook. A private hook is the single
change that would make this whole document decorative.

### 5.3 Confinement makes the shim replaceable

Because the wire is versioned (§5.9) and the confinement properties are
testable (§8), axVerity's shim is the **reference**, not the only permitted
implementation. A consumer with a real reason to write its own transport may,
and must pass the same conformance run including the negative test.

One blessed shape plus a public conformance suite is what prevents N divergent
integrations. A monopoly on the transport is not.

### 5.4 One listener, connections served concurrently

A single listener. Connections are served concurrently (amended, `f18532f`,
REQ-14): an idle open connection does not block another connection, which is
answered while the first is still open. There is no role handshake — see §5.9
and Appendix A; there is no handshake at all. Connections are never refused.

**Consumer guidance.** Because connections are served concurrently, a
connection you hold open does not stop other clients being answered. Still
prefer connect, call, close, and set a client-side timeout.

**`ADMIT` blocks the server for its whole duration, and the scan is part of it.**
Before the writer is spawned, the shim walks the entire body once — counting
frames and checking each record is a triple (§4.1). Measured at 300,000 records
on a 6.75 MB body, that pre-spawn scan is **401 ms against a 3.24 s write, about
12.4%**, and the server answers nobody for all of it: not the scan, not the
write, not the reply. A reader issuing a query at that moment waits the full
~3.6 s with no message.

**Batch size is the lever, and it is the consumer's to pull.** §4.4 pushes
batches *larger* because a batch of one is the most expensive way to write
anything; §5.4 pushes them *smaller* because a large one monopolises the server.
Neither is wrong and this document will not pick for you — the trade is between
write throughput and read latency for everyone else on that process, and only
the consumer knows which it is buying. If reads must stay responsive while
writing, batch in the thousands rather than the hundreds of thousands. If the
store is being loaded and nobody is reading, batch as large as memory allows.

Serialisation was the v2.0 draft design; connections are now served
concurrently (§5.4, REQ-14), so an idle open connection no longer stalls others.
The ADMIT cost above is measured on the earlier serial server and has not been
re-measured under concurrent serving; treat it as indicative.

### 5.5 Read role

One RAM tier per server process. Rebuild is a server-level operation and
staleness (§4.6) is a server-level property — every reader on a server sees the
same prefix.

Multiple server processes over one store are permitted for **reading**, and
each carries its own rebuild staleness. Note the interaction with §4.2: two
server processes over one store are also two paths to the writer with nothing
between them, and §5.6's lease does not exist to prevent it (Appendix A). One
server process per store is the only configuration this document can currently
stand behind for a store that is being written.

### 5.6 Write role

**DELETED at v2.0: there is no lease, and there never was.**

v1.0 published the write role as an exclusive lease refused at handshake, and
made that lease "the mechanism that makes §4.2 unbreakable over the wire instead
of merely stated". No `LEASE` verb exists, no handshake exists, and nothing
refuses a second writer. What happens instead is precisely what the deleted
clause ruled out: the second connection is accepted and served (concurrently, §5.4),
with nothing telling it that another writer exists.

The clause is removed rather than corrected because a specification of a refusal
that nothing performs is worse than silence — a consumer reading it builds a
pooled writer expecting to be told, and is not told.

**What actually holds §4.2, stated as what it is.** Connections are served concurrently (§5.4), so
this document does not claim that two writers cannot interleave through one
server process; no mechanism here prevents it. §5.5
permits several server processes over one store, and two shims on one store are
two writers with nothing between them. Single-writer is therefore a **consumer
obligation** (§7) and a deployment obligation, and this document does not claim
to enforce it.

Rebuilding it as a real mechanism is a v2.1 question and belongs to whoever has
a second writer to point at it (§9 rule 4).

### 5.7 Ops

**Three verbs, and the op set is exactly what is on the wire.**

```
  QUERY     mask s v t                 -> result stream, or STALE
  REBUILD                              -> ok, watermark
  ADMIT     count, records             -> ok, counts + block id range per stream
```

Every other opcode, `0` and `4` included, answers `UNKNOWN opcode N`.

There is no op here that does not exist in §3 or §4. If a verb appears on the
wire that has no in-process counterpart, the transport has grown semantics and
is out of contract.

**Two verbs were removed at v2.0, and the reason is the same for both.** v1.0
listed five and shipped four; the two the wire did not honour were the two this
section had to keep apologising for.

- `LEASE` was never built. §5.6's clause went with it.
- `DURABLE` was built and answered `ok` unconditionally. §4.3 explains why it
  was deleted rather than fixed.

**`ADMIT` returns the block-id range**, one per stream, closing the gap §5.7
carried through the whole of v1.0. §4.5 is the shape and A.8 is the bytes.

### 5.8 Errors

Errors distinguish two classes, and the distinction is normative:

- **Out of contract** — second writer, mixed role, malformed batch. The client
  is wrong. Retrying will not help and must not be attempted.
- **Transient** — connection loss, server restart. Retry is legitimate.

Collapsing these two is how a pooled-writer client turns a refusal into a retry
loop. They must not share an error code.

### 5.9 Protocol versioning

The wire is its own ratchet surface and carries its own version, negotiated at
handshake. Ops may be added within a major version; none may be removed or have
their semantics changed. A server refuses a major version it does not implement
rather than approximating it.

**Two of those three sentences are aspirational and one has now bitten.** There
is no handshake and no version on the wire (A.1), so a v1.0 client meeting a
v2.0 server discovers the change by calling `DURABLE` and being told
`UNKNOWN opcode 4`, or by calling `QUERY` and being told `STALE` — at runtime,
per call, with no negotiation and no refusal. That is a worse migration story
than this section promises, and it is the strongest argument on the table for a
handshake actually being built. Until one exists, **a deployment upgrades server
and clients together.**

### 5.10 Consumer-side adapters

A consumer may of course build its own adapter above the shim — that is where a
consumer's naming, currency and joins belong. Such an adapter is itself a
consumer of this contract, and this document applies to it unchanged. What it
must not do is push those semantics *down* into the shim (§5.2).

### 5.11 Open transport decisions

Recommendations given; the Lead Architect's call.

| # | Decision | Recommendation |
|---|---|---|
| T1 | One listener with role handshake, or separate read/write listeners | **One listener.** The refusal in §5.6 is explicit and legible; two ports invite a consumer to treat the write port as poolable |
| T2 | Shared server RAM tier vs per-connection | **Shared.** One rebuild cost amortised over N readers, and staleness becomes one property instead of N |
| T3 | Results streamed vs handle-plus-paged-fetch | **Streamed.** The O(R²) concern is in-process list copying, not the wire; paging adds server-side result state for no gain |
| T4 | ADMIT streams records vs client names a server-side file path | **Stream.** A path-based ADMIT requires a shared filesystem and quietly makes remote writes second-class |
| T5 | Frame encoding | **Unresolved, and currently two.** Frames carry an LEB128 length; the records inside an `ADMIT` body carry a fixed 8-byte little-endian length, because that is the writer's own input format and the transport passes it through byte-for-byte rather than re-framing it (§5.2 property 5). Both are published in Appendix A. Recommendation: **keep two and say so**. Reconciling them means changing the writer's input format, which is a write-path change and a separate authorisation, and it buys a consumer nothing that Appendix A does not — the two encodings never appear at the same layer, so no parser has to choose between them |
| T6 | Lease expiry on a wedged client | Needs a decision. A dead holder blocking all writes indefinitely is a real failure mode; a too-eager expiry reintroduces two writers. Recommend explicit release plus disconnect detection only, no timeout, until a real deadlock is observed |

---

## 6. Non-obligations (normative)

Not gaps. Not roadmap. Not deferred. **Consumer-side by design.**

| Not provided | Where it lives |
|---|---|
| Naming, namespaces, name-keyed lookup | Consumer |
| Supersession, currency, lifecycle | Consumer |
| Tombstones | Consumer |
| Content addressing, content-derived identity | Consumer |
| Update, delete, in-place mutation | Nowhere. Ever. |
| Conjunctive joins across patterns | Consumer, over query results |
| Index checkpointing | Nowhere, this version |
| Auth, TLS, multi-tenancy on the wire | Not this version — §10 |

### 6.1 Supersession — the landmine

A store may have **exactly one** supersession model in force, and it belongs to
the consumer.

axVerity's internal name-index push is not a lifecycle model and MUST NOT be run
as one against consumer data. A consumer with an edge-derived model that also
lets a version-chain push run over the same data will get nodes it considers
dead answering live. This is the single worst failure mode available at this
boundary, and it is silent.

An edge-derived model falls out of the generic store in one query:

```
  rt_query(2, _, "supersedes", _)   ->   target set == the superseded set
```

`_ _ t` is per-result flat. Cost is O(answer).

---

## 7. Consumer obligations

A consumer SHALL:

1. Own its naming, lifecycle, and semantics entirely.
2. Supply the store path. Never assume CWD-relative resolution.
3. Treat the RAM tier as process-scoped. Never persist it, never share it
   across processes, never assume it survives.
4. Declare its supersession model, and run exactly one.
5. Guarantee a single writer per store. The transport enforces this for wire
   clients; a consumer linking in-process carries it entirely itself.
6. Treat an out-of-contract error as a bug, never as a retry.
7. State whether it waits for durability, and measure the claim if it does.
8. Publish a **conformance oracle** (§8) before depending on axVerity in
   anything that matters.
9. Not read, port, or depend on any other consumer's internals to satisfy any
   of the above.

---

## 8. Conformance

A consumer proves itself against the contract — not against axVerity's current
build, and not against another consumer's behaviour.

```
  conformance corpus  (triples, fixed, shared)
         |
         +--> axVerity ---------------> results --+
         |     in-process AND wire                 +--> diff
         +--> consumer's own oracle ---> results ---+
```

**Shared and owned by this contract:** the corpus, the eight binding patterns, a
write/read-back round-trip, and a **wire-vs-in-process equivalence run** — the
transport must produce identical results to the linked tiers over the same
corpus, or it has semantics of its own.

**The corpus must vary record SIZE, not only shape.** Every size defect this
contract has recorded — S2's retired rationale, the framing ceiling, and both
spanning defects in §10 item 13 — survived a green suite because the corpus in
front of it was uniformly small, so the failing region was never entered. A
conformance corpus that exercises eight binding patterns over 12-byte triples
proves eight binding patterns over 12-byte triples. At minimum it must carry
records on both sides of the deployment's `block_capacity` and both sides of
2,097,151, since those are the two boundaries where the write path changes
representation.

**Owned by each consumer:** the oracle, and the acceptance criterion.

A consumer's oracle is whatever it already trusts. For a consumer migrating
from another store, that is the store it replaces. For a greenfield project it is a reference implementation the project
writes itself. Neither is axVerity's problem.

Acceptance is **identical result sets over the full corpus across N rebuild
cycles**, plus round-trip identity on admission, plus wire/in-process
equivalence. Not sampled. Correctness, crash and round-trip tests are binary —
small populations, never large ones.

The shim ships with **negative conformance tests**, which are what make
confinement (§5.2) checkable rather than aspirational:

- A second WRITE connection is refused, and the refusal is an out-of-contract
  error, not a transient one.
- The shim's link/dependency surface contains nothing below §2–§4. If it binds
  a private symbol, confinement property 1 has already failed.
- A repeated identical QUERY reaches the tiers both times. A shim that answers
  the second from state of its own has violated property 2, and will drift from
  §4.6 visibility the moment the store advances.
- Wire results are identical to in-process results over the full corpus
  (property 3).

---

## 9. Ratchet rules

1. **Obligations may be added, never removed or narrowed** within a major
   version.
2. **Non-obligations may only be promoted by major version bump**, and only on
   evidence that two independent consumers need the same thing in the same
   shape. One consumer's need is a consumer-side problem by definition.
3. **A locked decision is not reopened by re-deriving the argument for the
   alternative.** New measured evidence, or nothing.
4. **Nothing is built ahead of its triggering condition.** A capability with no
   live consumer does not get built, does not get specced, and does not appear
   here as future work.
5. Amendments carry the intent_id that governed them.

---

## 10. Resolution of the unratified claims

Every claim this document rested on without a citation, resolved. **Settled**
items are facts with a citation or a test that produced them. **Open** items
stay open, each with what would settle it — an open item is not a defect, it is
a claim this document does not make.

Resolved 2026-08-20 under `AXVERITY_SILENT_LOSS_FIX_V1`, against a
50-arm black-box wire harness (`wire-harness/`), the shim's three suites, the
read tier's durable suite and the write path's slice and crash suites.

### Settled

| # | Claim | Verdict | Citation |
|---|---|---|---|
| 1 | `rt_query(mask, s, v, t)` signature and mask encoding | **fact** | `readtier/lib/rt_query.m1:10`; masks dispatched at `:11-18` |
| 2 | Mask 0/1/2/3 map to `_ _ _`, `s _ _`, `_ _ t`, `s v _` | **fact — and it was FALSE** | The mask is bitwise: `rt_query.m1:11-18` dispatches 1→`s`, 2→`v`, 4→`t`. §3.1 is corrected and carries the note. Found by `P2/contract-mask-table-is-wrong` |
| 3 | `rt_rebuild` resolves the store path CWD-relative | **fact** | `readtier/lib/rt_rebuild.m1:54-55` — literal relative paths. The shim `cd`s into the store root before serving (`shim/bin/axshim`), which is why an absolute store path is honoured: `P4/store-path-is-honoured-not-CWD-relative` PASSES from an unrelated CWD |
| 5 | Rebuild cost figures in §3.2 | **fact at 13k; unmeasured at 1M** | 13,000 w2-shaped triples rebuild in 430–449 ms — sub-second, as published. The ~1M / ~37 s figure is still an extrapolation and §3.2 says so |
| 6 | Name-index push is not a lifecycle model | **fact** | 11 `sup/*` assertions in the read tier's selftests, and the harness recovered a complete supersession model from published verbs alone with no ids and no store access. §6.1's worked example is correct as written |
| 7 | `wp_slice` shape; `wp_wait_durable` is an opt-in watermark ack | **fact** | `lib/wp_wait_durable.m1:34`; the publish point is asserted by `tests/run-slice-test.sh` (`PUBLISH_POINT`: published with no consumer, writer never stalled) |
| 8 | Block ids / RIDs are unknowable before admission | **fact** | `lib/wp_bid_resolve.m1:26-39` — max+1 over the durable store, resolved inside the writer at write time. §4.5's two-phase requirement therefore stands. See the open half below |
| 13 | §4.1's "no size at which a record is accepted and then not returned" | **fact — and it was FALSE when published** | Two defects, both silent, both found by reviewing the landing rather than by any suite. A record that spans without filling a block was durable and indexed by nothing (`rebuild_records=2` of 3 at 3,145,728 B, the shipping capacity); and a spanning record's locator decoded its own first body byte as a length prefix (`len=100` for a 10 MB record). Fixed, and now held by `T9` / `T8` of `tests/run-readtier-durable-test.sh` and `SPAN_ONE_BLOCK` of `tests/run-slice-test.sh`, each of which fails without its fix |
| 17 | Five liveness probes in `shim/tests/unknowns.py` asked "did it answer ok" and meant "did it serve" | **was a REGRESSION from v2.0's freshness gate; found at G6, fixed** | Each computed `survived = (status == OK)` on a `QUERY` issued with no `REBUILD` — which §3.1's gate now correctly answers `status 1 STALE`, a served connection giving a correct refusal. Measured at HEAD in an isolated worktree: `22 characterised, 0 unexpected`, exit 0; on the landing before the fix: `17 characterised, 5 unexpected`, exit 1. **The suite's own summary encoded it from the moment the gate landed and was read as normal output for three gates** — `unexpected` is a `bad()` count, and `characterised` fell 22 → 17 at the same time. Re-specified, not relaxed, to the same two-reply set `run-shim-breakage.sh` received at G5 item 8a: status 0, or status 1 whose body begins `STALE`. Back to `22 characterised, 0 unexpected`, exit 0 |
| 14 | §2.1's `shared id space` and unconditional `varint length prefix` | **both FALSE; §2.1 corrected** | Per-handle sequences make `block-36` ambiguous across streams (`readtier/lib/rt_rid_stride.m1:26-28`), and a spanning record carries no length prefix at all (`experiments/continuation/FORMAT-SPAN.md`). Consumer-visible only to something parsing the store directly, which §3 makes unnecessary |
| 12 | The shim can be built entirely on the published surface | **fact, for the shim** | The shim exists, links the tiers in-process, and reaches nothing below §2–§4; the one store path it names (`shim/lib/sh_rebuild.m1:20`) is §2.1's published layout. **The document was nonetheless short**: a consumer could not write a *client* from it, because no opcode, framing, separator or status byte was published. Appendix A closes that. Property 1 holds; the gap it was guarding against was real and was elsewhere |

### Open

| # | Claim | Status | What would settle it |
|---|---|---|---|
| 4 | The four-pattern consumer requirement is complete | **open, and no longer load-bearing** | Provenance still unconfirmed, and re-deriving it is consumer-side work. It gates nothing now: all **eight** binding patterns are exact — six probes across a 12-triple corpus, zero missing and zero unexpected on every mask — so completeness of the four does not change what this document owes |
| 9 | Concurrent readers observe no torn state against a live-appending store | **open, and currently UNREACHABLE** | The question cannot arise on this build: exactly one connection is served at a time (§5.4), so concurrent readers do not exist. Settling it needs either a concurrent server or in-process observation with two reader threads against a writing store. Until then §5.5's shared-tier claim is untested rather than false |
| 16 | Where the store's working files are declared | **open, placement only** | §2.1 declares `admit.tmp`, `writer.err` and `admit.ids`, and that section's own text says they are not part of the durable artefact it describes. Two options, both already named in the document: leave them in §2.1, which is where the store layout is published, or move them to §5 with the transport that creates them. Nothing about the files' behaviour is in question — only which section owns them |
| 15 | An empty store has no read verb that answers `ok` | **open, introduced at v2.0** | `REBUILD` answers `NOSTORE` and `QUERY` now answers `STALE`, because the freshness gate starts closed and only `REBUILD` opens it. Both refusals are honest; the pair is a narrowing v1.0 did not have, and a consumer's first contact with a fresh deployment is two refusals. Settling it is a decision, not a test: either `REBUILD` succeeds with `0` on an empty store (which makes `NOSTORE` disappear and opens the gate), or this stands and §A.7 tells consumers to expect it |
| 11 | Auth / TLS deferral is safe | **open** | True on loopback and nowhere else, and worse than the draft assumed: with no handshake, any client may connect and write; since v2.0 amended §5.4 (REQ-14, connections served concurrently), a silent connection no longer denies service to others, but nothing refuses or identifies a second writer. Settling it is a deployment-envelope decision, not a test. **v2.0 is a loopback contract.** |

### Not implemented — stated, so nobody builds on them

| # | Claim | Status |
|---|---|---|
| 10 | A resident lease over a run-and-exit writer | **NOT IMPLEMENTED, and no longer specified.** §5.6's clause was DELETED at v2.0 rather than left describing a refusal nothing performs. The op set is exactly `{QUERY, REBUILD, ADMIT}`. Single-writer is a consumer and deployment obligation; §5.6 now says so |
| — | §4.5's block-id return | **IMPLEMENTED at v2.0**, as one `(first, count)` range per stream. It was blocked first: `AXVERITY_W2_ADMIT_HANDLE_V1` locks `block_id` as "global, single-writer, dense from 0", which `experiments/handle/no-global-id.sh` shows has not been true since per-handle sequences landed — the union of the two directories is a multiset, and the writer's own global counter reissues an id across a restart while naming no file. The Lead Architect amended the limit to §2.1's semantics rather than the fact. Held by `P1/ADMIT-returns-a-block-id-range-per-stream` (the range advances by exactly the block count; an empty stream is absent, not zero), `experiments/handle/ids-vs-ls.sh` (published range vs `ls` before/after, 5 shapes, 10/10) and `experiments/handle/handle-roundtrip.sh` (T1 a supersedes edge built from the reply alone; T4 a handle byte-identical across a real SIGKILL, restart and replay) |
| — | `DURABLE` | **REMOVED at v2.0**, having been implemented as an unconditional `ok`. It is listed here rather than dropped so that a reader of v1.0 finds out what happened to it |

### Outstanding obligations — asserted, not yet tested

These are obligations this document makes and that **no instrument has yet
checked**. They are not open questions about the design; they are claims whose
evidence does not exist.

| Obligation | Why it is untested |
|---|---|
| **§8 wire-vs-in-process equivalence** — a consumer linking the tiers directly gets the same surface with the shim absent | Needs in-process observation alongside a wire run. The wire harness is restricted to the socket by design and cannot see the other half |
| **§5.2 confinement properties 1–2** — the shim consumes only the published contract, and holds no state beyond connection bookkeeping | Property 1 is argued from source and property 2 from the absence of caches. Neither is *tested*; a real check needs an instrument that can observe what the shim reads and retains at runtime |
| **§4.3 / §4.4 durability and the write cost model** — the write path is a full barrier at a fixed fsync count per durable block | Settled only by `strace`, which no suite runs. v2.0 removed `DURABLE` rather than leave a verb answering `ok` in place of that evidence (A.9), so the wire now carries **no durability claim at all** — which is weaker than v1.0 pretended and exactly as strong as what is measured |

A consumer may rely on §2–§7 as written. It may not rely on the four rows above
being *demonstrated* — they are the first things a v1.1 conformance instrument
should attack.

**And that distinction is not academic — it has already been paid for twice.**
§4.1's "there is no size at which a record is accepted and then not returned"
was published in the same revision that broke it, and stayed false through a
fully green suite, because the tests that existed asserted record counts and
name counts and neither can see a record that was never indexed at all. The
rule this produces: **an obligation added to §2–§5 needs an instrument that
fails without it, written before the obligation is published, not a
demonstration that the happy path works.** A green suite is evidence about the
cases it enumerates and about nothing else.

---

## 11. Out of scope for v2.0

Named so they are not mistaken for oversights:

- **Migration.** Nothing here migrates anything. A consumer projecting an
  existing corpus into a store does so one-way, additively, with its existing
  store canonical until its own conformance says otherwise.
- **Multi-shard coordination.** This contract describes one store. Placement,
  sharding and cross-shard consistency are not addressed and must not be
  inferred from it.
- **Any consumer's existing wire.** Retiring one is that consumer's decision,
  taken after its conformance goes green.

---

## Appendix A — The wire, byte for byte

**Normative.** This appendix exists because the rest of §5 published verb
*names*, error *classes* and a *recommendation*, and a consumer cannot write a
client from those. Every byte below was **observed on a socket** against a
running `shim/bin/axshim` — opcodes by sweep, encodings by probe, replies by
capture. None of it was read out of the shim's source, because what a consumer
meets is the wire and not the intent behind it.

Reference client: `wire-harness/axwire.py` — dependency-free, ~273 lines.
Adopt it rather than reimplementing this.

### A.1 Connection

Plain TCP. **There is no greeting.** A server sends nothing on accept; a client
that waits for one waits forever. There is no handshake, no role negotiation
and no version exchange — §5.9's ratchet has no hinge on this build, and a
client must assume it is talking to the only protocol version that exists.

One connection is served at a time (§5.4). Connect, call, close.

### A.2 Framing — both directions

```
  frame  =  LEB128(payload_length)  ||  payload
```

Unsigned LEB128, 7 bits per byte, low group first, high bit set on every byte
but the last.

```
  request payload  =  opcode_byte  ||  args
  reply   payload  =  status_byte  ||  body        (body is UTF-8 text)
```

### A.3 Opcodes

Established by sweeping all 256 values. Exactly three answer.

```
  1  QUERY      2  REBUILD      3  ADMIT
```

Everything else — including `0`, and including `4`, which was `DURABLE` through
v1.0 — answers `status 1`, body `UNKNOWN opcode N`. There is no `LEASE` (§5.7).

### A.4 Status bytes

```
  0   ok
  1   out of contract — the client is wrong; do not retry (§7.6)
  2   transient      — retry is legitimate
  3   server fault   — the server could not run; retrying will not help
```

Codes 2 and 3 are reachable only through `ADMIT`, and only when the writer is
killed by a signal or cannot be started. Every read-path failure is 1 —
including the v2.0 `STALE` refusal (A.6), which is out-of-contract by §5.8's own
test: retrying the same `QUERY` without a `REBUILD` in between will not help. A
transient condition on any other verb is learned from the socket dying, not
from a status byte. Treat an unexpected status as out-of-contract.

### A.5 The field separator

**`0x1f` (US) separates fields in both directions and is never escaped.**

A name containing `0x1f` corrupts the frame it appears in. `0x1f` is reserved
and a consumer must not emit it inside a name. Every other byte sequence that
is valid UTF-8 round-trips exactly — verified across ASCII, Latin-1, CJK,
astral-plane, emoji, RTL, combining marks, embedded NUL, tab, CR and newline.

**The empty string is a legal name** and round-trips as an empty field.

### A.6 QUERY

```
  request args  =  ASCII(mask)  US  s  US  v  US  t
```

The mask is a decimal ASCII integer and is a **bit set**: bit 0 binds `s`,
bit 1 binds `v`, bit 2 binds `t` (§3.1). Arguments for unbound positions are
ignored but the separators must still be present — four fields, always.

The reply is a **stream**:

```
  frame 0   status 0, body = ASCII row count N
  frames 1..N   status 0, body = s US v US t
```

Read the head frame, parse N, then read exactly N frames. Nothing marks the
end of the stream and the connection is **not** closed after it — a client
that keeps reading blocks, and while it blocks nobody else is served.

Observed:

```
  -> 06 01 30 1f 1f 1f                    QUERY mask 0
  <- 02 00 32                             "2"
  <- 11 00 alpha US knows US beta
  <- 12 00 alpha US likes US gamma
```

A mask outside 0–7 is not refused (§3.1).

**A `QUERY` may be refused before it is evaluated (v2.0).** If the serving
process has not completed a `REBUILD`, or has completed an `ADMIT` since its
last one, the reply is a single frame and there is no result stream to read:

```
  -> 06 01 30 1f 1f 1f                    QUERY mask 0
  <- .. 01 "STALE the RAM projection does not reflect the durable store — …"
```

A client must check the status byte of the **head** frame before reading N
frames behind it. `axwire.Client.query` already does; a raw caller that assumes
the head frame is a count reads the refusal text as a row count, gets a
`ValueError`, and desynchronises the stream.

### A.7 REBUILD

```
  request args  =  none
  reply         =  status 0, body = ASCII watermark (records indexed)
```

The watermark counts every durable record across every stream, and agrees with
the sum of the `admitted=` counts that produced them.

On a store nothing has ever been admitted to, `REBUILD` answers **status 1**
with `NOSTORE …`. An empty store is the normal first state of every deployment
and the condition clears the moment anyone admits — so despite §7.6, this is
the one status-1 a consumer may retry. It is recorded as a defect in §10, not
as a rule to build on.

**v1.0 said "prefer `QUERY`, which answers `ok` with `0` rows on the same
store". That advice is void.** Since v2.0 the freshness gate starts closed and
only a successful `REBUILD` opens it, so `QUERY` on an untouched store answers
`STALE` and `REBUILD` answers `NOSTORE`: a brand-new deployment has **no read
verb that answers `ok`** until somebody admits. Treat both refusals as "this
store is empty and nobody has written to it", and retry after your first
`ADMIT`.

### A.8 ADMIT

```
  request args  =  LEB128(count)  ||  record*
  record        =  u64 little-endian length  ||  payload
  payload       =  UTF-8  s US v US t
```

**Note the second length encoding.** Frames use LEB128; records inside an
`ADMIT` body use a fixed 8-byte little-endian length, because the body is
passed to the writer byte-for-byte and that is the writer's own input format
(§5.2 property 5, §5.11 T5). The two never appear at the same layer.

`count` must equal the number of records the body actually holds. A
disagreement is refused with status 1 and nothing is written — the body is
self-delimiting, so the count is checked, not trusted. `count = 0` is refused,
and so is any record that is not valid UTF-8 carrying exactly two separators
(§4.1). The `payload` line above is therefore **enforced, not merely
described**: the wire carries triples, and a consumer that needs to store an
opaque blob is not doing it through `ADMIT`.

```
  reply  =  status 0, body = "ok admitted=N bytes=M structure=F,C payload=F,C"
```

`F,C` is `(first block id, block count)` for that stream, and the two ranges are
independent — ids are dense per stream (§2.1) and there is no global id. A
stream that produced no block carries `-1,0`; **`-1` is deliberate, because `0`
is a real block id.** Observed:

```
  -> 33 01 16 00 00 00 00 00 00 00  docA US kind US note
  <- 00 "ok admitted=1 bytes=22 structure=0,1 payload=-1,0"
```

A reply may instead carry `range=unavailable` with **no** `structure=` or
`payload=` key. It means the write landed and the range could not be reported;
the status is still `0` and the batch must not be retried. A client checks for
the key's presence — it never defaults a missing key to `0` (§4.5).

`wire-harness/axwire.py`'s `parse_handle()` is the reference parser; it returns
a stream only when its count is positive, so an empty stream is **absent** from
the result rather than present as a zero.

A record is admitted at any size up to `max_record` (§4.1) — **65536** by
default, and a per-deployment setting rather than a constant of the protocol. A
record over it is refused with status 1 and nothing in the batch is written;
nothing between is dropped.

`max_record` is the ONLY size bound on the wire. The store's block size is not
one and must not be reasoned about: a record larger than a block is written
across several and reassembled on read, so a consumer sees one record whatever
its size. A record admitted at any size below `max_record` is returned by a
subsequent `QUERY` under every name it carries.

**"Nothing in the batch is written" is a durable-state claim, not a claim about
what the writer touched.** A refused batch can leave `.axverity-store/**/*.part`
files behind — a partially written block never renamed into place. They are
inert: a block becomes durable only on rename, recovery discards `.part`
entries, and `REBUILD` counts them as skipped rather than reading them. Nothing
sweeps them, so a consumer that retries a too-large batch in a loop accumulates
them. Do not; a status-1 refusal is not retryable (§7.6).

**The refusal names the limit (REQ-6).** The writer writes its one-line
diagnostic (`FATAL records_too_large=1 max_record=65536`) to
`.axverity-store/writer.err`, and the shim relays it word for word in the reply
body. The limit is `.axverity-store/config/max_record`, default 65536:

```
  <- 01 "WRITER exit=1 the writer rejected this batch; retrying the same
         bytes will not help: records_too_large=1 max_record=65536"
```

The status is the contract: `1` means refused and durable state is unchanged,
so retrying is pointless until the batch changes. Discovering the configured
limit is §4.1's business — ask the operator — not this reply's.

Observed — two records, one 16 B and one 17 B:

```
  -> 33 03 02
     10 00 00 00 00 00 00 00  alpha US knows US beta
     11 00 00 00 00 00 00 00  alpha US likes US gamma
  <- 00 "ok admitted=2 bytes=49"
```

Writes are invisible to `QUERY` until a `REBUILD` (§4.6).

### A.9 DURABLE — REMOVED at v2.0

```
  -> .. 04 "41"
  <- .. 01 "UNKNOWN opcode 4"
```

Through v1.0, opcode 4 was `DURABLE watermark -> status 0, "ok"`, and **the
argument was never read**: every watermark tried answered `ok`, including one
far beyond anything admitted, a negative one, and a non-numeric one. §4.3
published it as an opt-in wait, so a consumer calling it was entitled to believe
it had one.

It is **deleted, not fixed**. On a run-and-exit writer there is nothing left to
wait for by the time a client can ask — `ADMIT`'s status 0 already means the
writer ran and exited — so the verb had no work to do, and a verb with no work
that answers `ok` anyway is the defect itself, not a stub of a feature. Opcode 4
is now indistinguishable from any other unassigned byte.

**A v1.0 client calling `DURABLE` gets `status 1` and must not retry.** There is
no handshake to warn it (§5.9); upgrade server and clients together.

### A.10 What a client must do

1. Connect, send one request, read the reply, close. Never hold a socket idle.
2. Set a timeout on every read. A hang is what a busy server looks like.
3. Read `QUERY` as head-count-then-N-frames; do not read past N — **and check
   the head frame's status first**, because a refused `QUERY` sends one frame
   and no stream (A.6).
4. Never emit `0x1f` inside a name.
5. Send `ADMIT` counts that match the body, and never send zero.
6. `REBUILD` after admitting, before expecting to read what you wrote — and
   after connecting to a server you did not just watch start. Forgetting is now
   a refusal rather than a wrong answer, but it is still your call to make.
7. Route on the status byte, not on the message text.
