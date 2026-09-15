# Step12F-P5 report

## Result

P5 functional coverage passes in both ModelSim modes and the approved
H-read/LFNST/scheduler structural changes are present. Fresh synthesis also
completes, but the 2.000 ns timing gate remains STOP. The current post-synthesis
WNS is `-0.769 ns`, TNS is `-3284.203 ns`, with 16,364 failing setup endpoints.
Hold is `WHS=-0.076 ns`, `THS=-3.422 ns`, with 48 failing endpoints. No route run
was started.

## Functional evidence

The final P5 capture-decoupled run passes normal and `SYNTHESIS` ModelSim:
156 Gate-B numeric cases, 13 vector-II modes, 369 Gate-C tuples / 45,636
beats per mode, 1,088 LFNST engine cases, 258 LFNST wrapper cases, the P3
write contract, and the directed P4 N=4 stream (16 descriptors, captures and
releases). The final coverage manifest is
`step12f_p5_h_capture_decoupled_pre/STEP12F_COVERAGE_MODELSIM_RUN.json`.

## P5 structural changes

The wrapper now uses a registered bank-local horizontal address recurrence and
a two-entry response tail/skid boundary. Response capture does not use the
current kernel-consume signal when the tail entry is available; a request-low
stall may require a refill edge, while the ready-high functional contract stays
one response per accepted group in the exercised tests. Input-cache read
addresses are independent of the live height cut; response validity still
masks unsupported rows. The P4 kernel predecodes slot metadata at admission and
uses a registered ready-token queue for issue selection, retaining the N=4
bubble-free stress contract.

## Fresh synthesis evidence

Vivado 2025.2 on `xcku5p-ffvb676-2-e` completed synthesis successfully in the
`step12f_p5_h_capture_decoupled_synth` directory. Resources are 38,164 LUT
(5,639 LUTRAM), 33,749 FF, 316 DSP, and 0 BRAM/URAM. Internal timing coverage
is complete: `check_timing` reports zero no-clock, unconstrained internal,
missing-I/O-delay, loop, and latch-loop findings; `report_exceptions` reports
`No valid timing exceptions found`.

The worst-100 setup report no longer contains H-read, LFNST-response or the
P4 scheduler families. Instead, its leading families are:

* `slot_width -> protocol_error_reg/D`, WNS `-0.769 ns`;
* `lfnst_run_q -> output_last_index_reg/D`, WNS `-0.746 ns`;
* `kernel_vector_q -> result-bank RAMD64E/WE`, WNS `-0.674 ns` (97 of the
  reported top-100 paths).

This is evidence that P5 changed the targeted cones, not evidence that the
full wrapper is timing-closed. The protocol/error-control and result-memory
write cones are recorded as newly leading blockers for the next decision;
they are not modified in P5.

## Decision

P5 is a functional pass and an effective partial structural/timing experiment,
but a physical timing STOP. The RTL checkpoint is retained; `v3.5-18`, frozen
R4C, Oracle/profile, and XDC remain unchanged. No place/route, tag, or 500 MHz
signoff is claimed.
