// AXVERITY_DURABLE_FORMAT_V1 — P0 harness.
//
// This is the measuring instrument, not the implementation. It is subject to
// the same NO_HARNESS_PROMOTION discipline the earlier probes carry: read it
// for reference, never move or copy it into lib/ or src/.
//
// It does four things, and deliberately nothing else:
//
//   1. GENERATES a record corpus and reports its size distribution. The
//      distribution is the input to T7 (does F3 apply at all) and it is
//      synthetic — there is no production workload to sample, and saying so
//      is part of the result.
//
//   2. DECODES durable stores INDEPENDENTLY of the writer. The decoder here
//      shares no code with the M1 candidate writers; it was written from the
//      format description, so a writer and a verifier agreeing is evidence,
//      not a tautology. This is what makes ROUND_TRIP_IS_THE_TEST mean
//      something.
//
//   3. KILLS PROCESSES. Not "simulates a crash state" — spawns the real
//      writer, waits for a real observable condition, and SIGKILLs it. What
//      the filesystem is left holding afterwards is the finding.
//
//   4. CORRUPTS stores on purpose, so every correctness claim can be shown
//      to fail when the thing it tests is broken (NEGATIVE_CONTROL_REQUIRED).
//
// Zero dependencies.

use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

// ───────────────────────────────────────────────────────────── rng

/// xorshift64*, seeded explicitly so every corpus is reproducible from
/// (dist, n, seed) alone and no measurement depends on an unrecorded state.
struct Rng(u64);
impl Rng {
    fn new(seed: u64) -> Self {
        Rng(if seed == 0 { 0x9E3779B97F4A7C15 } else { seed })
    }
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545F4914F6CDD1D)
    }
    fn below(&mut self, n: u64) -> u64 {
        if n == 0 { 0 } else { self.next() % n }
    }
}

// ───────────────────────────────────────────────────────────── corpus

// Corpus wire form — the INPUT to a candidate writer, not a durable format:
//   repeat { i64 little-endian length, that many bytes }
// 8-byte lengths so an M1 writer can stage the whole file into raw memory
// and read each length with a single mem_read_int_raw, with no byte-level
// decoding of its own. Nothing about this shape constrains what the writer
// then does durably.

fn corpus_write(path: &Path, recs: &[Vec<u8>]) {
    let mut buf = Vec::new();
    for r in recs {
        buf.extend_from_slice(&(r.len() as i64).to_le_bytes());
        buf.extend_from_slice(r);
    }
    fs::create_dir_all(path.parent().unwrap()).ok();
    fs::write(path, &buf).expect("corpus write");
}

fn corpus_read(path: &Path) -> Vec<Vec<u8>> {
    let buf = fs::read(path).unwrap_or_else(|e| panic!("corpus read {}: {}", path.display(), e));
    let mut out = Vec::new();
    let mut i = 0usize;
    while i + 8 <= buf.len() {
        let len = i64::from_le_bytes(buf[i..i + 8].try_into().unwrap()) as usize;
        i += 8;
        if i + len > buf.len() {
            panic!("corpus truncated at record {}", out.len());
        }
        out.push(buf[i..i + len].to_vec());
        i += len;
    }
    out
}

/// Record shapes. `structure` mirrors what the read tier actually indexes —
/// an (S,V,T) triple of names, US-separated, which is the record the
/// name-index and the three projections consume. `payload` is opaque blob
/// content. `mixed` is both, in the ratio a graph store would see.
fn corpus_gen(dist: &str, n: usize, seed: u64) -> Vec<Vec<u8>> {
    let mut rng = Rng::new(seed);
    let mut out = Vec::with_capacity(n);
    let tcard = std::cmp::max(1, n / 4);
    for i in 0..n {
        let r: Vec<u8> = match dist {
            "structure" => {
                // Same synthetic graph shape rt_pop_step.m1 builds, so the
                // distribution measured here is the distribution the read
                // tier was measured against. DELIBERATELY SEED-INDEPENDENT:
                // it is a pure function of the index, exactly as the read
                // tier's own population is. Two `structure` corpora of the
                // same n are byte-identical whatever seed is passed — use a
                // content-varying dist (fixed:W, uniform:LO:HI) when a test
                // needs two DIFFERENT bodies of records.
                format!("s{}\x1fv{}\x1ft{}", i / 4, i % 7, i % tcard).into_bytes()
            }
            "mixed" => {
                if rng.below(100) < 80 {
                    format!("s{}\x1fv{}\x1ft{}", i / 4, i % 7, i % tcard).into_bytes()
                } else {
                    // Blob sizes: log-uniform over 64B..8KiB, the range a
                    // value payload plausibly occupies. Content is
                    // deterministic-per-index so a mismatch localises.
                    let mag = 6 + rng.below(7); // 2^6 .. 2^12
                    let len = (1u64 << mag) + rng.below(1u64 << mag);
                    let mut b = Vec::with_capacity(len as usize);
                    let mut s = Rng::new(seed ^ (i as u64).wrapping_mul(0x100000001B3));
                    for _ in 0..len {
                        b.push((s.next() & 0xff) as u8);
                    }
                    b
                }
            }
            d if d.starts_with("uniform:") => {
                let p: Vec<u64> = d[8..].split(':').map(|x| x.parse().unwrap()).collect();
                let (lo, hi) = (p[0], p[1]);
                let len = lo + rng.below(hi - lo + 1);
                let mut b = Vec::with_capacity(len as usize);
                let mut s = Rng::new(seed ^ (i as u64).wrapping_mul(0x100000001B3));
                for _ in 0..len {
                    b.push((s.next() & 0xff) as u8);
                }
                b
            }
            d if d.starts_with("fixed:") => {
                let len: u64 = d[6..].parse().unwrap();
                let mut b = Vec::with_capacity(len as usize);
                let mut s = Rng::new(seed ^ (i as u64).wrapping_mul(0x100000001B3));
                for _ in 0..len {
                    b.push((s.next() & 0xff) as u8);
                }
                b
            }
            other => panic!("unknown dist '{}'", other),
        };
        out.push(r);
    }
    out
}

fn report_dist(recs: &[Vec<u8>]) {
    let mut lens: Vec<usize> = recs.iter().map(|r| r.len()).collect();
    lens.sort_unstable();
    let n = lens.len();
    if n == 0 {
        println!("records=0");
        return;
    }
    let q = |p: f64| lens[std::cmp::min(n - 1, (p * n as f64) as usize)];
    let sum: usize = lens.iter().sum();
    let mean = sum as f64 / n as f64;
    let var = lens.iter().map(|&l| (l as f64 - mean).powi(2)).sum::<f64>() / n as f64;
    println!("records={}", n);
    println!("bytes_total={}", sum);
    println!("min={} p50={} p90={} p99={} max={}", lens[0], q(0.50), q(0.90), q(0.99), lens[n - 1]);
    println!("mean={:.1} stddev={:.1}", mean, var.sqrt());
    println!("distinct_lengths={}", {
        let mut u = lens.clone();
        u.dedup();
        u.len()
    });
    // F3 applicability: fixed-width slots waste (W - len) on every record.
    // Report the waste at the width that would have to be chosen (max), so
    // the decision is a number rather than an opinion.
    let w = lens[n - 1];
    let waste = (w * n) as f64 - sum as f64;
    println!(
        "f3_slot_width_if_bounded={} f3_padding_waste_bytes={} f3_padding_waste_pct={:.1}",
        w,
        waste as u64,
        100.0 * waste / (w * n) as f64
    );
    // Histogram, powers of two.
    let mut hist: BTreeMap<u32, usize> = BTreeMap::new();
    for &l in &lens {
        let b = if l == 0 { 0 } else { 64 - (l as u64).leading_zeros() };
        *hist.entry(b).or_insert(0) += 1;
    }
    for (b, c) in hist {
        let lo = if b == 0 { 0 } else { 1u64 << (b - 1) };
        let hi = if b == 0 { 0 } else { (1u64 << b) - 1 };
        println!("hist {}..{} {} ({:.1}%)", lo, hi, c, 100.0 * c as f64 / n as f64);
    }
}

// ───────────────────────────────────────────────────────── block inventory

#[derive(Debug, Clone)]
struct BlockRef {
    run: i64, // -1 for a flat layout
    id: i64,
    path: PathBuf,
}

/// Enumerate durable blocks under `store`, ordered. Handles both the flat
/// layout (`blocks/block-<id>.bin`) and the per-run layout
/// (`blocks/run-<epoch>/block-<id>.bin`), because those are two of the
/// declared block-id candidates and the verifier must not favour either.
///
/// Files that are not `block-<int>.bin` are reported separately, never
/// silently skipped — a leftover `.tmp.<pid>.<n>` IS the crash evidence.
fn inventory(store: &Path) -> (Vec<BlockRef>, Vec<PathBuf>) {
    let mut blocks = Vec::new();
    let mut others = Vec::new();
    let visit = |dir: &Path, run: i64, blocks: &mut Vec<BlockRef>, others: &mut Vec<PathBuf>| {
        let rd = match fs::read_dir(dir) {
            Ok(r) => r,
            Err(_) => return,
        };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                continue;
            }
            let name = p.file_name().unwrap().to_string_lossy().to_string();
            if let Some(rest) = name.strip_prefix("block-") {
                if let Some(num) = rest.strip_suffix(".bin") {
                    if let Ok(id) = num.parse::<i64>() {
                        blocks.push(BlockRef { run, id, path: p });
                        continue;
                    }
                }
            }
            others.push(p);
        }
    };
    // per-run subdirectories first
    if let Ok(rd) = fs::read_dir(store) {
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                let name = p.file_name().unwrap().to_string_lossy().to_string();
                if let Some(num) = name.strip_prefix("run-") {
                    if let Ok(run) = num.parse::<i64>() {
                        visit(&p, run, &mut blocks, &mut others);
                    }
                }
            }
        }
    }
    visit(store, -1, &mut blocks, &mut others);
    blocks.sort_by_key(|b| (b.run, b.id));
    (blocks, others)
}

// ───────────────────────────────────────────────────────────── formats

#[derive(Clone, Copy, Debug, PartialEq)]
enum Fmt {
    F0,
    F1Fixed,
    F1Var,
    F2,
    F3(usize),
}

fn parse_fmt(s: &str) -> Fmt {
    match s {
        "f0" => Fmt::F0,
        "f1f" => Fmt::F1Fixed,
        "f1v" => Fmt::F1Var,
        "f2" => Fmt::F2,
        other => {
            if let Some(w) = other.strip_prefix("f3:") {
                Fmt::F3(w.parse().expect("f3:<slotwidth>"))
            } else {
                panic!("unknown format '{}' (f0|f1f|f1v|f2|f3:<W>)", other)
            }
        }
    }
}

const FOOTER: usize = 8;

#[derive(Debug)]
enum DecodeErr {
    ShortFile(usize, usize),
    BadLen(usize, usize),
    Overrun(usize, usize),
    BadCount(usize),
    BadTable(usize),
}

impl std::fmt::Display for DecodeErr {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            DecodeErr::ShortFile(got, want) => write!(f, "short file: {} bytes, expected {}", got, want),
            DecodeErr::BadLen(off, len) => write!(f, "record length {} at offset {} does not fit the block", len, off),
            DecodeErr::Overrun(off, cap) => write!(f, "decoder ran past the block: offset {} of {}", off, cap),
            DecodeErr::BadCount(c) => write!(f, "trailing directory claims {} records, impossible for this block", c),
            DecodeErr::BadTable(off) => write!(f, "trailing directory entry at {} is not monotonic", off),
        }
    }
}

fn rd_u32(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(b[off..off + 4].try_into().unwrap())
}

/// Decode one durable block into its records. Returns Err rather than
/// panicking so a deliberately corrupted store produces a diagnosis, which
/// is what the negative controls need to observe.
fn decode_block(fmt: Fmt, cap: usize, raw: &[u8]) -> Result<Vec<Vec<u8>>, DecodeErr> {
    // Every candidate writes VARIABLE-LENGTH block files: exactly the bytes
    // it packed plus the 8-byte continuation footer, never padded out to
    // `cap`. That is what the current write path already does for its last
    // block (wp_mem_controller_step.m1:49-52), and it means no candidate has
    // to zero a tail or carry an end-of-records sentinel — the file's own
    // length is the terminator. `cap` is therefore a ceiling, not a size,
    // and a file above it is a defect.
    if raw.len() < FOOTER || raw.len() > cap {
        return Err(DecodeErr::ShortFile(raw.len(), cap));
    }
    let usable = raw.len() - FOOTER;
    let mut out = Vec::new();
    match fmt {
        Fmt::F0 => {
            // No boundaries exist in the format. The whole usable region is
            // one undelimited run of bytes; returning it as a single
            // "record" is the honest decode, and the record-level compare
            // is what will fail.
            out.push(raw[..usable].to_vec());
        }
        Fmt::F1Fixed => {
            let mut off = 0usize;
            while off < usable {
                if off + 4 > usable {
                    return Err(DecodeErr::Overrun(off, usable));
                }
                let len = rd_u32(raw, off) as usize;
                if len == 0 || off + 4 + len > usable {
                    return Err(DecodeErr::BadLen(off, len));
                }
                out.push(raw[off + 4..off + 4 + len].to_vec());
                off += 4 + len;
            }
            if off != usable {
                return Err(DecodeErr::Overrun(off, usable));
            }
        }
        Fmt::F1Var => {
            let mut off = 0usize;
            while off < usable {
                let mut len = 0usize;
                let mut shift = 0u32;
                let mut o = off;
                loop {
                    if o >= usable {
                        return Err(DecodeErr::Overrun(o, usable));
                    }
                    let b = raw[o];
                    len |= ((b & 0x7f) as usize) << shift;
                    o += 1;
                    if b & 0x80 == 0 {
                        break;
                    }
                    shift += 7;
                    if shift > 35 {
                        return Err(DecodeErr::BadLen(off, len));
                    }
                }
                if len == 0 || o + len > usable {
                    return Err(DecodeErr::BadLen(off, len));
                }
                out.push(raw[o..o + len].to_vec());
                off = o + len;
            }
            if off != usable {
                return Err(DecodeErr::Overrun(off, usable));
            }
        }
        Fmt::F2 => {
            // records | u32 end-offset per record | u32 count | footer.
            // Read from the tail: one seek gives every boundary in the block
            // without touching a single payload byte.
            if usable < 4 {
                return Err(DecodeErr::BadCount(0));
            }
            let cnt = rd_u32(raw, usable - 4) as usize;
            if cnt == 0 || cnt * 4 + 4 > usable {
                return Err(DecodeErr::BadCount(cnt));
            }
            let tbl = usable - 4 - cnt * 4;
            let mut prev = 0usize;
            for i in 0..cnt {
                let end = rd_u32(raw, tbl + i * 4) as usize;
                if end <= prev || end > tbl {
                    return Err(DecodeErr::BadTable(tbl + i * 4));
                }
                out.push(raw[prev..end].to_vec());
                prev = end;
            }
            if prev != tbl {
                return Err(DecodeErr::BadTable(tbl));
            }
        }
        Fmt::F3(w) => {
            if w < 5 {
                return Err(DecodeErr::BadCount(w));
            }
            if usable % w != 0 {
                return Err(DecodeErr::Overrun(usable, w));
            }
            for j in 0..usable / w {
                let off = j * w;
                let len = rd_u32(raw, off) as usize;
                if len == 0 || len > w - 4 {
                    return Err(DecodeErr::BadLen(off, len));
                }
                out.push(raw[off + 4..off + 4 + len].to_vec());
            }
        }
    }
    Ok(out)
}

fn footer_of(raw: &[u8]) -> i64 {
    let n = raw.len();
    i64::from_le_bytes(raw[n - FOOTER..].try_into().unwrap())
}

// ───────────────────────────────────────────────────────────── verify

struct VerifyOpts {
    fmt: Fmt,
    cap: usize,
    store: PathBuf,
    corpus: PathBuf,
    /// Accept a store that holds only the first K records (a killed run).
    /// The prefix that IS there must still be exact — a crash may lose the
    /// tail, never corrupt the head.
    prefix_ok: bool,
    quiet: bool,
}

fn verify(o: &VerifyOpts) -> i32 {
    let want = corpus_read(&o.corpus);
    let (blocks, others) = inventory(&o.store);
    let mut got: Vec<Vec<u8>> = Vec::new();
    let mut fails: Vec<String> = Vec::new();

    if blocks.is_empty() {
        fails.push("no block files found".into());
    }

    // Duplicate ids inside one run are the block-id defect made visible.
    let mut seen: BTreeMap<(i64, i64), usize> = BTreeMap::new();
    for b in &blocks {
        *seen.entry((b.run, b.id)).or_insert(0) += 1;
    }
    for (k, c) in &seen {
        if *c > 1 {
            fails.push(format!("duplicate block id run={} id={} appears {}x", k.0, k.1, c));
        }
    }
    // Density: the continuation footer asserts block k is followed by k+1,
    // and any replay that uses "first missing file" as its frontier stops
    // dead at a hole. A gap is a failure, not cosmetics.
    let mut per_run: BTreeMap<i64, Vec<i64>> = BTreeMap::new();
    for b in &blocks {
        per_run.entry(b.run).or_default().push(b.id);
    }
    for (run, ids) in &per_run {
        for (i, id) in ids.iter().enumerate() {
            if *id != i as i64 {
                fails.push(format!("run {} is not dense from 0: position {} holds id {}", run, i, id));
                break;
            }
        }
    }

    for b in &blocks {
        let raw = match fs::read(&b.path) {
            Ok(r) => r,
            Err(e) => {
                fails.push(format!("{}: unreadable: {}", b.path.display(), e));
                continue;
            }
        };
        match decode_block(o.fmt, o.cap, &raw) {
            Ok(mut recs) => got.append(&mut recs),
            Err(e) => fails.push(format!("{}: {}", b.path.display(), e)),
        }
    }

    // Record-level compare, in order, byte-identical.
    if o.fmt == Fmt::F0 {
        // F0 carries no boundaries at all. The only claim it can support is
        // stream equality, so that is the only claim tested — and the
        // record claim is recorded as unsupported by construction.
        let want_stream: Vec<u8> = want.iter().flat_map(|r| r.iter().copied()).collect();
        let got_stream: Vec<u8> = got.iter().flat_map(|r| r.iter().copied()).collect();
        let n = std::cmp::min(want_stream.len(), got_stream.len());
        let head_ok = want_stream[..n] == got_stream[..n];
        let complete = got_stream.len() >= want_stream.len();
        if !head_ok {
            fails.push("stream bytes differ from the corpus".into());
        }
        if !complete && !o.prefix_ok {
            fails.push(format!(
                "stream truncated: {} of {} corpus bytes present (padding excluded)",
                n,
                want_stream.len()
            ));
        }
        println!("RECORDS_RECOVERABLE=no  (F0 carries no record boundaries — record count, order and length are all unrecoverable from the durable bytes)");
        println!("stream_bytes_present={} stream_bytes_expected={}", got_stream.len(), want_stream.len());
    } else {
        let have = got.len();
        let cmp_n = if o.prefix_ok { std::cmp::min(have, want.len()) } else { want.len() };
        if !o.prefix_ok && have != want.len() {
            fails.push(format!("record count {} != corpus {}", have, want.len()));
        }
        if o.prefix_ok && have > want.len() {
            fails.push(format!("record count {} exceeds corpus {}", have, want.len()));
        }
        let mut bad = 0usize;
        for i in 0..std::cmp::min(cmp_n, std::cmp::min(have, want.len())) {
            if got[i] != want[i] {
                if bad < 5 && !o.quiet {
                    println!(
                        "  record {} differs: got {} bytes, want {} bytes{}",
                        i,
                        got[i].len(),
                        want[i].len(),
                        if got[i].len() == want[i].len() { " (same length, different bytes)" } else { "" }
                    );
                }
                bad += 1;
            }
        }
        if bad > 0 {
            fails.push(format!("{} of {} compared records differ", bad, cmp_n));
        }
        println!("RECORDS_RECOVERABLE=yes  records_read={} corpus_records={}", have, want.len());
    }

    if !others.is_empty() {
        println!("non_block_files={} (first: {})", others.len(), others[0].display());
    }
    println!("blocks={} runs={}", blocks.len(), per_run.len());

    if fails.is_empty() {
        println!("VERIFY PASS");
        0
    } else {
        for f in &fails {
            println!("VERIFY FAIL: {}", f);
        }
        1
    }
}

// ─────────────────────────────────────────────────────────── S2 verify

/// Verify an S2 store: two stream directories, ONE shared id space.
///
/// This is a different shape from `verify`, not a flag on it, because the
/// density invariant moves. Under S1 each stream is its own namespace and each
/// is dense from 0. Under S2 a block id is global, so `structure` might hold
/// 0,1,4 and `payload` 2,3,5 — neither is dense alone and checking them that
/// way would fail a correct store. **Density is a property of the union**, and
/// so is the duplicate check: the same id appearing in both streams is exactly
/// the collision a shared counter exists to prevent, and it is invisible to
/// any per-directory test.
///
/// Each stream is then compared against the corpus filtered by the same size
/// threshold the writer routed on, in order, byte-identical. Routing is part
/// of the format here: a record in the wrong stream is a failure even if its
/// bytes survive.
fn verify_s2(cap: usize, root: &Path, corpus: &Path, thresh: usize, prefix_ok: bool) -> i32 {
    let want = corpus_read(corpus);
    let mut fails: Vec<String> = Vec::new();

    let sdir = root.join("structure");
    let pdir = root.join("payload");
    let (sblocks, sothers) = inventory(&sdir);
    let (pblocks, pothers) = inventory(&pdir);

    // ── each stream dense from 0 ────────────────────────────────────────
    //
    // AXVERITY_EXTENT_WRITE_PATH 5b/5d RETIRED THE UNION CHECK, and this is
    // not a weakening. The id space is PER STREAM now: slablock mints a
    // sequence per handle and a handle is a directory, so structure/block-0
    // and payload/block-0 both exist and both are correct. A locator carries
    // the stream (measured: without it a reader spent ~3.5 us probing two
    // directories to find a record it then read in 676 ns), so "no id in both
    // streams" stopped being a defect and became the design.
    //
    // DENSITY is what the union check was really protecting, and per-stream
    // density catches the same failures: a stream that lost a block has a
    // hole, and a stream that restarted its sequence — the B1 mint-from-zero
    // defect — overwrites and comes up short. Both fail here.
    if sblocks.is_empty() && pblocks.is_empty() {
        fails.push("no block files found in either stream".into());
    }
    for (blocks, name) in [(&sblocks, "structure"), (&pblocks, "payload")] {
        let mut ids: Vec<i64> = blocks.iter().map(|b| b.id).collect();
        ids.sort();
        for w in ids.windows(2) {
            if w[0] == w[1] {
                fails.push(format!("{}: id {} appears twice", name, w[0]));
            }
        }
        for (i, id) in ids.iter().enumerate() {
            if *id != i as i64 {
                fails.push(format!(
                    "{} is not dense from 0: position {} holds id {} (a hole at {})",
                    name, i, id, i
                ));
                break;
            }
        }
    }

    // ── each stream against its filtered slice of the corpus ────────────
    let want_s: Vec<&Vec<u8>> = want.iter().filter(|r| r.len() <= thresh).collect();
    let want_p: Vec<&Vec<u8>> = want.iter().filter(|r| r.len() > thresh).collect();

    let mut decode_stream = |blocks: &Vec<BlockRef>, label: &str| -> Vec<Vec<u8>> {
        let mut got = Vec::new();
        for b in blocks {
            match fs::read(&b.path) {
                Ok(raw) => match decode_block(Fmt::F1Var, cap, &raw) {
                    Ok(mut r) => got.append(&mut r),
                    Err(e) => fails.push(format!("{}/{}: {}", label, b.path.display(), e)),
                },
                Err(e) => fails.push(format!("{}/{}: unreadable: {}", label, b.path.display(), e)),
            }
        }
        got
    };
    let got_s = decode_stream(&sblocks, "structure");
    let got_p = decode_stream(&pblocks, "payload");

    let mut cmp = |got: &Vec<Vec<u8>>, want: &Vec<&Vec<u8>>, label: &str| {
        if !prefix_ok && got.len() != want.len() {
            fails.push(format!(
                "{}: record count {} != corpus slice {}",
                label,
                got.len(),
                want.len()
            ));
        }
        if prefix_ok && got.len() > want.len() {
            fails.push(format!(
                "{}: record count {} exceeds corpus slice {}",
                label,
                got.len(),
                want.len()
            ));
        }
        let n = std::cmp::min(got.len(), want.len());
        let mut bad = 0usize;
        for i in 0..n {
            if got[i] != *want[i] {
                bad += 1;
            }
        }
        if bad > 0 {
            fails.push(format!("{}: {} of {} compared records differ", label, bad, n));
        }
        // Routing is part of the format: a record that landed in the wrong
        // stream is a failure even when its bytes are intact.
        for (i, r) in got.iter().enumerate() {
            let misrouted = if label == "structure" { r.len() > thresh } else { r.len() <= thresh };
            if misrouted {
                fails.push(format!(
                    "{}: record {} is {} bytes — wrong side of threshold {}",
                    label, i, r.len(), thresh
                ));
                break;
            }
        }
    };
    cmp(&got_s, &want_s, "structure");
    cmp(&got_p, &want_p, "payload");

    let temps = sothers.len() + pothers.len();
    if temps > 0 {
        let first = sothers.first().or_else(|| pothers.first()).unwrap();
        println!("non_block_files={} (first: {})", temps, first.display());
    }
    println!(
        "structure_blocks={} payload_blocks={} max_structure_id={} max_payload_id={}",
        sblocks.len(),
        pblocks.len(),
        sblocks.iter().map(|b| b.id).max().unwrap_or(-1),
        pblocks.iter().map(|b| b.id).max().unwrap_or(-1)
    );
    println!(
        "structure_records={}/{} payload_records={}/{}",
        got_s.len(),
        want_s.len(),
        got_p.len(),
        want_p.len()
    );

    if fails.is_empty() {
        println!("VERIFY PASS");
        0
    } else {
        for f in &fails {
            println!("VERIFY FAIL: {}", f);
        }
        1
    }
}

// ───────────────────────────────────────────────────── spawn and real kill

/// Spawn a writer and SIGKILL it. `--after-blocks K` polls the store until K
/// durable blocks exist and kills immediately; `--after-ms D` kills on a
/// wall-clock delay so the kill lands at an arbitrary, unaligned point in
/// the write protocol. Both are real signals to a real process — nothing
/// here constructs a filesystem state by hand.
fn spawn_kill(args: &[String]) -> i32 {
    let mut store = PathBuf::new();
    let mut after_blocks: Option<usize> = None;
    let mut after_ms: Option<u64> = None;
    let mut cmd: Vec<String> = Vec::new();
    let mut cwd: Option<PathBuf> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--store" => { store = PathBuf::from(&args[i + 1]); i += 2; }
            "--after-blocks" => { after_blocks = Some(args[i + 1].parse().unwrap()); i += 2; }
            "--after-ms" => { after_ms = Some(args[i + 1].parse().unwrap()); i += 2; }
            "--cwd" => { cwd = Some(PathBuf::from(&args[i + 1])); i += 2; }
            "--" => { cmd = args[i + 1..].to_vec(); break; }
            other => panic!("spawn-kill: unknown arg {}", other),
        }
    }
    if cmd.is_empty() {
        panic!("spawn-kill: no command after --");
    }

    let mut c = Command::new(&cmd[0]);
    c.args(&cmd[1..]).stdout(Stdio::null()).stderr(Stdio::null());
    if let Some(d) = &cwd {
        c.current_dir(d);
    }
    let t0 = Instant::now();
    let mut child = c.spawn().expect("spawn writer");

    let deadline = Duration::from_millis(after_ms.unwrap_or(600_000));
    let mut killed = false;
    let mut blocks_at_kill = 0usize;
    loop {
        if let Some(status) = child.try_wait().expect("try_wait") {
            println!("writer_exited_on_its_own=true status={:?}", status.code());
            break;
        }
        if let Some(k) = after_blocks {
            let (b, _) = inventory(&store);
            if b.len() >= k {
                blocks_at_kill = b.len();
                child.kill().expect("SIGKILL");
                killed = true;
                break;
            }
        }
        if t0.elapsed() >= deadline {
            let (b, _) = inventory(&store);
            blocks_at_kill = b.len();
            child.kill().expect("SIGKILL");
            killed = true;
            break;
        }
        std::thread::sleep(Duration::from_micros(200));
    }
    let status = child.wait().expect("wait");
    let (blocks, others) = inventory(&store);
    let tmp: Vec<&PathBuf> = others.iter().filter(|p| p.to_string_lossy().contains(".tmp.")).collect();
    let mut short = 0usize;
    for b in &blocks {
        if let Ok(m) = fs::metadata(&b.path) {
            if m.len() == 0 {
                short += 1;
            }
        }
    }
    println!("killed={} signal={:?} exit={:?}", killed, status_signal(&status), status.code());
    println!("blocks_at_kill={} blocks_after={} zero_length_blocks={}", blocks_at_kill, blocks.len(), short);
    println!("leftover_temp_files={}", tmp.len());
    for t in tmp.iter().take(3) {
        let sz = fs::metadata(t).map(|m| m.len()).unwrap_or(0);
        println!("  temp {} ({} bytes)", t.display(), sz);
    }
    println!("elapsed_ms={}", t0.elapsed().as_millis());
    if killed { 0 } else { 2 }
}

fn status_signal(s: &std::process::ExitStatus) -> Option<i32> {
    // No libc dependency: the raw wait status encodes the signal in the low
    // 7 bits, which is what `code() == None` means on unix.
    use std::os::unix::process::ExitStatusExt;
    s.signal()
}

// ─────────────────────────────────────────────────── deliberate corruption

/// NEGATIVE_CONTROL_REQUIRED. Every mode below breaks exactly one property
/// the verifier claims to check. A suite that still passes after one of
/// these has not been shown to have teeth.
fn corrupt(args: &[String]) -> i32 {
    let store = PathBuf::from(&args[0]);
    let mode = args[1].as_str();
    let (blocks, _) = inventory(&store);
    if blocks.is_empty() {
        println!("corrupt: no blocks in {}", store.display());
        return 2;
    }
    let pick = |frac: f64| -> &BlockRef { &blocks[std::cmp::min(blocks.len() - 1, (blocks.len() as f64 * frac) as usize)] };
    match mode {
        // A crash that leaves a partially written target file. The write
        // protocol is supposed to make this unreachable; the point of
        // producing it by hand is to prove the DECODER notices, so that
        // when the kill trials report zero of them it means something.
        "truncate" => {
            let b = pick(0.5);
            let f = fs::OpenOptions::new().write(true).open(&b.path).unwrap();
            let len = f.metadata().unwrap().len();
            f.set_len(len / 2).unwrap();
            println!("corrupt truncate {} -> {} bytes", b.path.display(), len / 2);
        }
        // One byte inside a record's payload.
        "flip" => {
            let b = pick(0.5);
            let mut raw = fs::read(&b.path).unwrap();
            let i = raw.len() / 3;
            raw[i] ^= 0xff;
            fs::write(&b.path, &raw).unwrap();
            println!("corrupt flip {} byte {}", b.path.display(), i);
        }
        // A whole block gone: the count and the density both break.
        "drop" => {
            let b = pick(0.5);
            fs::remove_file(&b.path).unwrap();
            println!("corrupt drop {}", b.path.display());
        }
        // Two blocks swap names: every record still present, order wrong.
        "reorder" => {
            let a = pick(0.3).clone();
            let b = pick(0.7).clone();
            if a.path == b.path {
                println!("corrupt reorder: need >=2 blocks");
                return 2;
            }
            let ra = fs::read(&a.path).unwrap();
            let rb = fs::read(&b.path).unwrap();
            fs::write(&a.path, &rb).unwrap();
            fs::write(&b.path, &ra).unwrap();
            println!("corrupt reorder {} <-> {}", a.path.display(), b.path.display());
        }
        // A length prefix bumped by one. Every boundary after it shifts;
        // this is the failure a framing format exists to prevent, so the
        // verifier must not be able to miss it.
        "shiftlen" => {
            let b = pick(0.5);
            let mut raw = fs::read(&b.path).unwrap();
            let old = rd_u32(&raw, 0);
            let new = old + 1;
            raw[0..4].copy_from_slice(&new.to_le_bytes());
            fs::write(&b.path, &raw).unwrap();
            println!("corrupt shiftlen {} first prefix {} -> {}", b.path.display(), old, new);
        }
        other => panic!("unknown corrupt mode '{}'", other),
    }
    0
}

// ───────────────────────────────────────────────────────────── scan

fn scan(args: &[String]) -> i32 {
    let store = PathBuf::from(&args[0]);
    let (blocks, others) = inventory(&store);
    let mut sizes: BTreeMap<u64, usize> = BTreeMap::new();
    for b in &blocks {
        let sz = fs::metadata(&b.path).map(|m| m.len()).unwrap_or(0);
        *sizes.entry(sz).or_insert(0) += 1;
    }
    println!("blocks={}", blocks.len());
    for (sz, c) in &sizes {
        println!("  size {} x{}", sz, c);
    }
    println!("non_block_files={}", others.len());
    for o in others.iter().take(5) {
        println!("  {} ({} bytes)", o.display(), fs::metadata(o).map(|m| m.len()).unwrap_or(0));
    }
    if let Some(b) = blocks.last() {
        if let Ok(raw) = fs::read(&b.path) {
            if raw.len() >= FOOTER {
                println!("last_block_footer={}", footer_of(&raw));
            }
        }
    }
    0
}

/// Dump decoded records as `<index> <len> <sha-ish>` so a mismatch can be
/// localised without eyeballing binary.
fn dump(args: &[String]) -> i32 {
    let fmt = parse_fmt(&args[0]);
    let cap: usize = args[1].parse().unwrap();
    let store = PathBuf::from(&args[2]);
    let (blocks, _) = inventory(&store);
    let mut i = 0;
    for b in &blocks {
        let raw = fs::read(&b.path).unwrap();
        match decode_block(fmt, cap, &raw) {
            Ok(recs) => {
                for r in recs {
                    println!("{} {} {}", i, r.len(), fnv(&r));
                    i += 1;
                }
            }
            Err(e) => println!("{}: DECODE ERROR {}", b.path.display(), e),
        }
    }
    0
}

fn fnv(b: &[u8]) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for &x in b {
        h ^= x as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{:016x}", h)
}

// ───────────────────────────────────────────────────────────── main

fn usage() -> ! {
    eprintln!(
        "fmth — AXVERITY_DURABLE_FORMAT_V1 harness

  corpus <out> <n> <dist> [seed]      generate a record corpus + report its distribution
                                      dist: structure | mixed | uniform:LO:HI | fixed:W
  dist <corpus>                       report a corpus's size distribution
  flatten <corpus> <out>              concatenate records into one undelimited stream
  corpus-filter <in> <out> le|gt <n>  split a corpus by record size (separation streams)
  verify <fmt> <cap> <store> <corpus> [--prefix-ok] [--quiet]
                                      independently decode a store and compare, in order
  dump <fmt> <cap> <store>            decoded record index/length/hash, one per line
  scan <store>                        inventory: blocks, sizes, leftovers, last footer
  spawn-kill --store D [--after-blocks K|--after-ms D] [--cwd D] -- <cmd...>
                                      spawn a writer and SIGKILL it for real
  corrupt <store> <mode>              truncate|flip|drop|reorder|shiftlen (negative control)

  fmt: f0 | f1f | f1v | f2 | f3:<slotwidth>"
    );
    std::process::exit(2)
}

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    if a.is_empty() {
        usage();
    }
    let rc = match a[0].as_str() {
        "corpus" => {
            if a.len() < 4 {
                usage();
            }
            let out = PathBuf::from(&a[1]);
            let n: usize = a[2].parse().unwrap();
            let seed: u64 = a.get(4).map(|s| s.parse().unwrap()).unwrap_or(12345);
            let recs = corpus_gen(&a[3], n, seed);
            corpus_write(&out, &recs);
            println!("corpus={} dist={} seed={}", out.display(), a[3], seed);
            report_dist(&recs);
            0
        }
        "corpus-filter" => {
            // Split a corpus the same way the separation candidates route it:
            // by record size, at the threshold. The mixed distribution is
            // cleanly bimodal (structure <= 31 B, payload >= 64 B), so a size
            // threshold and a type tag select the same records — and a size
            // threshold needs no change to the corpus format or the decoder.
            let recs = corpus_read(Path::new(&a[1]));
            let th: usize = a[4].parse().unwrap();
            let keep: Vec<Vec<u8>> = match a[3].as_str() {
                "le" => recs.into_iter().filter(|r| r.len() <= th).collect(),
                "gt" => recs.into_iter().filter(|r| r.len() > th).collect(),
                o => panic!("corpus-filter: le|gt, got {}", o),
            };
            let bytes: usize = keep.iter().map(|r| r.len()).sum();
            corpus_write(Path::new(&a[2]), &keep);
            println!("filtered records={} bytes={}", keep.len(), bytes);
            0
        }
        "flatten" => {
            // Concatenate a corpus's record bytes with no delimiters at all
            // — the undelimited byte stream the CURRENT write path consumes.
            let recs = corpus_read(Path::new(&a[1]));
            let flat: Vec<u8> = recs.iter().flat_map(|r| r.iter().copied()).collect();
            fs::write(Path::new(&a[2]), &flat).expect("flatten write");
            println!("flattened {} records -> {} bytes at {}", recs.len(), flat.len(), &a[2]);
            0
        }
        "dist" => {
            report_dist(&corpus_read(Path::new(&a[1])));
            0
        }
        "verify" => {
            if a.len() < 5 {
                usage();
            }
            let o = VerifyOpts {
                fmt: parse_fmt(&a[1]),
                cap: a[2].parse().unwrap(),
                store: PathBuf::from(&a[3]),
                corpus: PathBuf::from(&a[4]),
                prefix_ok: a.iter().any(|x| x == "--prefix-ok"),
                quiet: a.iter().any(|x| x == "--quiet"),
            };
            verify(&o)
        }
        "verify-s2" => {
            if a.len() < 5 {
                usage();
            }
            verify_s2(
                a[1].parse().unwrap(),
                Path::new(&a[2]),
                Path::new(&a[3]),
                a[4].parse().unwrap(),
                a.iter().any(|x| x == "--prefix-ok"),
            )
        }
        "dump" => dump(&a[1..]),
        "scan" => scan(&a[1..]),
        "spawn-kill" => spawn_kill(&a[1..]),
        "corrupt" => corrupt(&a[1..]),
        _ => usage(),
    };
    std::process::exit(rc);
}

// Silence the unused-import warning on platforms where Read is not needed.
#[allow(dead_code)]
fn _keep(_: &dyn Read) {}
