#!/usr/bin/env python
"""Before/after evidence for the classifier counterexamples the audits found.

Runs the same fixtures through two classifiers: the one at a historical revision
(default: the original A-phase commit) and the one on disk.  A fixture "leaked"
when the old classifier did not fail it.  This is the only way to show the holes
were real: the current classifier rejecting a fixture says nothing about whether
the previous one would have.

Fixtures that the old flow already handled are kept as regression guards; the
summary says which is which rather than pretending every row was a new hole.

The historical source is read out of git, so this stays reproducible as long as
the revision exists; nothing is copied into the tree.

Run:  python probe_classifier_history.py [--rev <rev>]
"""

import argparse
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import run_regress as new   # noqa: E402

DEFAULT_REV = "9e5c2b6"
REL = "03_verification/uvm/run_regress.py"


def load_old(rev):
    """Compile the historical run_regress.py from git as a separate module."""
    src = subprocess.run(["git", "show", f"{rev}:{REL}"], cwd=HERE,
                         capture_output=True)
    if src.returncode != 0:
        raise SystemExit(f"git show {rev}:{REL} failed: "
                         f"{src.stderr.decode('utf-8', 'replace').strip()}")
    tmp = Path(tempfile.mkdtemp()) / "old_run_regress.py"
    tmp.write_bytes(src.stdout)
    spec = importlib.util.spec_from_file_location("old_rr", tmp)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def base(ids=None, **over):
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


def old_effective(old, fields, kase, perr, log, to, rc):
    """The verdict the old flow produced: classify plus its caller-side patch.

    The exit-code handling lived in run_one() back then, not in the classifier,
    so reproducing it here is what makes the comparison fair.
    """
    status, reason = old.classify(fields, kase, perr, log, to)[:2]
    if rc:
        if status == "PASS":
            status, reason = "DIRTY", "NONZERO_EXIT_WITH_CLEAN_RESULT"
        elif reason in ("NO_RESULT_FILE", "FINISHED_WITHOUT_RESULT"):
            status, reason = "FAIL", "SIMULATOR_ERROR"
    return status, reason


# (defect, fields, case, parse_error, loginfo, timed_out, run_id, returncode)
# Rows where a timeout with no other defect is the intended verdict.
INCOMPLETE_OK = {"D5 clean result + timeout", "D5 no result + finish + timeout"}

FIXTURES = [
    # -- first round: the six defects the first audit found ----------------
    ("D1 guard counter unwatched",
     base(vld_stall_guard=1), mk_case(), None, no_log(), False, None, None),
    ("D3 run_id not verified",
     base(run_id="stale-run"), mk_case(), None, no_log(), False, "r1", None),
    ("D4 garbage id value accepted",
     base({"err.error.ITS_DATA_MISMATCH": 1, "err.error.BOGUS": "garbage"},
          uvm_error=1), mk_case(uvm_error_ids={"ITS_DATA_MISMATCH": 1}),
     None, no_log(), False, None, None),
    ("D4 server total optional",
     {k: v for k, v in base().items() if k != "err_server_total_error"},
     mk_case(), None, no_log(), False, None, None),
    ("D4 fatal id total unchecked",
     base({"err.fatal.X": 1}, uvm_fatal=0, err_server_total_fatal=1),
     mk_case(), None, no_log(), False, None, None),
    ("D5 fatal after result file",
     base(), mk_case(), None, no_log(uvm_fatal_lines=1), False, None, None),
    ("D5 empty result + native fatal",
     {}, mk_case(), "RESULT_EMPTY", no_log(native_fatal=1), False, None, None),
    ("D5 timeout + native error",
     {}, mk_case(), "RESULT_MISSING", no_log(native_error=1), True, None, None),
    # -- second round: the anomalous combinations the review found ---------
    ("D5 empty result + uvm fatal",
     {}, mk_case(), "RESULT_EMPTY", no_log(uvm_fatal_lines=1), False, None, None),
    ("D5 empty result + native error",
     {}, mk_case(), "RESULT_EMPTY", no_log(native_error=1), False, None, None),
    ("D5 clean result + timeout",
     base(), mk_case(uvm_error=0, tus=1), None, no_log(), True, None, None),
    ("D5 no result + finish + timeout",
     {}, mk_case(), "RESULT_MISSING", no_log(), True, None, None),
    ("D5 four diagnostics at once",
     {}, mk_case(), "RESULT_MISSING",
     no_log(native_fatal=1, native_error=1, uvm_fatal_lines=1),
     True, None, None),
    ("D5 stale run id + bad count",
     base(run_id="stale-run", beats="3"), mk_case(beats=4), None, no_log(),
     False, "r1", None),
    ("D5 abnormal exit, no result",
     {}, mk_case(), "RESULT_MISSING",
     no_log(saw_finish=False, saw_uvm_summary=False), False, None, 1),
    ("D5 abnormal exit, clean result",
     base(), mk_case(uvm_error=0, tus=1), None, no_log(), False, None, 1),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rev", default=DEFAULT_REV)
    args = ap.parse_args()

    old = load_old(args.rev)
    lines = [f"classifier before/after  (old = {args.rev}, new = working tree)"]
    leaks = guards = 0
    new_wrong = []
    for defect, fields, kase, perr, log, to, rid, rc in FIXTURES:
        o_status, o_reason = old_effective(old, fields, kase, perr, log, to, rc)
        n_status, n_reason, n_reasons = new.classify(
            fields, kase, perr, log, to, rid, rc)
        old_s = f"{o_status}/{o_reason}" if o_reason else o_status
        new_s = f"{n_status}/{n_reason}" if n_reason else n_status
        changed = (o_status, o_reason) != (n_status, n_reason)
        if changed:
            leaks += 1
        else:
            guards += 1
        label = "FIXED" if changed else "guard"
        lines.append(f"{label:<6}{defect:<34} old={old_s:<38} new={new_s}")
        # A timeout on its own is incomplete evidence by design, so those rows
        # are only wrong if they come out as anything else.
        if defect in INCOMPLETE_OK:
            if (n_status, n_reason) != ("INCOMPLETE", "TIMEOUT"):
                new_wrong.append(defect)
                lines.append("      !! expected INCOMPLETE/TIMEOUT")
        elif n_status not in ("FAIL", "DIRTY"):
            new_wrong.append(defect)
            lines.append("      !! the new classifier did not fail this fixture")

    # The four-diagnostic row also has to keep every fact, not just the primary.
    _s, _r, rs = new.classify({}, mk_case(), "RESULT_MISSING",
                              no_log(native_fatal=1, native_error=1,
                                     uvm_fatal_lines=1), True)
    want = ["NATIVE_FATAL", "UVM_FATAL_EARLY_EXIT", "NATIVE_ERROR", "TIMEOUT"]
    lines.append("")
    lines.append(f"reasons on the four-diagnostic row: {rs}")
    lines.append(f"                                     want {want}")
    if rs != want:
        new_wrong.append("four-diagnostic reason set")

    lines.append("")
    lines.append(f"fixtures: {len(FIXTURES)}   changed by the fix: {leaks}   "
                 f"already handled before: {guards}")
    lines.append(f"new classifier wrong: {len(new_wrong)}")

    out = new.OUT / "probe"
    out.mkdir(parents=True, exist_ok=True)
    path = out / "classifier_before_after.txt"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    print(f"\nwrote {path}")
    return 0 if not new_wrong else 1


if __name__ == "__main__":
    sys.exit(main())