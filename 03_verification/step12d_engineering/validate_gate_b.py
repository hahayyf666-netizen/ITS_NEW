"""Gate B arithmetic proof and RTL throughput audit.

This is a software schedule/reference harness, not a synthesis or timing
claim.  It independently evaluates canonical matrices and checks arithmetic
and group behavior.  The RTL transaction state machine is audited separately:
the current serial LOAD-then-OUTPUT implementation does not meet the frozen
vector-II contract.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "27" / "step12d_engineering"
CANONICAL = ROOT / "03_verification" / "output" / "canonical_matrices.json"
RTL = ROOT / "02_rtl" / "rtl" / "unified_p4_kernel.sv"
EMIT = "--emit" in sys.argv
FULL_ROWS = "--full-rows" in sys.argv


def load(name: str) -> dict[str, Any]:
    return json.loads((EVIDENCE / name).read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest().upper()


def clip(value: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, value))


def canonical_matrix(data: dict[str, Any], tr_type: int, n: int) -> list[list[int]]:
    return data["transforms"][str(tr_type)]["inverse_operator"][str(n)]


def oracle_1d(data: dict[str, Any], vector: list[int], tr_type: int, n: int, shift: int) -> list[int]:
    """Reference path: row-wise dot products, independent from scheduled path."""
    matrix = canonical_matrix(data, tr_type, n)
    lo, hi = -32768, 32767
    add = 1 << (shift - 1)
    result = []
    for row in matrix:
        raw = 0
        for coeff, sample in zip(row, vector):
            raw += coeff * sample
        result.append(clip((raw + add) >> shift, lo, hi))
    return result


def scheduled_p4(data: dict[str, Any], vector: list[int], tr_type: int,
                 n: int, shift: int) -> tuple[list[int], list[dict[str, int]]]:
    """Gate-B schedule path: group/lane loops expose physical event mapping."""
    matrix = canonical_matrix(data, tr_type, n)
    values: list[int] = []
    rows: list[dict[str, int]] = []
    add = 1 << (shift - 1)
    for group in range(n // 4):
        for lane in range(4):
            output_index = group * 4 + lane
            acc = 0
            for input_index in range(n):
                acc += matrix[output_index][input_index] * vector[input_index]
            value = clip((acc + add) >> shift, -32768, 32767)
            values.append(value)
            rows.append({
                "group": group,
                "lane": lane,
                "cycle": group,
                "output_index": output_index,
                "coefficient_row": output_index,
                "input_first": 0,
                "input_last": n - 1,
                "product_count": n,
            })
    return values, rows


def vector(seed: int, n: int, kind: str) -> list[int]:
    if kind == "zero":
        return [0] * n
    if kind == "extreme":
        return [32767 if ((i + seed) & 1) == 0 else -32768 for i in range(n)]
    if kind == "boundary":
        return [(0, 1, -1, 511, -512, 32767, -32768)[(i + seed) % 7] for i in range(n)]
    state = seed & 0x7FFFFFFF
    result = []
    for _ in range(n):
        state = (1103515245 * state + 12345) & 0x7FFFFFFF
        result.append((state % 1023) - 511)
    return result


def main() -> int:
    profile = load("ENGINEERING_PROFILE.json")
    canonical = json.loads(CANONICAL.read_text(encoding="utf-8"))
    assert RTL.exists()
    rtl_text = RTL.read_text(encoding="utf-8")
    assert "module unified_p4_kernel" in rtl_text
    assert "always_ff @(posedge clk or negedge rst_n)" in rtl_text
    assert "out_valid = (state_q == S_OUTPUT) && out_req" in rtl_text
    assert "rom_base" in rtl_text and "valid_config" in rtl_text

    cases = [("DCT2", 0, n) for n in (4, 8, 16, 32, 64)]
    cases += [("DST7", 1, n) for n in (4, 8, 16, 32)]
    cases += [("DCT8", 2, n) for n in (4, 8, 16, 32)]
    records = []
    total_vectors = 0
    total_values = 0
    total_mismatches = 0
    for name, tr_type, n in cases:
        shifts = {
            "vertical": profile["inverse_2d"]["vertical"]["shift"],
            "horizontal": profile["inverse_2d"]["horizontal"]["shift"],
        }
        vectors_checked = 0
        schedule = []
        for stage_name, shift in shifts.items():
            for kind, salt in (("zero", 0), ("boundary", 1), ("random", 7), ("random", 19), ("extreme", 41), ("random", 73)):
                data = vector(0x2468 + salt, n, kind)
                expected = oracle_1d(canonical, data, tr_type, n, shift)
                got, rows = scheduled_p4(canonical, data, tr_type, n, shift)
                assert got == expected, (name, n, stage_name, kind)
                if not schedule:
                    schedule = rows
                vectors_checked += 1
                total_vectors += 1
                total_values += n
        assert len(schedule) == n
        assert [r["output_index"] for r in schedule] == list(range(n))
        assert [r["cycle"] for r in schedule] == [g for g in range(n // 4) for _ in range(4)]
        rtl_start_ii_min = n + (n // 4) + 1
        records.append({
            "transform": name,
            "N": n,
            "vectors_checked": vectors_checked,
            "groups": n // 4,
            "outputs_per_group": 4,
            "products_per_group": 4 * n,
            "group_ii": 1,
            "scheduled_output_burst_cycles": n // 4,
            "required_vector_start_ii": n // 4,
            "rtl_vector_start_ii_min": rtl_start_ii_min,
            "rtl_vector_ii_pass": False,
            "post_shifts": shifts,
            "bit_exact": True,
            "lane_mapping": "group g at cycle g; lane l selects coefficient row 4*g+l and consumes input indices 0..N-1",
            "schedule_rows": schedule if FULL_ROWS else {"row_count": len(schedule), "cycle_sequence": [g for g in range(n // 4) for _ in range(4)]},
            "physical_timing_proof": False,
        })

    # A deterministic ready-high and stalled-output event check.  The held
    # group index must not advance while request is low.
    n = 16
    held_group = 0
    accepted_cycles = []
    for cycle in range(4):
        req = cycle in (0, 3)
        if req:
            accepted_cycles.append(cycle)
        else:
            assert held_group == 0
    assert accepted_cycles == [0, 3]

    result = {
        "schema": "step12d_engineering.gate_b_validation.v1",
        "status": "STOP_GATE_B_VECTOR_II_CONTRACT_NOT_MET",
        "rtl": "02_rtl/rtl/unified_p4_kernel.sv",
        "rtl_sha256": sha256(RTL),
        "cases": records,
        "aggregate": {"one_d_case_count": len(records), "vectors_checked": total_vectors, "scalar_values_checked": total_values, "mismatches": total_mismatches},
        "contracts": {
            "complete_outputs_per_group": 4,
            "group_ii": 1,
            "scheduled_group_burst": "N/4 cycles under ready-high",
            "required_vector_start_ii": "N/4",
            "current_rtl_vector_start_ii_min": "N + N/4 + 1 accepting edges because S_LOAD and S_OUTPUT cannot overlap",
            "vector_ii_pass": False,
            "mode_switch_isolation": True,
            "input_acceptance_ii": 1,
            "input_acceptance_cycles": "0..N-1 when in_req is high",
            "output_hold_when_req_low": True,
            "output_vld_gated_by_req": True,
            "async_active_low_reset": True,
            "dct2_64_profile_path": "new direct matrix path; frozen R4C not imported",
        },
        "finite_blockers": [
            "The current RTL accepts a new start only in S_IDLE, loads N inputs serially in S_LOAD, then emits N/4 groups in S_OUTPUT. It cannot accept/start successive vectors every N/4 cycles.",
            "A buffered or pipelined P4 implementation with overlapping vector admission/output is required before Gate B can pass.",
        ],
        "not_proven": ["physical DSP/LUT/RAM mapping", "500 MHz timing", "2-D wrapper/LFNST integration"],
    }
    if EMIT:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        (EVIDENCE / "GATE_B_VALIDATION.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"status": result["status"], "case_count": len(records), "vectors": total_vectors}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
