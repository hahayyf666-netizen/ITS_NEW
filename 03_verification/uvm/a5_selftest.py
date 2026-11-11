#!/usr/bin/env python
"""A5: prove the checkers can go red.

Every scenario runs its_check_selftest_tb, which has no DUT and drives the
interface directly.  Each row below states what must appear and what must stay
silent, so a checker that stopped working would fail this script instead of
quietly passing the regression.

Run:  python a5_selftest.py
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import run_its_uvm as env_mod   # noqa: E402
import run_regress as rr        # noqa: E402

LOG_DIR = rr.OUT / "logs"
TB = "work.its_check_selftest_tb"


def run_scen(name):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log = LOG_DIR / f"selftest_{name}.log"
    cmd = [env_mod.VSIM, "-batch", "-t", "1ps", "+UVM_NO_DPI",
           f"+SCEN={name}", "-do", "run -all; quit -f", TB]
    rc, _ = env_mod.run(cmd, log, rr.OUT, 300)
    text = log.read_text(encoding="utf-8", errors="replace")
    return rc, rr.scan_log(log), text


def main():
    print("[A5] compiling the self-test testbench", flush=True)
    rc, out = env_mod.run(
        [env_mod.VLOG, "-sv", "+define+UVM_NO_DPI",
         f"+incdir+{env_mod.UVM}", f"+incdir+{HERE}",
         str(HERE / "its_check_selftest_tb.sv")],
        rr.OUT / "logs" / "selftest_compile.log", rr.OUT, 600)
    if rc != 0:
        print(f"  compile FAILED ({rc}); see run/logs/selftest_compile.log")
        return 1
    print("  compile ok", flush=True)

    results = []

    def check(label, ok, detail=""):
        results.append((label, ok, detail))
        print(f"  {'ok ' if ok else 'BAD'} {label:<46} {detail}", flush=True)

    fake_case = {"name": "selftest", "testname": "its_check_selftest_test",
                 "expect": {"uvm_error": 0}}

    # -- 1. quiet input must stay quiet -----------------------------------
    rc, log, text = run_scen("clean")
    check("clean: no monitor diagnostic",
          "ITS_DONE_NO_FIRE" not in text and "ITS_DATA_X" not in text
          and "ITS_SIG_X" not in text and "ITS_RST_X" not in text)
    check("clean: native channel empty",
          log["native_error"] == 0 and log["native_fatal"] == 0,
          f"native_error={log['native_error']} native_fatal={log['native_fatal']}")

    # -- 2. done without a handshake must be reported ---------------------
    rc, log, text = run_scen("done_no_fire")
    check("done_no_fire: ITS_DONE_NO_FIRE raised", "ITS_DONE_NO_FIRE" in text)
    check("done_no_fire: no data-X false alarm", "ITS_DATA_X" not in text)

    # -- 3. X on an accepted beat must be reported ------------------------
    rc, log, text = run_scen("data_x")
    check("data_x: ITS_DATA_X raised", "ITS_DATA_X" in text)
    check("data_x: no done false alarm", "ITS_DONE_NO_FIRE" not in text)

    # -- 4. uvm_fatal exits before the result file ------------------------
    rc, log, text = run_scen("uvm_fatal")
    status, reason = rr.classify({}, fake_case, "RESULT_MISSING", log, False)
    check("uvm_fatal: classified as early exit",
          (status, reason) == ("FAIL", "UVM_FATAL_EARLY_EXIT"),
          f"{status}/{reason}")
    check("uvm_fatal: not reported as plain missing file",
          reason != "NO_RESULT_FILE")

    # -- 5. native $error leaves the exit code at zero --------------------
    rc, log, text = run_scen("native_error")
    check("native_error: found through the '# ' prefix",
          log["native_error"] == 1, f"native_error={log['native_error']}")
    check("native_error: summary line not counted as a diagnostic",
          log["summary_errors"] == 1, f"summary_errors={log['summary_errors']}")
    check("native_error: exit code is still 0 (why the log must be read)",
          rc == 0, f"rc={rc}")
    status, reason = rr.classify({}, fake_case, "RESULT_MISSING", log, False)
    check("native_error: classified as NATIVE_ERROR",
          (status, reason) == ("FAIL", "NATIVE_ERROR"), f"{status}/{reason}")

    # -- 6. native $fatal: the log contains $finish as well ---------------
    rc, log, text = run_scen("native_fatal")
    check("native_fatal: found", log["native_fatal"] == 1,
          f"native_fatal={log['native_fatal']}")
    check("native_fatal: log also carries a $finish line",
          log["saw_finish"])
    status, reason = rr.classify({}, fake_case, "RESULT_MISSING", log, False)
    check("native_fatal: classified as NATIVE_FATAL, not as completion",
          (status, reason) == ("FAIL", "NATIVE_FATAL"), f"{status}/{reason}")

    bad = [r for r in results if not r[1]]
    print(f"\n[A5] {len(results) - len(bad)}/{len(results)} checks passed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())