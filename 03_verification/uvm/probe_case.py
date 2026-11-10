"""One-off probe: run a test and dump its structured result.

Used while deriving the expected counts for the new negative tests. Not part of
the regression pipeline.
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run_its_uvm as env_mod  # noqa: E402

OUT = HERE / "run"


def probe(name, plusargs, timeout=900):
    res = OUT / f"probe_{name}.result"
    log = OUT / "logs" / f"probe_{name}.log"
    if res.exists():
        res.unlink()
    cmd = [env_mod.VSIM, "-batch", "-t", "1ps", "+UVM_NO_DPI", "-voptargs=+acc",
           f"+UVM_TESTNAME={name}"]
    cmd += [f"+{p}" for p in plusargs]
    cmd += [f"+RESULT_FILE={res}",
            f"-gVECTOR_FILE={OUT / 'unified_gate_c_vectors.txt'}",
            "-do", "run -all; quit -f", "work.its_uvm_tb"]
    rc, elapsed = env_mod.run(cmd, log, OUT, timeout)
    text = log.read_text(errors="replace") if log.exists() else ""
    print(f"\n=== {name} rc={rc} ({elapsed:.0f}s) ===")
    if res.exists():
        for line in res.read_text(errors="replace").splitlines():
            if line.startswith("cg."):
                if line.split("=")[-1] != "0":
                    print("   " + line)
            else:
                print("   " + line)
    else:
        print("   (no result file)")
    for pat in ("ITS_PROTOCOL_ERROR", "ITS_INCOMPLETE_TU", "ITS_DATA_MISMATCH",
                "ITS_RESET", "ITS_RAND ", "UVM_FATAL", "ITS_DONE_MISMATCH",
                "ITS_UNEXPECTED_BEAT"):
        hits = [l for l in text.splitlines() if pat in l]
        if hits:
            print(f"   [{pat}] x{len(hits)}: {hits[0].strip()[:150]}")


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        if ":" in arg:
            tn, pl = arg.split(":", 1)
            probe(tn, [p for p in pl.split(",") if p])
        else:
            probe(arg, [])