"""P0-B: quantify Q04 (SAT10 vs signed LOW10) over the existing corpus.

Reports out-of-range points and *actual* divergence points separately, because
an out-of-range value can still map identically (e.g. wide=1535 -> SAT10=511,
LOW10=511). Both metrics are point-level; a TU-level roll-up is also emitted.

Corpus is exactly the one used by verify_full_spatial_reference.py (667 cases:
369 standard + 298 extra). These are engineering corpus statistics, not a
business-probability estimate.
"""
from __future__ import annotations
import json, sys
from collections import Counter, defaultdict
from pathlib import Path

REPO = Path(r"C:\Users\Fine\Documents\deepseek-harness\default-workspace\its_push")
ENG = REPO / "03_verification/step12d_engineering"
sys.path.insert(0, str(ENG))

from validate_gate_c_model import Descriptor, CANONICAL, load_json, inverse_2d, output_beats  # noqa: E402
from generate_gate_c_hdl_vectors import full_engineering_cases, sparse_entries  # noqa: E402
from verify_full_spatial_reference import extra_cases, image  # noqa: E402

OUT = Path(r"C:\Users\Fine\Documents\deepseek-harness\default-workspace\closure_audit\p0")


def flat(beats):
    return [v for beat in beats for v in beat]


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    canonical = load_json(CANONICAL)

    standard = [(f"gate_c_{i}", d, sparse_entries(d, 0x520 + i), "standard")
                for i, d in enumerate(full_engineering_cases())]
    extra = [(n, d, e, "stress" if n.startswith("signed16_stress") else "extra")
             for n, d, e, _ in extra_cases()]
    cases = standard + extra

    tot_pts = tot_oob = tot_div = 0
    tu_total = tu_oob = tu_div = 0
    max_diff = 0
    max_diff_case = None
    by_lfnst = defaultdict(lambda: dict(tu=0, tu_div=0, pts=0, oob=0, div=0))
    by_class = defaultdict(lambda: dict(tu=0, tu_div=0, pts=0, oob=0, div=0))
    by_area = defaultdict(lambda: dict(tu=0, tu_div=0, pts=0, oob=0, div=0))
    div_hist = Counter()
    oob_hist = Counter()
    examples = []

    for name, d, entries, klass in cases:
        coeff = image(d, entries)
        wide = inverse_2d(coeff, d.width, d.height, d.hor, d.ver,
                          d.set_idx, d.lfnst_idx, canonical)
        low = flat(output_beats(wide, "LOW10"))
        sat = flat(output_beats(wide, "SAT10"))
        assert len(low) == len(sat) == d.width * d.height

        oob = sum(1 for row in wide for v in row if v < -512 or v > 511)
        div = 0
        case_max = 0
        first = None
        for idx, (a, b) in enumerate(zip(sat, low)):
            if a != b:
                div += 1
                delta = abs(a - b)
                if delta > case_max:
                    case_max = delta
                if first is None:
                    r, c = div_hint = (idx // d.width, idx % d.width)
                    wv = wide[r][c]
                    first = {"point": [r, c], "wide": wv, "SAT10": a, "LOW10": b}

        pts = d.width * d.height
        tot_pts += pts
        tot_oob += oob
        tot_div += div
        tu_total += 1
        tu_oob += 1 if oob else 0
        tu_div += 1 if div else 0
        if case_max > max_diff:
            max_diff = case_max
            max_diff_case = (name, d.width, d.height, d.lfnst_idx, first)
        div_hist[div] += 1
        oob_hist[oob] += 1

        for bucket, key in ((by_lfnst, "on" if d.lfnst_idx else "off"),
                            (by_class, klass),
                            (by_area, "small" if pts <= 64 else ("mid" if pts <= 1024 else "large"))):
            b = bucket[key]
            b["tu"] += 1
            b["tu_div"] += 1 if div else 0
            b["pts"] += pts
            b["oob"] += oob
            b["div"] += div

        if div and len(examples) < 12:
            examples.append({"case": name, "size": f"{d.width}x{d.height}",
                             "hor": d.hor, "ver": d.ver, "lfnst_idx": d.lfnst_idx,
                             "points": pts, "oob": oob, "div": div, "first": first})

    def rate(a, b):
        return round(a / b, 6) if b else 0.0

    report = {
        "schema": "its.p0.q04_divergence.v1",
        "scope": "Engineering corpus statistics (369 standard + 298 extra). "
                 "Not a business-probability estimate and not a spec ruling.",
        "official_equivalence": "NOT_PROVEN",
        "corpus_cases": tu_total,
        "total_points": tot_pts,
        "out_of_signed10_points": tot_oob,
        "out_of_signed10_rate": rate(tot_oob, tot_pts),
        "divergent_points": tot_div,
        "divergent_rate": rate(tot_div, tot_pts),
        "tus_with_out_of_range": tu_oob,
        "tus_with_divergence": tu_div,
        "tu_divergence_rate": rate(tu_div, tu_total),
        "max_abs_difference": max_diff,
        "max_abs_difference_case": max_diff_case,
        "note_oob_vs_div": "out-of-range != divergent; e.g. wide=1535 -> SAT10=511, LOW10=511",
        "divergent_point_count_histogram": dict(sorted(div_hist.items())),
        "by_lfnst": {k: v for k, v in by_lfnst.items()},
        "by_corpus_class": {k: v for k, v in by_class.items()},
        "by_area": {k: v for k, v in by_area.items()},
        "examples": examples,
    }
    (OUT / "q04_divergence.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(f"cases={tu_total} points={tot_pts}")
    print(f"out-of-range points = {tot_oob} ({rate(tot_oob, tot_pts)*100:.4f}%)")
    print(f"divergent  points   = {tot_div} ({rate(tot_div, tot_pts)*100:.4f}%)")
    print(f"TUs with divergence = {tu_div}/{tu_total}")
    print(f"max |SAT10-LOW10|   = {max_diff}")
    for k, v in by_lfnst.items():
        print(f"  lfnst={k}: TU div {v['tu_div']}/{v['tu']}, pts div {v['div']}/{v['pts']}")
    for k, v in by_class.items():
        print(f"  class={k}: TU div {v['tu_div']}/{v['tu']}, pts div {v['div']}/{v['pts']}")
    for k, v in by_area.items():
        print(f"  area={k}: TU div {v['tu_div']}/{v['tu']}, pts div {v['div']}/{v['pts']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())