#!/usr/bin/env python
"""D5 regression runner for the ITS UVM layer.

Verdict sources, in order of precedence:

  1. the structured RESULT_FILE (key=value lines from write_result_file);
  2. the simulator log, for *native* diagnostics only (** Error / ** Fatal /
     ** Assertion).  A native $error never changes the exit code and never
     reaches the UVM report server, so a run can be clean in the result file and
     still have failed an RTL assertion.  Log scanning therefore covers the
     native channel; it is never used to second-guess a structured field.
  3. the exit code and the timeout.

The log scan normalises the leading "# " that ModelSim puts on every echoed
line before it looks for a diagnostic, and it excludes the summary line
"# Errors: N, Warnings: M", command echoes and source references, which would
otherwise be counted as failures.

Usage:
    python run_regress.py prep
    python run_regress.py run [--only a,b]
    python run_regress.py all
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import run_its_uvm as env_mod  # noqa: E402  (shares tools, paths and prep)

OUT = HERE / "run"
RESULT_DIR = OUT / "results"
UCDB_DIR = OUT / "ucdb"
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

# Everything a verdict depends on.  If any of these changes, a stored result is
# no longer evidence about the current tree, so the manifest records all of them.
ROOT = HERE.parent.parent
FINGERPRINT_FILES = [
    ROOT / "02_rtl/rtl/unified_its_wrapper.sv",
    ROOT / "02_rtl/rtl/unified_p4_kernel.sv",
    HERE / "its_uvm_pkg.sv",
    HERE / "its_uvm_tb.sv",
    HERE / "its_if.sv",
    HERE / "cases.json",
    HERE / "run_regress.py",
    HERE / "run_its_uvm.py",
    HERE / "a5_selftest.py",
    HERE / "its_check_selftest_tb.sv",
    OUT / "unified_gate_c_vectors.txt",
    ROOT / "03_verification/sim/rom_coeffs.hex",
    ROOT / "03_verification/sim/lfnst_coeffs.hex",
    ROOT / "03_verification/sim/lfnst_packed_coeffs.hex",
]


def _validate_expect(name, expect):
    """Fail early on an expectation that names a counter nobody produces."""
    def walk(val, where):
        if isinstance(val, dict):
            for k, v in val.items():
                walk(v, f"{where}.{k}")
        elif isinstance(val, (list, tuple)):
            for v in val:
                walk(v, where)
        elif isinstance(val, str) and val.startswith("@"):
            if val[1:] not in REQUIRED_FIELDS:
                raise SystemExit(f"{name}: {where} names unknown counter {val}")

    for key, val in expect.items():
        walk(val, f"expect.{key}")


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
        # An id-level expectation subsumes the severity total: the counts must
        # add up to it, and that consistency is checked separately.
        if "uvm_error_ids" in here:
            expect.pop("uvm_error", None)
        expect.update(here)
        merged["expect"] = expect
        _validate_expect(merged["name"], expect)
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


COUNT_RE = re.compile(r"^\d+$")


def sha256_file(path):
    if not path.exists():
        return "absent"
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fingerprint():
    """Hash every input a verdict depends on: RTL, TB, vectors, judge scripts."""
    files = {}
    for p in FINGERPRINT_FILES:
        try:
            key = str(p.relative_to(ROOT))
        except ValueError:
            key = str(p)
        files[key] = sha256_file(p)
    digest = hashlib.sha256(
        "".join(f"{k}={v};" for k, v in sorted(files.items())).encode()
    ).hexdigest()
    return {"files": files, "digest": digest}


_RUN_SEQ = 0


def new_run_id(case_name):
    """Unique per run, not just per case: two runs of one case must differ."""
    global _RUN_SEQ
    _RUN_SEQ += 1
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    return f"{stamp}-{os.getpid()}-{_RUN_SEQ:03d}-{case_name}"


DIAG_RE = re.compile(
    r"^\s*(?:#\s*)?(\*\*\s*(Error|Fatal|Assertion))(?: \(suppressible\))?\s*:\s*(.*)$"
)
SUMMARY_RE = re.compile(r"^\s*(?:#\s*)?Errors:\s*\d+,\s*Warnings:\s*\d+\s*$")
SUMMARY_VAL_RE = re.compile(r"Errors:\s*(\d+),\s*Warnings:\s*(\d+)")
UVM_LINE_RE = re.compile(r"^\s*(?:#\s*)?(UVM_ERROR|UVM_FATAL)\b")
# The report summary prints "UVM_ERROR :    0" per severity.  That is a count,
# not a diagnostic, and counting it would mark every clean run as failing.
UVM_SUMMARY_RE = re.compile(
    r"^\s*(?:#\s*)?UVM_(ERROR|FATAL|WARNING|INFO)\s*:\s*\d+\s*$")
LOG_SKIP = (
    "# vsim", "# vlog", "# vopt", "# Loading", "# ** Note", "#   File:",
    "#    Time:", "#    Scope:", "# //", "# ---", "# Start time",
    "# End time", "# run -all", "# quit", "# Errors:",
)


def scan_log(path):
    """Native diagnostics from the simulator log.

    ModelSim prefixes every echoed line with '# ', so a line-start match on
    '** Error' would miss all of them.  The summary line 'Errors: N, Warnings: M'
    and command/source echoes are excluded by construction.

    Note that a native $fatal log also contains a '$finish' line, so the
    presence of $finish is recorded but never treated as completion evidence.
    """
    info = {"native_error": 0, "native_fatal": 0, "native_assert": 0,
            "uvm_error_lines": 0, "uvm_fatal_lines": 0, "first": [],
            "saw_uvm_summary": False, "saw_finish": False,
            "summary_errors": None, "summary_warnings": None}
    if not path.exists():
        return info
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.rstrip()
        if "UVM Report Summary" in line:
            info["saw_uvm_summary"] = True
        if "$finish" in line:
            info["saw_finish"] = True
        if SUMMARY_RE.match(line):
            m = SUMMARY_VAL_RE.search(line)
            if m:
                info["summary_errors"] = int(m.group(1))
                info["summary_warnings"] = int(m.group(2))
            continue
        if UVM_SUMMARY_RE.match(line):
            continue
        if UVM_LINE_RE.match(line):
            if "UVM_ERROR" in line:
                info["uvm_error_lines"] += 1
            else:
                info["uvm_fatal_lines"] += 1
            continue
        if any(line.strip().startswith(p.strip()) for p in LOG_SKIP):
            continue
        m = DIAG_RE.match(line)
        if m:
            kind = m.group(2)
            if kind == "Fatal":
                info["native_fatal"] += 1
            elif kind == "Assertion":
                info["native_assert"] += 1
            else:
                info["native_error"] += 1
            if len(info["first"]) < 5:
                info["first"].append(f"{kind}: {m.group(3)[:100]}")
    return info


REQUIRED_FIELDS = (
    "run_id", "case", "test", "tus", "beats", "overlap", "resets",
    "data_errors", "done_errors", "protocol_errors", "unexpected", "pending",
    "uvm_error", "uvm_fatal", "sig_errors", "x_errors", "in_errors",
)
STRING_FIELDS = ("run_id", "case", "test")


def as_count(fields, key):
    """Strict non-negative integer.  Garbage must never collapse to 'absent'."""
    v = fields.get(key)
    if v is None:
        return None, f"MISSING:{key}"
    if not COUNT_RE.match(v.strip()):
        return None, f"NOT_A_COUNT:{key}={v!r}"
    return int(v), None


def resolve_num(value, counts):
    """Let an expectation name a counter: '@beats' means "as many as there were".

    A negative control is usually "every beat must mismatch", not "exactly four
    must mismatch"; the four is an observation of one vector, the beat count is
    the reason.  Binding to the counter keeps the contract causal.
    """
    if isinstance(value, str) and value.startswith("@"):
        name = value[1:]
        if name not in counts:
            raise KeyError(f"unknown counter in expectation: {name}")
        return counts[name]
    return value


def classify(fields, case, parse_error, loginfo, timed_out):
    """Map the structured result plus the native channel to a status."""
    loginfo = loginfo or {}
    expect = case["expect"]

    # -- runs without a result file still have to be judged ---------------
    # A uvm_fatal exits through UVM_EXIT (uvm_report_handler.svh:431), so
    # report_phase never runs and the result file is never written.  Without
    # this branch such a run would look like a mere missing artefact.
    if parse_error == "RESULT_MISSING":
        if timed_out:
            return "INCOMPLETE", "TIMEOUT"
        if loginfo.get("uvm_fatal_lines", 0) > 0:
            return "FAIL", "UVM_FATAL_EARLY_EXIT"
        if loginfo.get("native_fatal", 0) > 0:
            return "FAIL", "NATIVE_FATAL"
        if loginfo.get("native_error", 0) + loginfo.get("native_assert", 0) > 0:
            return "FAIL", "NATIVE_ERROR"
        if loginfo.get("summary_errors") == 0 and loginfo.get("saw_finish"):
            return "DIRTY", "FINISHED_WITHOUT_RESULT"
        return "INCOMPLETE", "NO_RESULT_FILE"
    if parse_error == "RESULT_EMPTY":
        return "INCOMPLETE", "EMPTY_RESULT_FILE"
    if parse_error:
        return "DIRTY", parse_error

    # -- native channel: a failure whatever the structured counters say ----
    if loginfo.get("native_fatal", 0) > 0:
        return "FAIL", "NATIVE_FATAL"
    allowed_native = int(expect.get("native_errors_allowed", 0))
    if loginfo.get("native_error", 0) + loginfo.get("native_assert", 0) > allowed_native:
        return "FAIL", "NATIVE_ERROR"

    # -- fields: presence and type ----------------------------------------
    for key in REQUIRED_FIELDS:
        if key not in fields:
            return "DIRTY", f"MISSING_FIELD:{key}"
    counts = {}
    for key in REQUIRED_FIELDS:
        if key in STRING_FIELDS:
            continue
        val, err = as_count(fields, key)
        if err:
            return "DIRTY", f"FIELD_FORMAT:{err}"
        counts[key] = val

    # -- identity: the file must belong to this case and this test ---------
    if fields["case"] != case["name"]:
        return "DIRTY", f"CASE_MISMATCH:file={fields['case']}"
    if fields["test"] != case["testname"]:
        return "DIRTY", f"TEST_MISMATCH:file={fields['test']}"

    # -- per-id error expectations -----------------------------------------
    actual_err = {k[len("err.error."):]: int(v) for k, v in fields.items()
                  if k.startswith("err.error.") and v.strip().isdigit()}

    # The per-id counts must add up to the severity total, and the server's own
    # total must agree with the UVM severity count.  A gap here means the
    # counting path missed a report, so no verdict can be trusted.
    if "err_server_total_error" in fields:
        tot, fmt_err = as_count(fields, "err_server_total_error")
        if fmt_err:
            return "DIRTY", f"FIELD_FORMAT:{fmt_err}"
        if tot != counts["uvm_error"] or sum(actual_err.values()) != tot:
            return "DIRTY", "ID_COUNT_MISMATCH"
    want_ids = expect.get("uvm_error_ids")
    if want_ids is not None:
        for eid, want in want_ids.items():
            got = actual_err.get(eid, 0)
            if isinstance(want, dict):
                lo = resolve_num(want.get("min", 0), counts)
                hi = resolve_num(want.get("max", 10 ** 9), counts)
            else:
                lo = hi = resolve_num(want, counts)
            if not lo <= got <= hi:
                return "FAIL", f"ERROR_ID_MISMATCH:{eid}={got}"
        if expect.get("uvm_error_exact", True):
            extra = sorted(k for k, v in actual_err.items()
                           if v > 0 and k not in want_ids)
            if extra:
                return "FAIL", "UNEXPECTED_ERROR_ID:" + ",".join(extra)

    if counts["uvm_fatal"] != 0:
        return "FAIL", "UVM_FATAL"

    # Error-count expectations, both exact and minimum forms.
    if "uvm_error" in expect:
        if counts["uvm_error"] != resolve_num(expect["uvm_error"], counts):
            return "FAIL", "UVM_ERROR_COUNT"
    if "uvm_error_min" in expect:
        if counts["uvm_error"] < resolve_num(expect["uvm_error_min"], counts):
            return "FAIL", "EXPECTED_ERROR_MISSING"

    for key in ("data_errors", "done_errors", "protocol_errors", "unexpected", "pending"):
        if key in expect:
            if counts[key] != resolve_num(expect[key], counts):
                return "FAIL", f"{key.upper()}_MISMATCH"
        elif key in ("data_errors", "pending"):
            # A clean run must not leak either, unless the case explicitly asks
            # for a minimum, or it states an exact id set: every data error
            # emits ITS_DATA_MISMATCH and every stranded TU emits
            # ITS_INCOMPLETE_TU, so the id set already forbids an undeclared leak.
            if (key + "_min") in expect or want_ids is not None:
                continue
            if counts[key] != 0:
                return "FAIL", f"{key.upper()}_NONZERO"

    # The independent protocol checks catch stimulus and handshake defects that
    # the scoreboard cannot see, so they must stay at zero unless a case states
    # a count.
    for key in ("sig_errors", "x_errors", "in_errors"):
        if counts[key] > resolve_num(int(expect.get(key, 0)), counts):
            return "FAIL", f"{key.upper()}_NONZERO"

    for key in ("tus", "beats"):
        if key in expect and counts[key] != resolve_num(expect[key], counts):
            return "FAIL", f"{key.upper()}_MISMATCH"

    # Minimum forms let a randomised case assert "at least this much ran"
    # without pinning a count that depends on the draw.
    for key in ("tus_min", "beats_min", "pending_min"):
        base = key.replace("_min", "")
        if key in expect and counts[base] < resolve_num(expect[key], counts):
            return "FAIL", f"{base.upper()}_TOO_FEW"

    for key in ("resets", "overlap"):
        if key in expect and counts[key] != resolve_num(expect[key], counts):
            return "FAIL", f"{key.upper()}_MISMATCH"

    for key in ("data_errors_min", "protocol_errors_min"):
        base = key.replace("_min", "")
        if key in expect:
            if counts[base] < resolve_num(expect[key], counts):
                return "FAIL", f"{base.upper()}_NOT_OBSERVED"

    if "overlap_min" in expect:
        if counts["overlap"] < resolve_num(expect["overlap_min"], counts):
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


def run_one(case, vector_file, want_ucdb=False, fp=None):
    RESULT_DIR.mkdir(parents=True, exist_ok=True)
    res_path = RESULT_DIR / f"{case['name']}.result"
    log_path = OUT / "logs" / f"regress_{case['name']}.log"
    ucdb = (UCDB_DIR / f"{case['name']}.ucdb") if want_ucdb else None
    if res_path.exists():
        res_path.unlink()

    # Identity is generated per run, not per case: two runs of the same case must
    # be distinguishable in the artefact set.
    run_id = new_run_id(case["name"])

    cmd = [env_mod.VSIM, "-batch", "-coverage", "-t", "1ps", "+UVM_NO_DPI",
           "-voptargs=+acc"]
    cmd += [f"+UVM_TESTNAME={case['testname']}"]
    # Raw vsim options, e.g. -sv_seed for a reproducible random draw.
    cmd += [str(a) for a in case.get("vsim_args", [])]
    cmd += [f"+{p}" for p in case["plusargs"]]
    cmd += [f"+RESULT_FILE={res_path}"]
    cmd += [f"+RUN_ID={run_id}", f"+CASE_NAME={case['name']}"]
    cmd += [f"-gVECTOR_FILE={OUT / vector_file}"]
    if ucdb is not None:
        if ucdb.exists():
            ucdb.unlink()
        ucdb.parent.mkdir(parents=True, exist_ok=True)
        cmd += ["-do", f"coverage save -testname {case['name']} -onexit {{{ucdb}}}; "
                       "run -all; quit -f"]
    else:
        cmd += ["-do", "run -all; quit -f"]
    cmd += ["work.its_uvm_tb"]

    t0 = time.time()
    rc, _ = env_mod.run(cmd, log_path, OUT, case["timeout_s"])
    elapsed = time.time() - t0
    timed_out = elapsed >= case["timeout_s"] - 1

    fields, parse_error = parse_result(res_path)
    loginfo = scan_log(log_path)
    status, reason = classify(fields, case, parse_error, loginfo, timed_out)
    if rc != 0:
        if status == "PASS":
            status, reason = "DIRTY", "NONZERO_EXIT_WITH_CLEAN_RESULT"
        elif reason in ("NO_RESULT_FILE", "FINISHED_WITHOUT_RESULT"):
            # The simulator itself failed to produce evidence.
            status, reason = "FAIL", "SIMULATOR_ERROR"

    missing = [str(p) for p in FINGERPRINT_FILES if not p.exists()]
    return {
        "name": case["name"],
        "testname": case["testname"],
        "run_id": run_id,
        "status": status,
        "reason": reason,
        "elapsed_s": round(elapsed, 1),
        "returncode": rc,
        "timed_out": timed_out,
        "log": {
            "native_error": loginfo["native_error"],
            "native_fatal": loginfo["native_fatal"],
            "native_assert": loginfo["native_assert"],
            "uvm_error_lines": loginfo["uvm_error_lines"],
            "uvm_fatal_lines": loginfo["uvm_fatal_lines"],
            "saw_uvm_summary": loginfo["saw_uvm_summary"],
            "saw_finish": loginfo["saw_finish"],
            "summary_errors": loginfo["summary_errors"],
            "first": loginfo["first"],
        },
        "fingerprint": (fp or {}).get("digest", "unrecorded"),
        "missing_inputs": missing,
        "fields": {k: v for k, v in fields.items() if not k.startswith("cg.")},
        "coverage": coverage_bins(fields),
    }


def write_manifest(rows, fp, path=None):
    """Start/end record for the whole regression: what ran, on what inputs."""
    path = path or (OUT / "RUN_MANIFEST.json")
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "runs": len(rows),
        "fingerprint": fp,
        "missing_inputs": [str(p) for p in FINGERPRINT_FILES if not p.exists()],
        "cases": rows,
    }
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False),
                    encoding="utf-8")
    return path


def stage_prep():
    env_mod.stage_prep()


def stage_run(only, cases_path=None):
    vector_file, cases = load_cases(cases_path)
    sel = [c for c in cases if not only or c["name"] in only]
    skipped = [c["name"] for c in cases if only and c["name"] not in only]

    print(f"[regress] {len(sel)} case(s) from cases.json", flush=True)
    fp = fingerprint()
    print(f"[regress] input fingerprint {fp['digest'][:16]}", flush=True)
    absent = [k for k, v in fp["files"].items() if v == "absent"]
    if absent:
        print(f"[regress] WARNING inputs not present: {', '.join(absent)}", flush=True)
    rows = []
    for case in sel:
        print(f"  [{case['name']}] ...", end=" ", flush=True)
        r = run_one(case, vector_file, want_ucdb=True, fp=fp)
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
        rows.append({"name": name, "run_id": None, "status": "INCOMPLETE",
                     "reason": "SKIPPED", "elapsed_s": 0.0, "returncode": None,
                     "fields": {}, "coverage": {}, "log": {}, "missing_inputs": []})

    manifest_path = write_manifest(rows, fp)
    print(f"[regress] manifest {manifest_path}", flush=True)

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
    # A complete clean record; each case overrides one field, so a missing-field
    # or format failure cannot be masked by an unrelated absence.
    def clean(**over):
        f = {"run_id": "r1", "case": "c1", "test": "t1",
             "tus": "1", "beats": "4", "overlap": "0", "resets": "0",
             "data_errors": "0", "done_errors": "0", "protocol_errors": "0",
             "unexpected": "0", "pending": "0", "uvm_error": "0",
             "uvm_fatal": "0", "sig_errors": "0", "x_errors": "0",
             "in_errors": "0"}
        f.update({k: str(v) for k, v in over.items()})
        return f

    def mk_case(**expect):
        return {"name": "c1", "testname": "t1", "expect": expect}

    def no_log(**over):
        d = {"native_error": 0, "native_fatal": 0, "native_assert": 0,
             "uvm_error_lines": 0, "uvm_fatal_lines": 0, "first": [],
             "saw_uvm_summary": True, "saw_finish": True,
             "summary_errors": 0, "summary_warnings": 0}
        d.update(over)
        return d

    cases = [
        # (label, fields, case, parse_error, loginfo, timed_out,
        #  wanted_status, wanted_reason)
        ("clean", clean(), mk_case(uvm_error=0, tus=1), None, no_log(), False,
         "PASS", ""),
        ("fatal counter", clean(uvm_fatal=1), mk_case(), None, no_log(), False,
         "FAIL", "UVM_FATAL"),
        ("error count", clean(uvm_error=3), mk_case(uvm_error=0), None,
         no_log(), False, "FAIL", "UVM_ERROR_COUNT"),
        ("expected error missing", clean(), mk_case(uvm_error_min=1), None,
         no_log(), False, "FAIL", "EXPECTED_ERROR_MISSING"),
        ("error id match", dict(clean(uvm_error=2),
                                **{"err.error.ITS_DATA_MISMATCH": "2"}),
         mk_case(uvm_error=2, uvm_error_ids={"ITS_DATA_MISMATCH": 2}), None,
         no_log(), False, "PASS", ""),
        ("error id count off",
         dict(clean(uvm_error=2), **{"err.error.ITS_DATA_MISMATCH": "1"}),
         mk_case(uvm_error=2, uvm_error_ids={"ITS_DATA_MISMATCH": 2}), None,
         no_log(), False, "FAIL", "ERROR_ID_MISMATCH:ITS_DATA_MISMATCH=1"),
        ("unexpected error id",
         dict(clean(uvm_error=2), **{"err.error.ITS_DATA_MISMATCH": "1",
                                     "err.error.ITS_DONE_MISMATCH": "1"}),
         mk_case(uvm_error=2, uvm_error_ids={"ITS_DATA_MISMATCH": 1}), None,
         no_log(), False, "FAIL", "UNEXPECTED_ERROR_ID:ITS_DONE_MISMATCH"),
        ("beat count", clean(beats=3), mk_case(beats=4), None, no_log(), False,
         "FAIL", "BEATS_MISMATCH"),
        ("overlap not observed", clean(tus=4, beats=32),
         mk_case(overlap_min=1), None, no_log(), False,
         "FAIL", "OVERLAP_NOT_OBSERVED"),
        ("tus_min satisfied", clean(tus=10, beats=99), mk_case(tus_min=8), None,
         no_log(), False, "PASS", ""),
        ("tus_min violated", clean(tus=3, beats=99), mk_case(tus_min=8), None,
         no_log(), False, "FAIL", "TUS_TOO_FEW"),
        ("reset count", clean(tus=2, beats=10, resets=0), mk_case(resets=1),
         None, no_log(), False, "FAIL", "RESETS_MISMATCH"),
        # Native channel: an RTL assertion touches no structured field at all.
        ("native error in log", clean(), mk_case(uvm_error=0), None,
         no_log(native_error=1), False, "FAIL", "NATIVE_ERROR"),
        ("native error tolerated", clean(), mk_case(native_errors_allowed=1),
         None, no_log(native_error=1), False, "PASS", ""),
        ("native fatal in log", clean(), mk_case(), None,
         no_log(native_fatal=1), False, "FAIL", "NATIVE_FATAL"),
        # Missing result file: the reason must name the real cause.
        # A run that ended without the UVM summary never got as far as the
        # report phase: that is a crash, not a clean finish.
        ("no result file", {}, mk_case(), "RESULT_MISSING",
         no_log(saw_finish=False, saw_uvm_summary=False), False,
         "INCOMPLETE", "NO_RESULT_FILE"),
        # The opposite: clean summary and $finish but no artefact at all.
        ("finished but no artefact", {}, mk_case(), "RESULT_MISSING",
         no_log(), False, "DIRTY", "FINISHED_WITHOUT_RESULT"),
        ("uvm fatal early exit", {}, mk_case(), "RESULT_MISSING",
         no_log(uvm_fatal_lines=1, saw_finish=True), False,
         "FAIL", "UVM_FATAL_EARLY_EXIT"),
        ("native fatal no result", {}, mk_case(), "RESULT_MISSING",
         no_log(native_fatal=1), False, "FAIL", "NATIVE_FATAL"),
        ("timeout", {}, mk_case(), "RESULT_MISSING", no_log(), True,
         "INCOMPLETE", "TIMEOUT"),
        ("empty result file", {}, mk_case(), "RESULT_EMPTY", no_log(), False,
         "INCOMPLETE", "EMPTY_RESULT_FILE"),
        ("duplicate key", clean(), mk_case(), "RESULT_DUPLICATE_KEY:tus",
         no_log(), False, "DIRTY", "RESULT_DUPLICATE_KEY:tus"),
        ("missing field", {k: v for k, v in clean().items() if k != "uvm_error"},
         mk_case(), None, no_log(), False, "DIRTY", "MISSING_FIELD:uvm_error"),
        # "-1" used to pass as a decimal integer.
        ("negative count", clean(uvm_error="-1"), mk_case(), None, no_log(),
         False, "DIRTY", "FIELD_FORMAT:NOT_A_COUNT:uvm_error='-1'"),
        ("garbage count", clean(sig_errors="abc"), mk_case(), None, no_log(),
         False, "DIRTY", "FIELD_FORMAT:NOT_A_COUNT:sig_errors='abc'"),
        ("stale case name", clean(case="other"), mk_case(), None, no_log(),
         False, "DIRTY", "CASE_MISMATCH:file=other"),
        ("stale test name", clean(test="other"), mk_case(), None, no_log(),
         False, "DIRTY", "TEST_MISMATCH:file=other"),
        ("sig error leaked", clean(sig_errors=1), mk_case(), None, no_log(),
         False, "FAIL", "SIG_ERRORS_NONZERO"),
        ("in error leaked", clean(in_errors=1), mk_case(), None, no_log(),
         False, "FAIL", "IN_ERRORS_NONZERO"),
        # An expectation may name a counter instead of hard-coding a number.
        ("symbolic bound ok",
         dict(clean(uvm_error="4"), **{"err.error.X": "3"}),
         mk_case(uvm_error_ids={"X": {"min": 1, "max": "@beats"}}),
         None, no_log(), False, "PASS", ""),
        ("symbolic bound violated",
         dict(clean(uvm_error="1"), **{"err.error.X": "0"}),
         mk_case(uvm_error_ids={"X": {"min": 1, "max": "@beats"}}),
         None, no_log(), False, "FAIL", "ERROR_ID_MISMATCH:X=0"),
        # The per-id counts must add up to the reported severity total.
        ("id count mismatch",
         dict(clean(uvm_error="4", err_server_total_error="3"),
              **{"err.error.X": "3"}),
         mk_case(uvm_error_ids={"X": {"min": 1, "max": "@beats"}}),
         None, no_log(), False, "DIRTY", "ID_COUNT_MISMATCH"),
    ]
    bad = 0
    print("[selftest] classifier behaviour", flush=True)
    for label, fields, kase, perr, log, to, want_status, want_reason in cases:
        status, reason = classify(fields, kase, perr, log, to)
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


def stage_coverage_merge():
    """Merge every per-case UCDB and report the DUT's code coverage.

    The UVM layer previously produced no code coverage at all: the D1 baseline
    numbers came from a separate directed testbench, so nothing tied these tests
    to the RTL lines they execute.  Merging the per-case databases closes that.
    """
    vcover = env_mod.MS / "vcover.exe"
    ucbs = sorted(UCDB_DIR.glob("*.ucdb"))
    if not ucbs:
        print("[cov] no UCDB files, skipping merge", flush=True)
        return None
    merged = OUT / "uvm_merged.ucdb"
    if merged.exists():
        merged.unlink()
    rc, dt = env_mod.run([vcover, "merge", *ucbs, "-out", merged],
                         OUT / "logs/vcover_merge.log", OUT, 1800)
    print(f"[cov] merge {len(ucbs)} ucdb -> exit={rc} ({dt:.0f}s)", flush=True)
    if rc != 0:
        return None

    # Report the DUT hierarchy only.  A whole-design report prints one block per
# instance, so a flat key/value parse would silently keep the last instance's
# numbers under a name that looks like a global total.  One -du report has a
# single block, so every value below is genuinely the DUT's.
    out = {}
    rpt = OUT / "coverage_uvm_dut.txt"
    env_mod.run([vcover, "report", "-du=unified_its_wrapper",
                 "-output", rpt, merged],
                OUT / "logs/vcover_report_dut.log", OUT, 1800)
    if rpt.exists():
        text = rpt.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            parts = line.split()
            if len(parts) < 5 or not parts[-1].endswith("%"):
                continue
            if parts[0] in ("Statements", "Branches", "Conditions",
                            "Expressions", "Toggles", "Assertions"):
                out[parts[0]] = parts[-1]
            elif parts[0] == "FSM" and len(parts) >= 6:
                out[f"FSM {parts[1]}"] = parts[-1]
    for k in sorted(out):
        print(f"[cov] dut {k:<20} {out[k]}", flush=True)
    # Persist as JSON too: the vcover text report is human-readable but a
    # regression gate cannot diff against it.
    ucdbs = sorted(p.name for p in (OUT / "ucdb").glob("*.ucdb"))
    (OUT / "COVERAGE_CODE.json").write_text(
        json.dumps({"dut": "unified_its_wrapper",
                    "ucdbs": len(ucdbs),
                    "ucdb_files": ucdbs,
                    "metrics": out}, indent=2, ensure_ascii=False),
        encoding="utf-8")
    print(f"[cov] wrote run/COVERAGE_CODE.json ({len(ucdbs)} ucdb)", flush=True)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stage", choices=["prep", "run", "all", "selftest", "coverage"])
    ap.add_argument("--only", default="")
    ap.add_argument("--cases", default="",
                    help="alternate case list (used to prove failure classification)")
    args = ap.parse_args()
    only = {s for s in args.only.split(",") if s}
    cases_path = Path(args.cases) if args.cases else None
    if args.stage == "selftest":
        return stage_selftest()
    if args.stage == "coverage":
        return 0 if stage_coverage_merge() else 1
    if args.stage in ("prep", "all"):
        stage_prep()
    if args.stage in ("run", "all"):
        return stage_run(only, cases_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())