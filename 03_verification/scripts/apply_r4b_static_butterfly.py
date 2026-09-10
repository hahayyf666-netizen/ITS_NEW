#!/usr/bin/env python3
"""Replace only the dynamic butterfly event block with the generated include."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / "02_rtl" / "rtl" / "p2f_dct2_64_b1_step102.sv"
start_marker = "            // Butterfly event fabric."
end_marker = "            // Capture one edge after the last root butterfly has registered."
replacement = (
    "            // R4B event-unrolled butterfly fabric.  Source and destination "
    "IDs are fixed by the audited 124-event graph; only context (bank/vector) "
    "remains dynamic.\n"
    "`include \"p2f_r4b_static_butterfly.svh\"\n\n"
)

text = RTL.read_text(encoding="utf-8")
start = text.find(start_marker)
end = text.find(end_marker, start)
if start < 0 or end < 0 or end <= start:
    raise SystemExit("dynamic butterfly block markers not found")
if text.count(start_marker) != 1 or text.count(end_marker) != 1:
    raise SystemExit("ambiguous butterfly block markers")
new_text = text[:start] + replacement + text[end:]
RTL.write_text(new_text, encoding="utf-8", newline="\n")
print(f"replaced {end-start} bytes in {RTL}")
