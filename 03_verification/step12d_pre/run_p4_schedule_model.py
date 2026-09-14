"""Execute the candidate direct-P4 schedule against independent arithmetic.

The model makes the cycle/group/lane/coefficient mapping explicit and checks
bit-exact 1-D output.  It does not prove a factorized 64-point schedule,
physical multiplier sharing, or timing.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "26" / "step12d_pre"
CANONICAL = ROOT / "03_verification" / "output" / "canonical_matrices.json"
ORACLE_DIR = ROOT / "04_reference" / "oracle"


def wrap16(value: int) -> int:
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def load_oracle():
    spec = importlib.util.spec_from_file_location("frozen_v34_rtl_bitexact", ORACLE_DIR / "v34_rtl_bitexact.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load frozen oracle")
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(ORACLE_DIR))
    spec.loader.exec_module(module)
    return module


def execute_case(canonical: dict, tr_type: int, n: int, vector: list[int]) -> tuple[list[int], list[dict[str, int]]]:
    matrix = canonical["transforms"][str(tr_type)]["inverse_operator"][str(n)]
    schedule: list[dict[str, int]] = []
    outputs: list[int] = []
    for group in range(n // 4):
        cycle_outputs = []
        for lane in range(4):
            output_index = group * 4 + lane
            input_indices = list(range(n))
            raw = sum(matrix[output_index][j] * vector[j] for j in input_indices)
            value = wrap16((raw + 32) >> 6)
            cycle_outputs.append(value)
            schedule.append({
                "cycle": group,
                "group": group,
                "lane": lane,
                "output_index": output_index,
                "input_first": input_indices[0],
                "input_last": input_indices[-1],
                "product_count": n,
            })
        outputs.extend(cycle_outputs)
    return outputs, schedule


def build_proof() -> dict:
    canonical = json.loads(CANONICAL.read_text(encoding="utf-8"))
    oracle = load_oracle()
    cases = [(0, n) for n in (4, 8, 16, 32, 64)]
    cases += [(1, n) for n in (4, 8, 16, 32)]
    cases += [(2, n) for n in (4, 8, 16, 32)]
    records = []
    for tr_type, n in cases:
        vectors_checked = 0
        schedule_rows = []
        for salt in (0, 1, 7, 19, 41):
            vector = [((i * 37 + salt * 19) % 511) - 255 for i in range(n)]
            got, rows = execute_case(canonical, tr_type, n, vector)
            expected = oracle.main_1d(vector, tr_type, n)
            assert got == expected
            if salt == 0:
                schedule_rows = rows
            vectors_checked += 1
        assert len(schedule_rows) == n
        assert [r["output_index"] for r in schedule_rows] == list(range(n))
        assert [r["cycle"] for r in schedule_rows] == [g for g in range(n // 4) for _ in range(4)]
        assert all(r["product_count"] == n for r in schedule_rows)
        records.append({
            "transform_type": tr_type,
            "N": n,
            "groups": n // 4,
            "group_ii": 1,
            "vector_ii_candidate": n // 4,
            "vectors_checked": vectors_checked,
            "products_per_group": 4 * n,
            "schedule_class": "factorized_64_reference_required" if (tr_type == 0 and n == 64) else "direct_p4_executed",
            "bit_exact_against_frozen_oracle": True,
            "physical_proof": False,
        })
    return {
        "schema": "step12d_pre.p4_execution_proof.v1",
        "status": "PASS_EXECUTABLE_P4_SCHEDULE_NOT_PHYSICAL_PROOF",
        "cases": records,
        "schedule_semantics": {
            "cycle": "group index within one accepted N-point vector",
            "lane": "four consecutive complete output indices",
            "coefficient_mapping": "lane output index selects one matrix row; all N input coefficients are consumed",
            "group_ii": 1,
            "vector_ii": "N/4 candidate",
        },
        "dct2_64_boundary": "Direct schedule is arithmetic reference only; factorized 128-lane R4C schedule remains separately required.",
        "physical_proof": False,
        "vivado_run": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stdout", action="store_true")
    args = parser.parse_args()
    proof = build_proof()
    if args.stdout:
        print(json.dumps(proof, ensure_ascii=False, indent=2))
        return 0
    (EVIDENCE / "P4_EXECUTION_PROOF.json").write_text(
        json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps({
        "status": proof["status"],
        "case_count": len(proof["cases"]),
        "physical_proof": False,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
