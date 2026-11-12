#!/usr/bin/env python
"""A5: a fatal in final_phase must fail even though the result file is clean.

report_phase writes and closes the result file, and final_phase runs after it.
A fatal there therefore leaves a complete, internally consistent artefact
behind, which is the one path where "the file looks fine" and "the run failed"
are both true.

The counterexample must be a real simulation, and its artefact must be the one
the fixed writer produces: nothing about the field list is hard-coded here, the
completeness check reads the writer's own required-field list.  The control run
- the same case, same writer, no injection - must be judged PASS, so the FAIL
below can only come from the injected fatal.

Run:  python a5_final_fatal.py
"""

import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import run_regress as rr   # noqa: E402


def completeness(fields):
    """Everything the runner insists on, plus the writer's final block."""
    missing = [k for k in rr.REQUIRED_FIELDS if k not in fields]
    has_cov = any(k.startswith("cg.") for k in fields)
    return missing, has_cov


def main():
    rr.stage_prep()
    vector_file, cases = rr.load_cases()
    case = next(c for c in cases if c["name"] == "single_tu")
    # Both runs write their own artefacts: reusing the case's name would
    # overwrite the regression's result file and log, leaving the manifest's
    # recorded sha256 pointing at bytes that no longer exist.
    probe_dir = rr.OUT / "probe"
    probe_dir.mkdir(parents=True, exist_ok=True)

    results = []

    def check(label, ok, detail=""):
        results.append((label, ok, detail))
        print(f"  {'ok ' if ok else 'BAD'} {label:<52} {detail}", flush=True)

    # -- control: same case, same writer, no injection --------------------
    print("[A5] control run (no injection)", flush=True)
    ctl = rr.run_one(case, vector_file, want_ucdb=False,
                     artifact_name="a5_final_fatal_control",
                     result_dir=probe_dir)
    res = probe_dir / "a5_final_fatal_control.result"
    raw = res.read_bytes() if res.exists() else b""
    ctl_fields, ctl_perr = rr.parse_result(res)
    check("control: judged PASS", ctl["status"] == "PASS",
          f"{ctl['status']}/{ctl['reason']}")
    check("control: result file parses", ctl_perr is None, str(ctl_perr))
    missing, has_cov = completeness(ctl_fields)
    check("control: result file complete", not missing and has_cov,
          f"missing={missing} cg={has_cov}")
    check("control: file ends with a complete line", raw.endswith(b"\n"))
    check("control: no fatal in the log", ctl["log"]["uvm_fatal_lines"] == 0)

    # -- probe: identical run, fatal injected after the file was written ---
    print("[A5] probe run (+FATAL_IN_FINAL=1)", flush=True)
    probe = rr.run_one(case, vector_file, want_ucdb=False,
                       extra_plusargs=("FATAL_IN_FINAL=1",),
                       artifact_name="a5_final_fatal_fatal",
                       result_dir=probe_dir)
    res = probe_dir / "a5_final_fatal_fatal.result"
    praw = res.read_bytes() if res.exists() else b""
    pfields, pperr = rr.parse_result(res)
    missing, has_cov = completeness(pfields)
    check("probe: result file still written", pperr is None, str(pperr))
    check("probe: result file complete, as the real writer emits it",
          not missing and has_cov, f"missing={missing} cg={has_cov}")
    check("probe: artefact alone looks clean",
          pfields.get("uvm_error") == "0" and pfields.get("uvm_fatal") == "0",
          f"uvm_error={pfields.get('uvm_error')} "
          f"uvm_fatal={pfields.get('uvm_fatal')}")
    check("probe: log carries the fatal", probe["log"]["uvm_fatal_lines"] == 1,
          f"uvm_fatal_lines={probe['log']['uvm_fatal_lines']}")
    check("probe: judged FAIL on the fatal, not PASS",
          (probe["status"], probe["reason"]) == ("FAIL", "UVM_FATAL_IN_LOG"),
          f"{probe['status']}/{probe['reason']}")

    evidence = {
        "case": case["name"],
        "artifacts": {"control": str(probe_dir / "a5_final_fatal_control.result"),
                      "probe": str(probe_dir / "a5_final_fatal_fatal.result")},
        "control": {"status": ctl["status"], "reason": ctl["reason"],
                    "uvm_fatal_lines": ctl["log"]["uvm_fatal_lines"],
                    "bytes": len(raw),
                    "sha256": hashlib.sha256(raw).hexdigest()},
        "probe": {"status": probe["status"], "reason": probe["reason"],
                  "reasons": probe["reasons"],
                  "uvm_fatal_lines": probe["log"]["uvm_fatal_lines"],
                  "bytes": len(praw),
                  "sha256": hashlib.sha256(praw).hexdigest()},
        "required_fields_checked": len(rr.REQUIRED_FIELDS),
    }
    out = rr.OUT / "A5_FINAL_FATAL.json"
    out.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    print(f"\n[A5] evidence written to {out}", flush=True)

    bad = [r for r in results if not r[1]]
    print(f"[A5] final_fatal assertions: {len(results)}   "
          f"passed: {len(results) - len(bad)}   failed: {len(bad)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())