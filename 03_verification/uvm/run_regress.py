#!/usr/bin/env python
"""D5 regression runner for the ITS UVM layer.

Design rule: the verdict is decided from the structured RESULT_FILE that each
simulation writes (key=value lines emitted by its_base_test::write_result_file).
This runner never greps the simulator log to decide pass/fail, so a wording
change in a UVM message cannot silently flip a result.

Actions required by the plan (D5 84-87):
  * case list externalised  -> cases.json
  * coverage merged         -> bin union across runs
  * failures auto-classified

Status vocabulary follows the plan: SKIP is INCOMPLETE, dirty or missing data is
never PASS.

Usage:
    python run_regress.py prep
    python run_regress.py run [--only a,b]
    python run_regress.py all
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import run_its_uvm as env_mod  # noqa: E402  (shares tools, paths and prep)

OUT = HERE / "run"
RESULT_DIR = OUT / "results"
CASES = HERE / "cases.json"

# Coverage bin layout, kept next to the emitter so both sides agree.
CG_TOTALS = {
    "shape": 25,
    "xform": 9,
    "lfnst_mode": 3,
    "lfnst_idx": 4,
    "sat": 3,
    "backpressure": 4,
    "stall_phase": 6,
}


def load_cases(path=None):
    # utf-8-sig tolerates a BOM, which editors and PowerShell add silently and
    # which json.loads rejects outright.
    data = json.loads((path or CASES).read_text(encoding="utf-8-sig"))
    defaults = data.get("defaults", {})
    cases = []
    for c in data["cases"]:
        merged = {"timeout_s": defaults.get("timeout_s", 900),
                  "plusargs": []}
        merged.update(c)
        expect = dict(defaults.get("expect", {}))
        here = c.get("expect", {})
        # A case that asks for a minimum count is overriding the inherited exact
        # expectation; keeping both would make the exact check win and fail.
        for key in list(expect):
            if key + "_min" in here:
                del expect[key]
        expect.update(here)
        merged["expect"] = expect
        cases.append(merged)
    return data.get("vector_file", "unified_gate_c_vectors.txt"), cases


def parse_result(path):
    """Read the structured result. Returns (dict, error_string_or_None)."""
    if not path.exists():
        return {}, "RESULT_MISSING"
    fields = {}
    dupes = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, _, value = line.partition("=")
        if key in fields:
            dupes.append(key)
        fields[key] = value
    if not fields:
        return {}, "RESULT_EMPTY"
    if dupes:
        return fields, "RESULT_DUPLICATE_KEY:" + ",".join(sorted(set(dupes)))
    return fields, None


def as_int(fields, key):
    v = fields.get(key)
    if v is None:
        return None
    try:
        return int(v)
    except ValueError:
        return None


def classify(fields, expect, parse_error):
    """Map a structured result to a status plus a failure class."""
    if parse_error == "RESULT_MISSING":
        return "INCOMPLETE", "NO_RESULT_FILE"
    if parse_error == "RESULT_EMPTY":
        return "INCOMPLETE", "EMPTY_RESULT_FILE"
    if parse_error:
        return "DIRTY", parse_error

    required = ("test", "tus", "beats", "uvm_error", "uvm_fatal")
    for key in required:
        if key not in fields:
            return "DIRTY", f"MISSING_FIELD:{key}"

    if as_int(fields, "uvm_fatal") not in (0, None):
        return "FAIL", "UVM_FATAL"

    # Error-count expectations, both exact and minimum forms.
    if "uvm_error" in expect:
        if as_int(fields, "uvm_error") != expect["uvm_error"]:
            return "FAIL", "UVM_ERROR_COUNT"
    if "uvm_error_min" in expect:
        got = as_int(fields, "uvm_error") or 0
        if got < expect["uvm_error_min"]:
            return "FAIL", "EXPECTED_ERROR_MISSING"

    for key in ("data_errors", "done_errors", "protocol_errors", "unexpected", "pending"):
        if key in expect:
            if as_int(fields, key) != expect[key]:
                return "FAIL", f"{key.upper()}_MISMATCH"
        elif key in ("data_errors", "pending"):
            # A clean run must not leak either, unless the case explicitly asks
            # for a minimum (negative controls expect mismatches on purpose).
            if (key + "_min") in expect:
                continue
            if (as_int(fields, key) or 0) != 0:
                return "FAIL", f"{key.upper()}_NONZERO"

    for key in ("tus", "beats"):
        if key in expect and as_int(fields, key) != expect[key]:
            return "FAIL", f"{key.upper()}_MISMATCH"

    for key in ("data_errors_min", "protocol_errors_min"):
        base = key.replace("_min", "")
        if key in expect:
            if (as_int(fields, base) or 0) < expect[key]:
                return "FAIL", f"{base.upper()}_NOT_OBSERVED"

    if "overlap_min" in expect:
        if (as_int(fields, "overlap") or 0) < expect["overlap_min"]:
            return "FAIL", "OVERLAP_NOT_OBSERVED"

    return "PASS", ""


def coverage_bins(fields):
    """Extract cg.<group>.<bin> counters into {group: {bin: count}}."""
    out = {}
    for key, value in fields.items():
        if not key.startswith("cg."):
            continue
        parts = key.split(".")
        if len(parts) != 3:
            continue
        group, binn = parts[1], parts[2]
        try:
            n = int(value)
        except ValueError:
            continue
        out.setdefault(group, {})[binn] = n
    return out


def merge_coverage(per_run):
    """Union of hit bins across runs, reported per group."""
    merged = {}
    for bins in per_run:
        for group, hits in bins.items():
            acc = merged.setdefault(group, {})
            for binn, n in hits.items():
                acc[binn] = acc.get(binn, 0) + n
    report = {}
    total_hit = total_bins = 0
    for group, hits in merged.items():
        total = CG_TOTALS.get(group)
        hit_bins = sum(1 for n in hits.values() if n > 0)
        if total:
            report[group] = {
                "hit_bins": hit_bins,
                "total_bins": total,
                "pct": round(100.0 * hit_bins / total, 2),
            }
            total_hit += hit_bins
            total_bins += total
    if total_bins:
        # Flat bin-hit ratio over all groups.  This weighting differs from
        # a covergroup's get_coverage() on partial runs, but the two agree at
        # 100%, and a flat ratio is the only well-defined way to combine runs.
        report["_overall"] = {
            "hit_bins": total_hit,
            "total_bins": total_bins,
            "pct": round(100.0 * total_hit / total_bins, 2),
        }
    return report


def run_one(case, vector_file):
    RESULT_DIR.mkdir(parents=True, exist_ok=True)
    res_path = RESULT_DIR / f"{case['name']}.result"
    log_path = OUT / "logs" / f"regress_{case['name']}.log"
    if res_path.exists():
        res_path.unlink()

    cmd = [env_mod.VSIM, "-batch", "-t", "1ps", "+UVM_NO_DPI", "-voptargs=+acc"]
    cmd += [f"+UVM_TESTNAME={case['testname']}"]
    cmd += [f"+{p}" for p in case["plusargs"]]
    cmd += [f"+RESULT_FILE={res_path}"]
    cmd += [f"-gVECTOR_FILE={OUT / vector_file}"]
    cmd += ["-do", "run -all; quit -f", "work.its_uvm_tb"]

    t0 = time.time()
    rc, _ = env_mod.run(cmd, log_path, OUT, case["timeout_s"])
    elapsed = time.time() - t0

    fields, parse_error = parse_result(res_path)
    if rc != 0 and parse_error is None:
        status, reason = classify(fields, case["expect"], parse_error)
        if status == "PASS":
            status, reason = "DIRTY", "NONZERO_EXIT_WITH_CLEAN_RESULT"
    else:
        status, reason = classify(fields, case["expect"], parse_error)
        if status == "INCOMPLETE" and elapsed >= case["timeout_s"] - 1:
            status, reason = "INCOMPLETE", "TIMEOUT"

    return {
        "name": case["name"],
        "testname": case["testname"],
        "status": status,
        "reason": reason,
        "elapsed_s": round(elapsed, 1),
        "returncode": rc,
        "fields": {k: v for k, v in fields.items() if not k.startswith("cg.")},
        "coverage": coverage_bins(fields),
    }


def stage_prep():
    env_mod.stage_prep()


def stage_run(only, cases_path=None):
    vector_file, cases = load_cases(cases_path)
    sel = [c for c in cases if not only or c["name"] in only]
    skipped = [c["name"] for c in cases if only and c["name"] not in only]

    print(f"[regress] {len(sel)} case(s) from cases.json", flush=True)
    rows = []
    for case in sel:
        print(f"  [{case['name']}] ...", end=" ", flush=True)
        r = run_one(case, vector_file)
        rows.append(r)
        extra = ""
        f = r["fields"]
        if f:
            extra = f" tus={f.get('tus')} beats={f.get('beats')} err={f.get('uvm_error')}"
        print(f"{r['status']}{('/', r['reason']) if r['reason'] else ''}{extra}"
              f" ({r['elapsed_s']:.0f}s)", flush=True)

    merged = merge_coverage([r["coverage"] for r in rows])

    # SKIP is INCOMPLETE, per the plan: an unexecuted case is not a pass.
    for name in skipped:
        rows.append({"name": name, "status": "INCOMPLETE", "reason": "SKIPPED",
                     "elapsed_s": 0.0, "returncode": None, "fields": {},
                     "coverage": {}})

    counts = {}
    for r in rows:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    fails = [r for r in rows if r["status"] not in ("PASS",)]
    classes = {}
    for r in fails:
        classes[r["reason"]] = classes.get(r["reason"], 0) + 1

    summary = {
        "cases": rows,
        "status_counts": counts,
        "failure_classes": classes,
        "merged_coverage": merged,
        "vector_file": vector_file,
    }
    (OUT / "REGRESSION.json").write_text(json.dumps(summary, indent=2),
                                         encoding="utf-8")

    print("\n=== status ===")
    for k in sorted(counts):
        print(f"  {k:<12} {counts[k]}")
    if classes:
        print("=== failure classes ===")
        for k in sorted(classes):
            print(f"  {k:<28} {classes[k]}")
    print("=== merged functional coverage ===")
    for group in sorted(merged):
        m = merged[group]
        if group == "_overall":
            continue
        print(f"  {group:<14} {m['pct']:6.2f}%  bins={m['hit_bins']}/{m['total_bins']}")
    ov = merged.get("_overall")
    if ov:
        print(f"  {'OVERALL':<14} {ov['pct']:6.2f}%  bins={ov['hit_bins']}/{ov['total_bins']}")
    ok = counts.get("PASS", 0)
    print(f"\nsummary: {ok}/{len(rows)} PASS")
    return 0 if ok == len(rows) else 1


def stage_selftest():
    """Prove the classifier can produce every status, without the simulator.

    Without this, "failures are classified" is only a claim: all seven real
    cases pass, so the failure paths would never execute.
    """
    cases = [
        # (label, fields, expect, parse_error, wanted_status, wanted_reason)
        ("clean",
         {"test": "t", "tus": "1", "beats": "4", "uvm_error": "0",
          "uvm_fatal": "0", "data_errors": "0", "pending": "0"},
         {"uvm_error": 0, "tus": 1}, None, "PASS", ""),
        ("fatal",
         {"test": "t", "tus": "1", "beats": "4", "uvm_error": "0",
          "uvm_fatal": "1"},
         {"uvm_fatal": 0}, None, "FAIL", "UVM_FATAL"),
        ("error count",
         {"test": "t", "tus": "1", "beats": "4", "uvm_error": "3",
          "uvm_fatal": "0"},
         {"uvm_error": 0}, None, "FAIL", "UVM_ERROR_COUNT"),
        ("expected error missing",
         {"test": "t", "tus": "1", "beats": "4", "uvm_error": "0",
          "uvm_fatal": "0"},
         {"uvm_error_min": 1}, None, "FAIL", "EXPECTED_ERROR_MISSING"),
        ("beat count",
         {"test": "t", "tus": "1", "beats": "3", "uvm_error": "0",
          "uvm_fatal": "0"},
         {"beats": 4}, None, "FAIL", "BEATS_MISMATCH"),
        ("no result file", {}, {}, "RESULT_MISSING", "INCOMPLETE",
         "NO_RESULT_FILE"),
        ("empty result file", {}, {}, "RESULT_EMPTY", "INCOMPLETE",
         "EMPTY_RESULT_FILE"),
        ("duplicate key", {"test": "t", "tus": "1"},
         {}, "RESULT_DUPLICATE_KEY:tus", "DIRTY", "RESULT_DUPLICATE_KEY:tus"),
        ("missing field",
         {"test": "t", "tus": "1", "beats": "4"}, {}, None, "DIRTY",
         "MISSING_FIELD:uvm_error"),
    ]
    bad = 0
    print("[selftest] classifier behaviour", flush=True)
    for label, fields, expect, perr, want_status, want_reason in cases:
        status, reason = classify(fields, expect, perr)
        ok = (status == want_status and reason == want_reason)
        if not ok:
            bad += 1
        print(f"  {'ok ' if ok else 'BAD'} {label:<24} -> {status}"
              f"{('/' + reason) if reason else ''}"
              f"   want {want_status}{('/' + want_reason) if want_reason else ''}",
              flush=True)

    # Coverage merge must union bins across runs, not average them.
    merged = merge_coverage([
        {"shape": {"0_0": 1, "0_1": 0}},
        {"shape": {"0_0": 0, "0_1": 2}},
    ])
    m = merged.get("shape", {})
    ok = (m.get("hit_bins") == 2)
    if not ok:
        bad += 1
    print(f"  {'ok ' if ok else 'BAD'} merge unions bins      -> "
          f"hit={m.get('hit_bins')} pct={m.get('pct')}  want hit=2", flush=True)

    print(f"\nselftest: {'PASS' if bad == 0 else 'FAIL'} "
          f"({len(cases) + 1 - bad}/{len(cases) + 1})")
    return 0 if bad == 0 else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stage", choices=["prep", "run", "all", "selftest"])
    ap.add_argument("--only", default="")
    ap.add_argument("--cases", default="",
                    help="alternate case list (used to prove failure classification)")
    args = ap.parse_args()
    only = {s for s in args.only.split(",") if s}
    cases_path = Path(args.cases) if args.cases else None
    if args.stage == "selftest":
        return stage_selftest()
    if args.stage in ("prep", "all"):
        stage_prep()
    if args.stage in ("run", "all"):
        return stage_run(only, cases_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())