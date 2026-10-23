#!/usr/bin/env python3
"""oracle — the conformance oracle (§8), decoded straight from the durable
store by an implementation that shares no code with the tiers.

It reads .axverity-store/structure/block-*.bin, decodes F1v records, and
answers all eight binding patterns from a plain Python set. That makes it an
independent answer for wire results AND for in-process results to be compared
against; the shim is never the reference for itself.
"""
import pathlib, sys

US = "\x1f"


def _blocks(store: pathlib.Path):
    d = store / "structure"
    if not d.is_dir():
        return []
    # LEXICOGRAPHIC, not numeric: the rebuild folds fs_list_dir, which sorts
    # entries as strings (io.rs:141), so block-10.bin is walked before
    # block-2.bin. That ordering is what the id assignment below depends on.
    return sorted(d.glob("block-*.bin"), key=lambda f: f.name)


def records(store: pathlib.Path):
    """Every structure record in the order the rebuild's directory fold walks
    them — fs_list_dir's lexicographic block order, then ordinal within a
    block. That order is what makes the id assignment below reproducible."""
    for f in _blocks(store):
        raw = f.read_bytes()
        body = raw[:-8]          # 8-byte footer chain
        off = 0
        while off < len(body):
            n, shift, k = 0, 0, off
            while k < len(body):
                b = body[k]
                n |= (b & 0x7F) << shift
                shift += 7
                k += 1
                if b < 0x80:
                    break
            else:
                break
            if k + n > len(body):
                break
            rec = body[k:k + n]
            off = k + n
            if n:
                yield rec.decode("utf-8", "replace")


def load(store: pathlib.Path):
    trips, malformed = set(), 0
    for rec in records(store):
        parts = rec.split(US)
        if len(parts) == 3 and all(parts):
            trips.add(tuple(parts))
        else:
            malformed += 1
    return trips, malformed


def idmap(store: pathlib.Path):
    """Recover the read tier's internal id assignment WITHOUT asking it.

    rt_dindex_rec feeds every record to rt_insert_names(s, v, t) in that order
    and the name index mints on first sight, so replaying the durable records
    in durable order reproduces the assignment exactly. It is derived here
    rather than read back because the shim, per its locked design, never calls
    rt_nidx_name_of — see the report."""
    name_of, next_id = {}, 0
    for rec in records(store):
        parts = rec.split(US)
        if len(parts) != 3 or not all(parts):
            continue
        for nm in parts:
            if nm not in name_of:
                name_of[nm] = str(next_id)
                next_id += 1
    return {v: k for k, v in name_of.items()}, name_of


def answer(trips, mask, s="", v="", t=""):
    """mask bits: 1=S 2=V 4=T. Unbound positions are ignored."""
    out = set()
    for (a, b, c) in trips:
        if mask & 1 and a != s:
            continue
        if mask & 2 and b != v:
            continue
        if mask & 4 and c != t:
            continue
        out.add((a, b, c))
    return out


if __name__ == "__main__":
    trips, mal = load(pathlib.Path(sys.argv[1]))
    print(f"triples={len(trips)} malformed={mal}")
