# axVerity — consumer readiness, 2026-08-26

One page. The contract is `AXVERITY_CONSUMER_CONTRACT.v2.0.md` (**v2.0
proposed, awaiting ratification** — v1.0 was ratified 2026-08-20 and the wire
has since changed under it); this says what it means for someone about to build
on it.

**Status: ready for a loopback consumer, one server process, one connection at
a time.** Not ready for a pooled client, a remote deployment, or two writers.

---

## How to make one

```sh
scripts/axv-store init  ./stores/mystore          # optionally --block-capacity N --max-record N
scripts/axv-store serve ./stores/mystore --port 7717 --detach
scripts/axv-store status ./stores/mystore
scripts/axv-store stop  ./stores/mystore
```

A store is selected by a process's **working directory** — both tiers resolve
`.axverity-store/...` relative to cwd and neither accepts a path (§10 item 3).
So a store is a directory, one store per directory, one server per store, and
`init` takes the directory the store will live in.

`mkdir` alone already works, and `tests/run-store-util-test.sh` asserts that so
the tiers never grow a dependency on this script. What `init` adds is the part
that is irreversible if you skip it: **`--block-capacity` is stamped on the
first write and fixed for the life of the store**, because every RID decodes
against the stamp. A bare `mkdir` silently takes the compiled-in default, and
changing your mind afterwards is a migration. `init` refuses to re-capacity a
store that holds blocks, and says why.

A knob you do not pass is left unset, so the writer's own default applies —
`scripts/axv-store` carries no copy of a default value. Asserted by
`tests/run-store-util-test.sh` (9 arms, from a clean build).

---

## What you can rely on

Every line here is asserted by a suite that runs from a clean build.

- **All eight binding patterns are exact.** Six probes across a 12-triple
  corpus, all eight masks, zero missing and zero unexpected rows. The mask is
  **bitwise** — bit0 `s`, bit1 `v`, bit2 `t` (§3.1).
- **A record you admit is a record you can query.** Any size, any name,
  including an empty one. There is no size, emptiness or count condition under
  which a record is accepted and then silently unqueryable. This was false until
  2026-08-20 and is the single largest change in this revision.
- **Names round-trip byte-exact** for ASCII, Latin-1, CJK, astral plane, emoji,
  RTL, combining marks, digits, leading zeros, spaces, quotes, backslashes,
  `%s`, `../../etc`, and embedded NUL, tab, CR and newline.
- **Restart-safe identity.** Block ids are max+1 over the durable store, dense
  across both streams, never reissued — proved across three real `SIGKILL`
  crash-restart rounds with zero ids reissued and no truncated block.
- **A refused batch writes nothing** and moves no watermark. A killed writer
  leaves a structurally intact prefix, and retrying the whole batch converges.
- **Supersession falls out of published verbs alone** — one verb-bound query
  for the superseded set, one for the declared set, the live set is the
  difference. No ids, no store access, no second model (§6.1).
- **The wire is published byte for byte** in Appendix A. `wire-harness/axwire.py`
  is a dependency-free reference client — adopt it, do not reimplement it.
- **`ADMIT` returns the block-id range it produced**, `structure=F,C
  payload=F,C` — `(first, count)` per stream. Two things to get right: ids are
  dense **per stream**, so a handle without its stream name is meaningless
  (`structure/block-4` and `payload/block-4` differ); and a stream that produced
  nothing reports `-1,0`, never `0,0`, because `0` is a real block id. A handle
  names BLOCKS, so a batch of one record is named exactly and a batch of a
  thousand is named as a batch.

## What you cannot rely on

- **Concurrency of any kind.** One connection is served at a time. A second
  `connect()` succeeds, sends, and then waits — invisibly, indefinitely. **A
  pooled client hangs.** An idle open socket denies service to everyone.
- **A lease.** `LEASE` does not exist and v2.0 deleted §5.6's clause describing
  one. Two server processes over one store are two unguarded writers, and
  single-writer is now published as your obligation rather than the wire's.
- **Any durability statement over the wire.** `DURABLE` used to answer `ok` to
  every argument; v2.0 **deleted the verb** rather than leave it doing that.
  Opcode 4 answers `UNKNOWN opcode 4`. `ADMIT` returning status 0 means the
  writer ran and exited; it is not an fsync claim, and nothing on the wire is.
- **Multiset semantics.** `QUERY` answers a set. Re-admitting an identical
  triple advances the watermark and does not add a row — axVerity is not an
  event log.
- **A mask outside 0–7 being refused.** It is served as though the low three
  bits were set. An off-by-one in your mask constant produces silence.
- **Anything remote.** No auth, no TLS, no handshake, no version negotiation.
  **v1.0 is a loopback contract.**
- **Four claims the contract makes but nothing has tested**: §8 wire-vs-in-process
  equivalence, §5.2 confinement properties 1–2, and §4.3/§4.4 durability by
  `strace`. See §10.

## What a consumer must do differently

Six things, each of which will otherwise fail silently or hang.

1. **Names, not ids** — for the RAM tier's ids, which remain internal,
   per-process and unaddressable. The BLOCK id range `ADMIT` returns is a
   different thing and is yours to use: it is an ordering and reference handle,
   not a content address, and what you persist as identity is still your own
   naming. Do not build a mapping from RAM-tier ids and do not persist one.
2. **One supersession model, and it is edge-derived.** Recover it with two
   verb-bound queries and a set difference (§6.1). Do not carry a second model
   across, and do not expect axVerity to have an opinion about currency — §1
   says it has none.
3. **Connect, call, close.** Never hold a socket across think time. Set a
   client-side timeout on every read: a hang is what a busy server looks like,
   and it is indistinguishable from a dead one.
4. **`REBUILD` before you read.** Writes are invisible until you do (§4.6), and
   since v2.0 forgetting is a **refusal** (`status 1 STALE`) rather than a
   confident `0` rows. The gate starts closed at server start, closes on every
   `ADMIT`, and only `REBUILD` opens it. Note the consequence on a brand-new
   deployment: `REBUILD` answers `NOSTORE` and `QUERY` answers `STALE`, so
   **neither read verb answers `ok` until somebody admits.**
5. **No `0x1f` in a name.** It is the field separator in both directions and is
   never escaped. A name containing one is now refused loudly at `ADMIT`; it
   used to corrupt the row.
6. **Triples only.** Every record must be valid UTF-8 carrying exactly two
   separators. Opaque blobs do not go through `ADMIT`, and a batch containing
   one is refused entire — nothing in it is written.

One more, which is a trade rather than a rule: **choose your batch size
deliberately.** §4.4 wants batches large; §5.4 wants them small, because the
server answers nobody for the whole of an `ADMIT` — at 300,000 records that is
~3.6 s including a ~12.4% pre-spawn scan. Thousands, not hundreds of thousands,
if anything else needs to read while you write.

---

## Where the evidence is

| | |
|---|---|
| `wire-harness/REPORT-WIRE-CLIENT.md` | 51 black-box arms; **34 PASS, 17 FINDING** at v2.0 — the silent stale read and the false durability wait are both closed, and a new arm holds the gate across a server restart |
| `experiments/handle/` | §4.5's block-id return: why it stopped, the ruling that unblocked it, and the four suites that hold it — form, published-range-vs-`ls`, T1 supersedes round trip, T4 across a real SIGKILL |
| `experiments/silentloss/` | the three silent-loss defects, reproducible from a clean slate; S2's retired rationale; R21 |
| `experiments/format/REPORT-LAND.md` | the durable format, F1v/B1/S2 |
| `shim/REPORT-SHIM.md`, `shim/REPORT-PRIMS.md` | the transport and its two primitives |
| `tests/`, `shim/tests/`, `readtier/` | write path, crash, transport, read tier |
| `experiments/perf/` | the cold-rebuild gate — exact index counts, banded ns/indexed record, anchored to the P4 and FINDING numbers |

Run everything with one command: **`tests/seal.sh`** — clean slate, full
rebuild chain, every suite below in order plus two end-to-end arms, and a single
verdict line. It deliberately does not run `experiments/perf/perf.sh` and prints
no timing.

Or individually: `tests/run-slice-test.sh`, `tests/run-crash-test.sh`,
`tests/run-readtier-durable-test.sh`, `shim/tests/run-shim-*.sh`,
`wire-harness/run-all.sh`, `experiments/format/check-hashes.sh`,
`experiments/handle/no-global-id.sh`, `experiments/handle/handle-form.sh`,
`experiments/handle/ids-vs-ls.sh`, `experiments/handle/handle-roundtrip.sh`,
`experiments/perf/perf.sh`.
