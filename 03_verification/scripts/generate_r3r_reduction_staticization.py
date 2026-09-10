"""Generate the R3R reduction datapath from the authoritative event tables.

This script deliberately does not consume the stale R3 connectivity JSON.  It
re-extracts live reduction events from p2f_step102_tables.svh, derives the
source-pair set for every physical slot, and then emits static RTL.  Runtime
source indexes are not used in the generated reduction block.
"""
from __future__ import annotations

from collections import Counter, defaultdict
from hashlib import sha256
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / "02_rtl/rtl/p2f_dct2_64_b1_step102.sv"
TABLE = ROOT / "02_rtl/rtl/p2f_step102_tables.svh"
B1_TABLE = ROOT / "02_rtl/rtl/p2f_b1_tables.svh"
CANONICAL = ROOT / "03_verification/output/canonical_matrices.json"
OUT = ROOT / "03_verification/output"
CAPS = [64, 32, 16, 8, 4]


def digest(path: Path) -> str:
    return sha256(path.read_bytes()).hexdigest()


def table(text: str, name: str) -> dict[int, int]:
    pairs = re.findall(r"(?m)^\s*(\d+):\s*" + re.escape(name) + r"\s*=\s*(-?\d+);", text)
    if len(pairs) != len({k for k, _ in pairs}):
        raise RuntimeError(f"duplicate table key in {name}")
    return {int(k): int(v) for k, v in pairs}


def extract_authoritative() -> tuple[list[dict], dict[tuple[int, int], dict], list[dict]]:
    text = TABLE.read_text(encoding="utf-8")
    names = ["red_count", "red_dot", "red_node", "red_terms", "red_src0", "red_src1"]
    t = {name: table(text, "p2f102_" + name) for name in names}
    events: list[dict] = []
    for stage, cap in enumerate(CAPS):
        for phase in range(1, 18):
            count = t["red_count"].get(stage * 32 + phase, 0)
            if count < 0 or count > cap:
                raise RuntimeError(f"invalid count stage={stage} phase={phase}: {count}")
            for slot in range(cap):
                key = stage * 2048 + phase * 64 + slot
                if slot < count and t["red_dot"].get(key, -1) >= 0:
                    events.append(
                        {
                            "stage": stage,
                            "phase": phase,
                            "slot": slot,
                            "dot": t["red_dot"][key],
                            "node": t["red_node"][key],
                            "terms": t["red_terms"][key],
                            "src0": t["red_src0"][key],
                            "src1": t["red_src1"][key],
                        }
                    )
    if len(events) != 1304:
        raise RuntimeError(f"authoritative reduction event count is {len(events)}, expected 1304")

    pairs: dict[tuple[int, int], dict[tuple[int, int], list[int]]] = defaultdict(lambda: defaultdict(list))
    for event in events:
        pairs[(event["stage"], event["slot"])][(event["src0"], event["src1"])].append(event["phase"])

    if len(pairs) != 124:
        raise RuntimeError(f"physical slot count is {len(pairs)}, expected 124")
    histogram = Counter(len(x) for x in pairs.values())
    if histogram != Counter({1: 96, 2: 28}):
        raise RuntimeError(f"slot source-pair histogram is {dict(histogram)}, expected 96/28")

    dots: dict[int, dict] = {}
    for event in events:
        if event["terms"] == 2 ** (event["stage"] + 1):
            dot = event["dot"]
            if dot in dots:
                raise RuntimeError(f"duplicate terminal producer for dot {dot}")
            dots[dot] = event
    if set(dots) != set(range(64)):
        raise RuntimeError("terminal producer coverage is not exactly 0..63")

    slot_rows = []
    for (stage, slot), choices in sorted(pairs.items()):
        slot_rows.append(
            {
                "stage": stage,
                "slot": slot,
                "pair_count": len(choices),
                "choices": [
                    {"source_pair": list(pair), "phases": sorted(phases)}
                    for pair, phases in sorted(choices.items())
                ],
            }
        )
    return events, {(row["stage"], row["slot"]): row for row in slot_rows}, [dots[d] for d in range(64)]


DATA_ARRAY = ["lane_product_reg", "red_s0_data", "red_s1_data", "red_s2_data", "red_s3_data"]
VECTOR_ARRAY = [
    "lane_vector_id_reg",
    "red_s0_vector",
    "red_s1_vector",
    "red_s2_vector",
    "red_s3_vector",
]


def source_sum(stage: int, pair: tuple[int, int]) -> str:
    array = DATA_ARRAY[stage]
    return f"{array}[{pair[0]}] + {array}[{pair[1]}]"


def source_vector(stage: int, pair: tuple[int, int]) -> str:
    return f"{VECTOR_ARRAY[stage]}[{pair[0]}]"


def generate_sum_block(slot_rows: dict[tuple[int, int], dict]) -> str:
    lines = [
        "    // R3R_STATIC_SUM_BEGIN",
        "    // Static current-cycle reduction values.  Every source index below",
        "    // is an elaboration-time constant; only the legal two-choice slots",
        "    // have a small red_cycle-controlled override.",
    ]
    for stage, cap in enumerate(CAPS):
        lines.append(f"    reg signed [39:0] r3r_s{stage}_sum_now [0:{cap - 1}];")
        lines.append(f"    reg [VECTOR_ID_W-1:0] r3r_s{stage}_vector_now [0:{cap - 1}];")
    lines.append("    integer r3r_idx;")
    lines.append("    always @* begin")
    for stage, cap in enumerate(CAPS):
        for slot in range(cap):
            row = slot_rows[(stage, slot)]
            pair = tuple(row["choices"][0]["source_pair"])
            lines.append(f"        r3r_s{stage}_sum_now[{slot}] = {source_sum(stage, pair)};")
            lines.append(f"        r3r_s{stage}_vector_now[{slot}] = {source_vector(stage, pair)};")
    for stage, cap in enumerate(CAPS):
        for slot in range(cap):
            row = slot_rows[(stage, slot)]
            for choice in row["choices"][1:]:
                pair = tuple(choice["source_pair"])
                for phase in choice["phases"]:
                    lines.append(f"        if (red_cycle == 6'd{phase}) begin")
                    lines.append(f"            r3r_s{stage}_sum_now[{slot}] = {source_sum(stage, pair)};")
                    lines.append(f"            r3r_s{stage}_vector_now[{slot}] = {source_vector(stage, pair)};")
                    lines.append("        end")
    lines += ["    end", "    // R3R_STATIC_SUM_END"]
    return "\n".join(lines)


def generate_reduction_block(events: list[dict]) -> str:
    by_phase: dict[int, list[dict]] = defaultdict(list)
    for event in events:
        by_phase[event["phase"]].append(event)
    lines = [
        "            // R3R_STATIC_REDUCTION_BEGIN",
        "            // Static source connectivity generated from authoritative tables.",
        "            if (red_active) begin",
        "                case (red_cycle)",
    ]
    for phase in sorted(by_phase):
        lines.append(f"                    6'd{phase}: begin")
        for event in sorted(by_phase[phase], key=lambda x: (x["stage"], x["slot"])):
            stage = event["stage"]
            slot = event["slot"]
            lines += [
                f"                        red_s{stage}_data[{slot}] <= r3r_s{stage}_sum_now[{slot}];",
                f"                        red_s{stage}_vector[{slot}] <= r3r_s{stage}_vector_now[{slot}];",
                f"                        red_s{stage}_dot[{slot}] <= 7'd{event['dot']};",
                f"                        red_s{stage}_terms[{slot}] <= 6'd{event['terms']};",
                f"                        red_s{stage}_valid[{slot}] <= 1'b1;",
            ]
        lines.append("                    end")
    lines += [
        "                    default: begin end",
        "                endcase",
        "            end",
        "            // R3R_STATIC_REDUCTION_END",
    ]
    return "\n".join(lines)


def generate_terminal_block(dot_producers: list[dict]) -> str:
    by_phase: dict[int, list[dict]] = defaultdict(list)
    for dot in dot_producers:
        by_phase[dot["phase"]].append(dot)
    lines = [
        "            // R3R_STATIC_TERMINAL_BEGIN",
        "            // Use the same current-cycle slot_sum as the reduction stage;",
        "            // this preserves NBA sampling and avoids a duplicate terminal adder.",
        "            if (red_active) begin",
        "                case (red_cycle)",
    ]
    for phase in sorted(by_phase):
        lines.append(f"                    6'd{phase}: begin")
        for dot in sorted(by_phase[phase], key=lambda x: x["dot"]):
            stage = dot["stage"]
            slot = dot["slot"]
            d = dot["dot"]
            lines += [
                f"                        dot_value_bank[r3r_s{stage}_vector_now[{slot}][0]][{d}] <= r3r_s{stage}_sum_now[{slot}];",
                "`ifndef SYNTHESIS",
                f"                        $fwrite(r3_terminal_trace_fd, \"%0t,%0d,{d},%0d,%0d\\n\", $time, r3r_s{stage}_vector_now[{slot}], red_cycle, r3r_s{stage}_sum_now[{slot}]);",
                "`endif",
            ]
            if stage == 4:
                lines += [
                    f"                        dot_value_valid[r3r_s{stage}_vector_now[{slot}][0]][{d}] <= 1'b1;",
                    f"                        dot_value_vector[r3r_s{stage}_vector_now[{slot}][0]][{d}] <= r3r_s{stage}_vector_now[{slot}];",
                ]
        lines.append("                    end")
    lines += [
        "                    default: begin end",
        "                endcase",
        "            end",
        "            // R3R_STATIC_TERMINAL_END",
    ]
    return "\n".join(lines)


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError(f"expected one replacement block: {old[:80]!r}")
    return text.replace(old, new, 1)


def main() -> None:
    events, slots, dots = extract_authoritative()
    rtl = RTL.read_text(encoding="utf-8")
    if "R3R_STATIC_SUM_BEGIN" in rtl or "R3R_STATIC_REDUCTION_BEGIN" in rtl:
        raise RuntimeError("R3R staticization markers already exist; refusing to overwrite")

    sum_block = generate_sum_block(slots)
    rtl = replace_once(rtl, "    // Stage D0: exact 128-lane schedule decode.", sum_block + "\n\n    // Stage D0: exact 128-lane schedule decode.")

    old_start = "            // Clear per-cycle valid bits, then populate only the scheduled\n"
    old_end = "\n            // R3 static terminal-dot commit generated from the manifest."
    start = rtl.index(old_start)
    end = rtl.index(old_end, start)
    clear = """            // Clear per-cycle valid bits.  Data and tags are populated only
            // by the static phase/source cases below.
            for (r = 0; r < 64; r = r + 1) red_s0_valid[r] <= 1'b0;
            for (r = 0; r < 32; r = r + 1) red_s1_valid[r] <= 1'b0;
            for (r = 0; r < 16; r = r + 1) red_s2_valid[r] <= 1'b0;
            for (r = 0; r < 8; r = r + 1) red_s3_valid[r] <= 1'b0;
            for (r = 0; r < 4; r = r + 1) red_s4_valid[r] <= 1'b0;

"""
    rtl = rtl[:start] + clear + generate_reduction_block(events) + rtl[end:]

    term_start = rtl.index("            // R3 static terminal-dot commit generated from the manifest.")
    term_end = rtl.index("            // Butterfly event fabric.", term_start)
    rtl = rtl[:term_start] + generate_terminal_block(dots) + "\n\n" + rtl[term_end:]
    RTL.write_text(rtl, encoding="utf-8", newline="")

    canonical_hash = digest(CANONICAL)
    result = {
        "schema": "p2f_b2_r3r_connectivity_v1",
        "status": "PASS_AUTHORITATIVE_EXTRACTION",
        "source_r3_baseline": str(ROOT),
        "r3r_rtl_sha256": digest(RTL),
        "r3r_table_sha256": digest(TABLE),
        "r3r_b1_table_sha256": digest(B1_TABLE),
        "canonical_sha256": canonical_hash,
        "reduction_events": len(events),
        "physical_slots": len(slots),
        "slot_pair_histogram": dict(Counter(row["pair_count"] for row in slots.values())),
        "terminal_dots": len(dots),
        "reduction_slots": sorted(slots.values(), key=lambda x: (x["stage"], x["slot"])),
        "dot_producers": dots,
        "frozen_contract": {
            "lanes": 128,
            "multiply_ops": 1368,
            "reduction_events": 1304,
            "II": 16,
            "group_II": 1,
            "P4": 4,
        },
    }
    (OUT / "p2f_b2_r3r_connectivity.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: result[k] for k in ["status", "reduction_events", "physical_slots", "slot_pair_histogram", "terminal_dots", "r3r_rtl_sha256"]}, indent=2))


if __name__ == "__main__":
    main()
