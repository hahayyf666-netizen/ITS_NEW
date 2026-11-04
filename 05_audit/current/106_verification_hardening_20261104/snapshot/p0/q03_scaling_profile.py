"""P0-A: Q03 scaling characteristics.

Records, per stage, how often the selected V shift 7 / H shift 10 profile
saturates and where the rounding boundary falls. This characterises the current
engineering binding; it deliberately does NOT invent a "rule divergence rate"
because no alternative candidate rule has been defined.

Method: wrap the model's round_clip (module-level indirection) so every clip
call is observed with its raw value, shift and result.
"""
from __future__ import annotations
import json, sys
from pathlib import Path

REPO = Path(r"C:\Users\Fine\Documents\deepseek-harness\default-workspace\its_push")
ENG = REPO / "03_verification/step12d_engineering"
sys.path.insert(0, str(ENG))

import validate_gate_c_model as m  # noqa: E402
from generate_gate_c_hdl_vectors import full_engineering_cases, sparse_entries  # noqa: E402
from verify_full_spatial_reference import extra_cases, image  # noqa: E402

OUT = Path(r"C:\Users\Fine\Documents\deepseek-harness\default-workspace\closure_audit\p0")

CTX = ["v"]
_orig_clip = m.round_clip
_orig_apply = m.apply_lfnst
ST = {}


def _bucket(name):
    return ST.setdefault(name, {"calls": 0, "clipped": 0, "raw_min": None, "raw_max": None,
                                "out_min": None, "out_max": None, "tie_cases": 0,
                                "shift": None})


def spy_clip(raw, shift, lo, hi):
    out = _orig_clip(raw, shift, lo, hi)
    name = "lfnst" if CTX[0] == "lfnst" else ("h" if shift == 10 else "v")
    b = _bucket(name)
    b["shift"] = shift
    b["calls"] += 1
    if out != (raw >> shift if raw >= 0 else -((-raw) >> shift)):
        pass
    if not (lo <= ((raw + (1 << (shift - 1))) >> shift) <= hi):
        b["clipped"] += 1
    b["raw_min"] = raw if b["raw_min"] is None else min(b["raw_min"], raw)
    b["raw_max"] = raw if b["raw_max"] is None else max(b["raw_max"], raw)
    b["out_min"] = out if b["out_min"] is None else min(b["out_min"], out)
    b["out_max"] = out if b["out_max"] is None else max(b["out_max"], out)
    # rounding tie: raw + half is an exact multiple of 2^shift with the half bit set
    if ((raw + (1 << (shift - 1))) % (1 << shift)) == (1 << (shift - 1)) % (1 << shift):
        b["tie_cases"] += 1
    return out


def spy_apply(*a, **k):
    CTX[0] = "lfnst"
    try:
        return _orig_apply(*a, **k)
    finally:
        CTX[0] = "v"


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    m.round_clip = spy_clip
    m.apply_lfnst = spy_apply

    canonical = m.load_json(m.CANONICAL)
    cases = [(f"gate_c_{i}", d, sparse_entries(d, 0x520 + i)) for i, d in enumerate(full_engineering_cases())]
    cases += [(n, d, e) for n, d, e, _ in extra_cases()]

    lfnst_on = 0
    for name, d, entries in cases:
        if d.lfnst_idx:
            lfnst_on += 1
        m.inverse_2d(image(d, entries), d.width, d.height, d.hor, d.ver,
                     d.set_idx, d.lfnst_idx, canonical)

    report = {
        "schema": "its.p0.q03_scaling_profile.v1",
        "official_equivalence": "NOT_PROVEN",
        "profile": "V shift 7 (round +64), H shift 10 (round +512), signed16 clip each stage",
        "corpus_cases": len(cases),
        "lfnst_on_cases": lfnst_on,
        "stages": ST,
        "scope": "Describes the selected engineering profile on the existing corpus. "
                 "No alternative candidate rule exists, so no divergence rate is reported.",
    }
    (OUT / "q03_scaling_profile.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    for name in ("v", "h", "lfnst"):
        b = ST.get(name)
        if not b:
            continue
        rate = b["clipped"] / b["calls"] if b["calls"] else 0
        print(f"{name:6s} shift={b['shift']} calls={b['calls']} clipped={b['clipped']} "
              f"({rate*100:.4f}%) raw=[{b['raw_min']},{b['raw_max']}] out=[{b['out_min']},{b['out_max']}] "
              f"ties={b['tie_cases']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())