#!/usr/bin/env python3
"""Fail-closed audit for the R4B event-unrolled butterfly implementation."""
from __future__ import annotations

import csv
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CSV = ROOT / "03_verification" / "output" / "r4b_pre_butterfly_audit" / "r4b_pre_butterfly_events.csv"
INC = ROOT / "02_rtl" / "rtl" / "p2f_r4b_static_butterfly.svh"
RTL = ROOT / "02_rtl" / "rtl" / "p2f_dct2_64_b1_step102.sv"
OUT = ROOT / "03_verification" / "output" / "r4b_event_static_connectivity.json"

ASSIGN_RE = re.compile(
    r"signal_reg\[(?P<dest>\d+)\]\s*<=\s*"
    r"(?P<even>\$signed\((?:dot_value_bank\[bf_bank\]\[(?P<edot>\d+)\]|signal_reg\[(?P<esig>\d+)\])\))\s*"
    r"(?P<op>[+-])\s*"
    r"(?P<odd>\$signed\(dot_value_bank\[bf_bank\]\[(?P<odot>\d+)\]\));"
)
PHASE_RE = re.compile(r"if \(bf_cycle == 6'd(?P<phase>\d+)\) begin")


def canonical_row(row: dict) -> tuple:
    even = json.loads(row["even"])
    odd = json.loads(row["odd"])
    return (
        int(row["phase"]),
        int(row["destination"]),
        even["kind"],
        int(even["id"]),
        odd["kind"],
        int(odd["id"]),
        row["operation"],
    )


def main() -> int:
    rows = list(csv.DictReader(CSV.open("r", encoding="utf-8", newline="")))
    expected = [canonical_row(r) for r in rows]
    text = INC.read_text(encoding="utf-8")
    observed = []
    current_phase = None
    for line in text.splitlines():
        phase = PHASE_RE.search(line)
        if phase:
            current_phase = int(phase.group("phase"))
        m = ASSIGN_RE.search(line)
        if not m:
            continue
        if current_phase is None:
            raise SystemExit("assignment appears before a phase guard")
        even_kind = "dot" if m.group("edot") is not None else "signal"
        even_id = int(m.group("edot") or m.group("esig"))
        observed.append(
            (
                current_phase,
                int(m.group("dest")),
                even_kind,
                even_id,
                "dot",
                int(m.group("odot")),
                "add" if m.group("op") == "+" else "sub",
            )
        )
    checks = {
        "expected_events": len(expected),
        "observed_events": len(observed),
        "expected_destinations": len({x[1] for x in expected}),
        "observed_destinations": len({x[1] for x in observed}),
        "duplicate_observed_destinations": len(observed) - len({x[1] for x in observed}),
        "event_sequence_exact": observed == expected,
        "no_dynamic_butterfly_lookup_in_rtl": not any(
            token in RTL.read_text(encoding="utf-8")
            for token in ("p2f102_bf_count(", "p2f102_bf_sig(", "p2f102_bf_even_sig(",
                          "p2f102_bf_even_dot(", "p2f102_bf_odd_dot(", "p2f102_bf_high(")
        ),
        "no_dynamic_signal_destination_in_rtl": "signal_reg[sid_tmp]" not in RTL.read_text(encoding="utf-8"),
        "include_has_begin_end": "R4B_EVENT_STATIC_BEGIN" in text and "R4B_EVENT_STATIC_END" in text,
    }
    checks["pass"] = all(
        [
            checks["expected_events"] == 124,
            checks["observed_events"] == 124,
            checks["expected_destinations"] == 124,
            checks["observed_destinations"] == 124,
            checks["duplicate_observed_destinations"] == 0,
            checks["event_sequence_exact"],
            checks["no_dynamic_butterfly_lookup_in_rtl"],
            checks["no_dynamic_signal_destination_in_rtl"],
            checks["include_has_begin_end"],
        ]
    )
    OUT.write_text(json.dumps(checks, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(checks, ensure_ascii=False, indent=2))
    return 0 if checks["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
