"""Fail-closed self-test for the RTL trace comparator."""
from __future__ import annotations

import argparse
import csv
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl-trace", type=Path, required=True)
    ap.add_argument("--model-trace", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    with args.rtl_trace.open(encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        fieldnames = list(reader.fieldnames or [])
    comparator = Path(__file__).with_name("validate_step12b_rtl_trace.py")

    def mutate(name: str) -> list[dict[str, str]]:
        out = [dict(row) for row in rows]
        selected = next(i for i, row in enumerate(out)
                        if row["event"] == "vector_start")
        if name == "vector_start_cycle":
            out[selected]["cycle"] = str(int(out[selected]["cycle"]) + 1)
        elif name == "missing_kernel_group":
            out.pop(next(i for i, row in enumerate(out)
                         if row["event"] == "kernel_group"))
        elif name == "wrong_vector_id":
            out[selected]["vector"] = str((int(out[selected]["vector"]) + 1) & 0xFFFF)
        elif name == "duplicate_result_write":
            idx = next(i for i, row in enumerate(out)
                       if row["event"] == "result_write")
            out.insert(idx, dict(out[idx]))
        elif name == "output_index_swap":
            fires = [i for i, row in enumerate(out) if row["event"] == "output_fire"]
            out[fires[0]]["index"], out[fires[1]]["index"] = out[fires[1]]["index"], out[fires[0]]["index"]
        elif name == "done_cycle":
            idx = next(i for i, row in enumerate(out) if row["event"] == "it_done")
            out[idx]["cycle"] = str(int(out[idx]["cycle"]) + 1)
        elif name == "trace_rollback":
            idx = next(i for i, row in enumerate(out) if row["event"] == "kernel_group")
            out[idx]["cycle"] = str(int(out[idx]["cycle"]) - 100)
        else:
            raise ValueError(name)
        return out

    names = ["vector_start_cycle", "missing_kernel_group", "wrong_vector_id",
             "duplicate_result_write", "output_index_swap", "done_cycle",
             "trace_rollback"]
    results: dict[str, bool] = {}
    with tempfile.TemporaryDirectory(prefix="step12b_trace_mut_") as temp:
        temp_path = Path(temp)
        for name in names:
            path = temp_path / f"{name}.csv"
            with path.open("w", encoding="utf-8", newline="") as f:
                writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
                writer.writeheader()
                writer.writerows(mutate(name))
            proc = subprocess.run([sys.executable, str(comparator),
                                   "--rtl-trace", str(path),
                                   "--model-trace", str(args.model_trace)],
                                  capture_output=True, text=True)
            results[name] = proc.returncode != 0
            if not results[name]:
                raise SystemExit(f"mutation was not rejected: {name}\n{proc.stdout}\n{proc.stderr}")
    payload = {"status": "PASS", "scope": "RTL trace comparator mutations",
               "mutations": results}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print("STEP12B_TRACE_MUTATION_PASS " + json.dumps(payload, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
