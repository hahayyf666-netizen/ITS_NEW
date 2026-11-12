#!/usr/bin/env python
"""Before/after evidence for the classifier counterexamples the audit found.

Runs the same fixtures through two classifiers: the one at a historical revision
(default: the original A-phase commit) and the one on disk.  A fixture "leaked"
when the old classifier did not fail it.  This is the only way to show the holes
were real: the current classifier rejecting a fixture says nothing about whether
the previous one would have.

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


# (defect, fields, case, parse_error, loginfo, timed_out, expected_run_id)
FIXTURES = [
    ("D1 guard counter unwatched",
     base(vld_stall_guard=1), mk_case(), None, no_log(), False, None),
    ("D3 run_id not verified",
     base(run_id="stale-run"), mk_case(), None, no_log(), False, "r1"),
    ("D4 garbage id value accepted",
     base({"err.error.ITS_DATA_MISMATCH": 1, "err.error.BOGUS": "garbage"},
          uvm_error=1), mk_case(uvm_error_ids={"ITS_DATA_MISMATCH": 1}),
     None, no_log(), False, None),
    ("D4 server total optional",
     {k: v for k, v in base().items() if k != "err_server_total_error"},
     mk_case(), None, no_log(), False, None),
    ("D4 fatal id total unchecked",
     base({"err.fatal.X": 1}, uvm_fatal=0, err_server_total_fatal=1),
     mk_case(), None, no_log(), False, None),
    ("D5 fatal after result file",
     base(), mk_case(), None, no_log(uvm_fatal_lines=1), False, None),
    ("D5 empty result + native fatal",
     {}, mk_case(), "RESULT_EMPTY", no_log(native_fatal=1), False, None),
    ("D5 timeout + native error",
     {}, mk_case(), "RESULT_MISSING", no_log(native_error=1), True, None),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rev", default=DEFAULT_REV)
    args = ap.parse_args()

    old = load_old(args.rev)
    lines = [f"classifier before/after  (old = {args.rev}, new = working tree)"]
    leaks = rejected = 0
    for defect, fields, kase, perr, log, to, rid in FIXTURES:
        o = old.classify(fields, kase, perr, log, to)
        n = new.classify(fields, kase, perr, log, to, rid)
        old_s = f"{o[0]}/{o[1]}" if o[1] else o[0]
        new_s = f"{n[0]}/{n[1]}" if n[1] else n[0]
        leaked = o[0] not in ("FAIL", "DIRTY")
        leaks += leaked
        rejected += n[0] in ("FAIL", "DIRTY")
        lines.append(f"{'LEAK' if leaked else 'ok  '}  {defect:<30} "
                     f"old={old_s:<34} new={new_s}")
        if not leaked:
            lines.append("      note: the old classifier already failed this one")
        if n[0] not in ("FAIL", "DIRTY"):
            lines.append("      !! the new classifier did not fail this fixture")
    lines.append("")
    lines.append(f"fixtures: {len(FIXTURES)}   old leaked: {leaks}   "
                 f"new rejected: {rejected}")

    out = new.OUT / "probe"
    out.mkdir(parents=True, exist_ok=True)
    path = out / "classifier_before_after.txt"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    print(f"\nwrote {path}")
    return 0 if (leaks == len(FIXTURES) and rejected == len(FIXTURES)) else 1


if __name__ == "__main__":
    sys.exit(main())