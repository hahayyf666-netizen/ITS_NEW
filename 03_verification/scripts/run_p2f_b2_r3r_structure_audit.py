"""Fail-closed audit of the R3R reduction connectivity in the actual RTL.

The expected connectivity is re-extracted from the authoritative event tables;
the manifest and generator output are not used as evidence.  The RTL parser
then checks the generated static-sum and terminal blocks and runs deliberately
broken temporary copies to prove that the checker rejects structural errors.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re
import shutil
import tempfile


ROOT = Path(__file__).resolve().parents[2]
RTL_DEFAULT = ROOT / "02_rtl/rtl/p2f_dct2_64_b1_step102.sv"
TABLE = ROOT / "02_rtl/rtl/p2f_step102_tables.svh"
OUT = ROOT / "03_verification/output"
CAPS = [64, 32, 16, 8, 4]
DATA_ARRAY = ["lane_product_reg", "red_s0_data", "red_s1_data", "red_s2_data", "red_s3_data"]


def table(text: str, name: str) -> dict[int, int]:
    rows = re.findall(r"(?m)^\s*(\d+):\s*" + re.escape(name) + r"\s*=\s*(-?\d+);", text)
    out = {int(k): int(v) for k, v in rows}
    if len(out) != len(rows):
        raise ValueError(f"duplicate table entries: {name}")
    return out


def expected_connectivity() -> tuple[list[dict], dict[tuple[int, int], set[tuple[int, int]]], dict[int, tuple[int, int, int]]]:
    text = TABLE.read_text(encoding="utf-8")
    t = {n: table(text, "p2f102_" + n) for n in ("red_count", "red_dot", "red_node", "red_terms", "red_src0", "red_src1")}
    events: list[dict] = []
    for stage, cap in enumerate(CAPS):
        for phase in range(1, 18):
            count = t["red_count"].get(stage * 32 + phase, 0)
            if not 0 <= count <= cap:
                raise ValueError(f"invalid count stage={stage} phase={phase}: {count}")
            for slot in range(count):
                key = stage * 2048 + phase * 64 + slot
                events.append({
                    "stage": stage, "phase": phase, "slot": slot,
                    "dot": t["red_dot"][key], "node": t["red_node"][key],
                    "terms": t["red_terms"][key],
                    "src0": t["red_src0"][key], "src1": t["red_src1"][key],
                })
    if len(events) != 1304:
        raise ValueError(f"expected 1304 events, got {len(events)}")
    pair_sets: dict[tuple[int, int], set[tuple[int, int]]] = defaultdict(set)
    for e in events:
        pair_sets[(e["stage"], e["slot"])].add((e["src0"], e["src1"]))
    if len(pair_sets) != 124:
        raise ValueError(f"expected 124 slots, got {len(pair_sets)}")
    terminal: dict[int, tuple[int, int, int]] = {}
    for e in events:
        if e["terms"] == 2 ** (e["stage"] + 1):
            if e["dot"] in terminal:
                raise ValueError(f"duplicate expected terminal dot {e['dot']}")
            terminal[e["dot"]] = (e["stage"], e["phase"], e["slot"])
    if set(terminal) != set(range(64)):
        raise ValueError("expected terminal dots are not exactly 0..63")
    return events, dict(pair_sets), terminal


def extract_block(text: str, begin: str, end: str) -> str:
    a = text.find(begin)
    b = text.find(end, a + len(begin)) if a >= 0 else -1
    if a < 0 or b < 0:
        raise ValueError(f"missing block markers {begin}/{end}")
    return text[a:b + len(end)]


def parse_actual(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    sum_block = extract_block(text, "R3R_STATIC_SUM_BEGIN", "R3R_STATIC_SUM_END")
    reduction_block = extract_block(text, "R3R_STATIC_REDUCTION_BEGIN", "R3R_STATIC_REDUCTION_END")
    terminal_block = extract_block(text, "R3R_STATIC_TERMINAL_BEGIN", "R3R_STATIC_TERMINAL_END")

    if re.search(r"p2f102_red_src[01]", reduction_block + sum_block):
        raise ValueError("dynamic red_src lookup remains in static reduction blocks")
    if re.search(r"\[[^\]]*(?:red_|cycle|phase|node|slot)[^\]]*\]", reduction_block):
        # The only allowed dynamic expression in reduction is the fixed case
        # selector red_cycle; source/data indices must be constants.
        for line in reduction_block.splitlines():
            if "red_s" in line and re.search(r"red_s\d+_(?:data|vector|dot|terms|valid)\[[^0-9\]]", line):
                raise ValueError(f"dynamic reduction destination index: {line.strip()}")

    pair_re = re.compile(
        r"r3r_s(?P<stage>[0-4])_sum_now\[(?P<slot>\d+)\]\s*=\s*"
        r"(?P<a>[A-Za-z0-9_]+)\[(?P<i>\d+)\]\s*\+\s*"
        r"(?P<b>[A-Za-z0-9_]+)\[(?P<j>\d+)\]\s*;"
    )
    actual_pairs: dict[tuple[int, int], set[tuple[int, int]]] = defaultdict(set)
    for m in pair_re.finditer(sum_block):
        stage, slot = int(m.group("stage")), int(m.group("slot"))
        expected_array = DATA_ARRAY[stage]
        if m.group("a") != expected_array or m.group("b") != expected_array:
            raise ValueError(f"wrong source array for stage {stage}, slot {slot}")
        actual_pairs[(stage, slot)].add((int(m.group("i")), int(m.group("j"))))

    if set(actual_pairs) != set(expected_connectivity()[1]):
        raise ValueError("actual sum slot set differs from authoritative slot set")
    _, expected_pairs, expected_terminal = expected_connectivity()
    pair_diffs = {
        str(k): {"expected": sorted(expected_pairs[k]), "actual": sorted(actual_pairs.get(k, set()))}
        for k in expected_pairs if actual_pairs.get(k, set()) != expected_pairs[k]
    }
    if pair_diffs:
        raise ValueError(f"source pair mismatch: {pair_diffs}")
    histogram = Counter(len(v) for v in actual_pairs.values())
    if histogram != Counter({1: 96, 2: 28}) or any(len(v) > 2 for v in actual_pairs.values()):
        raise ValueError(f"actual pair histogram is {dict(histogram)}, expected 96/28")

    # Every scheduled event must have a corresponding static write.  This is
    # a structural check, not a count copied from a manifest.
    writes = re.findall(r"red_s([0-4])_data\[(\d+)\]\s*<=\s*r3r_s\1_sum_now\[\2\]", reduction_block)
    if len(writes) != 1304:
        raise ValueError(f"static reduction writes={len(writes)}, expected 1304")

    terminal_re = re.compile(
        r"dot_value_bank\[r3r_s([0-4])_vector_now\[(\d+)\]\[0\]\]\[(\d+)\]\s*<=\s*"
        r"r3r_s\1_sum_now\[\2\];"
    )
    actual_terminal: dict[int, tuple[int, int]] = {}
    for m in terminal_re.finditer(terminal_block):
        dot = int(m.group(3))
        if dot in actual_terminal:
            raise ValueError(f"duplicate actual terminal dot {dot}")
        actual_terminal[dot] = (int(m.group(1)), int(m.group(2)))
    if set(actual_terminal) != set(range(64)):
        raise ValueError("actual terminal coverage is not exactly 0..63")
    for dot, (stage, slot) in actual_terminal.items():
        exp_stage, _phase, exp_slot = expected_terminal[dot]
        if (stage, slot) != (exp_stage, exp_slot):
            raise ValueError(f"terminal dot {dot}: actual {(stage, slot)} expected {(exp_stage, exp_slot)}")
    if re.search(r"dot_value_bank.*<=\s*red_s[0-4]_data", terminal_block):
        raise ValueError("terminal samples registered red_s*_data instead of current-cycle sum_now")

    return {
        "rtl": str(path),
        "static_sum_slots": len(actual_pairs),
        "pair_histogram": dict(sorted(histogram.items())),
        "reduction_static_writes": len(writes),
        "terminal_dots": len(actual_terminal),
        "dynamic_red_src_in_static_blocks": False,
        "terminal_uses_current_sum_now": True,
    }


def negative_cases(rtl_path: Path) -> dict[str, str]:
    original = rtl_path.read_text(encoding="utf-8")
    cases: dict[str, str] = {}
    with tempfile.TemporaryDirectory(prefix="r3r_audit_") as td:
        td_path = Path(td)
        # Mutations are deliberately local to the actual RTL blocks.
        sum_begin = original.index("R3R_STATIC_SUM_BEGIN")
        sum_end = original.index("R3R_STATIC_SUM_END", sum_begin)
        term_begin = original.index("R3R_STATIC_TERMINAL_BEGIN")
        term_end = original.index("R3R_STATIC_TERMINAL_END", term_begin)
        sum_text = original[sum_begin:sum_end]
        term_text = original[term_begin:term_end]
        first_fixed = re.search(r"r3r_s0_sum_now\[0\] = lane_product_reg\[0\] \+ lane_product_reg\[1\];", sum_text)
        if not first_fixed:
            raise ValueError("negative-test anchor not found")

        mutations = {
            "wrong_fixed_source": original.replace(first_fixed.group(0), first_fixed.group(0).replace("[1]", "[2]", 1), 1),
            "third_pair": original[:sum_end] + "\n        r3r_s0_sum_now[0] = lane_product_reg[0] + lane_product_reg[2];" + original[sum_end:],
            "wrong_legal_pair": original.replace(first_fixed.group(0), first_fixed.group(0).replace("[0] + lane_product_reg[1]", "[2] + lane_product_reg[3]"), 1),
            "stale_terminal_sampling": original[:term_begin] + term_text.replace("r3r_s0_sum_now[0]", "red_s0_data[0]", 1) + original[term_end:],
            "duplicate_terminal_dot": original[:term_end] + "\n" + next(line for line in term_text.splitlines() if "dot_value_bank[r3r_s" in line) + original[term_end:],
        }
        for name, mutated in mutations.items():
            temp = td_path / f"{name}.sv"
            temp.write_text(mutated, encoding="utf-8")
            try:
                parse_actual(temp)
            except Exception as exc:  # expected rejection
                cases[name] = f"PASS (rejected: {type(exc).__name__}: {exc})"
            else:
                cases[name] = "FAIL (mutation was accepted)"
    if any(v.startswith("FAIL") for v in cases.values()):
        raise ValueError(f"negative test failure: {cases}")
    return cases


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl", type=Path, default=RTL_DEFAULT)
    ap.add_argument("--skip-negative", action="store_true")
    args = ap.parse_args()
    actual = parse_actual(args.rtl)
    negatives = {} if args.skip_negative else negative_cases(args.rtl)
    result = {
        "status": "PASS",
        "expected": {"events": 1304, "slots": 124, "fixed_slots": 96, "two_choice_slots": 28, "terminal_dots": 64},
        "actual": actual,
        "negative_tests": negatives,
    }
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "p2f_b2_r3r_actual_rtl_connectivity.json").write_text(json.dumps(actual, indent=2) + "\n", encoding="utf-8")
    (OUT / "p2f_b2_r3r_structure_audit.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    (OUT / "p2f_b2_r3r_negative_tests.md").write_text(
        "# R3R negative structural tests\n\n" + "\n".join(f"- `{k}`: {v}" for k, v in negatives.items()) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
