# Step12F-P7 report

## Result

P7 functional verification passes in both ModelSim normal and `SYNTHESIS`
modes. The product pipeline and wrapper/kernel context boundary were applied,
and fresh Vivado synthesis completed. The 2.000 ns setup/hold gate remains a
P1 STOP; place/route was not authorized.

## Functional evidence

The captured ModelSim run passes 156 Gate-B numeric cases, 13 one-dimensional
vector-II modes, 369 Gate-C tuples / 45,636 beats per mode, 1,088 LFNST engine
cases, 258 LFNST wrapper cases, the P3 write contract, and the directed P4 N=4
slot-release stream in both modes. The machine-readable capture is
`step12f_p7_coverage/STEP12F_COVERAGE_MODELSIM_RUN.json`.

## P7 implementation changes

`unified_p4_kernel` now separates resettable validity/metadata from data-only
multiply and reduction registers. Inactive operands are zeroed at the
registered Stage-0 boundary. Vivado reports absorption of the multiply data
registers into DSP48E2 AREG/BREG/MREG/PREG mappings. The old
coefficient-to-product family is no longer in the synthesized top-100, but the
coefficient-specific targeted query is empty after endpoint trimming, so this
is not an all-path timing proof.

The wrapper now freezes transform size, active size, output size, stage, and
group count in a phase-entry context register. The targeted scheduler-to-
descriptor representative path is positive (`+0.627 ns`), and descriptor-to-
input/metadata paths are positive (`+1.570 ns` / `+1.648 ns`).

## Fresh synthesis evidence

Vivado 2025.2 on `xcku5p-ffvb676-2-e` completed synthesis in 445 seconds;
peak reported memory was 4,120.977 MB during report generation. The design
uses 30,173 CLB LUTs (5,639 LUT-memory LUTs), 25,118 registers, 1,621 CARRY8,
320 DSP48E2, and no BRAM/URAM. Input, intermediate, and result memories are
still distributed RAM.

The setup gate is negative: `WNS=-0.335 ns`, `TNS=-521.715 ns`, and 4,231
failing endpoints. The leading path is the remaining kernel context/capacity
feedback cone:

```text
kernel_ctx_group_count_q_reg[1]/C
  -> output_group_count
  -> unified_p4_kernel in_req / kernel_in_req
  -> kernel_phase_q_reg[0]/CE
```

It has 2.230 ns data delay, of which 1.685 ns is estimated routing, across
eight logic levels. A second top-100 population is the final shift/round/clip
and output packing family (`s6_shift_q` to `pipe_out_data_q`), with a
representative slack of `-0.286 ns`.

Hold remains the small registered-neighbor OOC boundary-style result:
`WHS=-0.076 ns`, `THS=-3.388 ns`, and 48 failing endpoints. The representative
path has zero logic levels and 0.014 ns data delay. No XDC, false path,
multicycle, or RTL hold hack was added.

Internal constraint coverage is complete: no no-clock, unconstrained
internal, missing-I/O-delay, loop, or latch-loop findings; there are no valid
timing exceptions. Synthesis DRC reports the known DPIP-2/DPOP-3/DPOP-4 DSP
methodology warnings but no critical warnings or errors.

## Decision

P7 is a functional PASS and an effective partial timing closure. The DSP
product structural objective and local scheduler/descriptor boundary are
effective, but global setup remains a P1 STOP. Do not route or create a tag.
The next investigation is limited to the kernel context/capacity feedback and
final output packing paths. R4C, ResultMemory, H-read, LFNST, XDC,
Oracle/profile, and `v3.5-18` remain frozen.
