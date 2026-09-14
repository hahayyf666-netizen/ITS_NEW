#!/usr/bin/env python3
"""Generate independent directed vectors for bounded_lfnst_engine.

The expected values are calculated directly from the hash-fixed canonical
LFNST matrices.  This generator deliberately does not import or call any RTL
arithmetic implementation; the packed ROM is only an implementation input.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CANONICAL = ROOT / "03_verification" / "output" / "canonical_matrices.json"


def round_clip(raw: int) -> int:
    value = (raw + 64) >> 7
    return max(-32768, min(32767, value))


def pack_terms(terms: list[int]) -> int:
    word = 0
    for lane, value in enumerate(terms):
        word |= (value & 0xFFFF) << (lane * 16)
    return word


def expected_groups(canonical: dict, ntrs: int, set_idx: int,
                    lfnst_idx: int, nonzero8: bool,
                    terms: list[int]) -> list[int]:
    matrix = canonical["lfnst"][str(ntrs)][str(set_idx)][str(lfnst_idx)]
    active = 8 if ntrs == 16 and nonzero8 else 16
    values = [round_clip(sum(matrix[row][term] * terms[term]
                             for term in range(active)))
              for row in range(ntrs)]
    return [pack_terms(values[group:group + 4])
            for group in range(0, ntrs, 4)]


def add_case(cases: list[dict], canonical: dict, ntrs: int, set_idx: int,
             lfnst_idx: int, nonzero8: bool, terms: list[int], label: str) -> None:
    groups = expected_groups(canonical, ntrs, set_idx, lfnst_idx,
                             nonzero8, terms)
    cases.append({
        "set": set_idx,
        "idx": lfnst_idx,
        "ntrs48": int(ntrs == 48),
        "nonzero8": int(nonzero8),
        "terms": pack_terms(terms),
        "groups": groups,
        "label": label,
    })


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    canonical = json.loads(CANONICAL.read_text(encoding="utf-8"))
    cases: list[dict] = []

    # Every selector, every term, both signs.  For nTrs=16, the nonzero8
    # selector is exercised explicitly, including terms 8..15 which must be
    # ignored.  For nTrs=48 the flag is intentionally toggled to prove it is
    # harmless outside the 16-output form.
    for ntrs in (16, 48):
        for set_idx in range(4):
            for lfnst_idx in (1, 2):
                for nonzero8 in (False, True):
                    for term in range(16):
                        for value, sign in ((32767, "pos"), (-32768, "neg")):
                            terms = [0] * 16
                            terms[term] = value
                            add_case(cases, canonical, ntrs, set_idx,
                                     lfnst_idx, nonzero8, terms,
                                     f"basis{term}_{sign}")

    # Dense patterns exercise simultaneous signed products and accumulator
    # clipping, which a one-hot basis cannot cover.
    rng = random.Random(0x12D5EED)
    for ntrs in (16, 48):
        for set_idx in range(4):
            for lfnst_idx in (1, 2):
                for nonzero8 in (False, True):
                    terms = [rng.randint(-32768, 32767) for _ in range(16)]
                    add_case(cases, canonical, ntrs, set_idx, lfnst_idx,
                             nonzero8, terms, "dense_random")
                    terms = [32767 if i % 2 == 0 else -32768
                             for i in range(16)]
                    add_case(cases, canonical, ntrs, set_idx, lfnst_idx,
                             nonzero8, terms, "dense_extreme")

    lines = [str(len(cases))]
    for case in cases:
        lines.append(
            f"{case['set']} {case['idx']} {case['ntrs48']} "
            f"{case['nonzero8']} {case['terms']:064x} {len(case['groups'])}"
        )
        lines.extend(f"{word:016x}" for word in case["groups"])
    encoded = ("\n".join(lines) + "\n").encode("ascii")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(encoded)
    print(json.dumps({
        "status": "PASS_GENERATE_LFNST_ENGINE_VECTORS",
        "cases": len(cases),
        "ntrs16_cases": sum(not c["ntrs48"] for c in cases),
        "ntrs48_cases": sum(bool(c["ntrs48"]) for c in cases),
        "basis_cases": sum(c["label"].startswith("basis") for c in cases),
        "sha256": hashlib.sha256(encoded).hexdigest().upper(),
        "canonical": str(CANONICAL),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
