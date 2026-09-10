"""Generate the resource-faithful Step 10.2 event tables.

The event order is derived mechanically from the frozen P4Dataflow graph.
This file does not derive a new transform.  It only assigns each already
proven reduction/butterfly operation to one shared physical slot per cycle.
"""
from __future__ import annotations

import sys
from collections import defaultdict
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parents[2]
sys.path.insert(0, str(SCRIPT_DIR))
from run_p2f_a1_dataflow import P4Dataflow  # noqa: E402

OUT = ROOT / "02_rtl" / "rtl" / "p2f_step102_tables.svh"
LANES = 128
RED_CAP = {0: 64, 1: 32, 2: 16, 3: 8, 4: 4}
BF_CAP = {4: 4, 8: 8, 16: 16, 32: 16, 64: 8}


def fn(name: str, args: str, rows: list[tuple[int, int]], default: int) -> list[str]:
    out = [f"function automatic integer {name}({args});", "  begin", "    case (key)"]
    for key, value in rows:
        out.append(f"      {key}: {name} = {value};")
    out += [f"      default: {name} = {default};", "    endcase", "  end", "endfunction", ""]
    return out


def depth(n: int) -> int:
    return n.bit_length() - 1


def collect_signals(model: P4Dataflow):
    signals = []
    sid_by_obj: dict[int, int] = {}

    def visit(sig):
        if id(sig) in sid_by_obj:
            return sid_by_obj[id(sig)]
        if sig.even is not None:
            visit(sig.even)
        sid = len(signals)
        sid_by_obj[id(sig)] = sid
        signals.append(sig)
        return sid

    roots = [visit(s) for s in model.root]
    return signals, sid_by_obj, roots


def main() -> None:
    m = P4Dataflow()
    lines = [
        "// AUTO-GENERATED for Step 10.2 from frozen P2FDataflow.",
        "// It contains event-to-slot mapping only; canonical math is unchanged.",
        "localparam integer P2F102_RED_MAX = 64;",
        "localparam integer P2F102_BF_MAX = 16;",
        "",
    ]

    # Reduction events. Stage-0 reads the registered multiplier lane; later
    # stages read two slots from the preceding shared stage one cycle earlier.
    red_by_stage_cycle: dict[tuple[int, int], list[dict[str, int]]] = defaultdict(list)
    for dot in m.dots:
        d = depth(len(dot.op_ids))
        for stage in range(d):
            cycle = dot.issue_rel + 2 + stage
            for node in range(len(dot.op_ids) >> (stage + 1)):
                red_by_stage_cycle[(stage, cycle)].append({
                    "dot": dot.dot_id, "node": node,
                    "term_count": len(dot.op_ids), "stage": stage,
                })
    red_src0: dict[tuple[int, int, int], int] = {}
    red_src1: dict[tuple[int, int, int], int] = {}
    red_dot: dict[tuple[int, int, int], int] = {}
    red_node: dict[tuple[int, int, int], int] = {}
    red_terms: dict[tuple[int, int, int], int] = {}
    slot_of: dict[tuple[int, int, int, int], int] = {}
    for (stage, cycle), evs in red_by_stage_cycle.items():
        evs.sort(key=lambda e: (e["dot"], e["node"]))
        if len(evs) > RED_CAP[stage]:
            raise RuntimeError(f"reduction capacity exceeded stage={stage} cycle={cycle}")
        for slot, e in enumerate(evs):
            slot_of[(stage, cycle, e["dot"], e["node"])] = slot
            key = stage * 2048 + cycle * 64 + slot
            red_dot[(stage, cycle, slot)] = e["dot"]
            red_node[(stage, cycle, slot)] = e["node"]
            red_terms[(stage, cycle, slot)] = e["term_count"]
            if stage == 0:
                dot = m.dots[e["dot"]]
                op0 = m.ops[dot.op_ids[2 * e["node"]]]
                op1 = m.ops[dot.op_ids[2 * e["node"] + 1]]
                red_src0[(stage, cycle, slot)] = op0.physical_lane
                red_src1[(stage, cycle, slot)] = op1.physical_lane
            else:
                prev_cycle = cycle - 1
                red_src0[(stage, cycle, slot)] = slot_of[(stage - 1, prev_cycle, e["dot"], 2 * e["node"])]
                red_src1[(stage, cycle, slot)] = slot_of[(stage - 1, prev_cycle, e["dot"], 2 * e["node"] + 1)]
    red_count_rows = []
    red_dot_rows = []
    red_node_rows = []
    red_terms_rows = []
    red_src0_rows = []
    red_src1_rows = []
    for (stage, cycle), evs in sorted(red_by_stage_cycle.items()):
        red_count_rows.append((stage * 32 + cycle, len(evs)))
        for slot, _ in enumerate(evs):
            k = stage * 2048 + cycle * 64 + slot
            red_dot_rows.append((k, red_dot[(stage, cycle, slot)]))
            red_node_rows.append((k, red_node[(stage, cycle, slot)]))
            red_terms_rows.append((k, red_terms[(stage, cycle, slot)]))
            red_src0_rows.append((k, red_src0[(stage, cycle, slot)]))
            red_src1_rows.append((k, red_src1[(stage, cycle, slot)]))
    lines += fn("p2f102_red_count", "input integer key", red_count_rows, 0)
    lines += fn("p2f102_red_dot", "input integer key", red_dot_rows, -1)
    lines += fn("p2f102_red_node", "input integer key", red_node_rows, -1)
    lines += fn("p2f102_red_terms", "input integer key", red_terms_rows, 0)
    lines += fn("p2f102_red_src0", "input integer key", red_src0_rows, -1)
    lines += fn("p2f102_red_src1", "input integer key", red_src1_rows, -1)

    # Butterfly events. One event is one E+/E- pair (one add and one sub).
    signals, sid_by_obj, roots = collect_signals(m)
    bf_by_level_cycle: dict[tuple[int, int], list[dict[str, int]]] = defaultdict(list)
    for sid, sig in enumerate(signals):
        level = 4 if sig.level == 4 else sig.level
        even_ready = getattr(sig, "even_dot").ready_rel if sig.even is None else sig.even.ready_rel
        odd_ready = sig.odd.ready_rel
        cycle = max(even_ready, odd_ready) + 1
        even_sig = -1 if sig.even is None else sid_by_obj[id(sig.even)]
        even_dot = getattr(sig, "even_dot").dot_id if sig.even is None else -1
        bf_by_level_cycle[(level, cycle)].append({
            "sid": sid, "even_sig": even_sig, "even_dot": even_dot,
            "odd_dot": sig.odd.dot_id, "high": int("high" in sig.signal_id),
        })
    bf_sig_rows = []; bf_even_sig_rows = []; bf_even_dot_rows = []
    bf_odd_dot_rows = []; bf_high_rows = []; bf_count_rows = []
    for (level, cycle), evs in sorted(bf_by_level_cycle.items()):
        evs.sort(key=lambda e: e["sid"])
        if len(evs) > BF_CAP[level]:
            raise RuntimeError(f"butterfly capacity exceeded level={level} cycle={cycle}")
        bf_count_rows.append((level * 32 + cycle, len(evs)))
        for slot, e in enumerate(evs):
            k = level * 2048 + cycle * 64 + slot
            bf_sig_rows.append((k, e["sid"]))
            bf_even_sig_rows.append((k, e["even_sig"]))
            bf_even_dot_rows.append((k, e["even_dot"]))
            bf_odd_dot_rows.append((k, e["odd_dot"]))
            bf_high_rows.append((k, e["high"]))
    lines += fn("p2f102_bf_count", "input integer key", bf_count_rows, 0)
    lines += fn("p2f102_bf_sig", "input integer key", bf_sig_rows, -1)
    lines += fn("p2f102_bf_even_sig", "input integer key", bf_even_sig_rows, -1)
    lines += fn("p2f102_bf_even_dot", "input integer key", bf_even_dot_rows, -1)
    lines += fn("p2f102_bf_odd_dot", "input integer key", bf_odd_dot_rows, -1)
    lines += fn("p2f102_bf_high", "input integer key", bf_high_rows, 0)
    lines += [f"localparam integer P2F102_ROOT0 = {roots[0]};"]
    for i, sid in enumerate(roots):
        lines.append(f"localparam integer P2F102_ROOT_{i} = {sid};")
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"generated {OUT} ({len(m.ops)} mul ops, {sum(len(v) for v in red_by_stage_cycle.values())} reduction events, {len(signals)} butterfly signals)")


if __name__ == "__main__":
    main()
