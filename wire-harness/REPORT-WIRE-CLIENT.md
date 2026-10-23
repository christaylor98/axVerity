# P6 — Wire client readiness report

`AXVERITY_WIRE_CLIENT_HARNESS_V1` · first run 2026-08-20, 50 arms, **28 PASS,
22 FINDING, 0 FAIL, 0 ERROR** · `wire-harness/run-all.sh`

**Re-run 2026-08-26 after `AXVERITY_SIZE_THRESHOLD_RECONCILE`,
`AXVERITY_SPAN_RESTORE` and its P8 follow-up: 50 arms, 32 PASS, 18 FINDING, 0
FAIL, 0 ERROR.** The four arms that moved since the first run are W1, W2, W4
and now W15; the body of this report is the first run's and is corrected in
place where a finding closed, never rewritten.

**Two arms were repaired rather than re-measured, and the distinction matters.**
Both had stopped probing their own subject when the default block grew from
16 KiB to 4 MiB and `max_record` was published at 65536 — the same class of rot
that hit T1, R17, U1b and U2. `P3/long-names` swept sizes against whatever the
deployment's limit happened to be; `P5/status-classes-reachable` called a
20,000-byte record "oversize" and recorded its status as **0**, an arm about
status classes not exercising a status class. Both now PIN the tunable they are
probing (`Shim(..., config={...})`) so each states the deployment it measures
instead of inheriting one. A black-box harness may not read a default out of
the implementation; it may set one.

## 0. What was and was not touched

The harness opened TCP sockets and started and stopped `shim/bin/axshim`. It
did not read, list, stat or glob anything under a store directory; it only
`mkdir`ed a fresh root per arm and `rm -rf`ed it before use. It did not read
`shim/`, `readtier/`, `lib/`, `src/`, or any registry — including
`shim/tests/axclient.py`, which is the one file that would have made P1
trivial and worthless. It read `AXVERITY_CONSUMER_CONTRACT.v1.0-draft.md` and
nothing else. It read the shim's stdout not at all: readiness is detected by
polling the port, and the process's output goes to `/dev/null`. Nothing outside
`wire-harness/` was edited. Every failing arm is left failing.

The only oracle is `harness.Sent` — the harness's own record of what it
admitted. No decoder, no store reader, no in-process tier.

## 1. The protocol, and where it came from

The contract publishes five verb *names* (§5.7), two error *classes* (§5.8), a
handshake (§5.4, §5.9) and one framing *recommendation* (§5.11 T5). It
publishes no opcode, no field order, no encoding, no status byte, and no record
format. **A consumer cannot write a client from this document.** Every byte
below marked `[WIRE]` was recovered from the socket by black-box probing — a
256-value opcode sweep, then an encoding sweep — and is preserved in
`wire-harness/probes/`.

```
request   LEB128(len) || opcode || args           [§5.11 T5 for the length]
          1 QUERY   2 REBUILD   3 ADMIT   4 DURABLE          [WIRE]
          no LEASE, no handshake, no version                 [WIRE]
reply     LEB128(len) || status || text                      [WIRE]
          status 0 ok, 1 out-of-contract; nothing else exists [WIRE]

QUERY     args = ASCII  mask US s US v US t                  [WIRE]
          reply = a stream: head frame carries the count,
                  then that many frames of  s US v US t      [WIRE, matches T3]
          mask is BITWISE: bit0 s, bit1 v, bit2 t            [WIRE]
REBUILD   args = none ; reply = watermark                    [WIRE]
ADMIT     args = LEB128(count) || record*                    [WIRE]
          record = u64 LITTLE-ENDIAN len || payload          [WIRE]
          payload = UTF-8  s US v US t                       [WIRE]
          reply  = "ok admitted=N bytes=M"                   [WIRE]
DURABLE   args = watermark ASCII (not read) ; reply = "ok"    [WIRE]

US = 0x1f, the field separator in both directions, never escaped.
```

Two length encodings are in use on one wire — LEB128 for frames, fixed u64
little-endian for records — which is precisely what §5.11 T5 chose one encoding
to prevent.

The client library is `wire-harness/axwire.py`. It is dependency-free, 273
lines, and is the thing a consumer should adopt rather than reimplement.

## 2. Results

| Phase | Arms | Pass | Finding |
|---|---|---|---|
| P1 client library and published surface | 8 | 2 | 6 |
| P2 round trip (load-bearing) | 16 | 13 | 3 |
| P3 names and edges | 9 | 4 | 5 |
| P4 lifecycle | 8 | 6 | 2 |
| P5 adversarial | 9 | 3 | 6 |

## 3. Findings, ordered by what they do to a consumer

### Blocking — a consumer that ships on this loses data or hangs

**W1 · A record of 33 bytes or more is accepted, counted, and invisible.**
`ADMIT` answers `ok admitted=1`; `REBUILD` answers watermark `0`; every mask
returns nothing. Swept one record per fresh store from 24 B to 49 B: 24–32 B
exact, 33 B and up gone. The boundary is the UTF-8 length of `s US v US t`, so
three names averaging ten characters are already over it. §8 requires
"round-trip identity on admission"; it does not hold above 32 bytes. The only
wire-visible symptom is that `REBUILD`'s watermark stops agreeing with `ADMIT`'s
own `admitted=` count. *(P3/record-size-32-byte-cliff)*

**W2 · An empty name in any position makes the whole triple invisible, with no
signal at all.** Unlike W1 the watermark *agrees* with the admitted count, so a
consumer comparing the two learns nothing. §1 says axVerity "has no opinion
about what any of those three positions mean"; the empty name is therefore a
legal name, and a consumer emits one the first time a field is blank.
*(P3/empty-name)*

**W3 · The server handles exactly one connection at a time, and never says so.**
A second `connect()` succeeds instantly, the client may send, and it receives
nothing until the first connection closes — then it is served in 0.000 s. Nine
sockets were held open at once and none was refused. A client that connects and
sends nothing blocks every other client indefinitely. §5.4 publishes "READ —
many concurrent connections permitted" and §5.5 invites pooling, multiplexing
and load-balancing. A pooled consumer hangs, and its first symptom is a timeout
with no message. *(P5/second-concurrent-connection, P5/an-idle-open-connection…)*

**W4 · `ADMIT` with count 0 permanently wedges the server.** Two bytes of body
from one client and the process never answers anyone again. It stays alive and
the port stays open, so a supervisor sees health. §4.1 says a batch of one is
legal; it does not say a batch of zero is fatal. *(P5/ADMIT-with-count-zero…)*

### Severe — the contract says something the wire does not do

**W5 · §3.1's mask table is wrong, and being wrong is silent.** The wire is
bitwise: bit0 `s`, bit1 `v`, bit2 `t`. §3.1 publishes mask 2 as `_ _ t`; on the
wire mask 2 is `_ v _` and `_ _ t` is mask 4. A consumer following the table
asks `query(2, t="beta")` for in-edges and receives an empty set with status
**ok**, concludes the node has no in-edges, and continues. §6.1 of the same
document writes the supersession query as `rt_query(2, _, "supersedes", _)` —
mask 2 with the *verb* bound — so the contract contradicts itself and §6.1 is
the half that is right. §10 item 2 lists this mapping as an untested
prediction; it is now settled, and it is wrong. *(P2/contract-mask-table-is-wrong,
P3/supersession-mask-number-contradicts-§3.1)*

**W6 · There is no LEASE, so §4.2 is enforced by nothing.** The op set is
exactly {QUERY, REBUILD, ADMIT, DURABLE}; every other opcode answers `UNKNOWN
opcode N`. §5.6 requires a second WRITE to be "refused at handshake, not
queued, not multiplexed, not accepted-then-serialised". What happens is
accepted-then-serialised, by name. On one server process the accept loop
happens to keep runs clean — but §5.5 explicitly permits "multiple server
processes over one store", and two shims on one store is two writers with
nothing between them. §5.6 says the lease is what "makes §4.2 unbreakable over
the wire instead of merely stated"; here it is merely stated.
*(P1/LEASE-absent, P5/two-WRITE-connections-are-accepted-then-serialised)*

**W7 · `DURABLE` is not argument-sensitive.** It answered `ok` for every
watermark tried, including one far beyond anything admitted and a non-numeric
one. §4.3 publishes it as an opt-in *wait* on a watermark and warns that "a
consumer that does not wait has not been told its data survives power loss". A
consumer that calls it is entitled to believe it waited. This harness cannot
settle the durability claim — §4.3 says `strace` settles it and WIRE_ONLY
forbids the instrument — but the wire carries no evidence the argument is read.
*(P4/durability-wait-is-not-argument-sensitive)*

**W8 · Two status codes exist, and the taxonomy §5.8 makes normative is not
expressible.** 0 is ok; 1 is everything the client got wrong. Transient is
reachable only as a dead socket, learned from the socket rather than the
protocol. A server with a recoverable in-band condition — busy, rebuilding,
writer unavailable — has no code to say it with and would have to reuse 1,
which §7.6 forbids the consumer from retrying. An internal fault and a
malformed request are the same byte. *(P5/status-classes-reachable)*

### The contract is short — a consumer cannot build without these

- **W9 · The wire format is unpublished in its entirety** — opcodes, argument
  order, record framing, the 0x1f separator, the status byte. Every one had to
  be probed. A name containing 0x1f corrupts the frame (loudly, at least), and
  nothing tells a consumer 0x1f is reserved. §10 item 12 asks whether the shim
  can be built on the published surface; the shim exists, but an outside
  consumer cannot build a *client* on it. *(P1 ×4, P3/name-containing-the-field-separator)*
- **W10 · No handshake and no version negotiation.** §5.9 makes the wire "its
  own ratchet surface" carrying a version negotiated at handshake, and requires
  a server to refuse a major version it does not implement. There is no
  handshake at all, so the ratchet has no hinge. *(P1/no-server-greeting)*
- **W11 · `ADMIT` returns no block id range**, contrary to §5.7. §4.5's
  two-phase write — "admit, read back, then admit the referencing records" —
  has nothing to read back. *(P1/ADMIT-does-not-return-block-ids)*
- **W12 · Masks outside 0–7 are not refused.** 8, 99, −1 and the literal string
  `frog` all answer ok; `frog` returns the whole store. An off-by-one in a
  consumer's mask constant produces silence, not a bug report.
  *(P2/masks-outside-0..7-are-not-refused)*
- **W13 · QUERY answers a set, not a multiset.** Re-admitting an identical
  triple advances the watermark (2→3→5) and leaves the row count at 2. §2.2's
  "further appends, interpreted client-side" is how a consumer is told to model
  change — but identical appends collapse on read, so axVerity cannot be used
  as an event log. *(P2/duplicate-admit-appears-twice)*
- **W14 · `REBUILD` on an empty store is classified out-of-contract.** An empty
  store is every deployment's first state and the condition clears the moment
  anyone admits, so retrying is exactly right — yet §7.6 obliges the consumer
  to treat status 1 as a bug and never retry. `QUERY` on the same store answers
  ok, so the two read verbs disagree about whether empty is an error. The
  message also names `.axverity-store/structure`, a path relative to the
  server's CWD rather than the store root supplied, which sends a diagnosing
  consumer to the wrong directory. *(P4/empty-store-REBUILD…)*
- **W15 · CLOSED (2026-08-26).** *"No record or name size limit is
  published."* It is published now: §4.1 states `max_record`, its default of
  65536, and its config path, and says a consumer must not hard-code it. The
  arm was re-pointed at the question that replaced it — is the published limit
  the ENFORCED limit — and it PASSES exactly: against a store pinned to
  `max_record=20000`, the last accepted name is 19,996 B and the first refused
  is 19,997 B, which is that limit less the 4 bytes of `US v US t` the record
  carries around it. *(P3/long-names)*

  The original W15 measurement is kept because it recorded a **different**
  defect that has since been fixed and must not be re-derived from this line:
  "33 B–16383 B silently dropped" was W1, the rebuild reading one stream, not
  a size limit at all. And "≥16384 B refused" was the block capacity acting as
  a record ceiling, which no longer exists — a record larger than a block now
  spans it.

## 4. What a consumer can rely on today

Every one of these is asserted against the harness's own sent-record, on a
store no other arm touched.

- **All eight binding patterns are exact.** Six probes each across a 12-triple
  corpus, all eight masks, zero missing and zero unexpected. The three durable
  orderings do serve the eight patterns as §3.1 claims — the numbering is the
  only thing wrong.
- **Names round-trip for every class w2 needs**: ASCII, Latin-1, CJK, astral
  plane, emoji, RTL, combining marks, digits, leading zeros, spaces, quotes,
  backslashes, `%s`, `../../etc`, and embedded NUL, tab, CR and newline. Only
  0x1f and the empty string fail.
- **An edge-derived supersession model falls out of published verbs alone.**
  One verb-bound query recovers the superseded set; a second recovers the
  declared set; the live set is the difference. No ids, no store access, no
  second model. §6.1's worked example is correct as written.
- **Results are stable across rebuild cycles** — five cycles, identical
  watermark and identical result set.
- **Lifecycle holds**: writes are invisible until `REBUILD` and visible after; a
  refused `ADMIT` writes nothing and moves no watermark; the connection survives
  a refusal; data survives a shim restart and a post-restart admit appends
  rather than overwrites; a killed server surfaces as a connection-level
  transient and a retry against a fresh server on the same store recovers
  everything exactly.
- **The store path is honoured and is not CWD-relative** — a shim started from
  an unrelated working directory against an absolute store root round-tripped
  exactly. §10 item 3 is settled in the contract's favour.
- **The envelope is comfortable**: 13 000 triples admit in 0.42 s, rebuild in
  0.45 s, enumerate in 0.32 s, exact. §3.2's "~13k triples sub-second" holds.
- **The `int_mod` defect is not observable at the wire on this build.** Records
  whose bodies span 67 distinct top-bit-set byte values, at every record length
  that fits, at every alignment, round-trip exactly — 29 hand-placed probes and
  325 at scale. **Caveat:** this only exercises records the reader can see at
  all, i.e. ≤32 bytes. Whatever the decoder does above the cliff is masked by
  W1, so the question is answered for the structure stream and cannot be asked
  of the payload stream from the wire.

## 5. What a consumer must do differently

1. **Keep every triple's `s US v US t` at or under 32 bytes**, or do not
   integrate yet. This is not a tuning parameter; above it, data is gone.
2. **Check `ADMIT`'s `admitted=N` against `REBUILD`'s watermark delta on every
   batch.** It is the only signal W1 produces. It will not catch W2.
3. **Never emit an empty name.** Substitute a sentinel client-side.
4. **Never emit 0x1f in a name.** Escape it client-side or reject it.
5. **Use mask 4, not mask 2, for in-edges.** Take the mask constants from
   `axwire.py`, not from §3.1.
6. **One connection, held by one thread, opened late and closed promptly.** Do
   not pool, do not multiplex, do not keep an idle reader open — any open
   connection is an exclusive lock on the whole server.
7. **Never send `ADMIT` with count 0.** Guard the empty batch client-side.
8. **Treat status 1 on `REBUILD` of an empty store as retryable** despite §7.6,
   until W14 is resolved.
9. **Do not claim durability** on the strength of a `DURABLE` ok.
10. **Do not count events.** Identical triples collapse on read (W13).
11. **Enforce single-writer yourself.** The wire does not (W6), and it
    especially does not across two server processes on one store.

## 6. §10 items this run settles

| # | Claim | Outcome |
|---|---|---|
| 1 | `rt_query(mask,s,v,t)` signature and mask encoding | mask encoding settled: **bitwise**, bit0 s / bit1 v / bit2 t |
| 2 | mask 0/1/2/3 map to `_ _ _`, `s _ _`, `_ _ t`, `s v _` | **WRONG** (W5) |
| 3 | `rt_rebuild` resolves store path CWD-relative | **No** — the supplied root is honoured from any CWD |
| 7 | `wp_wait_durable` is an opt-in watermark ack | ack yes, watermark no (W7) |
| 8 | Block ids unknowable before admission | moot at the wire — none are returned at all (W11) |
| 9 | Concurrent readers observe no torn state | **unreachable**, not answered — concurrent readers do not exist (W3) |
| 10 | A run-and-exit writer can serve a resident lease holder | moot — there is no lease (W6) |
| 12 | The shim can be built on the published surface | the shim exists; **a client cannot be** (W9) |

Item 12 is the document's own critical path. The answer this run gives is
narrow and specific: §2–§4 describe a data model a consumer can use, and §5
does not describe a transport a consumer can implement against. Every §5
obligation this harness could test — handshake, version, lease, concurrent
readers, error taxonomy, one frame encoding — is stated in the contract and
absent from the wire.

## 7. Gaps that could not be written as arms

Reported rather than worked around, per the governing intent:

- **Role separation (§5.4).** There is no handshake, so READ and WRITE roles do
  not exist and "roles are not mixable on one connection" cannot be exercised.
- **Protocol version refusal (§5.9).** Nothing to negotiate.
- **Lease release, explicit or by disconnect (§5.6), and T6 expiry.** No lease.
- **The fsync-per-committed-row metric (§4.4) and the durability claim (§4.3).**
  Both require `strace`; WIRE_ONLY forbids it. §4.3 itself says mechanism
  argument does not settle this, so the harness records only that the wire
  offers no evidence.
- **Wire-vs-in-process equivalence (§8).** Requires linking the tiers, which
  the boundary forbids. It is a real §8 obligation and remains untested.
- **Confinement properties 1 and 2 (§5.2).** "Binds no private symbol" is a
  link-surface property and "a repeated identical QUERY reaches the tiers both
  times" needs an in-process observer. Note that P2's five identical rebuild
  cycles and repeated identical queries returned consistent results and W3
  shows no per-connection state survives, but neither is proof of property 2.

## 8. Reintegration check

- **identity** — a black-box conformance harness that speaks only TCP, plus a
  client library w2 can adopt. Delivered: `axwire.py`, five phase suites, 50
  arms, `run-all.sh`, this report.
- **WIRE_ONLY** — sockets and the shim process only. No store read, no glob, no
  stat, no log, no link. Store roots are `mkdir`ed and `rm -rf`ed, never
  inspected.
- **THE_CLIENT_KNOWS_ONLY_WHAT_IT_SENT** — every assertion compares against
  `harness.Sent` / a literal corpus the arm constructed. No decoder, no oracle
  but the harness's own record.
- **NO_INTERNAL_IDS** — no arm reads, asserts on, or depends on a block id,
  RID or ordinal. `REBUILD`'s watermark is used only as a count of what the
  harness itself sent, and W11 records that no ids are returned at all.
- **FRAMING_WRITTEN_FROM_THE_SPEC** — §5.11 T5 supplied the frame length
  encoding; everything else was recovered by probing the socket. `shim/tests/`
  was not opened. The shared-assumption risk is answered structurally: the
  harness could not copy an assumption it never read, and each recovered fact is
  tagged `[WIRE]` in `axwire.py` and reported as a gap.
- **CHARACTERISE_NEVER_FIX** — nothing outside `wire-harness/` was modified.
  Two P3 arms were *narrowed* (name classes held under the 32-byte cliff) so
  they measure one dimension; the dimension removed became W1, the report's
  headline, not a workaround.
- **ONE_CONNECTION_AT_A_TIME_IS_A_FINDING_NOT_A_DESIGN** — the harness is
  single-connection by default; concurrency appears only in arms that exist to
  observe it. W3 and W6 report the contract's promises unmet without calling a
  serialised server broken.
- **priority** boundary-purity > oracle-independence > coverage — the arms that
  could not be written (§7 above) were dropped rather than reached below the
  wire for.
- **authority AI_PROPOSE_ONLY** — nothing here is a decision. Findings are
  reported; whether the contract narrows or the shim grows is the Lead Architect's call.
- **arm isolation** — each risky arm runs against its own fresh store root and
  its own shim process, so no arm passes on another's state.

## 9. Files

```
wire-harness/axwire.py     the client library — dependency-free, adoptable
wire-harness/shimctl.py    shim lifecycle; mkdir + rm -rf only, never reads
wire-harness/harness.py    arm bookkeeping and the Sent oracle
wire-harness/wp.py         raw frame probe used during discovery
wire-harness/p1..p5.py     the five phases
wire-harness/run-all.sh    the whole suite
wire-harness/findings/     per-phase and combined JSON
wire-harness/probes/       the protocol-discovery scripts, preserved as the
                           reproduction for every [WIRE] claim above
```
