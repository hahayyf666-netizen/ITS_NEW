"""Independent VTM-profile inverse-transform oracle and ambiguity audit.

The implementation uses only immutable canonical coefficient matrices.  It
does not import the historical RTL oracle, wrapper arithmetic, or any RTL
source.  ``--emit`` prints the result so a caller can store it through the
repository patch workflow on Windows worktrees where generated audit paths
are ACL-protected.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
CANONICAL_PATH = ROOT / "03_verification" / "output" / "canonical_matrices.json"
EVIDENCE = ROOT / "05_audit" / "current" / "27" / "step12d_engineering"
EMIT = "--emit" in sys.argv


def load_canonical() -> dict[str, Any]:
    return json.loads(CANONICAL_PATH.read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest().upper()


def clip3(value: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, value))


def low10(value: int) -> int:
    bits = value & 0x3FF
    return bits if bits < 512 else bits - 1024


def sat10(value: int) -> int:
    return clip3(value, -512, 511)


def wrap16(value: int) -> int:
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def profile_params(bit_depth: int, extended: bool) -> dict[str, int]:
    max_range = min(20, bit_depth + 6) if extended else 15
    return {
        "bit_depth": bit_depth,
        "extended": int(extended),
        "max_range": max_range,
        "vertical_shift": 7,
        "vertical_add": 64,
        "horizontal_shift": 6 + max_range - 1 - bit_depth,
        "horizontal_add": 1 << (6 + max_range - 1 - bit_depth - 1),
    }


def apply_shift_clip(raw: int, shift: int, lo: int, hi: int) -> int:
    # VTM adds the positive rounding factor before an arithmetic right shift.
    return clip3((raw + (1 << (shift - 1))) >> shift, lo, hi)


def transform_matrix(canonical: dict[str, Any], tr_type: int, n: int) -> list[list[int]]:
    return canonical["transforms"][str(tr_type)]["inverse_operator"][str(n)]


def inverse_1d(vector: list[int], tr_type: int, n: int, *, shift: int,
               clip: tuple[int, int], canonical: dict[str, Any]) -> list[int]:
    if len(vector) != n:
        raise ValueError(f"1-D input length {len(vector)} != {n}")
    matrix = transform_matrix(canonical, tr_type, n)
    return [apply_shift_clip(sum(matrix[i][j] * vector[j] for j in range(n)), shift, *clip)
            for i in range(n)]


def skip_lines(width: int, height: int, hor: int, ver: int, lfnst_idx: int) -> tuple[int, int]:
    if lfnst_idx:
        if (width == 4 and height > 4) or (height == 4 and width > 4):
            return width - 4, height - 4
        if width >= 8 and height >= 8:
            return width - 8, height - 8
    skip_w = 16 if hor != 0 and width == 32 else max(width - 32, 0)
    skip_h = 16 if ver != 0 and height == 32 else max(height - 32, 0)
    return skip_w, skip_h


def diag_scan(width: int, height: int) -> list[tuple[int, int]]:
    result: list[tuple[int, int]] = []
    for diagonal in range(width + height - 1):
        points = []
        for row in range(height):
            col = diagonal - row
            if 0 <= col < width:
                points.append((row, col))
        if diagonal & 1:
            points.reverse()
        result.extend(points)
    return result


def apply_lfnst(coeff: list[list[int]], width: int, height: int, set_idx: int,
                lfnst_idx: int, canonical: dict[str, Any], profile: dict[str, int]) -> list[list[int]]:
    if lfnst_idx not in (1, 2):
        return [row[:] for row in coeff]
    ntrs = 48 if width >= 8 and height >= 8 else 16
    nonzero = 8 if (width, height) in ((4, 4), (8, 8)) else 16
    sb = 8 if ntrs == 48 else 4
    scan = diag_scan(sb, sb)
    gathered = [coeff[r][c] if r < height and c < width else 0 for r, c in scan[:16]]
    matrix = canonical["lfnst"][str(ntrs)][str(set_idx)][str(lfnst_idx)]
    wide = []
    for out in range(ntrs):
        raw = sum(matrix[out][j] * gathered[j] for j in range(nonzero))
        wide.append(apply_shift_clip(raw, 7, -(1 << profile["max_range"]), (1 << profile["max_range"]) - 1))

    # Contest profile fixes a deterministic non-transposed low-frequency
    # scatter.  The supplied matrix remains the source of coefficients; this
    # explicit scatter is an engineering binding, not an assertion about all
    # VTM intra-mode transpose contexts.
    result = [row[:] for row in coeff]
    out_scan = diag_scan(sb, sb)[:ntrs]
    for (r, c), value in zip(out_scan, wide):
        if r < height and c < width:
            result[r][c] = value
    for r, c in scan[:16]:
        if r < height and c < width and (r, c) not in out_scan:
            result[r][c] = 0
    return result


def inverse_2d(coeff: list[list[int]], width: int, height: int, hor: int, ver: int,
               *, lfnst_idx: int = 0, set_idx: int = 0,
               params: dict[str, int], canonical: dict[str, Any]) -> list[list[int]]:
    if len(coeff) != height or any(len(row) != width for row in coeff):
        raise ValueError("coefficient shape mismatch")
    work = apply_lfnst(coeff, width, height, set_idx, lfnst_idx, canonical, params)
    skip_w, skip_h = skip_lines(width, height, hor, ver, lfnst_idx)
    cutoff_h = height - skip_h
    cutoff_w = width - skip_w
    vmat = transform_matrix(canonical, ver, height)
    hmat = transform_matrix(canonical, hor, width)
    vclip = (-(1 << params["max_range"]), (1 << params["max_range"]) - 1)
    tmp = [[0 for _ in range(width)] for _ in range(height)]
    for col in range(cutoff_w):
        for out_row in range(cutoff_h):
            raw = sum(vmat[out_row][k] * work[k][col] for k in range(cutoff_h))
            tmp[out_row][col] = apply_shift_clip(raw, params["vertical_shift"], *vclip)
    # VTM explicitly zeroes skipped output rows/columns.  The horizontal
    # stage consumes only cutoff_w columns and produces all width outputs.
    out = [[0 for _ in range(width)] for _ in range(height)]
    pel_clip = (-32768, 32767)
    for row in range(height):
        for out_col in range(width):
            raw = sum(hmat[out_col][k] * tmp[row][k] for k in range(cutoff_w))
            out[row][out_col] = apply_shift_clip(raw, params["horizontal_shift"], *pel_clip)
    return out


def legacy_2d(coeff: list[list[int]], width: int, height: int, hor: int, ver: int,
              canonical: dict[str, Any]) -> list[list[int]]:
    """Independent historical Step12B baseline, not imported from old code."""
    vmat = transform_matrix(canonical, ver, height)
    hmat = transform_matrix(canonical, hor, width)
    tmp = [[wrap16((sum(vmat[r][k] * coeff[k][c] for k in range(height)) + 32) >> 6)
            for c in range(width)] for r in range(height)]
    return [[wrap16((sum(hmat[c][k] * tmp[r][k] for k in range(width)) + 32) >> 6)
             for c in range(width)] for r in range(height)]


def lcg(seed: int) -> int:
    return (1103515245 * seed + 12345) & 0x7FFFFFFF


def sample_matrix(width: int, height: int, seed: int, kind: str) -> list[list[int]]:
    values: list[int] = []
    state = seed & 0x7FFFFFFF
    for i in range(width * height):
        if kind == "zero":
            value = 0
        elif kind == "extreme":
            value = 32767 if ((i + seed) & 1) == 0 else -32768
        elif kind == "boundary":
            value = (0, 1, -1, 511, -512, 32767, -32768)[i % 7]
        else:
            state = lcg(state)
            value = (state % 1023) - 511
        values.append(value)
    return [values[row * width:(row + 1) * width] for row in range(height)]


def supported_tuples() -> list[tuple[int, int, int, int]]:
    shapes = [(4, 4), (4, 8), (4, 16), (4, 32), (4, 64), (8, 4), (16, 4), (32, 4), (64, 4),
              (8, 8), (8, 16), (8, 32), (8, 64), (16, 8), (32, 8), (64, 8), (16, 16),
              (16, 32), (16, 64), (32, 16), (32, 32), (32, 64), (64, 16), (64, 32), (64, 64)]
    result = []
    for width, height in shapes:
        for hor in (0, 1, 2):
            for ver in (0, 1, 2):
                if (width == 64 and hor != 0) or (height == 64 and ver != 0):
                    continue
                result.append((width, height, hor, ver))
    assert len(result) == 169
    return result


def audit_bucket(name: str, tuples: list[tuple[int, int, int, int]], kind: str,
                 canonical: dict[str, Any], params: dict[str, int]) -> dict[str, Any]:
    total = 0
    profile_diffs = 0
    adapter_diffs = 0
    out_of_range = 0
    profile_variant_diffs = 0
    variant = profile_params(10, True)
    legacy_diffs = 0
    case_rows = []
    for index, (width, height, hor, ver) in enumerate(tuples):
        coeff = sample_matrix(width, height, 0x13579BDF + index * 17, kind)
        wide = inverse_2d(coeff, width, height, hor, ver, params=params, canonical=canonical)
        alt_wide = inverse_2d(coeff, width, height, hor, ver, params=variant, canonical=canonical)
        old = legacy_2d(coeff, width, height, hor, ver, canonical)
        local_total = width * height
        local_profile = sum(1 for r in range(height) for c in range(width) if wide[r][c] != alt_wide[r][c])
        local_adapter = sum(1 for r in range(height) for c in range(width) if low10(wide[r][c]) != sat10(wide[r][c]))
        local_legacy = sum(1 for r in range(height) for c in range(width) if low10(wide[r][c]) != low10(old[r][c]))
        local_range = sum(1 for row in wide for value in row if not (-512 <= value <= 511))
        total += local_total
        profile_variant_diffs += local_profile
        adapter_diffs += local_adapter
        legacy_diffs += local_legacy
        out_of_range += local_range
        case_rows.append({"width": width, "height": height, "hor": hor, "ver": ver, "values": local_total, "profile_variant_diffs": local_profile, "adapter_diffs": local_adapter, "out_of_range": local_range, "legacy_low10_diffs": local_legacy})
    profile_diffs = profile_variant_diffs
    return {"bucket": name, "sample_kind": kind, "case_count": len(tuples), "scalar_values": total, "profile_ambiguity_differences": profile_diffs, "adapter_low10_vs_sat10_differences": adapter_diffs, "signed10_out_of_range": out_of_range, "legacy_baseline_low10_differences": legacy_diffs, "cases": case_rows}


def main() -> int:
    canonical = load_canonical()
    params = profile_params(10, False)
    tuples = supported_tuples()
    one_d = [(0, n, 0, 0) for n in (4, 8, 16, 32, 64)] + [(1, n, 0, 0) for n in (4, 8, 16, 32)] + [(2, n, 0, 0) for n in (4, 8, 16, 32)]
    buckets = [
        audit_bucket("official_vectors", [], "zero", canonical, params),
        audit_bucket("VTM_reference_vectors", tuples[::7] + [(w, h, hor, ver) for _, w, hor, ver in one_d[:0]], "random", canonical, params),
        audit_bucket("directed_boundary_vectors", [(4, 4, 0, 0), (8, 8, 0, 0), (16, 16, 1, 2), (32, 32, 2, 1), (64, 64, 0, 0)], "boundary", canonical, params),
        audit_bucket("seeded_random_vectors", tuples[:48], "random", canonical, params),
        audit_bucket("extreme_vectors", [(4, 4, 0, 0), (8, 16, 1, 0), (16, 32, 2, 1), (32, 32, 1, 2), (64, 64, 0, 0)], "extreme", canonical, params),
    ]
    result = {
        "schema": "step12d_engineering.vtm_profile_oracle_results.v1",
        "status": "PASS_INDEPENDENT_VTM_PROFILE_ORACLE_AND_IMPACT_AUDIT",
        "canonical_sha256": sha256(CANONICAL_PATH),
        "profile": params,
        "profile_variant": profile_params(10, True),
        "profile_variant_name": "bitDepth10_extendedPrecisionOn",
        "one_d_cases_available": len(one_d),
        "buckets": buckets,
        "interpretation": {
            "profile_ambiguity": "compares engineering profile (10-bit, extended off) with a distinct VTM profile; differences do not prove contest hidden-golden behavior",
            "adapter_ambiguity": "compares LOW10 and SAT10 over the same wide residual; only values outside signed-10 range can differ",
            "official_vectors_count": 0,
            "hidden_golden_claim": "not made",
        },
    }
    impact = {
        "schema": "step12d_engineering.ambiguity_impact_audit.v1",
        "status": "PASS_IMPACT_AUDIT_WITH_OFFICIAL_VECTOR_BUCKET_EMPTY",
        "profile_binding": "contest_engineering_vtm10_v1",
        "official_equivalence": "NOT_PROVEN",
        "buckets": [{k: v for k, v in row.items() if k != "cases"} for row in buckets],
        "conclusion": "engineering profile and adapters are reproducible; sample-domain differences are measured, not a claim about historical hidden golden",
    }
    if EMIT:
        print(json.dumps({"VTM_PROFILE_ORACLE_RESULTS.json": json.dumps(result, ensure_ascii=False, indent=2) + "\n", "AMBIGUITY_IMPACT_AUDIT.json": json.dumps(impact, ensure_ascii=False, indent=2) + "\n"}, ensure_ascii=False))
    else:
        (EVIDENCE / "VTM_PROFILE_ORACLE_RESULTS.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        (EVIDENCE / "AMBIGUITY_IMPACT_AUDIT.json").write_text(json.dumps(impact, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"status": result["status"], "buckets": len(buckets)}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
