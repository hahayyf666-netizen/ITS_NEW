"""Generate the R4A lane-local operand/coefficient tables from R4_PRE data.

The source map is authoritative and copied into this complete R4A project.
This generator never changes the operation schedule: it only changes how the
already fixed phase/lane constants are represented in RTL.
"""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "03_verification" / "output" / "r4_lane_source_map.json"
OUT = ROOT / "02_rtl" / "rtl" / "p2f_r4a_local_tables.svh"
LANES = 128
PHASES = 16
CHOICES = 3


def row(values: list[int]) -> str:
    return "'{" + ", ".join(str(v) for v in values) + "}"


def main() -> None:
    data = json.loads(SRC.read_text(encoding="utf-8"))
    src_ids: list[list[int]] = []
    src_sel: list[list[int]] = []
    coeff: list[list[int]] = []
    valid: list[list[int]] = []
    op_id: list[list[int]] = []
    for lane in range(LANES):
        records = data[str(lane)]["records"]
        sources: list[int] = []
        for rec in records:
            s = int(rec["source_x_index"])
            if s not in sources:
                sources.append(s)
        if not 1 <= len(sources) <= CHOICES:
            raise ValueError(f"lane {lane}: source count {len(sources)}")
        src_ids.append(sources + [sources[-1]] * (CHOICES - len(sources)))
        by_phase = {int(rec["issue_cycle"]): rec for rec in records}
        sels: list[int] = []
        cs: list[int] = []
        vs: list[int] = []
        ops: list[int] = []
        for phase in range(PHASES):
            rec = by_phase.get(phase)
            if rec is None:
                sels.append(0)
                cs.append(0)
                vs.append(0)
                ops.append(-1)
            else:
                sels.append(sources.index(int(rec["source_x_index"])))
                cs.append(int(rec["coefficient"]))
                vs.append(1)
                ops.append(int(rec["op_id"]))
        src_sel.append(sels)
        coeff.append(cs)
        valid.append(vs)
        op_id.append(ops)

    lines = [
        "// AUTO-GENERATED for R4A; source is r4_lane_source_map.json.",
        "// Do not edit manually: operation schedule and values are unchanged.",
        "localparam integer R4A_CLUSTER_COUNT = 4;",
        "localparam integer R4A_LANES_PER_CLUSTER = 32;",
        "localparam integer R4A_PHASE_COUNT = 16;",
        "localparam integer R4A_SOURCE_CHOICE_COUNT = 3;",
        "localparam integer R4A_SRC_ID [0:127][0:2] = '{",
    ]
    for lane, vals in enumerate(src_ids):
        lines.append("  " + row(vals) + ("," if lane != LANES - 1 else ""))
    lines += ["};", "localparam integer R4A_SRC_SEL [0:127][0:15] = '{"]
    for lane, vals in enumerate(src_sel):
        lines.append("  " + row(vals) + ("," if lane != LANES - 1 else ""))
    lines += ["};", "localparam integer R4A_COEFF [0:127][0:15] = '{"]
    for lane, vals in enumerate(coeff):
        lines.append("  " + row(vals) + ("," if lane != LANES - 1 else ""))
    lines += ["};", "localparam integer R4A_VALID [0:127][0:15] = '{"]
    for lane, vals in enumerate(valid):
        lines.append("  " + row(vals) + ("," if lane != LANES - 1 else ""))
    lines += ["};", "localparam integer R4A_OP_ID [0:127][0:15] = '{"]
    for lane, vals in enumerate(op_id):
        lines.append("  " + row(vals) + ("," if lane != LANES - 1 else ""))
    lines += ["};", ""]
    OUT.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print(f"generated {OUT} lanes={LANES} phases={PHASES}")


if __name__ == "__main__":
    main()
