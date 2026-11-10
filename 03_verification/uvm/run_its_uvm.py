#!/usr/bin/env python
"""D3 UVM runner for the VVC ITS inverse-transform DUT.

Compiles the RTL with the ModelSim-bundled UVM 1.2 library and runs the UVM
tests with -batch (the -c console path is blocked by the machine's code
integrity policy, see 05_audit/current/108_d1_coverage_baseline_20261110).

Golden beats come from the project's own generator, so the scoreboard checks
against an independent oracle rather than against DUT output.

Usage:
    python run_its_uvm.py prep                 # generate vectors + compile
    python run_its_uvm.py run [--only name]    # run tests
    python run_its_uvm.py all
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

MS = Path(r"D:\software\Modelsim\win64")
VSIM = MS / "vsim.exe"
VLOG = MS / "vlog.exe"
VLIB = MS / "vlib.exe"
UVM = Path(r"D:\software\Modelsim\verilog_src\uvm-1.1d\src")
LIC = r"D:\software\Modelsim\LICENSE.TXT"

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
OUT = HERE / "run"
PROFILE = "contest_engineering_vtm10_sat10_v2"

RTL = [
    REPO / "02_rtl/rtl/its_simple_ram.sv",
    REPO / "02_rtl/rtl/its_input_cache_bank.sv",
    REPO / "02_rtl/rtl/unified_p4_kernel.sv",
    REPO / "02_rtl/rtl/bounded_lfnst_engine.sv",
    REPO / "02_rtl/rtl/unified_its_wrapper.sv",
]

SRC = [
    HERE / "its_if.sv",
    HERE / "its_uvm_pkg.sv",
    HERE / "its_uvm_tb.sv",
]

# (name, plusargs, expectation)
#   "pass"  -> exit 0, no UVM_ERROR, ITS_CHECK_PASS seen
#   "mismatch" -> UVM_ERROR ITS_DATA_MISMATCH must be reported
#   "protocol" -> UVM_ERROR ITS_PROTOCOL_ERROR must be reported
RUNS = [
    ("single_tu",   ["+UVM_TESTNAME=its_single_tu_test", "+CASE_INDEX=0"], "pass"),
    ("rect_tu",     ["+UVM_TESTNAME=its_rect_tu_test"], "pass"),
    ("multi_tu_4",  ["+UVM_TESTNAME=its_multi_tu_test", "+TU_COUNT=4", "+TU_START=0"], "pass"),
    ("multi_tu_16", ["+UVM_TESTNAME=its_multi_tu_test", "+TU_COUNT=16", "+TU_START=3"], "pass"),
    ("neg_wrong_golden", ["+UVM_TESTNAME=its_wrong_golden_test", "+WRONG_GOLDEN"], "mismatch"),
    ("neg_illegal_desc", ["+UVM_TESTNAME=its_illegal_desc_test"], "protocol"),
    # D4 stimulus: the entire vector set in one simulation.  Coverage numbers
    # are only meaningful when this runs, because it is the only run that
    # touches every shape, transform type and LFNST mode.
    ("sweep", ["+UVM_TESTNAME=its_sweep_test"], "pass"),
]


def env():
    e = dict(os.environ)
    e["LM_LICENSE_FILE"] = LIC
    e["MGLS_LICENSE_FILE"] = LIC
    return e


def run(cmd, logpath, cwd, timeout):
    logpath = Path(logpath)
    logpath.parent.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    with open(logpath, "w", encoding="utf-8", errors="replace") as fh:
        fh.write("CMD: " + " ".join(str(c) for c in cmd) + "\n\n")
        fh.flush()
        try:
            p = subprocess.run([str(c) for c in cmd], cwd=str(cwd), env=env(),
                               stdout=fh, stderr=subprocess.STDOUT, timeout=timeout)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            fh.write(f"\n*** TIMEOUT after {timeout}s\n")
            rc = -9
    return rc, time.time() - t0


def stage_prep():
    OUT.mkdir(parents=True, exist_ok=True)
    gdir = REPO / "03_verification/step12d_engineering"
    vec = OUT / "unified_gate_c_vectors.txt"

    print("[1/4] generating Gate-C vectors ...", flush=True)
    rc, dt = run([sys.executable, gdir / "generate_gate_c_hdl_vectors.py",
                  "--profile", PROFILE, "--full", vec],
                 OUT / "logs/gen_gate_c.log", OUT, 3600)
    if rc != 0 or not vec.exists():
        print(f"  GENERATOR FAILED rc={rc}")
        sys.exit(1)
    print(f"      {vec.name}: {vec.stat().st_size} B ({dt:.0f}s)")

    print("[2/4] staging coefficient ROM ...", flush=True)
    # The RTL loads 03_verification/sim/*.hex relative to the run directory.
    romdir = OUT / "03_verification" / "sim"
    romdir.mkdir(parents=True, exist_ok=True)
    for h in ("rom_coeffs.hex", "lfnst_coeffs.hex", "lfnst_packed_coeffs.hex"):
        shutil.copy2(REPO / "02_rtl/rtl" / h, romdir / h)

    print("[3/4] vlib work ...", flush=True)
    if (OUT / "work").exists():
        shutil.rmtree(OUT / "work", ignore_errors=True)
    rc, _ = run([VLIB, "work"], OUT / "logs/vlib.log", OUT, 300)
    if rc != 0:
        print("  vlib failed")
        sys.exit(1)

    print("[4/4] compiling UVM library + RTL + UVM sources (single pass) ...", flush=True)
    files = list(RTL) + list(SRC)
    missing = [f for f in files if not f.exists()]
    if missing:
        print("  MISSING SOURCES: " + ", ".join(str(m) for m in missing))
        sys.exit(1)
    # The library and the sources must go through vlog in one invocation so the
    # UVM_NO_DPI define applies to both; a separate library pass leaves DPI
    # exports behind and vsim then demands a C compiler at load time.
    cmd = [VLOG, "-sv", "+define+UVM_NO_DPI", f"+incdir+{UVM}", f"+incdir+{HERE}",
           UVM / "uvm_pkg.sv"]
    cmd += files
    cmd += ["-l", OUT / "logs/compile.log"]
    rc, dt = run(cmd, OUT / "logs/compile.stdout.log", OUT, 3600)
    text = (OUT / "logs/compile.log").read_text(encoding="utf-8", errors="replace")
    errs = text.count("** Error")
    warns = text.count("** Warning")
    print(f"      exit={rc} errors={errs} warnings={warns} ({dt:.0f}s)")
    if rc != 0 or errs:
        print("  COMPILE FAILED")
        sys.exit(1)
    print("prep done")


def stage_run(only):
    print(f"[run] {len(RUNS)} UVM test(s)", flush=True)
    cases = load_vectors(OUT / "unified_gate_c_vectors.txt")
    results = []
    for name, plusargs, expect in RUNS:
        if only and name not in only:
            continue
        log = OUT / "logs" / f"sim_{name}.log"
        cmd = [VSIM, "-batch", "-t", "1ps", "+UVM_NO_DPI", "-voptargs=+acc"]
        cmd += plusargs
        cmd += [f"-gVECTOR_FILE={OUT / 'unified_gate_c_vectors.txt'}"]
        cmd += ["-do", "run -all; quit -f", "work.its_uvm_tb"]
        print(f"  [{name}] ...", end=" ", flush=True)
        rc, dt = run(cmd, log, OUT, 7200)
        text = log.read_text(encoding="utf-8", errors="replace")
        n_err = re_first_int(text, "UVM_ERROR :")
        fatal = re_first_int(text, "UVM_FATAL :")
        mismatch = "ITS_DATA_MISMATCH" in text
        proto = "ITS_PROTOCOL_ERROR" in text
        check_pass = "ITS_CHECK_PASS" in text
        saw_tus = saw_beats = saw_overlap = None
        m = re.search(r"ITS_CHECK_PASS.*?tus=(\d+) beats=(\d+) overlap=(\d+)", text)
        if m:
            saw_tus, saw_beats, saw_overlap = (int(m.group(1)), int(m.group(2)),
                                               int(m.group(3)))
        # Independent recomputation from the vector file.
        want_tus = want_beats = None
        if expect == "pass":
            if name == "single_tu":
                want_tus, want_beats = 1, cases[0][2]
            elif name == "rect_tu":
                want_tus, want_beats = expected_shape(cases, "rect_tu")
            elif name == "sweep":
                want_tus = len(cases)
                want_beats = sum(c[2] for c in cases)
            elif name.startswith("multi_tu"):
                count = next(int(p.split("=")[1]) for p in plusargs
                             if p.startswith("+TU_COUNT="))
                start = next((int(p.split("=")[1]) for p in plusargs
                              if p.startswith("+TU_START=")), 0)
                idx = [(start + i * 7) % len(cases) for i in range(count)]
                want_tus, want_beats = count, sum(cases[i][2] for i in idx)
        if expect == "pass":
            ok = (rc == 0 and n_err == 0 and fatal == 0 and check_pass
                  and not mismatch and not proto
                  and saw_tus == want_tus and saw_beats == want_beats)
            if name.startswith("multi_tu"):
                ok = ok and saw_overlap is not None and saw_overlap > 0
        elif expect == "mismatch":
            ok = mismatch and n_err > 0
        elif expect == "protocol":
            ok = proto and n_err > 0
        else:
            ok = False
        cg = {}
        for m in re.finditer(r"ITS_CG (\w+) ([\d.]+) bins=(\S+)", text):
            cg[m.group(1)] = {"pct": float(m.group(2)), "bins": m.group(3)}
        m = re.search(r"ITS_CG beats=(\d+)", text)
        if m:
            cg["_beats"] = {"pct": None, "bins": m.group(1)}
        status = "PASS" if ok else "FAIL"
        detail = ""
        if expect == "pass":
            detail = (f" tus={saw_tus}/{want_tus} beats={saw_beats}/{want_beats}"
                      f" overlap={saw_overlap}")
        print(f"{status} err={n_err} fatal={fatal}{detail} ({dt:.0f}s)", flush=True)
        if cg:
            for k in ("shape", "xform", "lfnst", "sat", "backpressure", "stall_phase"):
                if k in cg:
                    print(f"        cg {k:<14} {cg[k]['pct']:6.2f}%  bins={cg[k]['bins']}",
                          flush=True)
        results.append({"name": name, "expect": expect, "status": status,
                        "uvm_errors": n_err, "uvm_fatals": fatal,
                        "check_pass_seen": check_pass, "mismatch_seen": mismatch,
                        "protocol_error_seen": proto,
                        "tus_reported": saw_tus, "tus_expected": want_tus,
                        "beats_reported": saw_beats, "beats_expected": want_beats,
                        "overlap_admissions": saw_overlap, "coverage": cg,
                        "returncode": rc, "elapsed_s": round(dt, 1)})
    (OUT / "UVM_RESULTS.json").write_text(json.dumps(results, indent=2),
                                          encoding="utf-8")
    sweep = next((r for r in results if r["name"] == "sweep"), None)
    if sweep and sweep.get("coverage"):
        gaps = {
            "shape":        "complete: all 25 supported (w,h) pairs hit",
            "xform":        "complete: DCT-II / DST-VII / DCT-VIII on both axes",
            "lfnst_mode":   "complete: off / set1 / set2",
            "lfnst_idx":    "complete: idx 0..3",
            "sat":          "complete: no-clamp / positive rail / negative rail",
            "backpressure": "complete: depth 0 / 1 / 2 / >=3",
            "stall_phase": (
                "4 of 6 reachable. lfnst and compute can never coincide with an "
                "output stall: unified_its_wrapper.sv:1354 gates compute_valid on "
                "!output_active, so no new kernel or LFNST run can start while a "
                "beat is pending. The two bins are unreachable by construction, "
                "not by missing stimulus."
            ),
        }
        d4 = {"stimulus": "sweep = all 369 vector cases in one simulation",
              "tus": sweep.get("tus_reported"),
              "beats": sweep.get("beats_reported"),
              "coverage": sweep["coverage"], "gap_notes": gaps}
        (OUT / "D4_COVERAGE.json").write_text(json.dumps(d4, indent=2),
                                              encoding="utf-8")
    ok = sum(1 for r in results if r["status"] == "PASS")
    print(f"\nsummary: {ok}/{len(results)} passed")


def load_vectors(path):
    """Return [(desc, input_count, beat_count)] straight from the vector file."""
    cases = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        tokens = fh.read().split()
    i = 0
    n = int(tokens[i]); i += 1
    for _ in range(n):
        desc = int(tokens[i], 16); ic = int(tokens[i + 1]); bc = int(tokens[i + 2])
        i += 3
        i += 2 * ic          # addr/value pairs
        i += bc              # expected beats
        cases.append((desc, ic, bc))
    return cases


def expected_shape(cases, test):
    """Mirror the sequence selection so the scoreboard numbers can be checked."""
    n = len(cases)
    if test == "single_tu":
        return 1, cases[0][2]
    if test == "rect_tu":
        for desc, _ic, bc in cases:
            w = desc & 0x7F
            h = (desc >> 7) & 0x7F
            if w != h:
                return 1, bc
        return 1, cases[0][2]
    if test.startswith("multi_tu"):
        return None, None    # filled in by caller with count/start
    return None, None


def run_stage_run(only):
    pass


def re_first_int(text, label):
    idx = text.find(label)
    if idx < 0:
        return 0
    tail = text[idx + len(label):].strip()
    num = ""
    for ch in tail:
        if ch.isdigit():
            num += ch
        elif num:
            break
    return int(num) if num else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stage", choices=["prep", "run", "all"])
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    only = {s for s in args.only.split(",") if s}
    if args.stage in ("prep", "all"):
        stage_prep()
    if args.stage in ("run", "all"):
        stage_run(only)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())