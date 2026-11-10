#!/usr/bin/env python
"""D1 coverage baseline driver.

Reuses the project's own step12f testbench set and vector generators, but:
  * compiles with +cover=bcestf  (branch/condition/expression/statement/toggle/FSM)
  * launches vsim with -batch    (the -c console path is blocked by policy)
  * saves one UCDB per testbench, then merges and reports

Usage:
    python run_d1.py prep                 # generate vectors + compile with coverage
    python run_d1.py run [--only a,b,c]   # simulate testbenches, save UCDBs
    python run_d1.py report               # merge UCDBs + produce reports
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

MS = Path(r"D:\software\Modelsim\win64")
VSIM = MS / "vsim.exe"
VLOG = MS / "vlog.exe"
VLIB = MS / "vlib.exe"
VCOVER = MS / "vcover.exe"
LIC = r"D:\software\Modelsim\LICENSE.TXT"

REPO = Path(__file__).resolve().parents[2] / "its_push"
BASE = Path(__file__).resolve().parent
MODE = "normal"
OUT = BASE / "run"
PROFILE = "contest_engineering_vtm10_sat10_v2"

RTL = [
    REPO / "02_rtl/rtl/its_simple_ram.sv",
    REPO / "02_rtl/rtl/its_input_cache_bank.sv",
    REPO / "02_rtl/rtl/unified_p4_kernel.sv",
    REPO / "02_rtl/rtl/bounded_lfnst_engine.sv",
    REPO / "02_rtl/rtl/unified_its_wrapper.sv",
    REPO / "02_rtl/rtl/its_unified_submission_top.sv",
]

TB_NAMES = [
    "unified_p4_kernel_numeric_tb",
    "unified_p4_kernel_throughput_tb",
    "unified_p4_kernel_throughput_full_tb",
    "unified_its_wrapper_tb",
    "unified_its_wrapper_p3_tb",
    "unified_p4_kernel_p4_tb",
    "unified_p4_fifo_payload_reset_tb",
    "unified_its_wrapper_numeric_tb",
    "unified_its_final_adapter_tb",
    "unified_its_sat10_wrapper_tb",
    "unified_its_hread_raw_capture_tb",
    "unified_its_primary_v_return_tb",
    "its_unified_submission_top_sat10_tb",
    "its_unified_submission_top_numeric_tb",
    "its_unified_submission_top_protocol_tb",
    "bounded_lfnst_engine_tb",
]

# tag, design, vector override, pass marker
RUNS = [
    ("kernel_numeric", "unified_p4_kernel_numeric_tb", None, "GATE_B_NUMERIC_TB_PASS cases=156"),
    ("kernel_ii", "unified_p4_kernel_throughput_tb", None, "GATE_B_VECTOR_II_TB_PASS modes=7"),
    ("kernel_ii_full", "unified_p4_kernel_throughput_full_tb", None, "GATE_F_VECTOR_II_TB_PASS modes=13"),
    ("wrapper_smoke", "unified_its_wrapper_tb", None, "GATE_C_WRAPPER_TB_PASS beats=16/16 done=1/1"),
    ("wrapper_p3", "unified_its_wrapper_p3_tb", None, "P3_VWRITE_TB_PASS"),
    ("kernel_p4", "unified_p4_kernel_p4_tb", None, "GATE_F_P4_STAGE0_TB_PASS"),
    ("fifo_reset", "unified_p4_fifo_payload_reset_tb", None, "P4_FIFO_PAYLOAD_RESET_PASS"),
    ("wrapper_numeric", "unified_its_wrapper_numeric_tb", None, "GATE_C_NUMERIC_TB_PASS cases=369"),
    ("adapter_sat10", "unified_its_final_adapter_tb", None, "SAT10_ADAPTER_EXHAUSTIVE_PASS values=65536"),
    ("sat10_wrapper", "unified_its_sat10_wrapper_tb", None, "SAT10_WRAPPER_BOUNDARY_PASS"),
    ("hread_raw", "unified_its_hread_raw_capture_tb", None, "H_READ_RAW_CAPTURE_PASS"),
    ("primary_v_return", "unified_its_primary_v_return_tb", None, "PRIMARY_V_RETURN_PASS"),
    ("top_sat10", "its_unified_submission_top_sat10_tb", None, "SAT10_SUBMISSION_TOP_PASS"),
    ("top_gate_c", "its_unified_submission_top_numeric_tb", None, "SUBMISSION_TOP_NUMERIC_PASS cases=369"),
    ("top_lfnst", "its_unified_submission_top_numeric_tb", "lfnst_wrapper_vectors.txt", "SUBMISSION_TOP_NUMERIC_PASS cases=388"),
    ("top_protocol", "its_unified_submission_top_protocol_tb", None, "SUBMISSION_TOP_PROTOCOL_PASS"),
    ("lfnst_engine", "bounded_lfnst_engine_tb", None, "LFNST_ENGINE_TB_PASS cases=1088"),
    ("lfnst_wrapper", "unified_its_wrapper_numeric_tb", "lfnst_wrapper_vectors.txt", "GATE_C_NUMERIC_TB_PASS cases=388"),
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


def gen(cmd, logname):
    rc, dt = run(cmd, OUT / "logs" / logname, OUT, 3600)
    if rc != 0:
        print(f"  GENERATOR FAILED: {logname} rc={rc}")
        sys.exit(1)


def stage_prep():
    OUT.mkdir(parents=True, exist_ok=True)
    gdir = REPO / "03_verification/step12d_engineering"

    print("[1/5] generating vector sets ...", flush=True)
    gen([sys.executable, gdir / "generate_gate_b_hdl_vectors.py", OUT / "unified_gate_b_vectors.txt"],
        "gen_gate_b.log")
    gen([sys.executable, gdir / "generate_gate_c_hdl_vectors.py", "--profile", PROFILE, "--full",
         OUT / "unified_gate_c_vectors.txt"], "gen_gate_c.log")
    gen([sys.executable, gdir / "generate_lfnst_engine_vectors.py", OUT / "lfnst_engine_vectors.txt"],
        "gen_lfnst_engine.log")
    gen([sys.executable, gdir / "generate_lfnst_wrapper_vectors.py", "--profile", PROFILE,
         OUT / "lfnst_wrapper_vectors.txt"], "gen_lfnst_wrapper.log")
    for f in ("unified_gate_c_vectors.txt", "unified_gate_b_vectors.txt"):
        p = OUT / f
        print(f"      {f}: {p.stat().st_size} B")

    print("[2/5] staging coefficient ROM files ...", flush=True)
    romdir = OUT / "03_verification" / "sim"
    romdir.mkdir(parents=True, exist_ok=True)
    for h in ("rom_coeffs.hex", "lfnst_coeffs.hex", "lfnst_packed_coeffs.hex"):
        shutil.copy2(REPO / "02_rtl/rtl" / h, romdir / h)

    print("[3/5] vlib work ...", flush=True)
    if (OUT / "work").exists():
        shutil.rmtree(OUT / "work", ignore_errors=True)
    rc, _ = run([VLIB, "work"], OUT / "logs/vlib.log", OUT, 300)
    if rc != 0:
        print("  vlib failed"); sys.exit(1)

    print("[4/5] vlog -sv +cover=bcestf (6 RTL + 16 TB) ...", flush=True)
    files = list(RTL) + [REPO / "03_verification/tb" / f"{t}.sv" for t in TB_NAMES]
    missing = [f for f in files if not f.exists()]
    if missing:
        print("  MISSING SOURCES: " + ", ".join(str(m) for m in missing)); sys.exit(1)
    cmd = [VLOG, "-sv", "+cover=bcestf"]
    if MODE == "synthesis":
        cmd.append("+define+SYNTHESIS")
    cmd += files + ["-l", OUT / "logs/compile.log"]
    rc, dt = run(cmd, OUT / "logs/compile.stdout.log", OUT, 3600)
    text = (OUT / "logs/compile.log").read_text(encoding="utf-8", errors="replace")
    errs = text.count("** Error")
    warns = text.count("** Warning")
    print(f"      exit={rc}  errors={errs}  warnings={warns}  ({dt:.0f}s)")
    if rc != 0 or errs:
        print("  COMPILE FAILED"); sys.exit(1)

    print("[5/5] prep done", flush=True)


def stage_run(only):
    ucdir = OUT / "ucdb"
    ucdir.mkdir(parents=True, exist_ok=True)
    sel = [r for r in RUNS if not only or r[0] in only]
    print(f"simulating {len(sel)} testbench run(s)", flush=True)
    results = []
    for tag, design, vec, marker in sel:
        ucdb = ucdir / f"{tag}.ucdb"
        if ucdb.exists():
            ucdb.unlink()
        do = f"coverage save -testname {MODE}_{tag} -onexit {{{ucdb}}}; run -all; quit -f"
        cmd = [VSIM, "-batch", "-coverage", "-t", "1ps", "-do", do]
        if vec:
            cmd.append(f"-gVECTOR_FILE={vec}")
        cmd.append(f"work.{design}")
        log = OUT / "logs" / f"sim_{tag}.log"
        print(f"  [{tag}] {design} ...", end=" ", flush=True)
        rc, dt = run(cmd, log, OUT, 7200)
        text = log.read_text(encoding="utf-8", errors="replace")
        passed = marker in text
        uok = ucdb.exists()
        status = "PASS" if passed else ("ERR" if "** Error" in text or "** Fatal" in text else "NOMARK")
        if not uok:
            status += "_NOUCDB"
        print(f"{status} ucdb={'Y' if uok else 'N'} ({dt:.0f}s)", flush=True)
        results.append({"tag": tag, "design": design, "vector": vec, "status": status,
                        "ucdb": ucdb.name if uok else None, "elapsed_s": round(dt, 1),
                        "returncode": rc})
    (OUT / "SIM_RESULTS.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    ok = sum(1 for r in results if r["status"].startswith("PASS"))
    print(f"\nsummary: {ok}/{len(results)} passed")


def stage_report():
    ucdir = OUT / "ucdb"
    uc = sorted(ucdir.glob("*.ucdb"))
    if not uc:
        print("no UCDBs"); sys.exit(1)
    merged = OUT / "merged.ucdb"
    if merged.exists():
        merged.unlink()
    rc, _ = run([VCOVER, "merge", merged] + uc, OUT / "logs/vcover_merge.log", OUT, 1800)
    print(f"merge exit={rc}  inputs={len(uc)}")
    for name, extra in (("summary", []),
                        ("detail", ["-detail"]),
                        ("html", ["-html"])):
        log = OUT / "logs" / f"vcover_{name}.log"
        args = [VCOVER, "report"] + extra + ["-output", OUT / f"coverage_{name}.txt", merged]
        rc, _ = run(args, log, OUT, 1800)
        print(f"  report {name}: exit={rc}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("stage", choices=["prep", "run", "report", "all"])
    ap.add_argument("--only", default="")
    ap.add_argument("--mode", choices=["normal", "synthesis"], default="normal")
    a = ap.parse_args()
    MODE = a.mode
    OUT = BASE / ("run" if MODE == "normal" else f"run_{MODE}")
    only = set(x.strip() for x in a.only.split(",") if x.strip())
    if a.stage in ("prep", "all"):
        stage_prep()
    if a.stage in ("run", "all"):
        stage_run(only)
    if a.stage in ("report", "all"):
        stage_report()