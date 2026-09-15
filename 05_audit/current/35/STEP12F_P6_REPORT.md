# Step12F-P6 report

## Result

P6 functional coverage passes in both ModelSim modes. The static geometry
decode, registered ResultMemory write command, monotonic result beat address,
and H-to-output commit barrier are present and exercised. Fresh Vivado
synthesis completes, but the 2.000 ns setup/hold gate remains STOP; no
place/route run was started.

## Functional evidence

The P6 capture passes normal and `SYNTHESIS` ModelSim: 156 Gate-B numeric cases,
13 vector-II modes, 369 Gate-C tuples / 45,636 beats per mode, 1,088 LFNST
engine cases, 258 LFNST wrapper cases, the P3 write contract, and the directed
P4 N=4 slot-release stream. The complete capture is
`step12f_p6_coverage/STEP12F_COVERAGE_MODELSIM_RUN.json`.

## P6 structural changes

The wrapper now decodes each supported power-of-two TU geometry through a
static case table at descriptor bind. The protocol and output-last paths use
registered geometry values; the generic `width*height` function is no longer
present in the RTL.

Horizontal kernel results are captured into a registered result-write command
and committed to ResultMemory on the following edge. The physical RAM ports
are driven from that command, and the old vector/group address expression is
retained only in a simulation-only equivalence assertion. A monotonic beat
counter supplies the physical ResultMemory address. The final H phase waits
for the last command to commit and for the command register to drain before
exposing `output_active`.

The targeted checkpoint confirms the intended cut: no timing paths were found
from synthesized kernel vector/group/phase state to ResultMemory WE pins. A
representative `result_cmd_valid_q` to ResultMemory WE path has `+0.883 ns`
setup slack with two logic levels.

## Fresh synthesis evidence

Vivado 2025.2 on `xcku5p-ffvb676-2-e` completed synthesis in 355 seconds with
3,566.645 MB peak memory. Resources are 38,300 CLB LUTs (5,639 LUT-memory
LUTs), 33,837 FF, 316 DSP, and 0 BRAM/URAM. Distributed memories remain
inferred as RAM64M/RAM64M8/RAM256X1D; no elaboration/resource explosion
reappeared.

The setup report is still negative: `WNS=-0.507 ns`, `TNS=-1828.651 ns`, and
12,319 failing endpoints. The top-100 population is no longer ResultMemory
write dominated. It contains four kernel-stage-to-phase-control paths at
`-0.507 ns`, five kernel-stage-to-read-request-control paths at `-0.369 ns`,
and 91 `s0_coeff_q`-to-product-register paths, worst `-0.447 ns`. The latter
still traverses the DSP multiply/output in one cycle (`2.428 ns` data delay,
8 logic levels), so it is a structural arithmetic blocker, not a routing-only
ResultMemory issue.

Hold remains the registered-neighbor OOC boundary behavior:
`WHS=-0.076 ns`, `THS=-3.372 ns`, 46 failing endpoints. A representative path
is `it_info[*]` to the descriptor FIFO register with zero logic levels and
0.014 ns data delay. No input-delay hack, exception, or false path was added.

Internal constraint coverage is complete: zero no-clock, unconstrained
internal, missing-I/O-delay, loop, and latch-loop findings; `report_exceptions`
reports `No valid timing exceptions found`. DRC contains the known DPIP-2,
DPOP-3, and DPOP-4 DSP pipelining warnings, with no errors or critical
warnings in the synthesis run.

## Decision

P6 is a functional pass and an effective partial structural closure. Its
ResultMemory target is closed at the synthesized topology level, but the
full-wrapper physical timing gate is a P1 STOP. Do not route, tag, or modify
ResultMemory again. The next decision must be based on the new P4 arithmetic
and kernel-control timing evidence; frozen R4C, XDC, Oracle/profile, and
throughput contracts remain unchanged.
