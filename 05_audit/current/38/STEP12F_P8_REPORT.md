# Step12F-P8 report

## Result

P8 functional verification passes in both ModelSim normal and `SYNTHESIS`
modes. The handshake boundary and constant V/H postprocess changes are
implemented, and fresh Vivado synthesis completes. The 2.000 ns setup/hold
gate remains a P1 STOP; place/route is not authorized.

## Functional evidence

The captured ModelSim run passes 156 Gate-B numeric cases, 13 one-dimensional
vector-II modes, 369 Gate-C tuples / 45,636 beats per mode, 1,088 LFNST engine
cases, 258 LFNST wrapper cases, the P3 write contract, and the directed P4 N=4
slot-release stream in both normal and `SYNTHESIS` modes. Evidence is in
`step12f_p8_coverage_20260915/STEP12F_COVERAGE_MODELSIM_RUN.json`.

Legacy standalone kernel testbenches do not connect the two newly added output
ports; ModelSim reports missing-port warnings for those tests, with zero
errors and all tests passing. Wrapper tests have no warnings. This is recorded
as a non-fatal compatibility note rather than a functional failure.

## P8 changes

`input_group_fire` is the same-edge kernel-owned transaction event used for
response consumption and group advance. `input_vector_done` is a separate
registered one-cycle token used for phase transitions, and wrapper input-valid
is suppressed while that token is asserted. This avoids conflating the event
with its completion token and preserves group II 1 and vector II `N/4`.

The postprocess now uses constant profile shifts, `(raw+64)>>>7` for vertical
and `(raw+512)>>>10` for horizontal, captures the full-width shifted result,
then performs signed-16 Clip3/packing in the following registered stage.
LOW10 remains at the wrapper result adapter.

## Fresh synthesis

Vivado 2025.2 on `xcku5p-ffvb676-2-e` completed fresh synthesis in 291 seconds
with approximately 4.1 GB peak report memory. The design uses 29,883 CLB LUTs
(5,639 LUT-memory LUTs), 25,229 registers, 1,637 CARRY8, 320 DSP48E2, and no
BRAM/URAM.

Setup remains negative: `WNS=-0.476 ns`, `TNS=-620.104 ns`, and 4,990 failing
endpoints. The representative worst path is:

```text
kernel_phase_q_reg[1]/C
  -> input_group_fire / kernel_input_group_fire handshake
  -> wrapper phase/group control
  -> kernel_group_q_reg[0]/D
```

It has 2.457 ns data delay, of which 1.926 ns is estimated routing, across
nine logic levels. This is a P8-specific same-edge handshake/control cone and
is the next narrow timing-closure target.

Hold remains the known zero-min registered-neighbor OOC boundary-style result:
`WHS=-0.076 ns`, `THS=-3.469 ns`, and 51 failing endpoints. The representative
path is `it_info[0] -> desc_mem_reg[0][0]/D`, with zero logic levels and
0.014 ns data delay. No timing exception, XDC change, or RTL hold hack was
added.

Internal constraint coverage is complete: no no-clock, unconstrained
internal, missing-I/O-delay, loop, or latch-loop findings; `report_exceptions`
states that no valid timing exceptions were found.

## Decision

P8 is a functional PASS and fresh-synthesis completion, but 500 MHz remains a
P1 STOP. Do not route or create a tag. The next investigation is limited to
decoupling the `input_group_fire` handshake from the phase/group control cone;
arithmetic, memories, R4C, XDC, Oracle/profile, and `v3.5-18` remain frozen.

