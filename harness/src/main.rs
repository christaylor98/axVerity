// AXVERITY_GRAPH_INDEX_ORDERING_BAKEOFF_V1 — measurement instrument.
//
// Isolated from the live write path by construction: this crate reads no
// M1 source, links nothing from lib/*.m1 or src/*.m1, and is never
// invoked by build/wp-slice. It measures RAM adjacency projections over
// synthetic triple datasets.
//
// Scope discipline: this program REPORTS numbers. It does not select an
// ordering count, a threshold, or a winner, and it does not prune the
// declared matrix — every configuration in the matrix is executed and
// emitted, at a fidelity (sample count) that is itself reported per row.
//
// Zero crate dependencies. The only foreign symbols are clock_gettime
// (wall + per-thread CPU, so every latency number can state whether the
// path blocked) and malloc_trim (return freed arenas between configs so
// RSS deltas stay meaningful).

use std::cell::UnsafeCell;
use std::fs::{self, OpenOptions};
use std::io::Write as IoWrite;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU32, AtomicU64, Ordering as Ord_};

// ---------------------------------------------------------------- clocks

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct Ts {
    sec: i64,
    nsec: i64,
}

extern "C" {
    fn clock_gettime(clk: i32, tp: *mut Ts) -> i32;
    fn malloc_trim(pad: usize) -> i32;
}

/// Reclamation epoch. Readers bump it odd on entering a query and even
/// on leaving; a writer may free a superseded version once the epoch has
/// advanced two ticks past retirement, i.e. the reader has passed through
/// a quiescent state. Without this the RSS measure would be dominated by
/// retained garbage rather than the live projection.
static EPOCH: AtomicU64 = AtomicU64::new(0);
/// Set while no reader thread is attached (warm-load, or reader finished):
/// retirement can then be freed immediately.
static NO_READER: AtomicBool = AtomicBool::new(true);
/// Calibrated clock overheads, published so every latency row can carry
/// the instrument cost embedded in it.
/// Readers currently attached. The reclamation proof is "the epoch
/// advanced two ticks past retirement, therefore the reader passed
/// through a quiescent state" — which holds for ONE reader only. With
/// two, each can supply the other's ticks while still holding a pointer,
/// and the writer frees underneath them. Every measured configuration in
/// every round uses a single reader thread; this counter makes that a
/// checked precondition instead of an unstated one. Supporting N readers
/// needs per-reader epoch slots, which is not implemented and is not
/// required by anything measured here.
static READERS: AtomicU32 = AtomicU32::new(0);

fn reader_attach() {
    let prev = READERS.fetch_add(1, Ord_::AcqRel);
    if prev != 0 {
        panic!(
            "reclamation precondition violated: {} concurrent readers, protocol supports 1",
            prev + 1
        );
    }
}

fn reader_detach() {
    READERS.fetch_sub(1, Ord_::AcqRel);
}

static WALL_OVERHEAD: AtomicU64 = AtomicU64::new(0);
static CPU_OVERHEAD: AtomicU64 = AtomicU64::new(0);

const CLOCK_MONOTONIC: i32 = 1;
const CLOCK_THREAD_CPUTIME_ID: i32 = 3;

#[inline(always)]
fn clk(id: i32) -> u64 {
    let mut t = Ts::default();
    unsafe { clock_gettime(id, &mut t) };
    (t.sec as u64) * 1_000_000_000 + (t.nsec as u64)
}

#[inline(always)]
fn wall_ns() -> u64 {
    clk(CLOCK_MONOTONIC)
}

#[inline(always)]
fn cpu_ns() -> u64 {
    clk(CLOCK_THREAD_CPUTIME_ID)
}

/// Cost of a clock pair, measured not assumed. CLOCK_MONOTONIC is a vDSO
/// read on most kernels; CLOCK_THREAD_CPUTIME_ID often is not, and on this
/// machine it is not — which is why the query bracket puts the CPU reads
/// OUTSIDE the wall reads, so per-query wall latency carries only the
/// cheap clock's overhead. Both figures are reported with every latency
/// row so a reader can net them out.
fn calibrate_wall_pair_ns() -> u64 {
    let n = 200_000u64;
    let t0 = wall_ns();
    let mut acc = 0u64;
    for _ in 0..n {
        acc = acc.wrapping_add(wall_ns()).wrapping_add(wall_ns());
    }
    let t1 = wall_ns();
    std::hint::black_box(acc);
    (t1 - t0) / n
}

fn calibrate_cpu_pair_ns() -> u64 {
    let n = 50_000u64;
    let t0 = wall_ns();
    let mut acc = 0u64;
    for _ in 0..n {
        acc = acc.wrapping_add(cpu_ns()).wrapping_add(cpu_ns());
    }
    let t1 = wall_ns();
    std::hint::black_box(acc);
    (t1 - t0) / n
}

// ------------------------------------------------------------------- rss

/// Resident set size in KiB, from /proc/self/status VmRSS — resident, not
/// allocated (the declared measure).
fn vmrss_kb() -> u64 {
    let s = fs::read_to_string("/proc/self/status").unwrap_or_default();
    for line in s.lines() {
        if let Some(rest) = line.strip_prefix("VmRSS:") {
            for tok in rest.split_whitespace() {
                if let Ok(v) = tok.parse::<u64>() {
                    return v;
                }
            }
        }
    }
    0
}

// ------------------------------------------------------------------- rng

/// splitmix64 — deterministic, seeded, no wall-clock input, so every run
/// is reproducible from the seed printed in the manifest.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ 0xDEAD_BEEF_CAFE_BABE)
    }
    #[inline(always)]
    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    #[inline(always)]
    fn below(&mut self, n: u32) -> u32 {
        ((self.next_u64() >> 32) as u32) % n.max(1)
    }
    #[inline(always)]
    fn unit(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
    /// Power-law-ish skew toward low ids: idx = floor(n * u^exp).
    /// Declared method: not a true Zipf, an explicit monotone skew.
    #[inline(always)]
    fn skewed(&mut self, n: u32, exp: f64) -> u32 {
        let u = self.unit();
        let x = u.powf(exp);
        let i = (n as f64 * x) as u32;
        i.min(n - 1)
    }
}

// -------------------------------------------------------------- triples

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct Triple {
    s: u32,
    v: u32,
    t: u32,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Pos {
    S,
    V,
    T,
}

/// The six orderings named in the intent's assumption block.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Ord6 {
    SVT,
    VST,
    TSV,
    STV,
    VTS,
    TVS,
}

/// Declared harness parameterization, NOT a design choice: ordering-count
/// N attaches the first N of this fixed list. The first three give one
/// ordering per bound position (S-, V-, T-keyed) so counts 1/2/3 cover
/// source/verb/target-bound progressively; 4..6 add the secondary
/// variants. Any other selection rule would produce a different curve;
/// this rule is reported with every row.
const ORDER_LIST: [Ord6; 6] = [
    Ord6::SVT,
    Ord6::VST,
    Ord6::TSV,
    Ord6::STV,
    Ord6::VTS,
    Ord6::TVS,
];

impl Ord6 {
    fn name(self) -> &'static str {
        match self {
            Ord6::SVT => "SVT",
            Ord6::VST => "VST",
            Ord6::TSV => "TSV",
            Ord6::STV => "STV",
            Ord6::VTS => "VTS",
            Ord6::TVS => "TVS",
        }
    }
    fn key_pos(self) -> Pos {
        match self {
            Ord6::SVT | Ord6::STV => Pos::S,
            Ord6::VST | Ord6::VTS => Pos::V,
            Ord6::TSV | Ord6::TVS => Pos::T,
        }
    }
    fn rest_pos(self) -> (Pos, Pos) {
        match self {
            Ord6::SVT => (Pos::V, Pos::T),
            Ord6::STV => (Pos::T, Pos::V),
            Ord6::VST => (Pos::S, Pos::T),
            Ord6::VTS => (Pos::T, Pos::S),
            Ord6::TSV => (Pos::S, Pos::V),
            Ord6::TVS => (Pos::V, Pos::S),
        }
    }
    #[inline(always)]
    fn key(self, tr: Triple) -> u32 {
        match self.key_pos() {
            Pos::S => tr.s,
            Pos::V => tr.v,
            Pos::T => tr.t,
        }
    }
    #[inline(always)]
    fn rest(self, tr: Triple) -> (u32, u32) {
        let (a, b) = self.rest_pos();
        let g = |p: Pos| match p {
            Pos::S => tr.s,
            Pos::V => tr.v,
            Pos::T => tr.t,
        };
        (g(a), g(b))
    }
    #[inline(always)]
    fn rebuild(self, key: u32, r: (u32, u32)) -> Triple {
        let mut tr = Triple { s: 0, v: 0, t: 0 };
        let (ra, rb) = self.rest_pos();
        let put = |p: Pos, val: u32, tr: &mut Triple| match p {
            Pos::S => tr.s = val,
            Pos::V => tr.v = val,
            Pos::T => tr.t = val,
        };
        put(self.key_pos(), key, &mut tr);
        put(ra, r.0, &mut tr);
        put(rb, r.1, &mut tr);
        tr
    }
}

// ------------------------------------------------------- version chains

/// How a key's accumulated deltas are folded back into sorted storage.
/// The main sweep only had `Full`, whose cost is linear in the WHOLE
/// posting list on every consolidation — so total consolidation work is
/// quadratic in the number of triples behind one key. With 100 distinct
/// verbs at large scale that is 10,000 entries per key, which is what
/// collapsed every ordering-count >= 2 ingest number. The other two
/// strategies exist to find out whether that collapse is a property of
/// version chains or a property of that one implementation choice.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Consol {
    /// Concatenate deltas with the entire base and re-sort it. O(n log n)
    /// in the whole posting list, per consolidation.
    Full,
    /// The base is already sorted: sort only the delta run (<= threshold
    /// items) and linear-merge. O(n) in the posting list per
    /// consolidation — a smaller constant, same asymptotic class.
    Merge,
    /// Logarithmic method: deltas become a new sorted run; runs of equal
    /// size class merge pairwise, binary-counter style. O(log n) amortized
    /// merge work per element, so total work is n log n rather than n^2 —
    /// but a read must now touch up to log(n/threshold) runs instead of
    /// one base.
    Segmented,
}

const CONSOLS: [Consol; 3] = [Consol::Full, Consol::Merge, Consol::Segmented];

impl Consol {
    fn name(self) -> &'static str {
        match self {
            Consol::Full => "full-rebuild",
            Consol::Merge => "merge",
            Consol::Segmented => "segmented",
        }
    }
    fn parse(s: &str) -> Consol {
        match s {
            "full-rebuild" | "full" => Consol::Full,
            "merge" => Consol::Merge,
            "segmented" | "seg" => Consol::Segmented,
            other => panic!("unknown consolidation strategy {other}"),
        }
    }
}

/// Linear merge of two sorted (u32,u32) runs into a fresh boxed slice.
fn merge_runs(a: &[(u32, u32)], b: &[(u32, u32)]) -> Box<[(u32, u32)]> {
    let mut out: Vec<(u32, u32)> = Vec::with_capacity(a.len() + b.len());
    let (mut i, mut j) = (0usize, 0usize);
    while i < a.len() && j < b.len() {
        if a[i] <= b[j] {
            out.push(a[i]);
            i += 1;
        } else {
            out.push(b[j]);
            j += 1;
        }
    }
    out.extend_from_slice(&a[i..]);
    out.extend_from_slice(&b[j..]);
    out.into_boxed_slice()
}

/// One node of a key's version chain. 32 bytes: a delta node carries one
/// (b,c) pair; a base node carries a leaked packed array. Nodes are never
/// mutated after publish — readers walk them lock-free via Acquire loads
/// while the single writer publishes new heads with Release stores.
#[repr(C)]
#[derive(Clone, Copy)]
struct Node {
    next: *const Node,
    base_ptr: *const (u32, u32),
    base_len: u32,
    /// Delta nodes: number of delta nodes from here down to the first run.
    /// Run nodes: always 0, so a delta stacked on a run gets depth 1.
    depth: u32,
    /// Delta nodes: the (b, c) payload. Run nodes: `d.0` carries the run's
    /// size-class level and `d.1` is unused — kept inside the existing 32
    /// bytes on purpose, so footprints stay comparable across strategies.
    d: (u32, u32),
}

unsafe impl Send for Node {}
unsafe impl Sync for Node {}

/// Where a projection's chain nodes come from.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Alloc {
    /// One `Box` per node on the shared process heap — what the main
    /// sweep used. Six projections' nodes end up interleaved, which is
    /// the suspected cause of the measured slowdown of orderings that
    /// were already present when others are added.
    Heap,
    /// A per-projection chunked arena with a free list threaded through
    /// the unused `next` field. Nodes of one ordering stay contiguous.
    /// Also drops the ~16-byte allocator header per node, so latency
    /// must be compared as an ord-1-to-ord-6 RATIO, not in absolute
    /// terms, to separate locality from header savings.
    Arena,
}

impl Alloc {
    fn name(self) -> &'static str {
        match self {
            Alloc::Heap => "heap",
            Alloc::Arena => "arena",
        }
    }
    fn parse(s: &str) -> Alloc {
        match s {
            "heap" => Alloc::Heap,
            "arena" => Alloc::Arena,
            other => panic!("unknown allocator {other}"),
        }
    }
}

/// 16k nodes = 512 KiB per chunk. Chunks are zero-initialized so no
/// uninitialized memory is ever observed; the cost is that at most one
/// partially-used chunk per projection is resident but unused, which is
/// reported rather than netted out.
const ARENA_CHUNK: usize = 16 * 1024;

struct Arena {
    chunks: Vec<Vec<Node>>,
    bump: usize,
    free_head: *mut Node,
}

impl Arena {
    fn new() -> Self {
        Arena {
            chunks: Vec::new(),
            bump: ARENA_CHUNK,
            free_head: std::ptr::null_mut(),
        }
    }
    #[inline]
    fn alloc(&mut self, n: Node) -> *mut Node {
        if !self.free_head.is_null() {
            let p = self.free_head;
            unsafe {
                self.free_head = (*p).next as *mut Node;
                *p = n;
            }
            return p;
        }
        if self.bump == ARENA_CHUNK {
            self.chunks.push(vec![
                Node {
                    next: std::ptr::null(),
                    base_ptr: std::ptr::null(),
                    base_len: 0,
                    depth: 0,
                    d: (0, 0),
                };
                ARENA_CHUNK
            ]);
            self.bump = 0;
        }
        let c = self.chunks.last_mut().unwrap();
        let p = unsafe { c.as_mut_ptr().add(self.bump) };
        self.bump += 1;
        unsafe { *p = n };
        p
    }
    #[inline]
    fn dealloc(&mut self, p: *mut Node) {
        unsafe { (*p).next = self.free_head };
        self.free_head = p;
    }
}

struct WriterState {
    /// (node, base_ptr, base_len, epoch_at_retirement) awaiting reclaim.
    /// Epochs are pushed non-decreasing, so the front is always oldest.
    retire: std::collections::VecDeque<(*mut Node, *mut (u32, u32), usize, u64)>,
    live_nodes: u64,
    retired_nodes: u64,
    retired_pairs: u64,
    stall_ns: u64,
    live_base_pairs: u64,
    run_count_max: u32,
    merge_pairs: u64,
    arena: Arena,
    /// Nodes superseded by the consolidation in progress. They may NOT be
    /// pushed to `retire` until the new chain head is published: until the
    /// Release store lands, a reader arriving through the slot still
    /// reaches them, and an epoch snapshot taken before the store can let
    /// the writer free them out from under that reader. Getting this
    /// ordering wrong segfaulted a full sweep 45 configurations in.
    pending: Vec<(*mut Node, *mut (u32, u32), usize)>,
    nodes_ever: u64,
    freed_nodes: u64,
    appends: u64,
    consolidations: u64,
    consol_ns: u64,
    consol_max_ns: u64,
    consol_pairs: u64,
    scratch: Vec<(u32, u32)>,
}

struct Projection {
    ord: Ord6,
    threshold: u32,
    consol: Consol,
    alloc: Alloc,
    slots: Vec<AtomicPtr<Node>>,
    wr: UnsafeCell<WriterState>,
    /// SINGLE_WRITER_PER_SHARD audit (T7): concurrent writer cardinality.
    active_writers: AtomicU32,
    writer_violations: AtomicU64,
}

unsafe impl Send for Projection {}
unsafe impl Sync for Projection {}

impl Projection {
    fn new(
        ord: Ord6,
        universe: u32,
        threshold: u32,
        consol: Consol,
        alloc: Alloc,
        expect: usize,
    ) -> Self {
        let mut slots = Vec::with_capacity(universe as usize);
        for _ in 0..universe {
            slots.push(AtomicPtr::new(std::ptr::null_mut()));
        }
        Projection {
            ord,
            threshold,
            consol,
            alloc,
            slots,
            wr: UnsafeCell::new(WriterState {
                retire: std::collections::VecDeque::with_capacity(1024),
                live_nodes: 0,
                retired_nodes: 0,
                retired_pairs: 0,
                stall_ns: 0,
                live_base_pairs: 0,
                run_count_max: 0,
                merge_pairs: 0,
                arena: Arena::new(),
                pending: Vec::with_capacity(64),
                nodes_ever: 0,
                freed_nodes: 0,
                appends: 0,
                consolidations: 0,
                consol_ns: 0,
                consol_max_ns: 0,
                consol_pairs: 0,
                scratch: Vec::with_capacity(1024),
            }),
            active_writers: AtomicU32::new(0),
            writer_violations: AtomicU64::new(0),
        }
    }

    /// Claim exclusive writer status for a phase. Asserts, at runtime,
    /// that no other writer is concurrently attached (T7 audit).
    fn claim_writer(&self) {
        let prev = self.active_writers.fetch_add(1, Ord_::AcqRel);
        if prev != 0 {
            self.writer_violations.fetch_add(1, Ord_::Relaxed);
        }
    }
    fn release_writer(&self) {
        self.active_writers.fetch_sub(1, Ord_::AcqRel);
    }

    #[inline]
    fn append(&self, tr: Triple) {
        let w = unsafe { &mut *self.wr.get() };
        // Cheap periodic re-audit of writer cardinality (every 1024
        // appends) — measured, not asserted in prose.
        if w.appends & 1023 == 0 && self.active_writers.load(Ord_::Relaxed) != 1 {
            self.writer_violations.fetch_add(1, Ord_::Relaxed);
        }
        w.appends += 1;

        let k = self.ord.key(tr) as usize;
        let pair = self.ord.rest(tr);
        let head = self.slots[k].load(Ord_::Acquire);
        let depth = if head.is_null() {
            1
        } else {
            unsafe { (*head).depth + 1 }
        };

        if depth > self.threshold {
            let t0 = wall_ns();
            w.pending.clear();

            // Split the old chain: delta nodes on top, run nodes beneath.
            w.scratch.clear();
            w.scratch.push(pair);
            let mut first_run = std::ptr::null_mut::<Node>();
            let mut q = head;
            while !q.is_null() {
                let n = unsafe { &*q };
                if !n.base_ptr.is_null() {
                    first_run = q;
                    break;
                }
                w.scratch.push(n.d);
                let nx = n.next as *mut Node;
                // Delta nodes carry no array. Staged, not retired: see
                // WriterState::pending.
                w.pending.push((q, std::ptr::null_mut(), 0));
                q = nx;
            }

            let node = match self.consol {
                Consol::Full => {
                    // Deltas plus the entire base, re-sorted.
                    if !first_run.is_null() {
                        let n = unsafe { &*first_run };
                        let sl = unsafe {
                            std::slice::from_raw_parts(n.base_ptr, n.base_len as usize)
                        };
                        w.scratch.extend_from_slice(sl);
                    }
                    w.scratch.sort_unstable();
                    self.stage_run(w, first_run);
                    self.new_run(w, w.scratch.as_slice().into(), 0, std::ptr::null())
                }
                Consol::Merge => {
                    // Sort only the delta run, then linear-merge.
                    w.scratch.sort_unstable();
                    let boxed = if first_run.is_null() {
                        let b: Box<[(u32, u32)]> = w.scratch.as_slice().into();
                        b
                    } else {
                        let n = unsafe { &*first_run };
                        let sl = unsafe {
                            std::slice::from_raw_parts(n.base_ptr, n.base_len as usize)
                        };
                        w.merge_pairs += sl.len() as u64;
                        merge_runs(w.scratch.as_slice(), sl)
                    };
                    self.stage_run(w, first_run);
                    self.new_run(w, boxed, 0, std::ptr::null())
                }
                Consol::Segmented => {
                    // Binary-counter merge: the delta run enters at level
                    // 0 and absorbs equal-level runs from the head; the
                    // untouched higher-level tail is relinked, not copied.
                    w.scratch.sort_unstable();
                    let mut cur: Box<[(u32, u32)]> = w.scratch.as_slice().into();
                    let mut level = 0u32;
                    let mut p = first_run;
                    while !p.is_null() {
                        let n = unsafe { &*p };
                        if n.d.0 != level {
                            break;
                        }
                        let sl = unsafe {
                            std::slice::from_raw_parts(n.base_ptr, n.base_len as usize)
                        };
                        w.merge_pairs += sl.len() as u64;
                        cur = merge_runs(&cur, sl);
                        level += 1;
                        let nx = n.next as *mut Node;
                        self.stage_run(w, p);
                        p = nx;
                    }
                    let mut runs = 1u32;
                    let mut t = p;
                    while !t.is_null() {
                        runs += 1;
                        t = unsafe { (*t).next } as *mut Node;
                    }
                    if runs > w.run_count_max {
                        w.run_count_max = runs;
                    }
                    self.new_run(w, cur, level, p as *const Node)
                }
            };
            self.slots[k].store(node, Ord_::Release);
            self.retire_pending(w);
            let dt = wall_ns() - t0;
            w.consolidations += 1;
            w.consol_ns += dt;
            if dt > w.consol_max_ns {
                w.consol_max_ns = dt;
            }
            w.consol_pairs += unsafe { (*node).base_len } as u64;
        } else {
            let node = self.alloc_node(
                w,
                Node {
                    next: head,
                    base_ptr: std::ptr::null(),
                    base_len: 0,
                    depth,
                    d: pair,
                },
            );
            w.nodes_ever += 1;
            w.live_nodes += 1;
            self.slots[k].store(node, Ord_::Release);
        }
        self.reclaim(w);
        self.backpressure(w);
    }

    #[inline]
    fn alloc_node(&self, w: &mut WriterState, n: Node) -> *mut Node {
        match self.alloc {
            Alloc::Heap => Box::into_raw(Box::new(n)),
            Alloc::Arena => w.arena.alloc(n),
        }
    }

    #[inline]
    fn free_node(&self, w: &mut WriterState, p: *mut Node) {
        match self.alloc {
            Alloc::Heap => unsafe { drop(Box::from_raw(p)) },
            Alloc::Arena => w.arena.dealloc(p),
        }
    }

    /// Publish one sorted run as a chain node. `level` is its size class
    /// (Segmented only; 0 for the single-base strategies).
    #[inline]
    fn new_run(
        &self,
        w: &mut WriterState,
        boxed: Box<[(u32, u32)]>,
        level: u32,
        next: *const Node,
    ) -> *mut Node {
        let len = boxed.len();
        let bp = Box::into_raw(boxed) as *mut (u32, u32);
        let node = self.alloc_node(
            w,
            Node {
                next,
                base_ptr: bp,
                base_len: len as u32,
                depth: 0,
                d: (level, 0),
            },
        );
        w.nodes_ever += 1;
        w.live_nodes += 1;
        w.live_base_pairs += len as u64;
        node
    }

    /// Stage one run node and its array for retirement after publish.
    #[inline]
    fn stage_run(&self, w: &mut WriterState, run: *mut Node) {
        if run.is_null() {
            return;
        }
        let n = unsafe { &*run };
        w.pending
            .push((run, n.base_ptr as *mut (u32, u32), n.base_len as usize));
    }

    /// Retire everything staged. Called only after the Release store that
    /// publishes the replacement chain, with an epoch read taken after
    /// that store, so no reader can still arrive at a staged node.
    #[inline]
    fn retire_pending(&self, w: &mut WriterState) {
        let e = EPOCH.load(Ord_::Acquire);
        for i in 0..w.pending.len() {
            let (np, bp, bl) = w.pending[i];
            if !bp.is_null() {
                w.live_base_pairs -= bl as u64;
                w.retired_pairs += bl as u64;
            }
            w.retire.push_back((np, bp, bl, e));
            w.retired_nodes += 1;
            w.live_nodes -= 1;
        }
        w.pending.clear();
    }

    /// Free retired versions that no reader can still be traversing.
    /// O(1) amortized: the queue is epoch-ordered, so it drains from the
    /// front while eligible, bounded per call.
    #[inline]
    fn reclaim(&self, w: &mut WriterState) {
        self.reclaim_bounded(w, 64);
    }

    #[inline]
    fn reclaim_bounded(&self, w: &mut WriterState, mut budget: u32) {
        let noreader = NO_READER.load(Ord_::Relaxed);
        let cur = EPOCH.load(Ord_::Acquire);
        while budget > 0 {
            let ok = match w.retire.front() {
                None => false,
                Some(&(_, _, _, e)) => noreader || cur >= e + 2,
            };
            if !ok {
                break;
            }
            let (np, bp, bl, _) = w.retire.pop_front().unwrap();
            unsafe {
                if !bp.is_null() {
                    drop(Box::from_raw(
                        std::slice::from_raw_parts_mut(bp, bl) as *mut [(u32, u32)]
                    ));
                }
            }
            self.free_node(w, np);
            w.freed_nodes += 1;
            w.retired_nodes -= 1;
            w.retired_pairs -= bl as u64;
            budget -= 1;
        }
    }

    /// Reclamation backpressure. Retired-but-unfreeable versions cannot
    /// grow without bound: a reader inside a multi-millisecond scan holds
    /// the epoch, and at a low threshold a writer retires a fresh base
    /// every few appends. Past the cap the writer stalls until the reader
    /// quiesces. That stall is real blocked time and is reported, not
    /// hidden — an unbounded queue OOM-killed the first fine round at
    /// large/ord=2.
    #[inline]
    fn backpressure(&self, w: &mut WriterState) {
        const MAX_RETIRED_NODES: u64 = 400_000;
        const MAX_RETIRED_PAIRS: u64 = 16_000_000;
        if w.retired_nodes <= MAX_RETIRED_NODES && w.retired_pairs <= MAX_RETIRED_PAIRS {
            return;
        }
        let t0 = wall_ns();
        while w.retired_nodes > MAX_RETIRED_NODES || w.retired_pairs > MAX_RETIRED_PAIRS {
            self.reclaim_bounded(w, 4096);
            if w.retired_nodes > MAX_RETIRED_NODES || w.retired_pairs > MAX_RETIRED_PAIRS {
                std::hint::spin_loop();
            }
        }
        w.stall_ns += wall_ns() - t0;
    }

    /// Drain the whole retirement queue (phase end, single writer, no
    /// concurrent reader).
    fn drain_retired(&self) {
        let w = unsafe { &mut *self.wr.get() };
        while let Some((np, bp, bl, _)) = w.retire.pop_front() {
            unsafe {
                if !bp.is_null() {
                    drop(Box::from_raw(
                        std::slice::from_raw_parts_mut(bp, bl) as *mut [(u32, u32)]
                    ));
                }
            }
            self.free_node(w, np);
            w.freed_nodes += 1;
            w.retired_nodes = w.retired_nodes.saturating_sub(1);
            w.retired_pairs = w.retired_pairs.saturating_sub(bl as u64);
        }
    }

    fn stall_ns(&self) -> u64 {
        unsafe { (*self.wr.get()).stall_ns }
    }

    /// Lock-free read of one key's full pair set. Returns the number of
    /// delta nodes walked (the chain-walk-depth sample).
    #[inline]
    fn collect(&self, key: u32, out: &mut Vec<(u32, u32)>) -> u32 {
        let mut p = self.slots[key as usize].load(Ord_::Acquire);
        let mut walked = 0u32;
        while !p.is_null() {
            let n = unsafe { &*p };
            if !n.base_ptr.is_null() {
                // A run. Segmented chains hold several in ascending size
                // class, so keep walking; Full and Merge have exactly one
                // followed by null, which this handles identically.
                let sl = unsafe { std::slice::from_raw_parts(n.base_ptr, n.base_len as usize) };
                out.extend_from_slice(sl);
                p = n.next as *mut Node;
                continue;
            }
            out.push(n.d);
            walked += 1;
            p = n.next as *mut Node;
        }
        walked
    }

    /// Two-position lookup: the key plus the first rest component.
    /// Delta nodes are unsorted, so they are scanned (bounded by the
    /// threshold); the base is sorted by (rest.0, rest.1), so the
    /// matching run is found by binary search. This is the only thing a
    /// secondary ordering buys over a primary one sharing its key
    /// position — and nothing in the main sweep exercised it.
    #[inline]
    fn collect_prefix(&self, key: u32, prefix: u32, out: &mut Vec<(u32, u32)>) -> u32 {
        let mut p = self.slots[key as usize].load(Ord_::Acquire);
        let mut walked = 0u32;
        while !p.is_null() {
            let n = unsafe { &*p };
            if !n.base_ptr.is_null() {
                // Binary-search this run; Segmented needs one search per
                // run, which is the cost that buys non-quadratic writes.
                let sl = unsafe { std::slice::from_raw_parts(n.base_ptr, n.base_len as usize) };
                let lo = sl.partition_point(|x| x.0 < prefix);
                let hi = sl.partition_point(|x| x.0 <= prefix);
                out.extend_from_slice(&sl[lo..hi]);
                p = n.next as *mut Node;
                continue;
            }
            if n.d.0 == prefix {
                out.push(n.d);
            }
            walked += 1;
            p = n.next as *mut Node;
        }
        walked
    }

    /// Number of sorted runs currently in one key's chain. Full and Merge
    /// hold at most one; Segmented holds up to log(n/threshold). This is
    /// the structural difference that content equivalence has to survive,
    /// so it is counted rather than assumed away.
    fn run_count(&self, key: u32) -> u32 {
        let mut p = self.slots[key as usize].load(Ord_::Acquire);
        let mut runs = 0u32;
        while !p.is_null() {
            let n = unsafe { &*p };
            if !n.base_ptr.is_null() {
                runs += 1;
            }
            p = n.next as *mut Node;
        }
        runs
    }

    /// Every run in one key's chain must be internally sorted. This is the
    /// precondition `collect_prefix` binary-searches on; Segmented needs it
    /// to hold per-run, which is strictly weaker than the globally-sorted
    /// base that Full and Merge maintain.
    fn runs_internally_sorted(&self, key: u32) -> bool {
        let mut p = self.slots[key as usize].load(Ord_::Acquire);
        while !p.is_null() {
            let n = unsafe { &*p };
            if !n.base_ptr.is_null() {
                let sl = unsafe { std::slice::from_raw_parts(n.base_ptr, n.base_len as usize) };
                if sl.windows(2).any(|w| w[0] > w[1]) {
                    return false;
                }
            }
            p = n.next as *mut Node;
        }
        true
    }

    fn nodes_allocated(&self) -> u64 {
        unsafe { (*self.wr.get()).live_nodes }
    }
    fn base_pairs(&self) -> u64 {
        unsafe { (*self.wr.get()).live_base_pairs }
    }
    fn nodes_ever(&self) -> u64 {
        unsafe { (*self.wr.get()).nodes_ever }
    }
    fn stats(&self) -> (u64, u64, u64, u64) {
        let w = unsafe { &*self.wr.get() };
        (
            w.consolidations,
            w.consol_ns,
            w.consol_max_ns,
            w.consol_pairs,
        )
    }
}

impl Drop for Projection {
    fn drop(&mut self) {
        self.drain_retired();
        for slot in self.slots.iter() {
            let mut p = slot.load(Ord_::Relaxed);
            while !p.is_null() {
                let n = unsafe { &*p };
                let nx = n.next as *mut Node;
                let bp = n.base_ptr as *mut (u32, u32);
                let bl = n.base_len as usize;
                unsafe {
                    if !bp.is_null() {
                        drop(Box::from_raw(
                            std::slice::from_raw_parts_mut(bp, bl) as *mut [(u32, u32)]
                        ));
                    }
                    if self.alloc == Alloc::Heap {
                        drop(Box::from_raw(p));
                    }
                }
                p = nx;
            }
            slot.store(std::ptr::null_mut(), Ord_::Relaxed);
        }
    }
}

// ------------------------------------------------------------ workloads

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Scale {
    Small,
    Medium,
    Large,
}

impl Scale {
    fn name(self) -> &'static str {
        match self {
            Scale::Small => "small",
            Scale::Medium => "medium",
            Scale::Large => "large",
        }
    }
    /// (triples, |S|, |V|, |T|)
    fn dims(self) -> (usize, u32, u32, u32) {
        match self {
            Scale::Small => (10_000, 1_000, 20, 1_000),
            Scale::Medium => (100_000, 10_000, 50, 10_000),
            Scale::Large => (1_000_000, 100_000, 100, 100_000),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Profile {
    LoggingAppend,
    QueryDominant,
}

impl Profile {
    fn name(self) -> &'static str {
        match self {
            Profile::LoggingAppend => "logging-append-dominant",
            Profile::QueryDominant => "query-dominant",
        }
    }
    /// writes : queries, as declared in the harness manifest.
    fn ratio(self) -> (u32, u32) {
        match self {
            Profile::LoggingAppend => (95, 5),
            Profile::QueryDominant => (20, 80),
        }
    }
}

/// Generates the triple stream for a (profile, scale). Deterministic in
/// the seed. Logging: sources drawn from an advancing recency window
/// (append-dominant temporal locality). Query-dominant: sources/targets drawn
/// with a monotone skew toward a hot set, verbs mildly skewed.
const PROFILES: [Profile; 2] = [Profile::LoggingAppend, Profile::QueryDominant];
const SCALES: [Scale; 3] = [Scale::Small, Scale::Medium, Scale::Large];
const THRESHOLDS: [u32; 4] = [4, 8, 16, u32::MAX];

fn generate(profile: Profile, scale: Scale, seed: u64) -> Vec<Triple> {
    let (n, su, vu, tu) = scale.dims();
    let mut rng = Rng::new(seed);
    let mut out = Vec::with_capacity(n);
    let window = (su / 20).max(16);
    for i in 0..n {
        let tr = match profile {
            Profile::LoggingAppend => {
                let base = (((i as u64) * ((su - window) as u64)) / (n as u64)) as u32;
                Triple {
                    s: base + rng.below(window),
                    v: rng.below(vu),
                    t: rng.below(tu),
                }
            }
            Profile::QueryDominant => Triple {
                s: rng.skewed(su, 3.0),
                v: rng.skewed(vu, 2.0),
                t: rng.skewed(tu, 3.0),
            },
        };
        out.push(tr);
    }
    out
}

// -------------------------------------------------------- query classes

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum QClass {
    SourceBound,
    VerbBound,
    TargetBound,
    TwoBound,
    VerbTargetBound,
    CyclicPattern,
}

const QCLASSES: [QClass; 6] = [
    QClass::SourceBound,
    QClass::VerbBound,
    QClass::TargetBound,
    QClass::TwoBound,
    QClass::VerbTargetBound,
    QClass::CyclicPattern,
];

impl QClass {
    fn name(self) -> &'static str {
        match self {
            QClass::SourceBound => "source-bound",
            QClass::VerbBound => "verb-bound",
            QClass::TargetBound => "target-bound",
            QClass::TwoBound => "two-bound",
            QClass::VerbTargetBound => "verb+target-bound",
            QClass::CyclicPattern => "cyclic-pattern",
        }
    }
}

struct Index {
    projs: Vec<Projection>,
}

struct QStat {
    walk: Vec<u32>,
    scanned: u64,
    matched: u64,
    /// Access path actually taken: 3 keyed on the single bound position,
    /// 2 prefix-2 (an ordering keys on one bound position AND orders by
    /// the other), 1 keyed on one position then filtered, 0 full scan.
    path: u8,
}

const PATH_NAME: [&str; 4] = ["scan", "keyed+filter", "prefix2", "keyed"];

impl Index {
    fn keyed_on(&self, p: Pos) -> Option<usize> {
        self.projs.iter().position(|x| x.ord.key_pos() == p)
    }

    /// All triples with `pos == id`. Uses a projection keyed on `pos` if
    /// one is attached; otherwise falls back to a full scan of
    /// projection 0 — which is exactly the cost the bakeoff exists to
    /// measure.
    fn lookup(&self, pos: Pos, id: u32, out: &mut Vec<Triple>, st: &mut QStat) {
        let mut pairs: Vec<(u32, u32)> = Vec::new();
        if let Some(i) = self.keyed_on(pos) {
            st.path = 3;
            let p = &self.projs[i];
            let d = p.collect(id, &mut pairs);
            st.walk.push(d);
            for &pr in pairs.iter() {
                out.push(p.ord.rebuild(id, pr));
            }
        } else {
            let p = &self.projs[0];
            st.path = 0;
            st.scanned += 1;
            for k in 0..p.slots.len() as u32 {
                pairs.clear();
                let d = p.collect(k, &mut pairs);
                st.walk.push(d);
                for &pr in pairs.iter() {
                    let tr = p.ord.rebuild(k, pr);
                    let hit = match pos {
                        Pos::S => tr.s == id,
                        Pos::V => tr.v == id,
                        Pos::T => tr.t == id,
                    };
                    if hit {
                        out.push(tr);
                    }
                }
            }
        }
    }

    /// Both positions bound. Prefers an ordering that keys on one bound
    /// position and orders by the other (prefix-2, binary search inside
    /// the base); falls back to keying on one position and filtering the
    /// other; falls back again to a full scan.
    fn lookup2(
        &self,
        pa: Pos,
        ida: u32,
        pb: Pos,
        idb: u32,
        out: &mut Vec<Triple>,
        st: &mut QStat,
    ) -> u8 {
        let hit = |t: &Triple, p: Pos, id: u32| match p {
            Pos::S => t.s == id,
            Pos::V => t.v == id,
            Pos::T => t.t == id,
        };
        for &(a, ia, b, ib) in [(pa, ida, pb, idb), (pb, idb, pa, ida)].iter() {
            if let Some(i) = self
                .projs
                .iter()
                .position(|p| p.ord.key_pos() == a && p.ord.rest_pos().0 == b)
            {
                let p = &self.projs[i];
                let mut pairs = Vec::new();
                let d = p.collect_prefix(ia, ib, &mut pairs);
                st.walk.push(d);
                for &pr in pairs.iter() {
                    out.push(p.ord.rebuild(ia, pr));
                }
                return 2;
            }
        }
        for &(a, ia, b, ib) in [(pa, ida, pb, idb), (pb, idb, pa, ida)].iter() {
            if self.keyed_on(a).is_some() {
                let mut tmp = Vec::new();
                self.lookup(a, ia, &mut tmp, st);
                out.extend(tmp.into_iter().filter(|t| hit(t, b, ib)));
                return 1;
            }
        }
        let mut tmp = Vec::new();
        self.lookup(pa, ida, &mut tmp, st);
        out.extend(tmp.into_iter().filter(|t| hit(t, pb, idb)));
        0
    }

    fn run(&self, q: QClass, rng: &mut Rng, dims: (usize, u32, u32, u32), st: &mut QStat) -> u64 {
        let (_, su, vu, tu) = dims;
        // Enter the read epoch (odd = in-query). The writer will not free
        // any version retired at or after this tick until we leave.
        EPOCH.fetch_add(1, Ord_::AcqRel);
        let mut buf: Vec<Triple> = Vec::new();
        match q {
            QClass::SourceBound => {
                self.lookup(Pos::S, rng.below(su), &mut buf, st);
            }
            QClass::VerbBound => {
                self.lookup(Pos::V, rng.below(vu), &mut buf, st);
            }
            QClass::TargetBound => {
                self.lookup(Pos::T, rng.below(tu), &mut buf, st);
            }
            QClass::TwoBound => {
                let s = rng.below(su);
                let v = rng.below(vu);
                let pth = self.lookup2(Pos::S, s, Pos::V, v, &mut buf, st);
                st.path = pth;
            }
            QClass::VerbTargetBound => {
                // The class the declared matrix could not reward: SVT
                // keys on S and orders by V, so two-bound(S,V) is already
                // prefix-served at ordering-count 1. Nothing at
                // ordering-count 3 orders V by T or T by V — only VTS and
                // TVS do, and those are the 5th and 6th orderings.
                let v = rng.below(vu);
                let t = rng.below(tu);
                let pth = self.lookup2(Pos::V, v, Pos::T, t, &mut buf, st);
                st.path = pth;
            }
            QClass::CyclicPattern => {
                // s -[v1]-> x -[v2]-> s : one hop out, bounded fan-out of
                // 8 (declared), then a return-edge probe per neighbour.
                let s = rng.below(su);
                let mut hop1 = Vec::new();
                self.lookup(Pos::S, s, &mut hop1, st);
                for tr in hop1.iter().take(8) {
                    let mut hop2 = Vec::new();
                    self.lookup(Pos::S, tr.t, &mut hop2, st);
                    for b in hop2.iter() {
                        if b.t == s {
                            buf.push(*b);
                        }
                    }
                }
            }
        }
        st.matched += buf.len() as u64;
        EPOCH.fetch_add(1, Ord_::AcqRel);
        buf.len() as u64
    }
}

// ------------------------------------------------------------ reporting

fn pct(sorted: &[u64], p: f64) -> u64 {
    if sorted.is_empty() {
        return 0;
    }
    let idx = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

const WALK_BUCKETS: [u32; 15] = [0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128];

fn walk_histogram(v: &[u32]) -> Vec<u64> {
    let mut h = vec![0u64; WALK_BUCKETS.len() + 1];
    for &d in v {
        let mut placed = false;
        for (i, &b) in WALK_BUCKETS.iter().enumerate() {
            if d <= b {
                h[i] += 1;
                placed = true;
                break;
            }
        }
        if !placed {
            h[WALK_BUCKETS.len()] += 1;
        }
    }
    h
}

struct Out {
    dir: PathBuf,
}

impl Out {
    fn new(dir: &Path) -> Self {
        fs::create_dir_all(dir).expect("create out dir");
        Out {
            dir: dir.to_path_buf(),
        }
    }
    fn header(&self, file: &str, hdr: &str) {
        let p = self.dir.join(file);
        if !p.exists() {
            let mut f = fs::File::create(&p).expect("create csv");
            writeln!(f, "{}", hdr).unwrap();
        }
    }
    fn row(&self, file: &str, row: &str) {
        let p = self.dir.join(file);
        let mut f = OpenOptions::new().append(true).open(&p).expect("append csv");
        writeln!(f, "{}", row).unwrap();
    }
}

// -------------------------------------------------- resident memory mode

/// Per-projection RSS must be measured in a FRESH process. Measured
/// in-process it reads near zero: glibc reuses the arenas freed by the
/// previous configuration, so VmRSS does not grow again and the delta
/// understates the true footprint by orders of magnitude. Each
/// (profile, scale, ordering, threshold) is therefore built once in a
/// dedicated child, whose VmRSS delta is taken across the build alone
/// (dataset generation happens before the baseline sample).
fn measure_mem_child(pi: usize, si: usize, oi: usize, thr: u32, ci: usize, ai: usize, seed: u64) {
    let profile = PROFILES[pi];
    let scale = SCALES[si];
    let ord = ORDER_LIST[oi];
    let consol = CONSOLS[ci];
    let alloc = if ai == 0 { Alloc::Heap } else { Alloc::Arena };
    let (_, su, vu, tu) = scale.dims();
    // Full stream. The main sweep measured this over half the stream,
    // which understated every footprint by roughly a factor of two and
    // made the figures non-comparable with the ingest and latency
    // numbers, which are taken against the whole stream.
    let triples = generate(profile, scale, seed);
    let warm = &triples[..];
    let universe = match ord.key_pos() {
        Pos::S => su,
        Pos::V => vu,
        Pos::T => tu,
    };
    NO_READER.store(true, Ord_::SeqCst);
    let before = vmrss_kb();
    let p = Projection::new(ord, universe, thr, consol, alloc, warm.len());
    p.claim_writer();
    for &tr in warm.iter() {
        p.append(tr);
    }
    p.release_writer();
    let after = vmrss_kb();
    println!(
        "{} {} {}",
        after.saturating_sub(before),
        p.nodes_allocated(),
        p.base_pairs()
    );
    std::process::exit(0);
}

type MemKey = (usize, usize, usize, u32, usize, usize);

fn memory_table(
    seed: u64,
    scales: &[Scale],
    max_ord: usize,
    strategies: &[Consol],
    allocs: &[Alloc],
) -> std::collections::HashMap<MemKey, (u64, u64, u64)> {
    let exe = std::env::current_exe().expect("current_exe");
    let mut map = std::collections::HashMap::new();
    let mut done = 0;
    let si_list: Vec<usize> = SCALES
        .iter()
        .enumerate()
        .filter(|(_, s)| scales.contains(s))
        .map(|(i, _)| i)
        .collect();
    let ci_list: Vec<usize> = CONSOLS
        .iter()
        .enumerate()
        .filter(|(_, c)| strategies.contains(c))
        .map(|(i, _)| i)
        .collect();
    let total = PROFILES.len()
        * si_list.len()
        * max_ord
        * (ci_list.len() * (THRESHOLDS.len() - 1) + 1)
        * allocs.len();
    for pi in 0..PROFILES.len() {
        for &si in si_list.iter() {
            for oi in 0..max_ord {
                for &thr in THRESHOLDS.iter() {
                    // At unbounded no consolidation ever runs, so all three
                    // strategies are the same code path and the same
                    // footprint. Measured once under Full and reused, with
                    // the equivalence asserted in the selftest rather than
                    // assumed.
                    let unb: Vec<usize> = vec![ci_list[0]];
                    let cis: &[usize] = if thr == u32::MAX { &unb } else { &ci_list };
                    for &ci in cis.iter() {
                    for ai in allocs.iter().map(|a| if *a == Alloc::Heap { 0 } else { 1 }) {
                    // Retry a child that dies (transient fork/OOM pressure
                    // from a concurrent build has been observed). A cell
                    // is never silently dropped: exhausting retries is a
                    // hard stop, not a zero.
                    let mut f: Vec<u64> = Vec::new();
                    let mut last = String::new();
                    for attempt in 0..3 {
                        let o = std::process::Command::new(&exe)
                            .arg("--measure-mem")
                            .arg(pi.to_string())
                            .arg(si.to_string())
                            .arg(oi.to_string())
                            .arg(thr.to_string())
                            .arg(ci.to_string())
                            .arg(ai.to_string())
                            .arg("--seed")
                            .arg(seed.to_string())
                            .output()
                            .expect("spawn mem child");
                        let txt = String::from_utf8_lossy(&o.stdout).to_string();
                        f = txt
                            .split_whitespace()
                            .filter_map(|x| x.parse().ok())
                            .collect();
                        if f.len() == 3 {
                            break;
                        }
                        last = format!(
                            "attempt {} status {:?} stdout {:?} stderr {:?}",
                            attempt,
                            o.status,
                            txt,
                            String::from_utf8_lossy(&o.stderr)
                        );
                    }
                    assert!(
                        f.len() == 3,
                        "mem child ({},{},{},{},{},{}) failed 3x: {}",
                        pi, si, oi, thr, ci, ai, last
                    );
                    map.insert((pi, si, oi, thr, ci, ai), (f[0], f[1], f[2]));
                    if thr == u32::MAX {
                        for &c2 in ci_list.iter() {
                            map.insert((pi, si, oi, thr, c2, ai), (f[0], f[1], f[2]));
                        }
                    }
                    done += 1;
                    }
                    }
                }
            }
        }
        println!("  resident-memory table: {}/{} subprocess builds", done, total);
    }
    map
}

// ------------------------------------------------------------ one cell

struct CellResult {
    ingest_wall_ns: u64,
    ingest_cpu_ns: u64,
    ingest_blocked_ns: u64,
    mixed_phase_wall_ns: u64,
    writes: u64,
    rss_total_kb: u64,
    per_proj: Vec<(Ord6, u64, u64, u64)>, // ord, rss_delta_kb, nodes, base_pairs
    consolidations: u64,
    consol_ns: u64,
    consol_max_ns: u64,
    consol_pairs: u64,
    writer_violations: u64,
}

#[allow(clippy::too_many_arguments)]
fn run_config(
    profile: Profile,
    scale: Scale,
    n_ord: usize,
    threshold: u32,
    triples: &[Triple],
    samples: usize,
    seed: u64,
    round: &str,
    out: &Out,
    memtab: &std::collections::HashMap<MemKey, (u64, u64, u64)>,
    pi: usize,
    si: usize,
    consol: Consol,
    ci: usize,
    alloc: Alloc,
    repn: usize,
) {
    let dims = scale.dims();
    let (_, su, vu, tu) = dims;
    let thr_name = if threshold == u32::MAX {
        "unbounded".to_string()
    } else {
        threshold.to_string()
    };

    let split = triples.len() / 2;
    let (warm, measured) = triples.split_at(split);

    // --- build projections; warm-load each sequentially on its own
    // dedicated thread, sampling VmRSS around it so the per-projection
    // RSS delta is a real resident measurement, not an allocation count.
    let mut projs: Vec<Projection> = Vec::new();
    for ord in ORDER_LIST.iter().take(n_ord) {
        let universe = match ord.key_pos() {
            Pos::S => su,
            Pos::V => vu,
            Pos::T => tu,
        };
        projs.push(Projection::new(*ord, universe, threshold, consol, alloc, triples.len()));
    }

    NO_READER.store(true, Ord_::SeqCst);
    let mut per_proj: Vec<(Ord6, u64, u64, u64)> = Vec::new();
    for (oi, p) in projs.iter().enumerate() {
        std::thread::scope(|sc| {
            sc.spawn(|| {
                p.claim_writer();
                for &tr in warm.iter() {
                    p.append(tr);
                }
                p.release_writer();
            });
        });
        // Resident footprint comes from the dedicated subprocess table,
        // not from an in-process VmRSS delta (see memory_table()).
        let ai = if alloc == Alloc::Heap { 0 } else { 1 };
        let m = memtab
            .get(&(pi, si, oi, threshold, ci, ai))
            .copied()
            .unwrap_or((0, 0, 0));
        per_proj.push((p.ord, m.0, m.1, m.2));
    }

    let idx = Index { projs };

    // --- measured mixed phase: one dedicated writer thread per
    // projection (single writer per shard, audited at runtime), plus one
    // reader thread issuing queries at the profile's duty cycle.
    let progress = AtomicU64::new(0);
    let writers_active = AtomicBool::new(true);
    let (_wr_ratio, _q_ratio) = profile.ratio();
    // Writes per query the reader targets: logging 95:5 -> 19 writes/query.
    let writes_per_query: u64 = match profile {
        Profile::LoggingAppend => 19,
        Profile::QueryDominant => 0, // query-dominant: no throttle
    };

    let mut lat: Vec<(QClass, u64, u64, bool)> = Vec::new(); // class, wall, cpu, during_ingest
    let mut walk_all: Vec<u32> = Vec::new();
    let mut scanned_by_class = [0u64; 6];
    let mut matched_by_class = [0u64; 6];
    let mut path_by_class = [0u8; 6];

    let phase_w0 = wall_ns();
    let writer_cpu = AtomicU64::new(0);
    // Ingest throughput must be measured over the WRITERS' own wall time,
    // never the enclosing scope: the reader thread outlives ingest in many
    // cells and would otherwise silently deflate every throughput number.
    let writer_wall_max = AtomicU64::new(0);
    let writer_blocked = AtomicU64::new(0);
    NO_READER.store(false, Ord_::SeqCst);

    std::thread::scope(|sc| {
        let writer_cpu = &writer_cpu;
        for p in idx.projs.iter() {
            let progress = &progress;
            let writer_wall_max = &writer_wall_max;
            let writer_blocked = &writer_blocked;
            sc.spawn(move || {
                p.claim_writer();
                let c0 = cpu_ns();
                let w0 = wall_ns();
                let mut i = 0u64;
                for &tr in measured.iter() {
                    p.append(tr);
                    i += 1;
                    if i & 255 == 0 {
                        progress.store(i, Ord_::Relaxed);
                    }
                }
                progress.store(i, Ord_::Relaxed);
                let dw = wall_ns() - w0;
                let dc = cpu_ns() - c0;
                writer_cpu.fetch_add(dc, Ord_::Relaxed);
                writer_wall_max.fetch_max(dw, Ord_::Relaxed);
                writer_blocked.fetch_add(dw.saturating_sub(dc), Ord_::Relaxed);
                p.release_writer();
            });
        }

        let reader = sc.spawn(|| {
            reader_attach();
            let mut rng = Rng::new(seed ^ 0xA5A5_1234);
            let mut lat: Vec<(QClass, u64, u64, bool)> = Vec::new();
            let mut walk_all: Vec<u32> = Vec::new();
            let mut scanned = [0u64; 6];
            let mut matched = [0u64; 6];
            let mut paths = [0u8; 6];
            let mut taken = [0usize; 6];
            let mut next_gate: u64 = writes_per_query;

            loop {
                let mut all_done = true;
                for (ci, q) in QCLASSES.iter().enumerate() {
                    if taken[ci] >= samples {
                        continue;
                    }
                    all_done = false;
                    if writes_per_query > 0 {
                        // Duty-cycle throttle: wait for the profile's
                        // write quota before issuing the next query, but
                        // never deadlock once writers have finished.
                        while progress.load(Ord_::Relaxed) < next_gate
                            && writers_active.load(Ord_::Relaxed)
                        {
                            std::hint::spin_loop();
                        }
                        next_gate = next_gate.saturating_add(writes_per_query);
                    }
                    let during = writers_active.load(Ord_::Relaxed);
                    let mut st = QStat {
                        walk: Vec::new(),
                        scanned: 0,
                        matched: 0,
                        path: 0,
                    };
                    // CPU brackets the wall bracket: the expensive clock
                    // is charged to the CPU sample, not to the reported
                    // wall latency.
                    let c0 = cpu_ns();
                    let w0 = wall_ns();
                    let r = idx.run(*q, &mut rng, dims, &mut st);
                    let w1 = wall_ns();
                    let c1 = cpu_ns();
                    std::hint::black_box(r);
                    lat.push((*q, w1 - w0, c1 - c0, during));
                    walk_all.extend_from_slice(&st.walk);
                    scanned[ci] += st.scanned;
                    matched[ci] += st.matched;
                    paths[ci] = st.path;
                    taken[ci] += 1;
                }
                if all_done {
                    break;
                }
            }
            NO_READER.store(true, Ord_::SeqCst);
            reader_detach();
            (lat, walk_all, scanned, matched, paths)
        });

        // Writers are joined implicitly at scope end; flip the flag once
        // the reader can observe ingest completion. The scope join order
        // means we set this after spawning, from a watcher.
        let watcher = sc.spawn(|| {
            let total = measured.len() as u64;
            while progress.load(Ord_::Relaxed) < total {
                std::hint::spin_loop();
            }
            writers_active.store(false, Ord_::Relaxed);
        });

        let (l, w, sc_, m, pa) = reader.join().expect("reader");
        watcher.join().expect("watcher");
        lat = l;
        walk_all = w;
        scanned_by_class = sc_;
        matched_by_class = m;
        path_by_class = pa;
    });

    let phase_w1 = wall_ns();
    NO_READER.store(true, Ord_::SeqCst);
    for p in idx.projs.iter() {
        p.drain_retired();
    }
    let mixed_phase_wall = phase_w1 - phase_w0;
    let ingest_wall = writer_wall_max.load(Ord_::Relaxed).max(1);
    let ingest_cpu = writer_cpu.load(Ord_::Relaxed);
    let ingest_blocked = writer_blocked.load(Ord_::Relaxed);
    let writes = measured.len() as u64 * n_ord as u64;

    let rss_total: u64 = per_proj.iter().map(|p| p.1).sum();
    let mut cons = (0u64, 0u64, 0u64, 0u64);
    let mut violations = 0u64;
    for p in idx.projs.iter() {
        let s = p.stats();
        cons.0 += s.0;
        cons.1 += s.1;
        cons.2 = cons.2.max(s.2);
        cons.3 += s.3;
        violations += p.writer_violations.load(Ord_::Relaxed);
    }

    let res = CellResult {
        ingest_wall_ns: ingest_wall,
        ingest_cpu_ns: ingest_cpu,
        ingest_blocked_ns: ingest_blocked,
        mixed_phase_wall_ns: mixed_phase_wall,
        writes,
        rss_total_kb: rss_total,
        per_proj,
        consolidations: cons.0,
        consol_ns: cons.1,
        consol_max_ns: cons.2,
        consol_pairs: cons.3,
        writer_violations: violations,
    };

    // --- steady-state phase: writers are joined, so every cell in the
    // matrix now queries the SAME complete dataset. Without this the
    // ordering-count curve is confounded: more orderings ingest slower,
    // so their mixed-phase queries see less data than ord=1's do.
    let mut slat: Vec<(QClass, u64, u64, bool)> = Vec::new();
    let mut swalk: Vec<u32> = Vec::new();
    let mut sscan = [0u64; 6];
    let mut smatch = [0u64; 6];
    let mut spath = [0u8; 6];
    {
        let mut rng = Rng::new(seed ^ 0xA5A5_1234);
        for _ in 0..samples {
            for (ci, q) in QCLASSES.iter().enumerate() {
                let mut stq = QStat {
                    walk: Vec::new(),
                    scanned: 0,
                    matched: 0,
                    path: 0,
                };
                let c0 = cpu_ns();
                let w0 = wall_ns();
                let r = idx.run(*q, &mut rng, dims, &mut stq);
                let w1 = wall_ns();
                let c1 = cpu_ns();
                std::hint::black_box(r);
                slat.push((*q, w1 - w0, c1 - c0, false));
                swalk.extend_from_slice(&stq.walk);
                sscan[ci] += stq.scanned;
                smatch[ci] += stq.matched;
                spath[ci] = stq.path;
            }
        }
    }

    // --------------------------------------------------------- emit
    let key = format!(
        "{},{},{},{},{},{},{},{}",
        round,
        consol.name(),
        alloc.name(),
        repn,
        profile.name(),
        scale.name(),
        n_ord,
        thr_name
    );

    for (phase, lset, scset, mset, pset) in [
        ("mixed", &lat, &scanned_by_class, &matched_by_class, &path_by_class),
        ("steady", &slat, &sscan, &smatch, &spath),
    ] {
    for (ci, q) in QCLASSES.iter().enumerate() {
        let mut ws: Vec<u64> = lset
            .iter()
            .filter(|x| x.0 == *q)
            .map(|x| x.1)
            .collect();
        let cs: Vec<u64> = lset.iter().filter(|x| x.0 == *q).map(|x| x.2).collect();
        let during = lset.iter().filter(|x| x.0 == *q && x.3).count();
        ws.sort_unstable();
        let n = ws.len() as u64;
        let wall_sum: u64 = ws.iter().sum();
        let cpu_sum: u64 = cs.iter().sum();
        let blocked = wall_sum.saturating_sub(cpu_sum);
        let blocked_pct = if wall_sum > 0 {
            (blocked as f64 * 100.0) / wall_sum as f64
        } else {
            0.0
        };
        let bound_pos = match q {
            QClass::SourceBound | QClass::TwoBound | QClass::CyclicPattern => Pos::S,
            QClass::VerbBound | QClass::VerbTargetBound => Pos::V,
            QClass::TargetBound => Pos::T,
        };
        let index_hit = idx.keyed_on(bound_pos).is_some();
        out.row(
            "cells-latency.csv",
            &format!(
                "{},{},{},{},{},{},{},{},{:.2},{},{},{},{},{},{},{}",
                key,
                phase,
                q.name(),
                n,
                pct(&ws, 0.50),
                pct(&ws, 0.99),
                ws.last().copied().unwrap_or(0),
                blocked,
                blocked_pct,
                index_hit,
                scset[ci],
                mset[ci],
                during,
                WALL_OVERHEAD.load(Ord_::Relaxed),
                CPU_OVERHEAD.load(Ord_::Relaxed),
                PATH_NAME[pset[ci] as usize]
            ),
        );
    }
    }

    for (phase, wv) in [("mixed", &walk_all), ("steady", &swalk)] {
    let hist = walk_histogram(wv);
    out.row(
        "walkdepth.csv",
        &format!(
            "{},{},{},{},{}",
            key,
            phase,
            wv.len(),
            wv.iter().copied().max().unwrap_or(0),
            hist.iter()
                .map(|x| x.to_string())
                .collect::<Vec<_>>()
                .join(",")
        ),
    );
    }

    let wps = (measured.len() as f64) * 1e9 / res.ingest_wall_ns as f64;
    let blocked_pct = (res.ingest_blocked_ns as f64 * 100.0)
        / (res.ingest_wall_ns as f64 * n_ord as f64).max(1.0);
    let nodes_ever: u64 = idx.projs.iter().map(|p| p.nodes_ever()).sum();
    let stall_ns: u64 = idx.projs.iter().map(|p| p.stall_ns()).sum();
    let run_max: u32 = idx
        .projs
        .iter()
        .map(|p| unsafe { (*p.wr.get()).run_count_max })
        .max()
        .unwrap_or(0);
    let merge_pairs: u64 = idx
        .projs
        .iter()
        .map(|p| unsafe { (*p.wr.get()).merge_pairs })
        .sum();
    let live_nodes: u64 = idx.projs.iter().map(|p| p.nodes_allocated()).sum();
    out.row(
        "cells-config.csv",
        &format!(
            "{},{},{},{},{},{:.1},{},{:.2},{},{},{},{},{},{},{:.1},{},{},{},{},{}",
            key,
            triples.len(),
            res.writes,
            res.ingest_wall_ns,
            res.ingest_cpu_ns,
            wps,
            res.ingest_blocked_ns,
            blocked_pct,
            res.mixed_phase_wall_ns,
            stall_ns,
            res.rss_total_kb,
            live_nodes,
            nodes_ever,
            res.consolidations,
            (res.consolidations as f64) * 1e9 / (res.ingest_wall_ns as f64),
            res.consol_ns,
            res.consol_max_ns,
            res.consol_pairs,
            run_max,
            merge_pairs
        ),
    );

    let ntri = triples.len() as f64;
    for (ord, rss, nodes, bp) in res.per_proj.iter() {
        let bytes_per_triple = (*rss as f64) * 1024.0 / ntri;
        out.row(
            "proj-memory.csv",
            &format!(
                "{},{},{},{},{},{},{},{:.2},{:.2}",
                key,
                ord.name(),
                rss,
                nodes,
                nodes * 32 / 1024,
                bp,
                triples.len(),
                bytes_per_triple,
                bytes_per_triple / 12.0
            ),
        );
    }

    out.row(
        "writer-audit.csv",
        &format!("{},{},{}", key, n_ord, res.writer_violations),
    );

    println!(
        "  [{}] ord={} thr={:>9} ingest={:.0} tr/s rss={} KiB cons={} violations={}",
        scale.name(),
        n_ord,
        thr_name,
        wps,
        res.rss_total_kb,
        res.consolidations,
        res.writer_violations
    );

    drop(idx);
    unsafe { malloc_trim(0) };
}

// -------------------------------------------------- harness perturbation

/// P1 gate: how much does the instrument disturb what it measures?
/// Compares raw append throughput with (a) no projections attached,
/// (b) projections attached but no timing instrumentation on the append
/// path, (c) the full measured configuration with a reader attached.
fn perturbation(out: &Out, seed: u64) {
    let triples = generate(Profile::LoggingAppend, Scale::Medium, seed);
    let (_, su, _, _) = Scale::Medium.dims();

    // (a) baseline: consume the stream, no projection attached.
    let t0 = wall_ns();
    let mut acc = 0u64;
    for tr in triples.iter() {
        acc = acc.wrapping_add(tr.s as u64 ^ tr.v as u64 ^ tr.t as u64);
    }
    let t1 = wall_ns();
    std::hint::black_box(acc);
    let base_ns = t1 - t0;

    // (b) one projection attached, writer alone, no reader, no per-query clocks.
    let p = Projection::new(Ord6::SVT, su, 8, Consol::Full, Alloc::Heap, triples.len());
    p.claim_writer();
    let t2 = wall_ns();
    for &tr in triples.iter() {
        p.append(tr);
    }
    let t3 = wall_ns();
    p.release_writer();
    let solo_ns = t3 - t2;

    // (c) same projection workload with a concurrent reader attached.
    let p2 = Projection::new(Ord6::SVT, su, 8, Consol::Full, Alloc::Heap, triples.len());
    let idx = Index { projs: vec![p2] };
    let stop = AtomicBool::new(false);
    NO_READER.store(false, Ord_::SeqCst);
    let t4 = wall_ns();
    std::thread::scope(|sc| {
        sc.spawn(|| {
            let p = &idx.projs[0];
            p.claim_writer();
            for &tr in triples.iter() {
                p.append(tr);
            }
            p.release_writer();
            stop.store(true, Ord_::Relaxed);
            NO_READER.store(true, Ord_::SeqCst);
        });
        sc.spawn(|| {
            let mut rng = Rng::new(seed ^ 7);
            let mut st = QStat {
                walk: Vec::new(),
                scanned: 0,
                matched: 0,
                path: 0,
            };
            while !stop.load(Ord_::Relaxed) {
                let c0 = cpu_ns();
                let w0 = wall_ns();
                let r = idx.run(QClass::SourceBound, &mut rng, Scale::Medium.dims(), &mut st);
                let w1 = wall_ns();
                let c1 = cpu_ns();
                std::hint::black_box((r, w1 - w0, c1 - c0));
                st.walk.clear();
            }
        });
    });
    let t5 = wall_ns();
    let withreader_ns = t5 - t4;

    let clkp = calibrate_wall_pair_ns() + calibrate_cpu_pair_ns();
    let n = triples.len() as f64;
    out.header(
        "perturbation.csv",
        "measurement,triples,wall_ns,ns_per_triple,vs_baseline_pct,method",
    );
    out.row(
        "perturbation.csv",
        &format!(
            "stream-only-no-projection,{},{},{:.1},0.0,CLOCK_MONOTONIC around full stream consume",
            triples.len(),
            base_ns,
            base_ns as f64 / n
        ),
    );
    out.row(
        "perturbation.csv",
        &format!(
            "one-projection-writer-alone,{},{},{:.1},{:.1},CLOCK_MONOTONIC around full ingest; single writer; no reader",
            triples.len(),
            solo_ns,
            solo_ns as f64 / n,
            (solo_ns as f64 - base_ns as f64) * 100.0 / base_ns as f64
        ),
    );
    out.row(
        "perturbation.csv",
        &format!(
            "one-projection-plus-reader,{},{},{:.1},{:.1},CLOCK_MONOTONIC around ingest with 1 concurrent instrumented reader thread",
            triples.len(),
            withreader_ns,
            withreader_ns as f64 / n,
            (withreader_ns as f64 - solo_ns as f64) * 100.0 / solo_ns as f64
        ),
    );
    out.row(
        "perturbation.csv",
        &format!(
            "clock-pair-overhead,{},{},{},0.0,mean of 200000 back-to-back wall_ns()+cpu_ns() pairs",
            200_000, clkp * 200_000, clkp
        ),
    );
    println!(
        "perturbation: stream-only {:.1} ns/triple, +projection {:.1} ns/triple ({:+.1}%), +reader {:.1} ns/triple ({:+.1}% vs writer-alone), clock pair {} ns",
        base_ns as f64 / n,
        solo_ns as f64 / n,
        (solo_ns as f64 - base_ns as f64) * 100.0 / base_ns as f64,
        withreader_ns as f64 / n,
        (withreader_ns as f64 - solo_ns as f64) * 100.0 / solo_ns as f64,
        clkp
    );
}


// -------------------------------------------------------------- selftest

/// Correctness gate: an index answer must equal brute force over the
/// source triple list. Runs every ordering-count and every threshold on a
/// small deterministic dataset; any mismatch aborts before a single
/// measured number is emitted.
fn selftest(seed: u64) {
    let triples = generate(Profile::QueryDominant, Scale::Small, seed);
    let dims = Scale::Small.dims();
    let (_, su, vu, tu) = dims;
    let mut checks = 0u64;
    let mut unbounded_shape: Option<(u64, u64)> = None;
    for &alloc in [Alloc::Heap, Alloc::Arena].iter() {
    for &consol in CONSOLS.iter() {
    for &n_ord in [1usize, 2, 3, 6].iter() {
        for &thr in [4u32, 8, 16, u32::MAX].iter() {
            let mut projs = Vec::new();
            for ord in ORDER_LIST.iter().take(n_ord) {
                let universe = match ord.key_pos() {
                    Pos::S => su,
                    Pos::V => vu,
                    Pos::T => tu,
                };
                projs.push(Projection::new(*ord, universe, thr, consol, alloc, triples.len()));
            }
            for p in projs.iter() {
                p.claim_writer();
                for &tr in triples.iter() {
                    p.append(tr);
                }
                p.release_writer();
            }
            let idx = Index { projs };
            let mut rng = Rng::new(seed ^ 0xBEEF);
            for _ in 0..40 {
                for &(pos, uni) in [(Pos::S, su), (Pos::V, vu), (Pos::T, tu)].iter() {
                    let id = rng.below(uni);
                    let mut got = Vec::new();
                    let mut st = QStat { walk: Vec::new(), scanned: 0, matched: 0, path: 0 };
                    idx.lookup(pos, id, &mut got, &mut st);
                    let mut want: Vec<Triple> = triples
                        .iter()
                        .copied()
                        .filter(|t| match pos {
                            Pos::S => t.s == id,
                            Pos::V => t.v == id,
                            Pos::T => t.t == id,
                        })
                        .collect();
                    let mut g = got.clone();
                    g.sort_by_key(|t| (t.s, t.v, t.t));
                    want.sort_by_key(|t| (t.s, t.v, t.t));
                    if g != want {
                        panic!(
                            "SELFTEST FAIL ord_count={} thr={} pos={:?} id={} got {} want {}",
                            n_ord, thr, pos, id, g.len(), want.len()
                        );
                    }
                    checks += 1;
                }
            }
            // Two-position lookups: answer must equal brute force, AND
            // the access path must be the one the ordering set can
            // actually support. (S,V) is prefix-served by SVT at every
            // ordering-count; (V,T) is prefix-served only once VTS/TVS
            // are attached, i.e. at ordering-count 6.
            for _ in 0..40 {
                for &(pa, ua, pb, ub) in [(Pos::S, su, Pos::V, vu), (Pos::V, vu, Pos::T, tu)].iter() {
                    let ia = rng.below(ua);
                    let ib = rng.below(ub);
                    let mut got = Vec::new();
                    let mut st = QStat { walk: Vec::new(), scanned: 0, matched: 0, path: 0 };
                    let path = idx.lookup2(pa, ia, pb, ib, &mut got, &mut st);
                    let hit = |t: &Triple, p: Pos, id: u32| match p {
                        Pos::S => t.s == id,
                        Pos::V => t.v == id,
                        Pos::T => t.t == id,
                    };
                    let mut want: Vec<Triple> = triples
                        .iter()
                        .copied()
                        .filter(|t| hit(t, pa, ia) && hit(t, pb, ib))
                        .collect();
                    let mut g = got.clone();
                    g.sort_by_key(|t| (t.s, t.v, t.t));
                    want.sort_by_key(|t| (t.s, t.v, t.t));
                    if g != want {
                        panic!(
                            "SELFTEST FAIL lookup2 ord_count={} thr={} {:?}/{:?} path={} got {} want {}",
                            n_ord, thr, pa, pb, path, g.len(), want.len()
                        );
                    }
                    let expect = if pa == Pos::S {
                        2
                    } else if n_ord == 6 {
                        2
                    } else if n_ord == 1 {
                        0
                    } else {
                        1
                    };
                    if path != expect {
                        panic!(
                            "SELFTEST FAIL lookup2 path ord_count={} {:?}/{:?} got {} expected {}",
                            n_ord, pa, pb, path, expect
                        );
                    }
                    checks += 1;
                }
            }

            let viol: u64 = idx.projs.iter().map(|p| p.writer_violations.load(Ord_::Relaxed)).sum();
            if viol != 0 {
                panic!("SELFTEST FAIL: {} concurrent-writer violations", viol);
            }
            // At unbounded no consolidation runs, so the three strategies
            // must produce byte-identical structure. The memory table
            // relies on this to measure unbounded once; assert it rather
            // than assume it.
            if thr == u32::MAX && n_ord == 6 {
                let shape: (u64, u64) = (
                    idx.projs.iter().map(|p| p.nodes_allocated()).sum(),
                    idx.projs.iter().map(|p| p.base_pairs()).sum(),
                );
                match unbounded_shape {
                    None => unbounded_shape = Some(shape),
                    Some(prev) => {
                        if prev != shape {
                            panic!(
                                "SELFTEST FAIL: unbounded structure differs across strategies: {:?} vs {:?} ({})",
                                prev, shape, consol.name()
                            );
                        }
                    }
                }
            }
            drop(idx);
        }
    }
    }
    }
    println!("selftest: PASS ({} index-vs-bruteforce comparisons (single-position and two-position lookups, with access-path assertions) over 16 (ordering-count x threshold) combinations, 10000-triple dataset)", checks);
}

// ----------------------------------------------------- W1: equivalence
//
// EQUIVALENCE_BEFORE_SPEED. Segmented's measured advantage over
// full-rebuild was taken at BOUNDED thresholds, where the three strategies
// do provably different amounts of work. The only equivalence previously
// asserted was at unbounded — the degenerate case where no consolidation
// runs at all and all three are literally the same code path. That
// assertion transfers nothing. A strategy that is fast because it retains
// fewer pairs, or answers from a smaller set, is not fast.
//
// WHAT IS COMPARED, and what "equivalent" is therefore allowed to mean:
//
//   Structural identity is FALSE at bounded thresholds and is not the
//   claim. Segmented deliberately holds up to log(n/threshold) sorted runs
//   where Full and Merge hold one. That difference is measured
//   (multi-run keys, run_count_max) rather than hidden, because it is the
//   thing being bought.
//
//   The claim is FULL QUERY-RESULT IDENTITY over the entire key space:
//
//     E1  For every key in the universe, the multiset of pairs returned by
//         collect() is identical across all three strategies, and equal to
//         brute force over the applied stream prefix. Exhaustive over
//         keys, not sampled.
//     E2  Total pairs retained equals the number of triples applied, for
//         each strategy. This is what forbids "fast because it does less":
//         no strategy may drop, merge away, or fail to retain a pair.
//     E3  For every key and every prefix value present under that key, the
//         prefix-2 result (the binary-searching read path, the one whose
//         soundness depends on run sortedness) is identical across
//         strategies and equal to brute force. Exhaustive over present
//         prefixes.
//     E4  Every run in every chain is internally sorted — the precondition
//         collect_prefix binary-searches on.
//     E5  Full and Merge additionally agree on ORDER, not just content.
//         Segmented is not required to, and where it differs the
//         difference is counted and reported.
//
// PRECONDITIONS — checked, not commented. Each panics:
//
//   P1  Quiesced. The comparison is of a stable snapshot: zero readers
//       attached and no writer in flight. Equivalence is NOT asserted
//       mid-mutation; the concurrent case is the stress gate's job, and
//       that gate checks monotonicity, not identity.
//   P2  Writer cardinality one per projection, audited at runtime.
//   P3  Identical input stream, identical order, applied to all three
//       strategies. Checked by construction here and by E2's count.
//   P4  Equivalence is asserted at the thresholds and scales actually
//       enumerated below and NOWHERE ELSE. The declared set is emitted
//       with the result so a later reader cannot borrow it upward.
//
// WHERE THIS DOES NOT HOLD, stated as the checked-scope record rather
// than a reassurance: nothing here licenses a claim about thresholds not
// in THRESHOLDS_CHECKED, about ordering positions not enumerated, about
// concurrent mutation, or about output ORDER for Segmented.

const EQUIV_THRESHOLDS: [u32; 4] = [4, 8, 16, u32::MAX];

struct EquivTally {
    keys: u64,
    pairs: u64,
    prefix2: u64,
    multirun_keys: u64,
    run_max: u32,
    order_mismatch_seg: u64,
}

fn equiv_precondition_quiesced(site: &str) {
    let r = READERS.load(Ord_::Acquire);
    assert!(
        r == 0,
        "W1 precondition P1 violated at {site}: {r} reader(s) attached. \
         Equivalence is asserted over a quiesced snapshot only."
    );
    assert!(
        NO_READER.load(Ord_::Acquire),
        "W1 precondition P1 violated at {site}: NO_READER is false. \
         Equivalence is asserted over a quiesced snapshot only."
    );
}

/// One (profile, scale, ordering, threshold) equivalence cell. Applies the
/// same stream, in the same order, to one projection per strategy, and
/// compares exhaustively at each checkpoint.
#[allow(clippy::too_many_arguments)]
fn equiv_cell(
    out: &Out,
    profile: Profile,
    scale: Scale,
    ord: Ord6,
    thr: u32,
    alloc: Alloc,
    triples: &[Triple],
    checkpoints: &[usize],
) -> EquivTally {
    let (_, su, vu, tu) = scale.dims();
    let universe = match ord.key_pos() {
        Pos::S => su,
        Pos::V => vu,
        Pos::T => tu,
    };
    let thr_name = if thr == u32::MAX {
        "unbounded".to_string()
    } else {
        thr.to_string()
    };

    let projs: Vec<Projection> = CONSOLS
        .iter()
        .map(|&c| Projection::new(ord, universe, thr, c, alloc, triples.len()))
        .collect();
    for p in projs.iter() {
        p.claim_writer();
    }

    let mut tally = EquivTally {
        keys: 0,
        pairs: 0,
        prefix2: 0,
        multirun_keys: 0,
        run_max: 0,
        order_mismatch_seg: 0,
    };

    let mut applied = 0usize;
    for &cp in checkpoints.iter() {
        // P3: same stream, same order, to all three.
        for p in projs.iter() {
            for &tr in triples[applied..cp].iter() {
                p.append(tr);
            }
        }
        applied = cp;
        equiv_precondition_quiesced("equiv_cell checkpoint");

        // Brute force over the applied prefix — the ground truth E1/E3
        // are measured against.
        let mut bf: Vec<Vec<(u32, u32)>> = vec![Vec::new(); universe as usize];
        for &tr in triples[..applied].iter() {
            bf[ord.key(tr) as usize].push(ord.rest(tr));
        }

        let mut got: Vec<Vec<(u32, u32)>> = vec![Vec::new(); CONSOLS.len()];
        let mut sorted: Vec<Vec<(u32, u32)>> = vec![Vec::new(); CONSOLS.len()];
        let mut total_pairs = vec![0u64; CONSOLS.len()];
        let mut pfx_got: Vec<Vec<(u32, u32)>> = vec![Vec::new(); CONSOLS.len()];
        // Per-checkpoint counts; the tally accumulates across checkpoints.
        let (mut ck_keys, mut ck_pairs, mut ck_pfx) = (0u64, 0u64, 0u64);
        let (mut ck_multirun, mut ck_ordmis) = (0u64, 0u64);
        let mut ck_runmax = 0u32;

        for k in 0..universe {
            for (i, p) in projs.iter().enumerate() {
                got[i].clear();
                p.collect(k, &mut got[i]);
                sorted[i].clone_from(&got[i]);
                sorted[i].sort_unstable();
                total_pairs[i] += got[i].len() as u64;
                // E4: every run internally sorted.
                assert!(
                    p.runs_internally_sorted(k),
                    "W1 E4 FAIL {}/{}/{}/thr={} key={} strategy={}: a run is not internally sorted; \
                     collect_prefix's binary search is unsound here",
                    profile.name(), scale.name(), ord.name(), thr_name, k, CONSOLS[i].name()
                );
            }
            let runs = projs[2].run_count(k);
            if runs > 1 {
                ck_multirun += 1;
            }
            if runs > ck_runmax {
                ck_runmax = runs;
            }

            let mut want = bf[k as usize].clone();
            want.sort_unstable();

            for i in 0..CONSOLS.len() {
                // E1: content identity vs brute force, exhaustive over keys.
                assert!(
                    sorted[i] == want,
                    "W1 E1 FAIL {}/{}/{}/thr={} key={} strategy={}: index {} pairs vs brute force {} \
                     — segmented's speed advantage cannot be reported at this threshold",
                    profile.name(), scale.name(), ord.name(), thr_name, k,
                    CONSOLS[i].name(), sorted[i].len(), want.len()
                );
                // E1: content identity across strategies.
                assert!(
                    sorted[i] == sorted[0],
                    "W1 E1 FAIL {}/{}/{}/thr={} key={}: {} differs from {}",
                    profile.name(), scale.name(), ord.name(), thr_name, k,
                    CONSOLS[i].name(), CONSOLS[0].name()
                );
            }
            // E5: Full and Merge agree on order too. Segmented need not.
            assert!(
                got[0] == got[1],
                "W1 E5 FAIL {}/{}/{}/thr={} key={}: full-rebuild and merge disagree on output ORDER",
                profile.name(), scale.name(), ord.name(), thr_name, k
            );
            if got[2] != got[0] {
                ck_ordmis += 1;
            }

            // E3: prefix-2, exhaustive over prefixes actually present.
            // `want` is sorted, so each prefix's expected answer is a
            // contiguous slice — taken by scan rather than by filtering
            // `want` once per prefix, which would be quadratic in the
            // posting list and is unrunnable at large scale.
            let mut start = 0usize;
            while start < want.len() {
                let pf = want[start].0;
                let mut end = start;
                while end < want.len() && want[end].0 == pf {
                    end += 1;
                }
                let wantp = &want[start..end];
                start = end;
                for (i, p) in projs.iter().enumerate() {
                    pfx_got[i].clear();
                    p.collect_prefix(k, pf, &mut pfx_got[i]);
                    pfx_got[i].sort_unstable();
                    assert!(
                        pfx_got[i].as_slice() == wantp,
                        "W1 E3 FAIL {}/{}/{}/thr={} key={} prefix={} strategy={}: prefix-2 returned {} \
                         pairs, brute force {}",
                        profile.name(), scale.name(), ord.name(), thr_name, k, pf,
                        CONSOLS[i].name(), pfx_got[i].len(), wantp.len()
                    );
                }
                for i in 1..CONSOLS.len() {
                    assert!(
                        pfx_got[i] == pfx_got[0],
                        "W1 E3 FAIL {}/{}/{}/thr={} key={} prefix={}: {} differs from {}",
                        profile.name(), scale.name(), ord.name(), thr_name, k, pf,
                        CONSOLS[i].name(), CONSOLS[0].name()
                    );
                }
                ck_pfx += 1;
            }
            ck_keys += 1;
            ck_pairs += got[0].len() as u64;
        }
        tally.keys += ck_keys;
        tally.pairs += ck_pairs;
        tally.prefix2 += ck_pfx;
        tally.multirun_keys += ck_multirun;
        tally.order_mismatch_seg += ck_ordmis;
        tally.run_max = tally.run_max.max(ck_runmax);

        // E2: nothing dropped. Every applied triple is still retrievable,
        // under every strategy. This is the assertion that forbids "fast
        // because it does less".
        for (i, tp) in total_pairs.iter().enumerate() {
            assert!(
                *tp == applied as u64,
                "W1 E2 FAIL {}/{}/{}/thr={} strategy={}: retains {} pairs for {} applied triples",
                profile.name(), scale.name(), ord.name(), thr_name, CONSOLS[i].name(), tp, applied
            );
        }
        // P2: writer cardinality audited at runtime.
        for (i, p) in projs.iter().enumerate() {
            let v = p.writer_violations.load(Ord_::Relaxed);
            assert!(
                v == 0,
                "W1 precondition P2 violated: {} concurrent-writer violations on {}",
                v, CONSOLS[i].name()
            );
        }

        let s: Vec<(u64, u64, u64, u64)> = projs.iter().map(|p| p.stats()).collect();
        let mp: Vec<u64> = projs
            .iter()
            .map(|p| unsafe { (*p.wr.get()).merge_pairs })
            .collect();
        out.row(
            "equivalence.csv",
            &format!(
                "{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}",
                profile.name(),
                scale.name(),
                ord.name(),
                alloc.name(),
                thr_name,
                (applied * 100) / triples.len(),
                applied,
                ck_keys,
                ck_pairs,
                ck_pfx,
                ck_multirun,
                ck_runmax,
                ck_ordmis,
                s[0].0, s[1].0, s[2].0,
                s[0].3, s[1].3, s[2].3,
                mp[2]
            ),
        );
    }

    for p in projs.iter() {
        p.release_writer();
    }
    tally
}

/// Query-level identity: the three strategies must answer every declared
/// query class identically, through whatever access path each ends up
/// taking. Covers the composite classes (two-bound, verb+target, cyclic)
/// that a per-key pair comparison does not reach.
/// Returns (comparisons, cyclic-pattern queries whose answer differed
/// across strategies under the harness's OWN order-dependent neighbour
/// truncation). The second figure is a property of the instrument, not of
/// the strategies: `Index::run`'s cyclic class takes the first 8
/// neighbours of an unordered result, and segmented returns that result in
/// a different order. It is counted here rather than removed, because
/// `Index::run` is the measured path and changing it would break
/// comparability with every prior round.
fn equiv_queries(profile: Profile, scale: Scale, n_ord: usize, thr: u32, seed: u64) -> (u64, u64) {
    let triples = generate(profile, scale, seed);
    let dims = scale.dims();
    let (_, su, vu, tu) = dims;
    let mut idxs: Vec<Index> = Vec::new();
    for &c in CONSOLS.iter() {
        let mut projs = Vec::new();
        for ord in ORDER_LIST.iter().take(n_ord) {
            let universe = match ord.key_pos() {
                Pos::S => su,
                Pos::V => vu,
                Pos::T => tu,
            };
            projs.push(Projection::new(
                *ord, universe, thr, c, Alloc::Heap, triples.len(),
            ));
        }
        for p in projs.iter() {
            p.claim_writer();
            for &tr in triples.iter() {
                p.append(tr);
            }
            p.release_writer();
        }
        idxs.push(Index { projs });
    }
    equiv_precondition_quiesced("equiv_queries");
    let mut checks = 0u64;
    let mut cyclic_order_divergence = 0u64;
    for (qi, q) in QCLASSES.iter().enumerate() {
        // Identical query stream per strategy: the rng is re-seeded per
        // (class, strategy) so all three see the same ids in the same order.
        let mut answers: Vec<Vec<Triple>> = Vec::new();
        let mut answers_raw: Vec<Vec<usize>> = Vec::new();
        for idx in idxs.iter() {
            let mut rng = Rng::new(seed ^ 0x51DE_0000 ^ (qi as u64));
            let mut acc: Vec<Triple> = Vec::new();
            let mut acc_raw: Vec<usize> = Vec::new();
            for _ in 0..200 {
                let mut st = QStat { walk: Vec::new(), scanned: 0, matched: 0, path: 0 };
                let mut buf: Vec<Triple> = Vec::new();
                match q {
                    QClass::SourceBound => idx.lookup(Pos::S, rng.below(su), &mut buf, &mut st),
                    QClass::VerbBound => idx.lookup(Pos::V, rng.below(vu), &mut buf, &mut st),
                    QClass::TargetBound => idx.lookup(Pos::T, rng.below(tu), &mut buf, &mut st),
                    QClass::TwoBound => {
                        let s = rng.below(su);
                        let v = rng.below(vu);
                        idx.lookup2(Pos::S, s, Pos::V, v, &mut buf, &mut st);
                    }
                    QClass::VerbTargetBound => {
                        let v = rng.below(vu);
                        let t = rng.below(tu);
                        idx.lookup2(Pos::V, v, Pos::T, t, &mut buf, &mut st);
                    }
                    QClass::CyclicPattern => {
                        let s = rng.below(su);
                        let mut hop1 = Vec::new();
                        idx.lookup(Pos::S, s, &mut hop1, &mut st);
                        // The harness's own selection: first 8 of an
                        // unordered result. Recorded, not asserted.
                        let mut raw = 0usize;
                        for tr in hop1.iter().take(8) {
                            let mut hop2 = Vec::new();
                            idx.lookup(Pos::S, tr.t, &mut hop2, &mut st);
                            raw += hop2.iter().filter(|b| b.t == s).count();
                        }
                        acc_raw.push(raw);
                        // Strategy-independent selection: the same 8
                        // neighbours regardless of chain order, so what is
                        // compared is the strategies and not the
                        // truncation.
                        hop1.sort_by_key(|t| (t.s, t.v, t.t));
                        for tr in hop1.iter().take(8) {
                            let mut hop2 = Vec::new();
                            idx.lookup(Pos::S, tr.t, &mut hop2, &mut st);
                            for b in hop2.iter() {
                                if b.t == s {
                                    buf.push(*b);
                                }
                            }
                        }
                    }
                }
                buf.sort_by_key(|t| (t.s, t.v, t.t));
                acc.extend_from_slice(&buf);
            }
            answers.push(acc);
            answers_raw.push(acc_raw);
        }
        for i in 1..answers.len() {
            assert!(
                answers[i] == answers[0],
                "W1 QUERY FAIL {}/{}/ord={}/thr={} class={}: {} answers differ from {}",
                profile.name(), scale.name(), n_ord,
                if thr == u32::MAX { "unbounded".into() } else { thr.to_string() },
                q.name(), CONSOLS[i].name(), CONSOLS[0].name()
            );
        }
        if *q == QClass::CyclicPattern {
            for i in 1..answers_raw.len() {
                cyclic_order_divergence += answers_raw[i]
                    .iter()
                    .zip(answers_raw[0].iter())
                    .filter(|(a, b)| a != b)
                    .count() as u64;
            }
        }
        checks += 200 * CONSOLS.len() as u64;
    }
    (checks, cyclic_order_divergence)
}

/// W1 driver. Runs the declared equivalence matrix and reports the scope
/// it actually covered — the scope IS part of the result.
fn equivalence(seed: u64, out: &Out, scope: &str) {
    out.header(
        "equivalence.csv",
        "profile,scale,ordering,alloc,threshold,checkpoint_pct,triples_applied,keys_compared,\
pairs_compared,prefix2_comparisons,segmented_multirun_keys,segmented_run_max,\
segmented_order_mismatch_keys,consolidations_full,consolidations_merge,consolidations_segmented,\
consol_pairs_full,consol_pairs_merge,consol_pairs_segmented,merge_pairs_segmented",
    );
    let mut keys = 0u64;
    let mut pairs = 0u64;
    let mut pfx = 0u64;
    let mut multirun = 0u64;
    let mut runmax = 0u32;
    let mut ordmis = 0u64;
    let mut cells = 0u64;

    // Declared scope. Small is exhaustive in every dimension; medium and
    // large trade ordering coverage for scale, because the pathological
    // case segmented was measured against is the verb-keyed projection at
    // large (100 verbs behind 1,000,000 triples).
    let plan: Vec<(Profile, Scale, Vec<Ord6>, Vec<Alloc>, Vec<f64>)> = match scope {
        "small" => vec![
            (Profile::QueryDominant, Scale::Small, ORDER_LIST.to_vec(), vec![Alloc::Heap, Alloc::Arena], vec![0.25, 0.5, 1.0]),
            (Profile::LoggingAppend, Scale::Small, ORDER_LIST.to_vec(), vec![Alloc::Heap, Alloc::Arena], vec![0.25, 0.5, 1.0]),
        ],
        _ => vec![
            (Profile::QueryDominant, Scale::Small, ORDER_LIST.to_vec(), vec![Alloc::Heap, Alloc::Arena], vec![0.25, 0.5, 1.0]),
            (Profile::LoggingAppend, Scale::Small, ORDER_LIST.to_vec(), vec![Alloc::Heap, Alloc::Arena], vec![0.25, 0.5, 1.0]),
            (Profile::QueryDominant, Scale::Medium, vec![Ord6::SVT, Ord6::VST, Ord6::TSV], vec![Alloc::Heap], vec![0.5, 1.0]),
            (Profile::LoggingAppend, Scale::Medium, vec![Ord6::SVT, Ord6::VST, Ord6::TSV], vec![Alloc::Heap], vec![0.5, 1.0]),
            (Profile::QueryDominant, Scale::Large, vec![Ord6::SVT, Ord6::VST], vec![Alloc::Heap], vec![1.0]),
            (Profile::LoggingAppend, Scale::Large, vec![Ord6::SVT, Ord6::VST], vec![Alloc::Heap], vec![1.0]),
        ],
    };

    for (profile, scale, ords, allocs, cps) in plan.iter() {
        let triples = generate(*profile, *scale, seed);
        let checkpoints: Vec<usize> = cps
            .iter()
            .map(|f| ((triples.len() as f64) * f) as usize)
            .collect();
        for &ord in ords.iter() {
            for &alloc in allocs.iter() {
                for &thr in EQUIV_THRESHOLDS.iter() {
                    let t = equiv_cell(out, *profile, *scale, ord, thr, alloc, &triples, &checkpoints);
                    keys += t.keys;
                    pairs += t.pairs;
                    pfx += t.prefix2;
                    multirun += t.multirun_keys;
                    runmax = runmax.max(t.run_max);
                    ordmis += t.order_mismatch_seg;
                    cells += 1;
                    println!(
                        "  equiv {}/{}/{}/{}/thr={:<9} keys={} pairs={} prefix2={} seg_multirun_keys={} seg_run_max={} seg_order_mismatch={}",
                        profile.name(), scale.name(), ord.name(), alloc.name(),
                        if thr == u32::MAX { "unbounded".to_string() } else { thr.to_string() },
                        t.keys, t.pairs, t.prefix2, t.multirun_keys, t.run_max, t.order_mismatch_seg
                    );
                    unsafe { malloc_trim(0) };
                }
            }
        }
    }

    // Composite query classes, across strategies, at every bounded
    // threshold and at unbounded as the control.
    let mut qchecks = 0u64;
    let mut cyc_div = 0u64;
    for &thr in EQUIV_THRESHOLDS.iter() {
        for (p, s, n) in [
            (Profile::QueryDominant, Scale::Small, 6usize),
            (Profile::LoggingAppend, Scale::Small, 6),
        ] {
            let (c, d) = equiv_queries(p, s, n, thr, seed);
            qchecks += c;
            cyc_div += d;
        }
        if scope != "small" {
            let (c, d) = equiv_queries(Profile::QueryDominant, Scale::Medium, 3, thr, seed);
            qchecks += c;
            cyc_div += d;
        }
    }

    println!(
        "\nW1 EQUIVALENCE: PASS\n  \
         scope={} cells={} thresholds=4/8/16 bounded{} (unbounded included as the control)\n  \
         E1 per-key content identity, exhaustive: {} keys compared across 3 strategies and vs brute force\n  \
         E2 retention: {} pairs, every strategy retains exactly the applied triple count at every checkpoint\n  \
         E3 prefix-2 identity, exhaustive over present prefixes: {} (key,prefix) comparisons x 3 strategies\n  \
         E4 run sortedness: checked on every chain visited\n  \
         E5 order identity: full-rebuild == merge asserted; segmented differs on {} keys (content-identical, order not asserted)\n  \
         query-class identity: {} answered-query comparisons over 6 classes, strategy-independent neighbour selection\n  \
         segmented structural divergence (the thing bought): {} keys held >1 run, max {} runs\n  \
         INSTRUMENT CAUTION, measured: {} cyclic-pattern queries returned a different answer across strategies\n  \
         under Index::run's OWN neighbour truncation (first 8 of an unordered result). Content is identical;\n  \
         the truncation is order-sensitive and segmented's order differs, so cross-strategy cyclic-pattern\n  \
         latency compares different neighbour sets. Affects the cyclic class only.\n  \
         NOT ESTABLISHED BY THIS: thresholds outside 4/8/16, concurrent mutation, output ORDER for segmented.",
        scope, cells, "",
        keys, pairs, pfx, ordmis, qchecks, multirun, runmax, cyc_div
    );
}

// ------------------------------------------- W2: working-set probe
//
// THE EFFECT. Adding orderings slows down the orderings already present.
// At large/query/threshold-4, source-bound steady-state p50 goes
// 300/270/350 ns at ordering-count 1 to 650/760/910 at ordering-count 3
// (round-consol, full-rebuild, heap, 3 reps). It reproduces in the STEADY
// phase, after every writer thread has been joined, so concurrent writer
// interference is not the cause. Allocator interleaving was falsified by
// the arena round.
//
// STANDING HYPOTHESIS H: the penalty is caused by cache/TLB pressure from
// the total resident working set.
//
// METHOD. Hardware counters are unavailable on this machine
// (/proc/sys/kernel/perf_event_paranoid = 3, no CAP_PERFMON; `perf stat -e
// cache-misses` is refused), so this takes the declared alternative:
// working-set size varied INDEPENDENTLY of ordering count. Every arm
// attaches the same number of projections and queries only SVT, which
// holds the identical full stream in every arm. What varies is how much
// data the OTHER projections hold — 0%, 25%, 50%, 100% of the stream.
// Structure is held constant; working set moves.
//
//   L1   = median SVT read latency, ordering-count 1        (control)
//   L6b0 = ordering-count 6, other projections EMPTY
//   L6b100 = ordering-count 6, other projections FULL       (= ordinary ord-6)
//
//   P = L6b100 - L1     the penalty, as previously reported
//   W = L6b100 - L6b0   the part attributable to working set alone
//
// FALSIFICATION CONDITION, STATED BEFORE THE MEASUREMENT:
//
//   H is FALSIFIED if W <= 0.5 * P — that is, if holding ordering count at
//   6 and removing only the other projections' DATA recovers less than
//   half the penalty. H additionally requires latency to be monotone
//   non-decreasing in ballast fraction; a non-monotone result falsifies it
//   even if W > 0.5 * P.
//
//   H SURVIVES only if W > 0.5 * P AND the ballast sweep is monotone.
//
//   SECONDARY, TLB-SPECIFIC: with transparent huge pages disabled for the
//   process (prctl PR_SET_THP_DISABLE), TLB coverage per page falls 512x,
//   so H predicts W GROWS. If W is unchanged with THP off, the
//   TLB-coverage mechanism specifically is unsupported — cache pressure is
//   not excluded by that arm alone.
//
//   VOID (not a result either way) if the effect does not reproduce
//   (P <= 0), or if the manipulation did not take: RSS must actually rise
//   with ballast fraction, and SVT's own structure must be identical in
//   every arm.
//
// If H is falsified, the standing instruction is to report the effect as
// reproduced-and-unexplained, NOT to substitute a third untested cause.

const PR_SET_THP_DISABLE: i32 = 41;
const PR_GET_THP_DISABLE: i32 = 42;

extern "C" {
    fn prctl(option: i32, a2: u64, a3: u64, a4: u64, a5: u64) -> i32;
}

/// One probe arm, in its own process so the allocator and RSS start clean.
#[allow(clippy::too_many_arguments)]
fn wsprobe_child(
    consol: Consol,
    scale: Scale,
    thr: u32,
    n_ord: usize,
    ballast_pct: u32,
    thp: bool,
    samples: usize,
    seed: u64,
) {
    if !thp {
        let rc = unsafe { prctl(PR_SET_THP_DISABLE, 1, 0, 0, 0) };
        assert!(rc == 0, "W2 precondition: PR_SET_THP_DISABLE failed rc={rc}");
        let got = unsafe { prctl(PR_GET_THP_DISABLE, 0, 0, 0, 0) };
        assert!(
            got == 1,
            "W2 precondition: THP disable did not take (PR_GET_THP_DISABLE={got}); \
             the no-THP arm would silently be a duplicate of the THP arm"
        );
    }
    let triples = generate(Profile::QueryDominant, scale, seed);
    let (_, su, vu, tu) = scale.dims();
    let ballast_n = (triples.len() as u64 * ballast_pct as u64 / 100) as usize;

    NO_READER.store(true, Ord_::SeqCst);
    let rss0 = vmrss_kb();
    let mut projs: Vec<Projection> = Vec::new();
    for ord in ORDER_LIST.iter().take(n_ord) {
        let universe = match ord.key_pos() {
            Pos::S => su,
            Pos::V => vu,
            Pos::T => tu,
        };
        projs.push(Projection::new(*ord, universe, thr, consol, Alloc::Heap, triples.len()));
    }
    for (i, p) in projs.iter().enumerate() {
        // Projection 0 (SVT) is the queried one and always holds the full
        // stream. Everything else is ballast.
        let n = if i == 0 { triples.len() } else { ballast_n };
        p.claim_writer();
        for &tr in triples[..n].iter() {
            p.append(tr);
        }
        p.release_writer();
    }
    let rss1 = vmrss_kb();
    let svt_nodes = projs[0].nodes_allocated();
    let svt_pairs = projs[0].base_pairs();

    let idx = Index { projs };
    // Warm pass, discarded: measures steady state, not first-touch page
    // faults. Same id sequence as the measured pass.
    for pass in 0..2 {
        let mut rng = Rng::new(seed ^ 0x2C4E_9001);
        let mut src: Vec<u64> = Vec::with_capacity(samples);
        let mut two: Vec<u64> = Vec::with_capacity(samples);
        for _ in 0..samples {
            let s = rng.below(su);
            let v = rng.below(vu);
            let mut st = QStat { walk: Vec::new(), scanned: 0, matched: 0, path: 0 };
            let mut buf: Vec<Triple> = Vec::new();
            let w0 = wall_ns();
            idx.lookup(Pos::S, s, &mut buf, &mut st);
            let w1 = wall_ns();
            std::hint::black_box(buf.len());
            assert!(st.path == 3, "W2 precondition: source-bound took path {} not keyed", st.path);
            src.push(w1 - w0);

            let mut buf2: Vec<Triple> = Vec::new();
            let mut st2 = QStat { walk: Vec::new(), scanned: 0, matched: 0, path: 0 };
            let w2 = wall_ns();
            let pth = idx.lookup2(Pos::S, s, Pos::V, v, &mut buf2, &mut st2);
            let w3 = wall_ns();
            std::hint::black_box(buf2.len());
            assert!(pth == 2, "W2 precondition: two-bound took path {pth} not prefix2");
            two.push(w3 - w2);
        }
        if pass == 1 {
            src.sort_unstable();
            two.sort_unstable();
            println!(
                "{} {} {} {} {} {} {} {}",
                rss1.saturating_sub(rss0),
                svt_nodes,
                svt_pairs,
                pct(&src, 0.50),
                pct(&src, 0.99),
                pct(&two, 0.50),
                pct(&two, 0.99),
                samples
            );
        }
    }
    std::process::exit(0);
}

fn median(v: &mut Vec<u64>) -> u64 {
    v.sort_unstable();
    pct(v, 0.50)
}

/// W2 driver. Runs the declared arms, checks the preconditions that make
/// the arms comparable, and evaluates the pre-stated falsification
/// condition mechanically rather than by narrative.
fn wsprobe(seed: u64, out: &Out, reps: usize, samples: usize, focus: bool) {
    out.header(
        "wsprobe.csv",
        "strategy,scale,threshold,thp,arm,orderings,ballast_pct,rep,rss_delta_kb,svt_nodes,\
svt_base_pairs,p50_source_ns,p99_source_ns,p50_twobound_ns,p99_twobound_ns,samples",
    );
    let exe = std::env::current_exe().expect("current_exe");
    let arms: [(&str, usize, u32); 7] = [
        ("ord1", 1, 0),
        ("ord3-ballast-000", 3, 0),
        ("ord3-ballast-100", 3, 100),
        ("ord6-ballast-000", 6, 0),
        ("ord6-ballast-025", 6, 25),
        ("ord6-ballast-050", 6, 50),
        ("ord6-ballast-100", 6, 100),
    ];
    // (scale, threshold, thp). The no-THP block runs at one configuration
    // only: it is the secondary TLB-specific prediction, not the main test.
    let all_blocks: [(Scale, u32, bool); 5] = [
        (Scale::Medium, 4, true),
        (Scale::Medium, 16, true),
        (Scale::Large, 4, true),
        (Scale::Large, 16, true),
        (Scale::Large, 4, false),
    ];
    // The confirmatory pass re-runs only the configuration where the first
    // pass found signal, at a higher repetition count, so the per-run mode
    // rate can be counted rather than medianed. Announced in the run log so
    // a focused pass can never be mistaken for the full block set.
    let focus_blocks: [(Scale, u32, bool); 2] = [(Scale::Large, 4, true), (Scale::Large, 4, false)];
    let blocks: &[(Scale, u32, bool)] = if focus {
        println!("W2 FOCUSED PASS: large/threshold-4 only (THP on and off). The medium and large/thr-16 blocks were run in the first pass and are NOT re-run here.");
        &focus_blocks
    } else {
        &all_blocks
    };
    let consol = Consol::Merge;

    for &(scale, thr, thp) in blocks.iter() {
        let mut med_src: std::collections::HashMap<&str, Vec<u64>> =
            std::collections::HashMap::new();
        let mut med_two: std::collections::HashMap<&str, Vec<u64>> =
            std::collections::HashMap::new();
        let mut med_rss: std::collections::HashMap<&str, Vec<u64>> =
            std::collections::HashMap::new();
        let mut svt_shape: Option<(u64, u64)> = None;

        for rep in 0..reps {
            for &(arm, n_ord, ballast) in arms.iter() {
                let o = std::process::Command::new(&exe)
                    .arg("--wsprobe-child")
                    .arg(consol.name())
                    .arg(scale.name())
                    .arg(thr.to_string())
                    .arg(n_ord.to_string())
                    .arg(ballast.to_string())
                    .arg(if thp { "1" } else { "0" })
                    .arg(samples.to_string())
                    .arg("--seed")
                    .arg(seed.to_string())
                    .output()
                    .expect("spawn wsprobe child");
                let txt = String::from_utf8_lossy(&o.stdout).to_string();
                let f: Vec<u64> = txt.split_whitespace().filter_map(|x| x.parse().ok()).collect();
                assert!(
                    f.len() == 8,
                    "W2 arm {arm} (scale={} thr={thr} thp={thp} rep={rep}) failed: status {:?} stdout {:?} stderr {:?}",
                    scale.name(), o.status, txt, String::from_utf8_lossy(&o.stderr)
                );
                // PRECONDITION: SVT holds identical structure in every arm.
                // If it does not, the arms are not measuring the same read.
                match svt_shape {
                    None => svt_shape = Some((f[1], f[2])),
                    Some(prev) => assert!(
                        prev == (f[1], f[2]),
                        "W2 precondition violated: SVT structure differs across arms \
                         ({:?} vs {:?} at arm {arm}); arms are not comparable",
                        prev, (f[1], f[2])
                    ),
                }
                out.row(
                    "wsprobe.csv",
                    &format!(
                        "{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}",
                        consol.name(), scale.name(), thr,
                        if thp { "on" } else { "off" },
                        arm, n_ord, ballast, rep,
                        f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7]
                    ),
                );
                med_src.entry(arm).or_default().push(f[3]);
                med_two.entry(arm).or_default().push(f[5]);
                med_rss.entry(arm).or_default().push(f[0]);
            }
        }

        // ---- evaluate the pre-stated condition, mechanically.
        let rss_b0 = median(med_rss.get_mut("ord6-ballast-000").unwrap());
        let rss_b25 = median(med_rss.get_mut("ord6-ballast-025").unwrap());
        let rss_b50 = median(med_rss.get_mut("ord6-ballast-050").unwrap());
        let rss_b100 = median(med_rss.get_mut("ord6-ballast-100").unwrap());
        // The manipulation must actually have moved the working set.
        assert!(
            rss_b100 > rss_b0,
            "W2 VOID: ballast did not change resident memory ({} vs {} KiB); \
             the working set was not varied and no verdict is available",
            rss_b0, rss_b100
        );
        for (label, tab) in [("source-bound", &mut med_src), ("two-bound(prefix-2)", &mut med_two)] {
            let l1 = median(tab.get_mut("ord1").unwrap());
            let b0 = median(tab.get_mut("ord6-ballast-000").unwrap());
            let b25 = median(tab.get_mut("ord6-ballast-025").unwrap());
            let b50 = median(tab.get_mut("ord6-ballast-050").unwrap());
            let b100 = median(tab.get_mut("ord6-ballast-100").unwrap());
            let p = b100 as i64 - l1 as i64;
            let w = b100 as i64 - b0 as i64;
            let monotone = b0 <= b25 && b25 <= b50 && b50 <= b100;
            let verdict = if p <= 0 {
                "VOID — effect did not reproduce in this configuration (P <= 0)"
            } else if w as f64 > 0.5 * p as f64 && monotone {
                "H SURVIVES — working set recovers > half the penalty and the sweep is monotone"
            } else if w as f64 > 0.5 * p as f64 {
                "H FALSIFIED — W > P/2 but the ballast sweep is NOT monotone"
            } else {
                "H FALSIFIED — removing the other projections' data recovers < half the penalty"
            };
            println!(
                "W2 {} scale={} thr={} thp={} class={}\n     \
                 L1={}ns  ord6-b000={}  b025={}  b050={}  b100={}   P={}ns  W={}ns  W/P={:.2}  monotone={}\n     \
                 rss(KiB) b000={} b025={} b050={} b100={}\n     {}",
                consol.name(), scale.name(), thr, if thp { "on" } else { "off" }, label,
                l1, b0, b25, b50, b100, p, w,
                if p != 0 { w as f64 / p as f64 } else { 0.0 }, monotone,
                rss_b0, rss_b25, rss_b50, rss_b100,
                verdict
            );
        }
    }
}

// ---------------------------------------------------------------- stress

/// Concurrency gate. The single-threaded selftest cannot see a
/// reclamation race: it needs a reader traversing a chain while the
/// writer retires it. Two invariants are checked continuously, both of
/// which a use-after-free breaks:
///
///   1. Append-only monotonicity — a key's published pair set never
///      shrinks. Per-location coherence guarantees a later Acquire load
///      cannot observe an older head, so any shrink means the reader
///      walked memory the writer had already reused.
///   2. Component range — every pair must hold a legal (verb, target).
///      Recycled node memory almost never does.
///
/// Run at threshold 4 on the skewed profile, which maximises
/// consolidation and therefore retirement pressure.
fn stress(seed: u64) {
    let triples = generate(Profile::QueryDominant, Scale::Medium, seed);
    let (_, su, vu, tu) = Scale::Medium.dims();
    let mut total_checks = 0u64;
    for &alloc in [Alloc::Heap, Alloc::Arena].iter() {
        for &consol in CONSOLS.iter() {
            let p = Projection::new(Ord6::SVT, su, 4, consol, alloc, triples.len());
            let idx = Index { projs: vec![p] };
            let done = AtomicBool::new(false);
            let bad_shrink = AtomicU64::new(0);
            let bad_range = AtomicU64::new(0);
            let checks = AtomicU64::new(0);
            NO_READER.store(false, Ord_::SeqCst);
            std::thread::scope(|sc| {
                let idx = &idx;
                let done = &done;
                let triples = &triples;
                sc.spawn(move || {
                    let p = &idx.projs[0];
                    p.claim_writer();
                    for &tr in triples.iter() {
                        p.append(tr);
                    }
                    p.release_writer();
                    done.store(true, Ord_::Relaxed);
                    NO_READER.store(true, Ord_::SeqCst);
                });
                for r in 0..1u64 {
                    let bad_shrink = &bad_shrink;
                    let bad_range = &bad_range;
                    let checks = &checks;
                    sc.spawn(move || {
                        reader_attach();
                        let mut rng = Rng::new(seed ^ (0x9911 + r));
                        let mut last = vec![0usize; su as usize];
                        let mut buf: Vec<(u32, u32)> = Vec::new();
                        while !done.load(Ord_::Relaxed) {
                            let k = rng.below(su);
                            buf.clear();
                            EPOCH.fetch_add(1, Ord_::AcqRel);
                            let _d = idx.projs[0].collect(k, &mut buf);
                            EPOCH.fetch_add(1, Ord_::AcqRel);
                            checks.fetch_add(1, Ord_::Relaxed);
                            if buf.len() < last[k as usize] {
                                bad_shrink.fetch_add(1, Ord_::Relaxed);
                            }
                            last[k as usize] = buf.len();
                            for &(a, b) in buf.iter() {
                                if a >= vu || b >= tu {
                                    bad_range.fetch_add(1, Ord_::Relaxed);
                                }
                            }
                        }
                        reader_detach();
                    });
                }
            });
            let sh = bad_shrink.load(Ord_::Relaxed);
            let rg = bad_range.load(Ord_::Relaxed);
            let ck = checks.load(Ord_::Relaxed);
            if sh != 0 || rg != 0 {
                panic!(
                    "STRESS FAIL {}/{}: {} shrinking reads, {} out-of-range pairs over {} lookups",
                    consol.name(),
                    alloc.name(),
                    sh,
                    rg,
                    ck
                );
            }
            total_checks += ck;
            drop(idx);
        }
    }
    println!(
        "stress: PASS ({} concurrent lookups against a live writer across 3 strategies x 2 allocators, 100000 triples at threshold 4, single reader per the reclamation precondition, zero shrinking reads and zero out-of-range pairs)",
        total_checks
    );
}

// ------------------------------------------------------------------ main

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut round = "rough".to_string();
    let mut samples: usize = 0;
    let mut outdir = ".axverity-store/bakeoff".to_string();
    let mut seed: u64 = 0x5EED_0BAC_0FFE_E001;
    let mut do_perturb = true;
    let mut memmode: Option<(usize, usize, usize, u32, usize, usize)> = None;
    let mut only_ords: Option<Vec<usize>> = None;
    let mut only_scales: Option<Vec<String>> = None;
    let mut strategies: Vec<Consol> = vec![Consol::Full];
    let mut allocs: Vec<Alloc> = vec![Alloc::Heap];
    let mut reps: usize = 1;
    let mut do_equiv = false;
    let mut equiv_scope = "all".to_string();
    let mut skip_mem = false;
    let mut do_wsprobe = false;
    let mut wsprobe_focus = false;
    let mut wschild: Option<(Consol, Scale, u32, usize, u32, bool, usize)> = None;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--round" => {
                round = args[i + 1].clone();
                i += 1;
            }
            "--samples" => {
                samples = args[i + 1].parse().unwrap();
                i += 1;
            }
            "--out" => {
                outdir = args[i + 1].clone();
                i += 1;
            }
            "--seed" => {
                seed = args[i + 1].parse().unwrap();
                i += 1;
            }
            "--only-ords" => {
                only_ords = Some(
                    args[i + 1]
                        .split(',')
                        .map(|x| x.parse::<usize>().unwrap())
                        .collect(),
                );
                i += 1;
            }
            "--strategies" => {
                strategies = args[i + 1].split(',').map(Consol::parse).collect();
                i += 1;
            }
            "--alloc" => {
                allocs = args[i + 1].split(',').map(Alloc::parse).collect();
                i += 1;
            }
            "--reps" => {
                reps = args[i + 1].parse().unwrap();
                i += 1;
            }
            "--only-scales" => {
                only_scales = Some(args[i + 1].split(',').map(|x| x.to_string()).collect());
                i += 1;
            }
            "--no-perturb" => do_perturb = false,
            "--equiv" => { do_equiv = true; }
            "--wsprobe" => { do_wsprobe = true; }
            "--wsprobe-focus" => { do_wsprobe = true; wsprobe_focus = true; }
            "--wsprobe-child" => {
                wschild = Some((
                    Consol::parse(&args[i + 1]),
                    match args[i + 2].as_str() {
                        "small" => Scale::Small,
                        "medium" => Scale::Medium,
                        "large" => Scale::Large,
                        o => panic!("unknown scale {o}"),
                    },
                    args[i + 3].parse::<u32>().unwrap(),
                    args[i + 4].parse::<usize>().unwrap(),
                    args[i + 5].parse::<u32>().unwrap(),
                    args[i + 6] == "1",
                    args[i + 7].parse::<usize>().unwrap(),
                ));
                i += 7;
            }
            "--equiv-scope" => {
                equiv_scope = args[i + 1].clone();
                i += 1;
            }
            "--no-mem" => skip_mem = true,
            "--selftest" => { selftest(seed); stress(seed); return; }
            "--stress" => { stress(seed); return; }
            "--measure-mem" => {
                memmode = Some((
                    args[i + 1].parse().unwrap(),
                    args[i + 2].parse().unwrap(),
                    args[i + 3].parse().unwrap(),
                    args[i + 4].parse().unwrap(),
                    args[i + 5].parse().unwrap(),
                    args[i + 6].parse().unwrap(),
                ));
                i += 6;
            }
            other => panic!("unknown arg {other}"),
        }
        i += 1;
    }
    if let Some((pi, si, oi, thr, ci, ai)) = memmode {
        measure_mem_child(pi, si, oi, thr, ci, ai, seed);
        return;
    }
    if let Some((c, sc, thr, n_ord, bal, thp, smp)) = wschild {
        wsprobe_child(c, sc, thr, n_ord, bal, thp, smp, seed);
        return;
    }
    if samples == 0 {
        samples = match round.as_str() {
            "rough" => 60,
            _ => 600,
        };
    }

    let out = Out::new(Path::new(&outdir));

    // W1 gate. Runs standalone: nothing downstream in this round may rely
    // on a segmented figure until this has passed and been reported.
    if do_equiv {
        fs::write(
            Path::new(&outdir).join("manifest.txt"),
            format!(
"AXVERITY_GRAPH_INDEX_ORDERING_BAKEOFF_V3 -- W1 equivalence manifest
round={round}
seed={seed}
scope={equiv_scope}
what_is_compared=E1 per-key pair multiset (exhaustive over the key universe, vs brute force and across all three strategies); \
E2 total retained pairs == applied triples per strategy; \
E3 prefix-2 results (exhaustive over prefixes present) vs brute force and across strategies; \
E4 every run internally sorted; \
E5 full-rebuild vs merge output ORDER identical, segmented order divergence counted not asserted
thresholds=4, 8, 16 (bounded, the ones the speed figures were taken at) plus unbounded as the control
preconditions_checked=P1 quiesced (zero readers, NO_READER true) -- panics; \
P2 writer cardinality one per projection, runtime-audited -- panics; \
P3 identical stream and order applied to all three strategies; \
P4 scope is the enumerated set only and is emitted with the result
not_established=thresholds outside 4/8/16; equivalence under concurrent mutation; output ORDER for segmented
"),
        ).ok();
        equivalence(seed, &out, &equiv_scope);
        return;
    }

    // W2 probe. The falsification condition is fixed in the source at
    // wsprobe()'s header, ahead of any measurement, and evaluated
    // mechanically from the medians rather than by narration.
    if do_wsprobe {
        let smp = if samples == 0 { 3000 } else { samples };
        fs::write(
            Path::new(&outdir).join("manifest.txt"),
            format!(
"AXVERITY_GRAPH_INDEX_ORDERING_BAKEOFF_V3 -- W2 working-set probe manifest
round={round}
seed={seed}
reps_per_arm={reps}
samples_per_class_per_arm={smp} (plus an equal discarded warm pass)
hypothesis=the extra-ordering read penalty is caused by cache/TLB pressure from total resident working set
method=hardware counters UNAVAILABLE (perf_event_paranoid=3, no CAP_PERFMON); declared alternative used:
  working-set size varied independently of ordering count. Every arm attaches the same projections and
  queries only SVT, which holds the identical full stream in every arm; the other projections hold
  0/25/50/100% of the stream.
falsification_condition_stated_before_measurement=
  P = median(ord6-ballast-100) - median(ord1); W = median(ord6-ballast-100) - median(ord6-ballast-000).
  H FALSIFIED if W <= 0.5*P, or if the ballast sweep is not monotone non-decreasing.
  H SURVIVES only if W > 0.5*P AND the sweep is monotone.
  SECONDARY (TLB-specific): with THP disabled, H predicts W GROWS.
  VOID if P <= 0 (effect did not reproduce), or if RSS did not rise with ballast, or if SVT's own
  structure differed across arms (both checked, both panic).
if_falsified=report the effect as reproduced-and-unexplained; do not substitute a third untested cause
strategy=merge (chosen so the probe does not depend on a segmented figure); allocator=heap; profile=query-dominant
phase=steady state only, zero writers attached, single reader
"),
        ).ok();
        wsprobe(seed, &out, reps, smp, wsprobe_focus);
        return;
    }

    out.header(
        "cells-latency.csv",
        "round,strategy,alloc,rep,profile,scale,orderings,threshold,phase,query_class,samples,p50_ns,p99_ns,max_ns,blocked_ns,blocked_pct,index_hit,scan_queries,matched_total,samples_during_ingest,wall_clock_overhead_ns,cpu_clock_overhead_ns,lookup_path",
    );
    out.header(
        "cells-config.csv",
        "round,strategy,alloc,rep,profile,scale,orderings,threshold,triples,appends_total,ingest_wall_ns,ingest_cpu_ns_sum,triples_per_sec,ingest_blocked_ns,ingest_blocked_pct,mixed_phase_wall_ns,reclaim_stall_ns,rss_delta_kb,live_nodes,nodes_ever,consolidations,consolidations_per_sec,consol_ns_total,consol_max_ns,consol_pairs,run_count_max,merge_pairs",
    );
    out.header(
        "walkdepth.csv",
        &format!(
            "round,strategy,alloc,rep,profile,scale,orderings,threshold,phase,samples,max_depth,{}",
            WALK_BUCKETS
                .iter()
                .map(|b| format!("le_{}", b))
                .collect::<Vec<_>>()
                .join(",")
                + ",gt_128"
        ),
    );
    out.header(
        "proj-memory.csv",
        "round,strategy,alloc,rep,profile,scale,orderings,threshold,ordering,rss_delta_kb,nodes,node_bytes_kb,base_pairs,triples,bytes_per_triple,x_vs_raw_12b",
    );
    out.header(
        "writer-audit.csv",
        "round,strategy,alloc,rep,profile,scale,orderings,threshold,projections,concurrent_writer_violations",
    );

    let wallp = calibrate_wall_pair_ns();
    let cpup = calibrate_cpu_pair_ns();
    WALL_OVERHEAD.store(wallp, Ord_::Relaxed);
    CPU_OVERHEAD.store(cpup, Ord_::Relaxed);
    println!(
        "bakeoff round={} samples/class={} seed={} wall-pair={}ns cpu-pair={}ns out={}",
        round, samples, seed, wallp, cpup, outdir
    );
    fs::write(
        Path::new(&outdir).join("manifest.txt"),
        format!(
"AXVERITY_GRAPH_INDEX_ORDERING_BAKEOFF_V1 harness manifest
round={round}
samples_per_query_class={samples}
seed={seed}
wall_clock_pair_overhead_ns={wallp}   (CLOCK_MONOTONIC, mean of 200000 back-to-back pairs)
cpu_clock_pair_overhead_ns={cpup}   (CLOCK_THREAD_CPUTIME_ID, mean of 50000 back-to-back pairs)
ordering_attach_order=SVT,VST,TSV,STV,VTS,TVS  (count N attaches the first N)
scales: small=10000 triples |S|=1000 |V|=20 |T|=1000; medium=100000 |S|=10000 |V|=50 |T|=10000; large=1000000 |S|=100000 |V|=100 |T|=100000
profiles: logging-append-dominant writes:queries=95:5, sources drawn from an advancing recency window of |S|/20; query-dominant writes:queries=20:80, sources/targets skewed floor(n*u^3), verbs floor(n*u^2)
phases: warm-load 50% of the stream per projection single-threaded, then a measured mixed phase where one dedicated writer thread per projection appends the remaining 50% while one reader thread issues queries at the profile duty cycle
ingest_wall = max over writer threads of that thread's own CLOCK_MONOTONIC span (never the enclosing scope)
blocked = wall - CLOCK_THREAD_CPUTIME_ID over the same span
resident memory = VmRSS delta measured in a dedicated child process per (profile,scale,ordering,threshold)
reclamation = epoch-based; superseded versions freed once the reader has passed a quiescent state
cyclic-pattern fan-out bound = 8 neighbours
resident_memory_table = {}
repetitions_per_cell = {reps}
",
            if skip_mem { "SKIPPED (--no-mem): every rss_delta_kb in this round is an unmeasured 0, not a measured zero" } else { "measured" }),
    ).ok();

    if do_perturb {
        perturbation(&out, seed);
    }

    // ---- the declared matrix. No pruning: 4 x 4 x 2 x 3 = 96 configs.
    let all_ord_counts = [1usize, 2, 3, 6];
    let ord_counts: Vec<usize> = match &only_ords {
        None => all_ord_counts.to_vec(),
        Some(v) => all_ord_counts.iter().copied().filter(|o| v.contains(o)).collect(),
    };
    if only_ords.is_some() {
        println!(
            "AUTHORIZED SUBSET: ordering-counts {:?} only (declared matrix already run in full; see round-rough / round-fine)",
            ord_counts
        );
    }
    let thresholds = [4u32, 8, 16, u32::MAX];
    let profiles = [Profile::LoggingAppend, Profile::QueryDominant];
    let all_scales = [Scale::Small, Scale::Medium, Scale::Large];
    let scales: Vec<Scale> = match &only_scales {
        None => all_scales.to_vec(),
        Some(v) => all_scales
            .iter()
            .copied()
            .filter(|s| v.iter().any(|x| x == s.name()))
            .collect(),
    };
    println!(
        "strategies={:?} allocs={:?} reps={} ordering-counts={:?} scales={:?}",
        strategies.iter().map(|c| c.name()).collect::<Vec<_>>(),
        allocs.iter().map(|a| a.name()).collect::<Vec<_>>(),
        reps,
        ord_counts,
        scales.iter().map(|s| s.name()).collect::<Vec<_>>()
    );

    let max_ord = ord_counts.iter().copied().max().unwrap_or(6);
    // The resident-memory table costs one full subprocess build per
    // (profile, scale, ordering, threshold, strategy, allocator) and is
    // not a write-side measure. A round that measures only ingest may skip
    // it — but then every rss column in that round is 0 and says so, in
    // the manifest and here, rather than reading as a measured zero.
    let memtab = if skip_mem {
        println!("resident-memory table: SKIPPED (--no-mem); rss_delta_kb columns in this round are NOT measured and are emitted as 0");
        std::collections::HashMap::new()
    } else {
        println!("building resident-memory table (subprocess builds, full stream)...");
        memory_table(seed, &scales, max_ord, &strategies, &allocs)
    };

    let mut cells = 0usize;
    let t_start = wall_ns();
    for &alloc in allocs.iter() {
    for &consol in strategies.iter() {
        for repn in 0..reps {
            for (pi, &profile) in profiles.iter().enumerate() {
                for (_si, &scale) in scales.iter().enumerate() {
                    let si = SCALES.iter().position(|s| *s == scale).unwrap();
                    println!(
                        "== {} / {} / rep {} / {} / {} ==",
                        consol.name(),
                        alloc.name(),
                        repn,
                        profile.name(),
                        scale.name()
                    );
                    let triples = generate(profile, scale, seed);
                    for &n_ord in ord_counts.iter() {
                        for &thr in thresholds.iter() {
                            run_config(
                                profile, scale, n_ord, thr, &triples, samples, seed, &round,
                                &out, &memtab, pi, si, consol,
                                CONSOLS.iter().position(|c| *c == consol).unwrap(),
                                alloc, repn,
                            );
                            cells += 1;
                        }
                    }
                }
            }
        }
    }
    }
    let t_end = wall_ns();
    println!(
        "matrix complete: {} configuration runs in {:.1}s",
        cells,
        (t_end - t_start) as f64 / 1e9
    );
}
