#!/usr/bin/env bash
# AXVERITY_WIRE_CLIENT_HARNESS_V1 — the whole suite.
# WIRE_ONLY: the only thing this touches is a TCP socket and the shim process.
set -u
cd "$(dirname "$0")/.."
rc=0
for p in p1 p2 p3 p4 p5; do
  echo "================================================================"
  python3 "wire-harness/$p.py" || rc=1
done
echo "================================================================"
python3 - <<'PY'
import json, glob, collections
rows=[]
for f in sorted(glob.glob("wire-harness/findings/p*.json")):
    rows += json.load(open(f))
c=collections.Counter(r["status"] for r in rows)
print("TOTAL:", ", ".join(f"{k}={v}" for k,v in sorted(c.items())), f"over {len(rows)} arms")
for r in rows:
    if r["status"] in ("FAIL","ERROR"):
        print("  !!", r["phase"], r["arm"], "-", str(r["detail"])[:120])
json.dump(rows, open("wire-harness/findings/all.json","w"), indent=1)
PY
exit $rc
