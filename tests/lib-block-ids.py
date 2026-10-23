import struct, sys, pathlib
sd, pd, footer = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
total = 0
for d, name in ((sd, "structure"), (pd, "payload")):
    ids = sorted(int(f.stem.split("-")[1]) for f in d.glob("block-*.bin"))
    if not ids:
        continue
    if ids != list(range(len(ids))):
        sys.exit(f"FAIL BLOCK_IDS_DENSE_PER_STREAM: {name} ids not dense from 0: {ids[:20]}")
    for i in ids:
        raw = (d / f"block-{i}.bin").read_bytes()
        if len(raw) < footer:
            sys.exit(f"FAIL: {name}/block-{i}.bin smaller than its footer")
        val = struct.unpack("<q", raw[-footer:])[0]
        if val != -1:
            sys.exit(f"FAIL FOOTER_IS_A_SENTINEL: {name}/block-{i} footer={val}, expected -1")
    total += len(ids)
    print(f"PASS BLOCK_IDS_DENSE_PER_STREAM: {name} 0..{ids[-1]} ({len(ids)} blocks)")
print(f"PASS FOOTER_IS_A_SENTINEL: all {total} blocks carry -1, no chain claimed")
