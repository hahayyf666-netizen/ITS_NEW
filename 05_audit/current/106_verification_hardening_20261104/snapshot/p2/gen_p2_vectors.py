"""P2: generate lockstep SAT10 / LOW10 vectors for the dual-instance hardware test.

Two DUT instances (FINAL_SATURATE=1 and 0) receive identical stimulus, so the
same input file drives both and the two expectation files must have identical
length. Additionally emits the model-level exhaustive mapping table over the
whole signed16 range, which is a statement about the rule, not about the RTL.
"""
from __future__ import annotations
import json, sys
from pathlib import Path

REPO = Path(r"C:\Users\Fine\Documents\deepseek-harness\default-workspace\its_push")
ENG = REPO / "03_verification/step12d_engineering"
sys.path.insert(0, str(ENG))

from validate_gate_c_model import Descriptor, CANONICAL, load_json, inverse_2d, output_beats  # noqa: E402
from verify_full_spatial_reference import image  # noqa: E402

OUT = Path(r"C:\Users\Fine\Documents\deepseek-harness\default-workspace\closure_audit\p2")

# (label, width, height, hor, ver, set_idx, lfnst_idx, [(addr, value), ...])
TUS = [
    ("dc_hi_4x4",      4,  4, 0, 0, 0, 0, [(0, 32767)]),
    ("dc_lo_4x4",      4,  4, 0, 0, 0, 0, [(0, -32768)]),
    ("dc_small_4x4",   4,  4, 0, 0, 0, 0, [(0, 512)]),
    ("lfnst_s0i1_4x4", 4,  4, 0, 0, 0, 1, [(0, 512)]),
    ("mixed_8x8",      8,  8, 0, 0, 0, 0, [(0, 32767), (9, -32768), (19, 16384)]),
    ("dst7_8x8",       8,  8, 1, 1, 0, 0, [(0, 16384), (9, -16384), (27, 8192)]),
    ("dct8_16x16",    16, 16, 2, 2, 0, 0, [(0, 32767), (17, -32768), (50, 12000)]),
    ("dc_hi_64x64",   64, 64, 0, 0, 0, 0, [(0, 32767)]),
]


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    canonical = load_json(CANONICAL)

    stim, sat_lines, low_lines = [], [], []
    per_tu = []
    total_sat_ne_low = 0

    for (label, w, h, hor, ver, s, l, pts) in TUS:
        d = Descriptor(w, h, hor, ver, s, l)
        wide = inverse_2d(image(d, list(pts)), w, h, hor, ver, s, l, canonical)
        sat = [v for b in output_beats(wide, "SAT10") for v in b]
        low = [v for b in output_beats(wide, "LOW10") for v in b]
        assert len(sat) == len(low) == w * h

        info = w | (h << 7) | (hor << 14) | (ver << 16) | (s << 18) | (l << 20)
        for i, (addr, val) in enumerate(pts):
            stim.append((info, addr, val, 1 if i == len(pts) - 1 else 0))

        def pack(vals):
            beats = []
            for i in range(0, len(vals), 4):
                word = 0
                for lane in range(4):
                    word |= (vals[i + lane] & 0x3FF) << (lane * 10)
                beats.append(word)
            return beats

        sb, lb = pack(sat), pack(low)
        sat_lines.extend(sb)
        low_lines.extend(lb)

        n_diff = sum(1 for a, b in zip(sat, low) if a != b)
        total_sat_ne_low += n_diff
        per_tu.append({"label": label, "info": f"0x{info:06x}", "size": f"{w}x{h}",
                       "tr_type_hor": hor, "tr_type_ver": ver, "set_idx": s, "lfnst_idx": l,
                       "points": len(pts), "point": w * h, "beats": len(sb),
                       "points_where_sat_ne_low": n_diff,
                       "wide_min": min(min(r) for r in wide),
                       "wide_max": max(max(r) for r in wide)})

    (OUT / "p2_stim.hex").write_text(
        "".join(f"{i:06x} {a:03x} {v & 0xFFFF:04x} {last}\n" for i, a, v, last in stim),
        encoding="ascii")
    (OUT / "p2_sat.hex").write_text("".join(f"{b:010x}\n" for b in sat_lines), encoding="ascii")
    (OUT / "p2_low.hex").write_text("".join(f"{b:010x}\n" for b in low_lines), encoding="ascii")

    # ---- exhaustive mapping table over the whole signed16 range (rule level) --
    clip = lambda v: -512 if v < -512 else (511 if v > 511 else v)
    wrap = lambda v: ((v & 0x3FF) ^ 0x200) - 0x200
    oob = sum(1 for v in range(-32768, 32768) if v < -512 or v > 511)
    diff = sum(1 for v in range(-32768, 32768) if clip(v) != wrap(v))
    boundary = {str(v): {"sat10": clip(v), "low10": wrap(v), "equal": clip(v) == wrap(v)}
                for v in (-513, -512, -511, 511, 512, 1535, 2047, -2048)}

    report = {
        "schema": "its.p2.low10_vectors.v1",
        "official_equivalence": "NOT_PROVEN",
        "note": "DUT instances differ only in FINAL_SATURATE; default production value remains 1.",
        "totals": {"stimulus_lines": len(stim), "beats_per_mode": len(sat_lines),
                   "points_where_sat_ne_low": total_sat_ne_low},
        "tus": per_tu,
        "mapping_table_signed16": {
            "domain": 65536, "out_of_signed10_range": oob,
            "sat10_ne_low10": diff,
            "inside_range_all_equal": True,
            "boundary_values": boundary,
            "scope": "model-level rule statement; does not by itself verify the RTL branch",
        },
    }
    (OUT / "P2_VECTORS.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(f"stimulus lines={len(stim)} beats/mode={len(sat_lines)}")
    for r in per_tu:
        print(f"  {r['label']:16s} {r['size']:6s} beats={r['beats']:4d} "
              f"SAT!=LOW pts={r['points_where_sat_ne_low']:4d}/{r['point']} "
              f"wide=[{r['wide_min']},{r['wide_max']}]")
    print(f"  total points where SAT10 != LOW10: {total_sat_ne_low}")
    print(f"  signed16: out_of_range={oob} sat_ne_low={diff}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())