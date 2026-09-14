"""Generate deterministic Gate-C HDL vectors from the independent Oracle.

The output is an ephemeral line-oriented file consumed by
``unified_its_wrapper_numeric_tb.sv``.  Expected data is produced by the
Gate-A VTM10 model, never by RTL arithmetic.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from validate_gate_c_model import (
    CANONICAL,
    Descriptor,
    inverse_2d,
    load_json,
    output_beats,
)


CASES = [
    # All thirteen one-dimensional transform/size modes, embedded in square
    # two-dimensional cases so both vertical and horizontal paths execute.
    *(Descriptor(n, n, 0, 0) for n in (4, 8, 16, 32, 64)),
    *(Descriptor(n, n, 1, 1) for n in (4, 8, 16, 32)),
    *(Descriptor(n, n, 2, 2) for n in (4, 8, 16, 32)),
    # Rectangular and mixed-axis modes.
    Descriptor(32, 16, 2, 1),
    Descriptor(16, 32, 1, 2),
    # Active-LFNST coverage: nTrs=16/48, nonzeroSize=8/16, all set/index
    # selector extremes represented without claiming exhaustive hidden-golden
    # equivalence.
    Descriptor(4, 4, 0, 0, 0, 1),
    Descriptor(4, 16, 0, 0, 1, 2),
    Descriptor(8, 8, 0, 0, 3, 2),
    Descriptor(16, 8, 0, 0, 2, 1),
]


def full_engineering_cases() -> list[Descriptor]:
    """Load the complete Gate-A engineering tuple universe.

    The matrix deliberately contains an explicitly labelled engineering
    superset for LFNST-off and the source-backed active-LFNST set.  This
    generator consumes that machine-readable source instead of reconstructing
    a Cartesian product locally, so the Step12F HDL campaign cannot silently
    drift from Gate A.
    """
    evidence = (Path(__file__).resolve().parents[2] / "05_audit" /
                "current" / "27" / "step12d_engineering" /
                "LEGAL_TRANSFORM_MATRIX.json")
    matrix = json.loads(evidence.read_text(encoding="utf-8"))
    type_code = {"DCT2": 0, "DST7": 1, "DCT8": 2}
    cases: list[Descriptor] = []
    for row in matrix["lfnst_off"]["tuples"]:
        cases.append(Descriptor(
            row["width"], row["height"],
            type_code[row["tr_type_hor"]], type_code[row["tr_type_ver"]],
            row.get("lfnst_tr_set_idx", 0), row["lfnst_idx"]))
    for row in matrix["lfnst_on"]["tuples"]:
        cases.append(Descriptor(
            row["width"], row["height"],
            type_code[row["tr_type_hor"]], type_code[row["tr_type_ver"]],
            row["lfnst_tr_set_idx"], row["lfnst_idx"]))
    return cases


def sparse_entries(desc: Descriptor, seed: int) -> list[tuple[int, int]]:
    points = desc.width * desc.height
    candidates = [
        (0, 32767 if seed & 1 else -32768),
        (points - 1, -32768 if seed & 1 else 32767),
        ((seed * 17) % points, 511),
        ((desc.width + seed * 7) % points, -512),
    ]
    # Preserve the last value for duplicate raster addresses and emit them in
    # ascending raster order, matching the contest sparse-input contract.
    merged: dict[int, int] = {}
    for address, value in candidates:
        merged[address] = value
    return sorted(merged.items())


def pack_beat(values: tuple[int, int, int, int]) -> int:
    packed = 0
    for lane, value in enumerate(values):
        packed |= (value & 0x3FF) << (10 * lane)
    return packed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--full", action="store_true",
        help="emit all Gate-A engineering tuples instead of the 19-case smoke set",
    )
    args = parser.parse_args()

    canonical = load_json(CANONICAL)
    cases = full_engineering_cases() if args.full else CASES
    lines = [str(len(cases))]
    manifest_cases = []
    total_beats = 0
    for case_index, desc in enumerate(cases):
        entries = sparse_entries(desc, 0x520 + case_index)
        coeff = [[0 for _ in range(desc.width)] for _ in range(desc.height)]
        for address, value in entries:
            row, col = divmod(address, desc.width)
            coeff[row][col] = value
        wide = inverse_2d(
            coeff,
            desc.width,
            desc.height,
            desc.hor,
            desc.ver,
            desc.set_idx,
            desc.lfnst_idx,
            canonical,
        )
        beats = output_beats(wide, "LOW10")
        lines.append(f"{desc.pack():06x} {len(entries)} {len(beats)}")
        lines.extend(f"{address} {value}" for address, value in entries)
        lines.extend(f"{pack_beat(beat):010x}" for beat in beats)
        total_beats += len(beats)
        manifest_cases.append(
            {
                "descriptor": desc.pack(),
                "width": desc.width,
                "height": desc.height,
                "hor": desc.hor,
                "ver": desc.ver,
                "lfnst_set": desc.set_idx,
                "lfnst_idx": desc.lfnst_idx,
                "inputs": len(entries),
                "beats": len(beats),
                "campaign": "full_engineering_tuple_universe" if args.full else "directed_smoke",
            }
        )

    payload = "\n".join(lines) + "\n"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    encoded = payload.encode("ascii")
    args.output.write_bytes(encoded)
    print(
        json.dumps(
            {
                "status": "PASS_VECTOR_GENERATION",
                "cases": len(cases),
                "beats": total_beats,
                "campaign": "full_engineering_tuple_universe" if args.full else "directed_smoke",
                "sha256": hashlib.sha256(encoded).hexdigest().upper(),
                "case_manifest": manifest_cases,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
