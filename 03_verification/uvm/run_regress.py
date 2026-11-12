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
#
# The compiled sources are taken from the compile list itself rather than
# repeated here: a hand-written list already drifted once, omitting three RTL
# files that the simulator really compiles, so a change there could not
# invalidate a stored result.  One source of truth, no second copy to forget.
ROOT = HERE.parent.parent
FINGERPRINT_FILES = list(env_mod.RTL) + list(env_mod.SRC) + [
    HERE / "cases.json",
    HERE / "run_regress.py",
    HERE / "run_its_uvm.py",
    HERE / "a5_selftest.py",
    HERE / "a5_final_fatal.py",
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
    # The guard counter is evidence like the others, and the two server totals
    # are the only cross-check on the per-id breakdown: leaving them optional
    # meant a writer could omit them and still be trusted.
    "vld_stall_guard", "err_server_total_error", "err_server_total_fatal",
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


# Written by run_its_uvm.run() only in its TimeoutExpired branch, so the marker
# is an explicit statement by the executor.  A bare rc == -9 is not: other
# abnormal terminations surface the same way.
TIMEOUT_MARK = "*** TIMEOUT after "


def _with_exit(status, reason, returncode, timed_out, parse_error):
    """Apply the exit code without overwriting a verdict the content supports.

    A definite diagnosis already earned by the content outranks a process-level
    symptom: the exit code may raise an incomplete run to a failed one, but it
    never replaces a reason that says more.  The exit code itself is kept as an
    entry in reasons by _verdict_reasons.
    """
    if returncode in (None, 0) or timed_out:
        return status, reason
    if status == "PASS":
        # A complete, readable, self-consistent record is the only situation in
        # which this label is true.
        return "DIRTY", "NONZERO_EXIT_WITH_CLEAN_RESULT"
    if status == "INCOMPLETE":
        # Nothing usable came out and the process did not end normally either:
        # the run itself failed, which says more than the artefact's shape.
        return "FAIL", "SIMULATOR_ERROR"
    return status, reason


# Findings that a write cut short can produce: a field that never made it to
# disk, an empty value on the last line, a line cut in half, or id sums that
# disagree because a line is missing.  During a timeout these are symptoms, so
# they downgrade the verdict to "incomplete" rather than "the writer is broken".
TORN_FINDINGS = ("MISSING_FIELD:", "FIELD_FORMAT:", "RESULT_",
                 "ID_COUNT_MISMATCH", "FATAL_ID_COUNT_MISMATCH")
# Findings a torn write cannot produce: a complete identity triple naming
# another run, or a complete value that is not a number.  Those stand even
# during a timeout, because the file had to be readable to say them at all.
FIRM_FINDINGS = ("RUN_ID_MISMATCH:", "CASE_MISMATCH:", "TEST_MISMATCH:")


def _torn(reason):
    """True when an interrupted write could explain this finding."""
    if not reason:
        return False
    for prefix in FIRM_FINDINGS:
        if reason.startswith(prefix):
            return False
    if reason.startswith("FIELD_FORMAT:"):
        # An empty value is what a cut line leaves behind; a non-empty value
        # that does not parse is a writer bug, not a torn file.
        return reason.endswith("=''")
    for prefix in TORN_FINDINGS:
        if reason.startswith(prefix):
            return True
    return False


def _classify(fields, case, parse_error, loginfo, timed_out,
              expected_run_id=None, returncode=None):
    """Map log facts and the structured result to a status.

    The order is deliberate:

      1. definite failures read from the log - they hold whatever the artefact
         looks like, and nothing below may downgrade them;
      2. contradictions that are legible and attributable on their own are
         collected next, so the ordered checks below cannot bury them: a
         duplicated key elsewhere or a cut tail does not make run_id, case,
         test or a complete-but-unparsable number unreadable;
      3. otherwise the artefact has to prove it is this run's output before any
         count in it is believed: presence, types, identity, then the id totals;
      4. only then are its counters compared with the case's expectations, so a
         stale or malformed record cannot produce a count verdict that hides
         the fact that it is not usable at all;
      5. a timeout is judged before damage that it could itself have caused;
      6. the shape decides between incomplete and dirty last.

    Returns (status, reason, extra) where extra carries findings that did not
    become the primary reason but must still reach the reason set.
    """
    loginfo = loginfo or {}
    native_errs = loginfo.get("native_error", 0) + loginfo.get("native_assert", 0)
    allowed_native = int(case["expect"].get("native_errors_allowed", 0))
    extra = []

    def done(status, reason):
        return (*_with_exit(status, reason, returncode, timed_out,
                            parse_error), extra)

    # -- 1. definite failures, whatever the artefact looks like ------------
    # A fatal can land after the result file was written: the file is produced
    # in report_phase, and final_phase still runs afterwards.  So both fatal
    # channels are checked unconditionally, and a definite failure is never
    # downgraded because a timeout or a missing file also happened.
    if loginfo.get("native_fatal", 0) > 0:
        return done("FAIL", "NATIVE_FATAL")
    if loginfo.get("uvm_fatal_lines", 0) > 0:
        # uvm_fatal exits through UVM_EXIT (uvm_report_handler.svh:431), so
        # report_phase never runs and no file is written.  When the file does
        # exist, the fatal landed after it, which is a different situation
        # worth telling apart in the record.
        return done("FAIL", "UVM_FATAL_EARLY_EXIT"
                    if parse_error == "RESULT_MISSING" else
                    "UVM_FATAL_IN_LOG")
    if native_errs > allowed_native:
        return done("FAIL", "NATIVE_ERROR")

    # -- 2. legible, attributable contradictions ---------------------------
    # Not gated on the artefact's shape: a duplicated key elsewhere, or a cut
    # tail, does not make the untouched fields any less readable.  The
    # duplicated key itself is the one thing that cannot be attributed.
    ambiguous = set()
    if parse_error and parse_error.startswith("RESULT_DUPLICATE_KEY:"):
        ambiguous = set(parse_error.split(":", 1)[1].split(","))
    firm = _firm_findings(fields, case, expected_run_id, ambiguous)

    # -- 3. the artefact, when there is a readable one ---------------------
    if parse_error is None:
        status, reason = _judge_artifact(fields, case, expected_run_id)
    elif parse_error in ("RESULT_MISSING", "RESULT_EMPTY"):
        status, reason = None, None
    else:
        # Structurally broken: nothing inside it can be used as a whole, but
        # the individual fields may still have been judged above.
        status, reason = "DIRTY", parse_error

    if firm:
        # A contradiction that is legible outranks whatever else the file is.
        for label in firm[1:]:
            extra.append(label)
        if reason and reason not in firm:
            extra.append(reason)
        return done("DIRTY", firm[0])

    if status is not None and status != "PASS":
        if timed_out and _torn(reason):
            # The file was cut while the run was being killed, so what it
            # is missing says nothing about the writer.
            extra.append(reason)
            return "INCOMPLETE", "TIMEOUT", extra
        return done(status, reason)

    # -- 4. timeout before the artefact's shape ----------------------------
    if timed_out:
        return "INCOMPLETE", "TIMEOUT", extra

    # -- 5. shape ----------------------------------------------------------
    if parse_error == "RESULT_MISSING":
        if loginfo.get("summary_errors") == 0 and loginfo.get("saw_finish"):
            return done("DIRTY", "FINISHED_WITHOUT_RESULT")
        return done("INCOMPLETE", "NO_RESULT_FILE")
    if parse_error == "RESULT_EMPTY":
        return done("INCOMPLETE", "EMPTY_RESULT_FILE")
    return done("PASS", "")


DYNAMIC_COUNT_PREFIXES = ("err.error.", "err.fatal.")


def _count_keys(fields):
    """Every field the verdict reads as a number: fixed ones and per-id ones."""
    keys = [k for k in REQUIRED_FIELDS if k not in STRING_FIELDS]
    keys.extend(k for k in fields if k.startswith(DYNAMIC_COUNT_PREFIXES))
    return keys


def _firm_findings(fields, case, expected_run_id=None, ambiguous=()):
    """Contradictions that are legible and attributable on their own.

    _judge_artifact stops at the first absent field, so on a torn file the
    identity block below it is never reached - yet run_id, case and test are
    the first three lines and are exactly what survives a cut.  Comparing them
    on their own keeps a readable contradiction from being hidden behind a
    truncation symptom.

    Two things stay out of scope:
      * an empty value, because that is what a cut line leaves behind;
      * a key named in `ambiguous` - a duplicated key kept only its last value,
        so it cannot be attributed.  Duplicating tus says nothing about run_id,
        and a duplicated run_id is not compared at all.
    """
    out = []
    skip = set(ambiguous)

    def add(label):
        if label not in out:
            out.append(label)

    if "run_id" not in skip:
        rid = fields.get("run_id")
        if (expected_run_id is not None and rid not in (None, "")
                and rid != expected_run_id):
            add(f"RUN_ID_MISMATCH:file={rid}")
    if "case" not in skip:
        name = fields.get("case")
        if name not in (None, "") and name != case["name"]:
            add(f"CASE_MISMATCH:file={name}")
    if "test" not in skip:
        testname = fields.get("test")
        if testname not in (None, "") and testname != case["testname"]:
            add(f"TEST_MISMATCH:file={testname}")
    for key in _count_keys(fields):
        if key in skip:
            continue
        raw = fields.get(key)
        if raw in (None, ""):
            continue
        _val, err = as_count(fields, key)
        if err:
            add(f"FIELD_FORMAT:{err}")
    return out


def _judge_artifact(fields, case, expected_run_id=None):
    """Judge a parsed artefact: trust first, then the counters.

    Every check here reads a file that already parsed, so the first block is
    about whether this file may be believed at all.
    """
    expect = case["expect"]

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

    # -- identity: the file must belong to this case, this test, this run ---
    # run_id is minted per run, so a stale artefact cannot pass as this run's
    # output even when the case and test names happen to match.
    if expected_run_id is not None and fields["run_id"] != expected_run_id:
        return "DIRTY", f"RUN_ID_MISMATCH:file={fields['run_id']}"
    if fields["case"] != case["name"]:
        return "DIRTY", f"CASE_MISMATCH:file={fields['case']}"
    if fields["test"] != case["testname"]:
        return "DIRTY", f"TEST_MISMATCH:file={fields['test']}"

    # -- per-id error expectations -----------------------------------------
    # Every id entry must parse.  Filtering the malformed ones out would let a
    # broken writer add arbitrary junk and still be judged, so a bad value is a
    # dirty artefact rather than something to skip.
    actual_err, actual_fat = {}, {}
    for key in fields:
        for prefix, sink in (("err.error.", actual_err),
                             ("err.fatal.", actual_fat)):
            if key.startswith(prefix):
                cnt, bad = as_count(fields, key)
                if bad:
                    return "DIRTY", f"FIELD_FORMAT:{bad}"
                sink[key[len(prefix):]] = cnt

    # The per-id counts must add up to the server's own total, and that total
    # must agree with the UVM severity count.  A gap here means the counting
    # path missed a report, so no verdict can be trusted.  Both totals are
    # required fields, so an omission is caught before this point.
    tot, fmt_err = as_count(fields, "err_server_total_error")
    if fmt_err:
        return "DIRTY", f"FIELD_FORMAT:{fmt_err}"
    if tot != counts["uvm_error"] or sum(actual_err.values()) != tot:
        return "DIRTY", "ID_COUNT_MISMATCH"
    ftot, ffmt_err = as_count(fields, "err_server_total_fatal")
    if ffmt_err:
        return "DIRTY", f"FIELD_FORMAT:{ffmt_err}"
    if ftot != counts["uvm_fatal"] or sum(actual_fat.values()) != ftot:
        return "DIRTY", "FATAL_ID_COUNT_MISMATCH"
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
    # a count.  vld_stall_guard belongs here too: a non-zero guard with no
    # matching ITS_VLD_STALL error means one of the two counting paths is
    # broken, which is exactly what this cross-check exists to catch.
    for key in ("sig_errors", "x_errors", "in_errors", "vld_stall_guard"):
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


# The two labels an abnormal exit can become the primary reason for.
EXIT_DERIVED_LABELS = ("SIMULATOR_ERROR", "NONZERO_EXIT_WITH_CLEAN_RESULT")


def _verdict_reasons(status, reason, case, loginfo, parse_error, timed_out,
                     returncode=None, extra=()):
    """Every fact that independently justifies a non-PASS verdict.

    This is the verdict reason set, not the full set of counters the run
    printed: the diagnostic counts stay in log/fields, which is where a reader
    who wants every observed number should look.  Declared diagnostics - the
    UVM_ERROR lines a negative case expects - are not verdict reasons and do
    not appear here.
    """
    if status == "PASS":
        return []
    loginfo = loginfo or {}
    allowed = int(case["expect"].get("native_errors_allowed", 0))
    out = []

    def add(label):
        if label and label not in out:
            out.append(label)

    add(reason)
    if loginfo.get("native_fatal", 0) > 0:
        add("NATIVE_FATAL")
    if loginfo.get("uvm_fatal_lines", 0) > 0:
        add("UVM_FATAL_EARLY_EXIT" if parse_error == "RESULT_MISSING"
            else "UVM_FATAL_IN_LOG")
    if loginfo.get("native_error", 0) + loginfo.get("native_assert", 0) > allowed:
        add("NATIVE_ERROR")
    # The exit code decided nothing when it is already the primary reason (as
    # either of those two labels); otherwise it is a fact that still has to
    # appear in the record - and only once.
    if (returncode not in (None, 0) and not timed_out
            and reason not in EXIT_DERIVED_LABELS):
        add("NONZERO_EXIT")
    if timed_out:
        add("TIMEOUT")
    for label in extra:
        add(label)
    return out


def classify(fields, case, parse_error, loginfo, timed_out,
             expected_run_id=None, returncode=None):
    """Verdict, primary reason, and the reasons that justified it.

    The first two elements keep the old shape so existing callers are
    unaffected.
    """
    status, reason, extra = _classify(fields, case, parse_error, loginfo,
                                      timed_out, expected_run_id, returncode)
    return status, reason, _verdict_reasons(status, reason, case, loginfo,
                                            parse_error, timed_out, returncode,
                                            extra)


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


def run_one(case, vector_file, want_ucdb=False, fp=None, extra_plusargs=(),
            artifact_name=None, result_dir=None):
    # A probe that reuses a case's artefact name overwrites the regression's
    # evidence: the manifest records a sha256 that no longer matches the file on
    # disk.  Probes therefore pass their own name and directory and leave the
    # regression artefact set untouched.
    tag = artifact_name or case["name"]
    rdir = result_dir or RESULT_DIR
    rdir.mkdir(parents=True, exist_ok=True)
    res_path = rdir / f"{tag}.result"
    log_path = OUT / "logs" / f"regress_{tag}.log"
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
    # Probe-only extra plusargs, used by the A5 counterexamples; a normal
    # regression run passes none.
    cmd += [f"+{p}" for p in extra_plusargs]
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
    # The executor's own marker, written only when it had to kill the run for
    # being too slow.  Deriving this from the elapsed time would call a run that
    # finished just under the limit a timeout, and would miss a kill that came
    # from somewhere else.
    timed_out = TIMEOUT_MARK in log_path.read_text(encoding="utf-8",
                                                   errors="replace")

    fields, parse_error = parse_result(res_path)
    loginfo = scan_log(log_path)
    status, reason, reasons = classify(fields, case, parse_error, loginfo,
                                       timed_out, expected_run_id=run_id,
                                       returncode=rc)

    missing = [str(p) for p in FINGERPRINT_FILES if not p.exists()]
    # The artefact's own bytes: a later reader can tell whether the file it is
    # looking at is the one this record describes.
    artifact = None
    if res_path.exists():
        data = res_path.read_bytes()
        artifact = {"path": str(res_path), "bytes": len(data),
                    "sha256": hashlib.sha256(data).hexdigest()}
    return {
        "name": case["name"],
        "testname": case["testname"],
        "run_id": run_id,
        "status": status,
        "reason": reason,
        "reasons": reasons,
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
        "command": [str(c) for c in cmd],
        "artifact": artifact,
        "missing_inputs": missing,
        "fields": {k: v for k, v in fields.items() if not k.startswith("cg.")},
        "coverage": coverage_bins(fields),
    }


def write_manifest(rows, fp, path=None, start=None, end=None, planned=None):
    """Start/end record for the whole regression: what ran, on what inputs.

    Written once before the first case runs and again when the last one
    finishes.  If the process dies in between, the start record on disk still
    says what was attempted and on which inputs - a record that only appears at
    the end documents nothing about a run that never finished.
    """
    path = path or (OUT / "RUN_MANIFEST.json")
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "record": "end" if end else "start",
        "start": start or {},
        "end": end,
        "runs_completed": len(rows),
        "planned_cases": planned or [],
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

    start = {"at": datetime.now().isoformat(timespec="seconds"),
             "only": sorted(only), "cases_path": str(cases_path) if cases_path else None}
    planned = [c["name"] for c in sel]
    write_manifest([], fp, start=start, planned=planned)

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

    manifest_path = write_manifest(
        rows, fp, start=start,
        end={"at": datetime.now().isoformat(timespec="seconds")},
        planned=planned)
    print(f"[regress] manifest {manifest_path}", flush=True)

    # The manifest records the bytes each artefact held.  Confirm those bytes are
    # still on disk at the moment the run reports, so the record cannot describe
    # a truncated or replaced file.  Preventing a later overwrite is the caller's
    # job: probes write into run/probe/ under their own name.
    drift = []
    for r in rows:
        art = r.get("artifact")
        if not art:
            continue
        p = Path(art["path"])
        if not p.exists():
            drift.append(f"{r['name']}: missing")
        elif hashlib.sha256(p.read_bytes()).hexdigest() != art["sha256"]:
            drift.append(f"{r['name']}: sha256 differs")
    if drift:
        print(f"[regress] ARTEFACT DRIFT: {'; '.join(drift)}", flush=True)
    else:
        print(f"[regress] artefacts verified: {len([r for r in rows if r.get('artifact')])} files",
              flush=True)

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
        "artifact_drift": drift,
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
    print(f"\nsummary: {ok}/{len(rows)} PASS"
          f"{'   ARTEFACT DRIFT' if drift else '   artefacts verified'}")
    return 0 if (ok == len(rows) and not drift) else 1


def stage_selftest():
    """Prove the classifier can produce every status, without the simulator.

    Without this, "failures are classified" is only a claim: all seven real
    cases pass, so the failure paths would never execute.
    """
    # A complete clean record; each case overrides one field, so a missing-field
    # or format failure cannot be masked by an unrelated absence.
    def clean(ids=None, **over):
        """A complete, self-consistent record; ids carries the per-id lines.

        The record must be physically possible: the server totals follow the
        severity counts and every non-zero count has an attributable id.  Tests
        that want a malformed record say so explicitly.
        """
        f = {"run_id": "r1", "case": "c1", "test": "t1",
             "tus": "1", "beats": "4", "overlap": "0", "resets": "0",
             "data_errors": "0", "done_errors": "0", "protocol_errors": "0",
             "unexpected": "0", "pending": "0", "uvm_error": "0",
             "uvm_fatal": "0", "sig_errors": "0", "x_errors": "0",
             "in_errors": "0", "vld_stall_guard": "0",
             "err_server_total_error": "0", "err_server_total_fatal": "0"}
        f.update({k: str(v) for k, v in (ids or {}).items()})
        f.update({k: str(v) for k, v in over.items()})
        if "err_server_total_error" not in over:
            f["err_server_total_error"] = f["uvm_error"]
        if "err_server_total_fatal" not in over:
            f["err_server_total_fatal"] = f["uvm_fatal"]
        if not any(k.startswith("err.error.") for k in f) and f["uvm_error"] != "0":
            f["err.error.SYNTH"] = f["uvm_error"]
        if not any(k.startswith("err.fatal.") for k in f) and f["uvm_fatal"] != "0":
            f["err.fatal.SYNTH"] = f["uvm_fatal"]
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
        ("error id match", clean({"err.error.ITS_DATA_MISMATCH": 2}, uvm_error=2),
         mk_case(uvm_error=2, uvm_error_ids={"ITS_DATA_MISMATCH": 2}), None,
         no_log(), False, "PASS", ""),
        ("error id count off",
         clean({"err.error.ITS_DATA_MISMATCH": 1}, uvm_error=1),
         mk_case(uvm_error=1, uvm_error_ids={"ITS_DATA_MISMATCH": 2}), None,
         no_log(), False, "FAIL", "ERROR_ID_MISMATCH:ITS_DATA_MISMATCH=1"),
        ("unexpected error id",
         clean({"err.error.ITS_DATA_MISMATCH": 1,
                "err.error.ITS_DONE_MISMATCH": 1}, uvm_error=2),
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
         clean({"err.error.X": 3}, uvm_error=3),
         mk_case(uvm_error_ids={"X": {"min": 1, "max": "@beats"}}),
         None, no_log(), False, "PASS", ""),
        ("symbolic bound violated",
         clean({"err.error.X": 0}, uvm_error=0),
         mk_case(uvm_error_ids={"X": {"min": 1, "max": "@beats"}}),
         None, no_log(), False, "FAIL", "ERROR_ID_MISMATCH:X=0"),
        # The per-id counts must add up to the reported severity total.
        ("id count mismatch",
         clean({"err.error.X": 3}, uvm_error=4, err_server_total_error=3),
         mk_case(uvm_error_ids={"X": {"min": 1, "max": "@beats"}}),
         None, no_log(), False, "DIRTY", "ID_COUNT_MISMATCH"),
        # -- counterexamples for the holes an independent audit found --------
        # Every row below used to be accepted; each one is a state the old
        # classifier let through.
        ("stale run id", clean(run_id="stale-run"), mk_case(), None, no_log(),
         False, "DIRTY", "RUN_ID_MISMATCH:file=stale-run", "r1"),
        ("garbage id value",
         clean({"err.error.ITS_DATA_MISMATCH": 1,
                "err.error.BOGUS": "garbage"}, uvm_error=1),
         mk_case(uvm_error_ids={"ITS_DATA_MISMATCH": 1}), None, no_log(),
         False, "DIRTY", "FIELD_FORMAT:NOT_A_COUNT:err.error.BOGUS='garbage'"),
        ("missing server total",
         {k: v for k, v in clean().items() if k != "err_server_total_error"},
         mk_case(), None, no_log(), False, "DIRTY",
         "MISSING_FIELD:err_server_total_error"),
        ("fatal id total mismatch",
         clean({"err.fatal.X": 1}, uvm_fatal=0, err_server_total_fatal=1),
         mk_case(), None, no_log(), False, "DIRTY", "FATAL_ID_COUNT_MISMATCH"),
        ("guard counter leaked", clean(vld_stall_guard=1), mk_case(), None,
         no_log(), False, "FAIL", "VLD_STALL_GUARD_NONZERO"),
        ("guard counter declared", clean(vld_stall_guard=1),
         mk_case(vld_stall_guard=1), None, no_log(), False, "PASS", ""),
        # A fatal after the result file was written (final_phase) must fail:
        # the artefact exists, so the old code never looked at the log.
        ("fatal after result file", clean(), mk_case(), None,
         no_log(uvm_fatal_lines=1), False, "FAIL", "UVM_FATAL_IN_LOG"),
        # A definite native failure outranks "the artefact was empty".
        ("empty result plus native fatal", {}, mk_case(), "RESULT_EMPTY",
         no_log(native_fatal=1), False, "FAIL", "NATIVE_FATAL"),
        # A definite native error outranks a timeout; both are kept.
        ("timeout plus native error", {}, mk_case(), "RESULT_MISSING",
         no_log(native_error=1), True, "FAIL", "NATIVE_ERROR"),
        # -- second round: the anomalous combinations the review found --------
        # A definite failure is a fact about the run, not about the artefact,
        # so it holds when the artefact is empty as well.
        ("empty result plus uvm fatal", {}, mk_case(), "RESULT_EMPTY",
         no_log(uvm_fatal_lines=1), False, "FAIL", "UVM_FATAL_IN_LOG"),
        ("empty result plus native error", {}, mk_case(), "RESULT_EMPTY",
         no_log(native_error=1), False, "FAIL", "NATIVE_ERROR"),
        # A timeout is not a pass, whatever the artefact looks like.
        ("valid result plus timeout", clean(), mk_case(uvm_error=0, tus=1),
         None, no_log(), True, "INCOMPLETE", "TIMEOUT"),
        # During a timeout, a missing file is a symptom, not evidence of a
        # broken writer, so it must not be graded DIRTY.
        ("no result, finish, timeout", {}, mk_case(), "RESULT_MISSING",
         no_log(), True, "INCOMPLETE", "TIMEOUT"),
        # Four independent diagnostics: the primary decides the status, the
        # rest still have to survive into the reason set.
        ("all diagnostics at once", {}, mk_case(), "RESULT_MISSING",
         no_log(native_fatal=1, native_error=1, uvm_fatal_lines=1), True,
         "FAIL", "NATIVE_FATAL"),
        # A record that is not this run's output must not produce count
        # verdicts: the counts belong to someone else.
        ("stale run id with bad count", clean(run_id="stale-run", beats="3"),
         mk_case(beats=4), None, no_log(), False,
         "DIRTY", "RUN_ID_MISMATCH:file=stale-run", "r1"),
        # An abnormal exit with nothing to show for it is a simulator failure,
        # not a clean result with a strange status.
        ("abnormal exit, no result", {}, mk_case(), "RESULT_MISSING",
         no_log(saw_finish=False, saw_uvm_summary=False), False,
         "FAIL", "SIMULATOR_ERROR", None, 1),
        ("abnormal exit, clean result", clean(), mk_case(uvm_error=0, tus=1),
         None, no_log(), False, "DIRTY", "NONZERO_EXIT_WITH_CLEAN_RESULT",
         None, 1),
        # -- fourth round: the exit code must not outrank a definite diagnosis
        # A uvm_fatal run exits non-zero too, so overwriting its reason with a
        # process-level label loses the more specific fact.
        ("fatal with abnormal exit", {}, mk_case(), "RESULT_MISSING",
         no_log(native_fatal=1), False, "FAIL", "NATIVE_FATAL", None, 1),
        ("uvm fatal with abnormal exit", {}, mk_case(), "RESULT_MISSING",
         no_log(uvm_fatal_lines=1), False, "FAIL", "UVM_FATAL_EARLY_EXIT",
         None, 1),
        ("empty result, native error, bad exit", {}, mk_case(), "RESULT_EMPTY",
         no_log(native_error=1), False, "FAIL", "NATIVE_ERROR", None, 1),
        ("stale run id with abnormal exit", clean(run_id="stale-run"),
         mk_case(), None, no_log(), False,
         "DIRTY", "RUN_ID_MISMATCH:file=stale-run", "r1", 1),
        # Damage a killed write can cause stays incomplete evidence when the
        # run was killed for being too slow.
        ("truncated result plus timeout",
         {"run_id": "r1", "case": "c1", "test": "t1", "tus": ""},
         mk_case(), None, no_log(), True, "INCOMPLETE", "TIMEOUT"),
        ("struct error plus timeout", {}, mk_case(), "RESULT_DUPLICATE_KEY:tus",
         no_log(), True, "INCOMPLETE", "TIMEOUT"),
        # An identity error is readable, so a timeout does not explain it away.
        ("stale run id plus timeout", clean(run_id="stale-run"), mk_case(),
         None, no_log(), True, "DIRTY",
         "RUN_ID_MISMATCH:file=stale-run", "r1"),
        # -- fifth round: a readable identity error must not be hidden by a
        # truncation symptom found earlier in the same file.
        ("identity under torn artefact",
         {"run_id": "old-run", "case": "c1", "test": "t1"},
         mk_case(), None, no_log(), True, "DIRTY",
         "RUN_ID_MISMATCH:file=old-run", "r1"),
        ("case mismatch under torn artefact",
         {"run_id": "r1", "case": "other", "test": "t1"},
         mk_case(), None, no_log(), True, "DIRTY", "CASE_MISMATCH:file=other"),
        ("test mismatch under torn artefact",
         {"run_id": "r1", "case": "c1", "test": "other"},
         mk_case(), None, no_log(), True, "DIRTY", "TEST_MISMATCH:file=other"),
        # Same shadowing for a complete but unusable value.
        ("bad value under torn artefact",
         {"run_id": "r1", "case": "c1", "test": "t1", "tus": "abc"},
         mk_case(), None, no_log(), True, "DIRTY",
         "FIELD_FORMAT:NOT_A_COUNT:tus='abc'"),
        # -- sixth round: the firm scope was still too narrow --------------
        # A duplicated key elsewhere does not make the untouched run_id
        # unreadable...
        ("duplicate key with stale run id", clean(run_id="old-run"),
         mk_case(), "RESULT_DUPLICATE_KEY:tus", no_log(), True, "DIRTY",
         "RUN_ID_MISMATCH:file=old-run", "r1"),
        # ...but a duplicated run_id itself cannot be attributed, so it is not
        # compared at all and the torn verdict stands.
        ("duplicated run id is not trusted", clean(run_id="old-run"),
         mk_case(), "RESULT_DUPLICATE_KEY:run_id", no_log(), True,
         "INCOMPLETE", "TIMEOUT", "r1"),
        # Per-id counters are judged as strictly as the fixed ones, even when
        # the required fields never got written.
        ("garbage error id under torn artefact",
         {"run_id": "r1", "case": "c1", "test": "t1",
          "err.error.BOGUS": "abc"},
         mk_case(), None, no_log(), True, "DIRTY",
         "FIELD_FORMAT:NOT_A_COUNT:err.error.BOGUS='abc'"),
    ]
    bad = 0
    print("[selftest] classifier behaviour", flush=True)
    extra_checks = 0
    for row in cases:
        label, fields, kase, perr, log, to, want_status, want_reason = row[:8]
        want_rid = row[8] if len(row) > 8 else None
        rc = row[9] if len(row) > 9 else None
        status, reason, _reasons = classify(fields, kase, perr, log, to,
                                            want_rid, rc)
        ok = (status == want_status and reason == want_reason)
        if not ok:
            bad += 1
        print(f"  {'ok ' if ok else 'BAD'} {label:<24} -> {status}"
              f"{('/' + reason) if reason else ''}"
              f"   want {want_status}{('/' + want_reason) if want_reason else ''}",
              flush=True)

    # A definite failure must not swallow the timeout that accompanied it: the
    # reason list carries both facts even though the primary one is the failure.
    extra_checks += 1
    _s, _r, rs = classify({}, mk_case(), "RESULT_MISSING",
                          no_log(native_error=1), True)
    ok = rs == ["NATIVE_ERROR", "TIMEOUT"]
    if not ok:
        bad += 1
    print(f"  {'ok ' if ok else 'BAD'} {'both reasons kept':<24} -> {rs}"
          f"   want ['NATIVE_ERROR', 'TIMEOUT']", flush=True)

    # Four independent diagnostics: none of them may be dropped just because
    # another one was chosen as the primary reason.
    extra_checks += 1
    _s, _r, rs = classify({}, mk_case(), "RESULT_MISSING",
                          no_log(native_fatal=1, native_error=1,
                                 uvm_fatal_lines=1), True)
    want_rs = ["NATIVE_FATAL", "UVM_FATAL_EARLY_EXIT", "NATIVE_ERROR", "TIMEOUT"]
    ok = rs == want_rs
    if not ok:
        bad += 1
    print(f"  {'ok ' if ok else 'BAD'} {'all four reasons kept':<24} -> {rs}"
          f"   want {want_rs}", flush=True)

    # A timeout on its own is incomplete evidence, never a pass.
    extra_checks += 1
    got = classify(clean(), mk_case(uvm_error=0, tus=1), None, no_log(), True)
    ok = got == ("INCOMPLETE", "TIMEOUT", ["TIMEOUT"])
    if not ok:
        bad += 1
    print(f"  {'ok ' if ok else 'BAD'} {'timeout alone not a pass':<24} -> {got}"
          f"   want ('INCOMPLETE', 'TIMEOUT', ['TIMEOUT'])", flush=True)

    # The exit code is a fact even when it did not decide the verdict, so it has
    # to reach the reason set too.
    extra_checks += 1
    _s, _r, rs = classify(clean(run_id="stale-run"), mk_case(), None,
                          no_log(), False, "r1", 1)
    want_rs = ["RUN_ID_MISMATCH:file=stale-run", "NONZERO_EXIT"]
    ok = rs == want_rs
    if not ok:
        bad += 1
    print(f"  {'ok ' if ok else 'BAD'} {'exit code in reasons':<24} -> {rs}"
          f"   want {want_rs}", flush=True)

    # A field lost to a killed write is recorded, but it does not decide the
    # verdict: the timeout did.
    extra_checks += 1
    _s, _r, rs = classify({"run_id": "r1", "case": "c1", "test": "t1",
                           "tus": ""}, mk_case(), None, no_log(), True)
    want_rs = ["TIMEOUT", "MISSING_FIELD:beats"]
    ok = (_s, _r, rs) == ("INCOMPLETE", "TIMEOUT", want_rs)
    if not ok:
        bad += 1
    print(f"  {'ok ' if ok else 'BAD'} {'torn finding kept as reason':<24} -> "
          f"{(_s, _r, rs)}   want ('INCOMPLETE', 'TIMEOUT', {want_rs})",
          flush=True)

    # The identity error is the primary reason, but the truncation that hid it
    # and the timeout that caused it are still facts.
    extra_checks += 1
    _s, _r, rs = classify({"run_id": "old-run", "case": "c1", "test": "t1"},
                          mk_case(), None, no_log(), True, "r1")
    want_rs = ["RUN_ID_MISMATCH:file=old-run", "TIMEOUT", "MISSING_FIELD:tus"]
    ok = (_s, _r) == ("DIRTY", "RUN_ID_MISMATCH:file=old-run") and rs == want_rs
    if not ok:
        bad += 1
    print(f"  {'ok ' if ok else 'BAD'} {'firm beats torn in reasons':<24} -> "
          f"{(_s, _r, rs)}   want ('DIRTY', 'RUN_ID_MISMATCH:file=old-run', "
          f"{want_rs})", flush=True)

    # The reason the artefact was rejected has to survive next to the
    # contradiction that outranked it.
    extra_checks += 1
    _s, _r, rs = classify(clean(run_id="old-run"), mk_case(),
                          "RESULT_DUPLICATE_KEY:tus", no_log(), True, "r1")
    want_rs = ["RUN_ID_MISMATCH:file=old-run", "TIMEOUT",
               "RESULT_DUPLICATE_KEY:tus"]
    ok = (_s, _r) == ("DIRTY", "RUN_ID_MISMATCH:file=old-run") and rs == want_rs
    if not ok:
        bad += 1
    print(f"  {'ok ' if ok else 'BAD'} {'duplicate key kept as reason':<24} -> "
          f"{(_s, _r, rs)}   want ('DIRTY', 'RUN_ID_MISMATCH:file=old-run', "
          f"{want_rs})", flush=True)

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

    total = len(cases) + 8   # + merge, both-reasons, four-reasons, timeout-alone,
    #                          exit-in-reasons, torn-finding, firm-beats-torn,
    #                          duplicate-key-in-reasons
    print(f"\nselftest: {'PASS' if bad == 0 else 'FAIL'} ({total - bad}/{total})")
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