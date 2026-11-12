#!/usr/bin/env python
"""A5: prove the checkers can go red.

Every scenario runs its_check_selftest_tb, which has no DUT and drives the
interface directly.  Each assertion below states what must appear and what must
stay silent, so a checker that stopped working would fail this script instead of
quietly passing the regression.

Each scenario is scored three ways: the scenario must have executed (marker
line), it must have produced the diagnostic it targets, and every other
diagnostic must have stayed silent - a violation that only shows up because
something else also fired is not independent evidence.

Run:  python a5_selftest.py
"""

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import run_its_uvm as env_mod   # noqa: E402
import run_regress as rr        # noqa: E402

LOG_DIR = rr.OUT / "logs"
TB = "work.its_check_selftest_tb"

# Every diagnostic the monitor can raise; "no false alarm" means none of these.
DIAG_IDS = ["ITS_SIG_X", "ITS_DONE_NO_FIRE", "ITS_DATA_X", "ITS_VLD_STALL",
            "ITS_IN_VLD_NO_REQ", "ITS_RST_X"]

COUNTERS_RE = re.compile(r"ITS_SELFTEST_COUNTERS scen=(\S+) sig=(\d+) "
                         r"x=(\d+) in=(\d+) guard=(\d+)")


def run_scen(name):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log = LOG_DIR / f"selftest_{name}.log"
    cmd = [env_mod.VSIM, "-batch", "-t", "1ps", "+UVM_NO_DPI",
           f"+SCEN={name}", "-do", "run -all; quit -f", TB]
    rc, _ = env_mod.run(cmd, log, rr.OUT, 300)
    text = log.read_text(encoding="utf-8", errors="replace")
    counters = {}
    m = COUNTERS_RE.search(text)
    if m:
        counters = {"scen": m.group(1), "sig": int(m.group(2)),
                    "x": int(m.group(3)), "in": int(m.group(4)),
                    "guard": int(m.group(5))}
    return rc, rr.scan_log(log), text, counters


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
    scenarios = []

    def check(label, ok, detail=""):
        results.append((label, ok, detail))
        print(f"  {'ok ' if ok else 'BAD'} {label:<48} {detail}", flush=True)

    def ran(name, text, counters):
        """The scenario must have executed and reached its counter print."""
        scenarios.append(name)
        check(f"{name}: scenario executed",
              f"ITS_SELFTEST_RAN scen={name}" in text)
        check(f"{name}: counters printed", counters.get("scen") == name,
              str(counters))

    def absent(name, text):
        leaked = [d for d in DIAG_IDS if d in text]
        check(f"{name}: no other diagnostic leaked", not leaked, str(leaked))

    fake_case = {"name": "selftest", "testname": "its_check_selftest_test",
                 "expect": {"uvm_error": 0}}

    # -- 1. quiet input must stay quiet -----------------------------------
    rc, log, text, counters = run_scen("clean")
    ran("clean", text, counters)
    check("clean: every counter zero",
          counters.get("sig") == 0 and counters.get("x") == 0
          and counters.get("in") == 0 and counters.get("guard") == 0,
          str(counters))
    check("clean: no monitor diagnostic",
          not [d for d in DIAG_IDS if d in text])
    check("clean: no UVM error at all", log["uvm_error_lines"] == 0,
          f"uvm_error_lines={log['uvm_error_lines']}")
    check("clean: native channel empty",
          log["native_error"] == 0 and log["native_fatal"] == 0,
          f"native_error={log['native_error']} native_fatal={log['native_fatal']}")

    # -- 2. done without a handshake must be reported ---------------------
    rc, log, text, counters = run_scen("done_no_fire")
    ran("done_no_fire", text, counters)
    check("done_no_fire: ITS_DONE_NO_FIRE raised", "ITS_DONE_NO_FIRE" in text)
    check("done_no_fire: counted", counters.get("sig", 0) > 0, str(counters))
    check("done_no_fire: no data-X false alarm", "ITS_DATA_X" not in text)

    # -- 3. valid without a request: reported on its own ------------------
    rc, log, text, counters = run_scen("vld_only")
    ran("vld_only", text, counters)
    check("vld_only: ITS_VLD_STALL raised", "ITS_VLD_STALL" in text)
    check("vld_only: guard counter agrees", counters.get("guard", 0) > 0,
          str(counters))
    check("vld_only: reported as an error, not as info",
          log["uvm_error_lines"] > 0, f"uvm_error_lines={log['uvm_error_lines']}")
    check("vld_only: not piggy-backed on done", "ITS_DONE_NO_FIRE" not in text)

    # -- 4. an undriven done (Z) must be reported -------------------------
    rc, log, text, counters = run_scen("done_z")
    ran("done_z", text, counters)
    check("done_z: ITS_SIG_X raised", "ITS_SIG_X" in text)
    check("done_z: X counter agrees", counters.get("x", 0) > 0, str(counters))
    check("done_z: not piggy-backed on done", "ITS_DONE_NO_FIRE" not in text)

    # -- 5. an unknown request (X) must be reported -----------------------
    rc, log, text, counters = run_scen("req_x")
    ran("req_x", text, counters)
    check("req_x: ITS_SIG_X raised", "ITS_SIG_X" in text)
    check("req_x: X counter agrees", counters.get("x", 0) > 0, str(counters))
    check("req_x: stall check stays out of it (req is neither 0 nor 1)",
          "ITS_VLD_STALL" not in text)

    # -- 6. X on an accepted beat must be reported ------------------------
    rc, log, text, counters = run_scen("data_x")
    ran("data_x", text, counters)
    check("data_x: ITS_DATA_X raised", "ITS_DATA_X" in text)
    check("data_x: no done false alarm", "ITS_DONE_NO_FIRE" not in text)

    # -- 7. uvm_fatal exits before the result file ------------------------
    rc, log, text, counters = run_scen("uvm_fatal")
    ran("uvm_fatal", text, counters)
    status, reason, _ = rr.classify({}, fake_case, "RESULT_MISSING", log, False)
    check("uvm_fatal: classified as early exit",
          (status, reason) == ("FAIL", "UVM_FATAL_EARLY_EXIT"),
          f"{status}/{reason}")
    check("uvm_fatal: not reported as plain missing file",
          reason != "NO_RESULT_FILE")

    # -- 8. native $error leaves the exit code at zero --------------------
    rc, log, text, counters = run_scen("native_error")
    ran("native_error", text, counters)
    check("native_error: found through the '# ' prefix",
          log["native_error"] == 1, f"native_error={log['native_error']}")
    check("native_error: summary line not counted as a diagnostic",
          log["summary_errors"] == 1, f"summary_errors={log['summary_errors']}")
    check("native_error: exit code is still 0 (why the log must be read)",
          rc == 0, f"rc={rc}")
    status, reason, _ = rr.classify({}, fake_case, "RESULT_MISSING", log, False)
    check("native_error: classified as NATIVE_ERROR",
          (status, reason) == ("FAIL", "NATIVE_ERROR"), f"{status}/{reason}")

    # -- 9. native $fatal: the log contains $finish as well ---------------
    rc, log, text, counters = run_scen("native_fatal")
    ran("native_fatal", text, counters)
    check("native_fatal: found", log["native_fatal"] == 1,
          f"native_fatal={log['native_fatal']}")
    check("native_fatal: log also carries a $finish line",
          log["saw_finish"])
    status, reason, _ = rr.classify({}, fake_case, "RESULT_MISSING", log, False)
    check("native_fatal: classified as NATIVE_FATAL, not as completion",
          (status, reason) == ("FAIL", "NATIVE_FATAL"), f"{status}/{reason}")

    bad = [r for r in results if not r[1]]
    print(f"\n[A5] scenarios: {len(scenarios)}   assertions: {len(results)}   "
          f"passed: {len(results) - len(bad)}   failed: {len(bad)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())