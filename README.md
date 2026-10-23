# axVerity

An append-only triple store, written in M1, the surface language of
[Axis](https://github.com/christaylor98/axis-lang). It has a durable block write path, an in-RAM read
tier rebuilt from disk, and a small TCP server (the shim) that serves both.

axVerity stores **triples** and nothing else. Every record is a
subject/verb/target triple of names. What a name means, which triples are
worth keeping and how documents are broken into them is up to the
application. axVerity's job is to store records and get them back.

> **Status: experimental.** It is fit for a loopback consumer: one server
> process per store, on one machine. It is not ready for remote deployment or
> multiple writers. [`READINESS.md`](READINESS.md) lists what you can and
> cannot rely on. The wire contract is
> [`AXVERITY_CONSUMER_CONTRACT.v2.0.md`](AXVERITY_CONSUMER_CONTRACT.v2.0.md).

## How it works

**Write path.** Records arrive as a length-prefixed stream. They are framed
into fixed-capacity blocks (4 MiB by default), sealed with an 8-byte footer,
fsynced and renamed into place. Records are routed by size into two streams,
`structure/` and `payload/`, and block ids are dense within each stream. Ids
resume at max+1 over what is already on disk, so a restart never reissues one.
A record too large for a block is not refused. It is written across
consecutive blocks of its stream, and the reader reassembles it.

**Read tier.** It runs a cold rebuild over both streams, then keeps a name
index and three adjacency projections in RAM. A query binds any combination
of subject, verb and target (an 8-way mask) and returns rows. A query made
before a rebuild, or after an admission, is refused with `STALE`. It never
answers with stale rows.

**Shim.** A TCP listener on loopback with three ops: `ADMIT` writes a batch
and returns the block-id range it produced per stream; `REBUILD` reloads the
read tier from disk; `QUERY` reads. Every other opcode is refused. The wire is
specified byte for byte in the contract's Appendix A, and
[`wire-harness/axwire.py`](wire-harness/axwire.py) is a dependency-free
reference client.

**Storage.** All data for a store lives under one directory,
`.axverity-store/`, inside the store's working directory. One store per
directory, one server per store.

## Requirements

axVerity is built from source with the Axis toolchain. You need these three
repositories checked out:

| repository | provides |
|---|---|
| [axis-lang](https://github.com/christaylor98/axis-lang) | the `axis` compiler and the M1 pipeline YAMLs (`axis-surface-m1-config/`) |
| [axis-codegen-bridge-rs](https://github.com/christaylor98/axis-codegen-bridge-rs) | `axis-codegen-bridge`, which turns Core IR into Rust and links the binaries |
| [axRegistry](https://github.com/christaylor98/axRegistry) | the shared `.axreg` registries (`axis-types`, `axis-bridge`, `gen-working`, `m1-builtins`) |

You also need a Rust toolchain (`cargo`), `bash` and `python3`.

Build the compiler and the bridge with `cargo build --release`. Rebuild both
after updating either one. The bridge links from its own `target/release`, so
a stale build silently keeps the old behaviour.

## Build

The build scripts default to sibling checkouts under `~/dev/`. Point them
elsewhere with environment variables:

```sh
export AXIS_COMPILER=/path/to/axis-lang/target/release/axis
export BRIDGE_BINARY=/path/to/axis-codegen-bridge-rs/target/release/axis-codegen-bridge
export M1_DIR=/path/to/axis-lang/axis-surface-m1-config
export REG_TYPES=/path/to/axRegistry/axis-types.axreg      # likewise REG_BRIDGE, REG_GEN, REG_M1

make build                     # write path       -> build/wp-slice
bash scripts/build-readtier.sh # read tier        -> readtier/build/rt-driver
bash shim/build-shim.sh        # server           -> shim/build/axshim-bin
```

`make test-prereqs` does all three.

## Run a store

```sh
scripts/axv-store init  ./stores/mystore            # optional: --block-capacity N --max-record N
scripts/axv-store serve ./stores/mystore --port 7717 --detach
scripts/axv-store status ./stores/mystore
scripts/axv-store stop  ./stores/mystore
```

Set `--block-capacity` at `init`. It is stamped on the first write and fixed
for the life of the store, because every record id decodes against it.

## Test

```sh
make test-prereqs   # once: builds the binaries the wire and id suites need
make test
```

The suites include real `SIGKILL` crash-restart rounds (`tests/run-crash-test.sh`),
a round trip across restart (`tests/run-slice-test.sh`), the durable read tier
(`tests/run-readtier-durable-test.sh`) and the wire contract. Decoding in the
tests is done by an independent Rust harness (`experiments/format/harness`),
not by the code under test. Nothing counts as done until a repeatable test
asserts it.

## Layout

| path | what |
|---|---|
| `lib/`, `src/` | the write path: one M1 fn per file in `lib/`, thin executable entry points in `src/` |
| `readtier/` | the read tier: name index, projections, cold rebuild, query |
| `shim/` | the TCP server |
| `registries/` | this project's `.axreg` entries, one per M1 fn |
| `scripts/` | build scripts and `axv-store` |
| `tests/` | the test suites `make test` runs |
| `harness/`, `wire-harness/` | the read-model harness and the wire-level probes |
| `experiments/format/` | the independent format decoder (`fmth`) the tests check against |

`CLAUDE.md` holds the working notes: measured costs, design decisions and
traps already found. It is long, but it explains why the code looks the way
it does.

## Known issue

The bridge's native fast path (bridge commit `469079b`) miscompiles functions
that write raw memory before giving up on the fast path. `make test` catches
it in the shim and the read tier. The build scripts therefore link with the
bridge's `--no-fast` flag by default. Once the bridge is fixed, build with
`BRIDGE_FLAGS=` (empty) to turn the fast path back on, then run `make test`.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
