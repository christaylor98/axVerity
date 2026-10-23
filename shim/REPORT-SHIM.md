# AXVERITY_SHIM_BUILD_V1 — the confined shim

**Round 2 status: 23/23 conformance, 12/12 refusals, no panics reachable
through any verb, and the wire now answers in names.** One verb, ADMIT, still
cannot be completed, for the same reason as round 1 and in the same place —
below M1, not in axVerity.

Nothing in `readtier/`, `lib/`, `src/`, `lib_coreir/` or `registries/` has been
touched in either round. `experiments/format/check-hashes.sh` reports
`WRITE_PATH_UNTOUCHED: all 22 files byte-identical to the P2 baseline`, and
`git status` is confined to `shim/`.

```
  shim/lib/*.m1        22 domain fns          shim/tests/run-shim-conformance.sh   23 passed
  shim/src/shim.m1     the entry outer        shim/tests/run-shim-breakage.sh      12 passed
  shim/registries/     its own registry       shim/tests/{axclient,oracle,conformance}.py
  shim/build-shim.sh   a third build          shim/bin/axshim
```

Whole conformance run: **2.9 s** from a clean build.

---

## 1. What was built

One process per store, single-threaded, one operation in flight, TCP, F1v
varint frames, four verbs and no LEASE. The shim links the read tier in-process
by co-feeding `registries/axverity-readtier.axreg` and `readtier/lib_coreir`
**read-only**; it compiles none of it.

**Confinement property 1 is checked, not asserted.** The conformance run greps
every `.m1` file under `shim/` for read-tier calls and requires the set to be a
subset of the published surface:

```
  PASS  the shim names 5 read-tier fns and every one is published:
        ['rt_nidx_name_of', 'rt_out_at', 'rt_out_count', 'rt_query', 'rt_rebuild']
```

**Connections are served concurrently; requests are answered serially.**
`sh_accept_step` is one step of a connection thread's accept loop: it accepts
one connection and serves it to completion on that thread. `sh_acceptor` runs
this loop on several threads sharing one listener, so connections are accepted
and served concurrently. Requests are still answered one at a time on the single
index thread (contract §5.4), so an ADMIT holds up other clients' replies. There
is nothing to acquire, release, or expire — no lease, which also disposes of
contract §10 item T6 (lease expiry on a wedged client).

---

## 2. Round 2, item 1 — the panics

Round 1 had two ways to take the process down. Both are now refusals, and
`tests/run-shim-breakage.sh` asserts the refusal rather than the crash.

A refusal differs from a crash in three checkable ways, and each is its own
arm: an out-of-contract status arrives **on the connection the client is already
holding**, the log shows **exactly one bind for the process's whole life** (no
respawn, so the port never moves), and the **same connection still serves the
next op**.

### R18 → REBUILD on a store nobody has written (`sh_rebuild`)

`rt_rebuild` folds `fs_list_dir(".axverity-store/structure")` unconditionally
and `fs_list_dir` panics on a missing directory (`io.rs:137`). The panic is not
the shim's to fix — `rt_rebuild.m1` is in the forbidden tree — but the **call**
is the shim's to decline, so it declines it:

```
  PASS  REBUILD on a fresh store is refused out-of-contract:
        NOSTORE .axverity-store/structure does not exist — nothing has been admitted...
  PASS  and the SAME connection still serves the next op
```

The shim does **not** create the directory. Materialising store layout is the
writer's job, and a transport that quietly conjured an empty store would turn
"nothing has been written here" into "this store is empty", which are different
facts. See R21 for what the guard costs.

### R19 → a QUERY body that is not UTF-8 (`sh_utf8_ok`)

`rt_query` takes `Text`, so a QUERY body has to become `Text`, and
`bytes_to_text` panics on invalid UTF-8 (`bytes_io.rs:217`). The bridge has no
validating variant, no lossy variant and no is-utf8 predicate, so the only way
to answer instead of crashing is to decide the question **before** converting.
Three M1 fns (`sh_byte_at`, `sh_u8_more`, `sh_u8_step`) implement the full
Unicode lead/continuation table.

The tempting shortcut — reject any byte ≥ 0x80 — would pass every arm below and
silently narrow the surface to ASCII names. So the last arm is the teeth:

```
  PASS  BARE_FF   refused out-of-contract before bytes_to_text
  PASS  OVERLONG  refused out-of-contract before bytes_to_text     (C0 80)
  PASS  SURROGATE refused out-of-contract before bytes_to_text     (ED A0 80)
  PASS  TRUNCATED refused out-of-contract before bytes_to_text     (C3, no continuation)
  PASS  and the SAME connection still answers a real query (4 rows for s0)
  PASS  a VALID multi-byte name is accepted, not refused — the guard validates
        UTF-8, it does not require ASCII
```

### R20 → no longer reachable

Both arms report `no panic — the guard answered instead of the runtime` and
`one bind for the process's life`. The respawn-onto-a-new-port mechanism is
still there in the bridge; nothing in the four verbs can now reach it.

---

## 3. Round 2, item 2 — R17, the name mapping

Round 1's wire answered in the tier's internal integer ids: `rt_query` was asked
in names and `rt_out_at` replied `('0','1','2')`, which no consumer can
interpret.

`sh_name3` now renders each row through **the tier's own published reverse
map**, `rt_nidx_name_of` — whose header states that the traversal API "carries
ids and renders names only at the boundary". The shim is that boundary.

**This does not violate §5.2 property 3.** "Add no semantics — no naming"
forbids the shim from *inventing* names or holding a namespace of its own. It
reads the tier's map and keeps nothing: three point lookups per row, every row,
every op. No cache, no persistence, no map constructed here.

That is not fastidiousness. The id assignment follows `fs_list_dir`'s
**lexicographic** block order (`io.rs:141`), so it moves as soon as a store
grows past ten blocks — a map cached across a REBUILD would render confidently
wrong names with a perfectly correct cardinality.

The conformance arm is built to catch exactly that, which is why an
identical-twice check is not enough on its own. It writes a corpus the store
**already holds**: no new triples, more blocks, and therefore a different fold
order and a different id assignment. A cached map would survive the cardinality
check and fail the names.

```
  PASS  two identical QUERYs in one connection agree (1558 rows)
  PASS  the extra lifetime added 5 blocks and no new triples (10900 unchanged)
  PASS  and it renumbered the tier's id space: 867 of 3007 ids now name a different thing
  PASS  the identical QUERY still answers the same 1558 NAMES across the
        renumbering — the map was re-read, not carried
```

The middle arm is what stops the last one being vacuous: if the renumbering had
not happened, a cached map could not have been detected.

With names on the wire, the eight binding patterns now compare **verbatim**
against the oracle. Round 1 needed an id→name assignment recovered on the test
side to make them compare at all; `oracle.idmap` survives only to prove the
renumbering above.

---

## 4. Reaches — reported, not resolved

### R15 — ADMIT cannot be completed: the bridge has no process-spawn primitive

Unchanged from round 1, and untouched this round by instruction. The locked
design's ADMIT is "write temp file, spawn `build/wp-slice <tmp> <count>`, wait
for exit, return exit code". **M1 cannot express the spawn.** The bridge
publishes 404 builtins; its entire process surface is `proc_args`, `proc_exit`
and `proc_sleep` (`runtime/process.rs`). The only `std::process::Command` in the
bridge tree is in `src/main.rs`, the compiler driver — not the runtime.

**This is not a reach into axVerity.** Nothing in the forbidden tree would need
to change. The gap is one layer down, in shared infrastructure, with an exact
precedent: the TCP primitives this shim runs on were added to the bridge for a
wire need, carrying the marker
`gap:axverity-postgres-wire-needs-socket-primitive`.

```axreg
fn proc_run
  in (Text, TextList)   // program, argv
  out Int               // exit code, after wait
  effect fullIo
end
```

Everything up to the spawn runs. The frame parses, the count varint decodes,
and the batch lands byte-identical:

```
  status 1: NOPRIM proc_run: staged 3 records, 33 bytes at .axverity-store/admit-0.tmp
  PASS  the batch is on disk byte-identical at admit-0.tmp (33 B)
```

### R16 — no chdir primitive

Unchanged. `bin/axshim` does the `cd` and `exec`s the binary, which then never
moves; the property the design asked for holds exactly. Confirms contract §10
item 3 and contradicts consumer obligation §7.2 ("Never assume CWD-relative
resolution"), which is not satisfiable against the tiers as they stand.

### R21 — the REBUILD guard has to know the store's directory layout — NEW

`sh_rebuild` names `.axverity-store/structure` in order to decline a call that
would panic. That layout **is** published — §2.1 fixes S2's two streams as part
of the durable artefact — so this is not a reach below §2–§4; it is §2. But it
is worth naming rather than letting it drift in: the shim now contains a second
copy of a path that lives in `rt_dblk_path.m1` and `rt_rebuild.m1`, and if the
store layout ever changes, this guard goes stale silently and the panic comes
back. The clean fix is one existence check inside `rt_rebuild.m1`, which is in
the forbidden tree.

### R22 — the UTF-8 validator is a bridge primitive written in M1 — NEW

`sh_byte_at` / `sh_u8_more` / `sh_u8_step` / `sh_utf8_ok` are ~90 lines of M1
re-implementing something Rust does in one call. It is correct and it is cheap
enough here — a QUERY body is a mask and three names, and the whole conformance
run is 2.9 s — but it reads **one byte per `mem_read_raw` call**, because M1 has
no byte-width load, so it would be the wrong shape for validating anything
large. What is actually missing is one of:

```axreg
fn bytes_is_utf8   in (Bytes)  out Bool     // predicate, then the existing bytes_to_text
fn bytes_to_text_checked  in (Bytes)  out Text  // "" on invalid, no panic
```

Not written — same rule as R15, and it is the same repo.

---

## 5. What this settles in the contract draft

| §10 item | before | after |
|---|---|---|
| 3 — `rt_rebuild` resolves CWD-relative | untested-prediction | **confirmed.** Hardcoded, no path parameter. §7.2 must change |
| 10 — can a run-and-exit writer serve a resident lease holder? | unknown | **moot.** There is no lease; the accept loop serialises. §5.6 can be deleted |
| 12 — can the shim be built on the published surface? | unknown | **yes for three verbs, and R17 is closed.** QUERY, REBUILD and DURABLE need no private hook — checked by grep, and the naming seam is served by the tier's own published reverse map. ADMIT still cannot be built, and the contract is not what is short |

Two things the draft says that this build still shows are wrong or unreachable:

- **§5.4 / §5.5, many concurrent readers.** Not delivered, and not deliverable
  by a single-threaded shim. Either the shim grows threads or the obligation
  narrows.
- **§5.2 property 3 vs the naming seam.** The draft's flat "no naming" reads as
  forbidding what round 2 does. The distinction that makes it work — the shim
  may *read* the tier's published reverse map per op, but may not *hold* a
  namespace, cache one, or invent names — is not in the text and should be.

## 6. Reproduce

```sh
scripts/build-readtier.sh && scripts/build.sh   # the tiers, unchanged
shim/build-shim.sh                              # the shim
shim/tests/run-shim-conformance.sh              # 23 passed, 0 failed
shim/tests/run-shim-breakage.sh                 # 12 passed, 0 failed
```
