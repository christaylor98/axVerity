"""Arm bookkeeping. The only oracle available to an arm is `Sent`."""
import sys, traceback, json, os

RESULTS = []

class Finding(Exception):
    """Raised by an arm to record a characterisation result that is not a
    harness bug. CHARACTERISE_NEVER_FIX: nothing is repaired, it is recorded."""

def arm(phase, name, note=""):
    def deco(fn):
        def run(*a, **kw):
            rec = {"phase": phase, "arm": name, "note": note}
            try:
                detail = fn(*a, **kw)
                rec["status"] = "PASS"
                rec["detail"] = detail or ""
            except Finding as e:
                rec["status"] = "FINDING"
                rec["detail"] = str(e)
            except AssertionError as e:
                rec["status"] = "FAIL"
                rec["detail"] = str(e)
            except Exception as e:
                rec["status"] = "ERROR"
                rec["detail"] = f"{type(e).__name__}: {e}"
                rec["trace"] = traceback.format_exc()[-1500:]
            RESULTS.append(rec)
            mark = {"PASS": "PASS   ", "FAIL": "FAIL   ",
                    "FINDING": "FINDING", "ERROR": "ERROR  "}[rec["status"]]
            print(f"  {mark} {phase}/{name}", flush=True)
            if rec["status"] != "PASS" or rec["detail"]:
                for line in str(rec["detail"]).splitlines():
                    print(f"          {line}", flush=True)
            return rec
        run.__name__ = fn.__name__
        return run
    return deco


class Sent:
    """THE_CLIENT_KNOWS_ONLY_WHAT_IT_SENT — the harness's own record of every
    triple it successfully admitted. This is the sole reference for every
    assertion. It never consults the store, a decoder, or a tier."""

    def __init__(self):
        self.triples = []

    def record(self, triples):
        self.triples.extend(tuple(t) for t in triples)

    def as_set(self):
        return set(self.triples)

    # the four binding patterns the contract publishes (§3.1)
    def expect(self, mask, s="", v="", t=""):
        if mask == 0:
            return set(self.triples)
        if mask == 1:
            return {x for x in self.triples if x[0] == s}
        if mask == 2:
            return {x for x in self.triples if x[2] == t}
        if mask == 3:
            return {x for x in self.triples if x[0] == s and x[1] == v}
        raise KeyError(f"mask {mask} has no published meaning in §3.1")


def dump(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(RESULTS, f, indent=1)

def summary():
    from collections import Counter
    c = Counter(r["status"] for r in RESULTS)
    return ", ".join(f"{k}={v}" for k, v in sorted(c.items()))
