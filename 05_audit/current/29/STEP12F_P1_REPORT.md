# Step12F-P1 — Bounded Synthesizable Datapath Replacement

## Status

`STOP_SYNTHESIS_TIMEOUT_RESOURCE`.

The bounded LFNST and wrapper functional evidence passes in both ModelSim
normal and `+define+SYNTHESIS` modes.  A fresh Vivado synthesis of the new
unified wrapper was then run from the repository RTL with one thread for a
bounded 7,200-second observation window.  It was still inside `synth_design`
after about 7,333 seconds and was stopped; no synthesis checkpoint,
utilization, timing, implementation, or power report was produced.

This is a physical-implementation P1 STOP.  It is not a functional failure
and it does not establish a 500 MHz result.

## Functional evidence

The final ModelSim runner (`step12f_p1_coverage_final`) passed both normal and
SYNTHESIS modes:

- Gate-B numeric: 156 cases per mode.
- All 13 one-dimensional vector-II modes, with II `N/4`.
- Gate-C full campaign: 369 tuples and 45,636 beats per mode.
- Bounded LFNST engine specialty: 1,088 cases per mode, including 1,024
  basis cases.
- LFNST wrapper specialty: 258 cases / 4,644 beats per mode, exercising all
  gather terms and set/index combinations.
- Smoke, ordering, no-drop/no-duplicate checks and compilation reported zero
  ModelSim errors.

The machine-readable summary and logs are in
`step12f_p1_coverage_final/STEP12F_COVERAGE_MODELSIM_RUN.json`.

## P1 changes exercised

The new path removes the synthesizable unbounded direct 2-D/LFNST reference
calculator, adds `bounded_lfnst_engine.sv` with a packed coefficient ROM and
64 products per issue group, and replaces bulk sparse-input/result operations
with bounded valid-tag and streaming transactions.  The independent Python
Oracle and vectors remain outside the DUT.

## Physical result

Vivado 2025.2, part `xcku5p-ffvb676-2-e`, 2.000 ns clock, one thread:

- Start: `2026-09-14 20:02:25`.
- Stop: `2026-09-14 22:04:38`.
- `synth_design`: no completion within the 7,200-second limit.
- Implementation: not run.
- Reports/checkpoint/timing/PPA: unavailable.

The log contains structural inference warnings, including dynamic
multi-write `kernel_tmp_calc` being dissolved into registers and unsupported
reset/multi-write patterns for wrapper memories.  These are diagnostics, not
final utilization numbers.

## Frozen boundaries

`v3.5-18`, its frozen R4C, the historical Step12B wrapper/XDC, and the
external functional contract were not changed.  No new tag was created.

## Next action

Preserve this STOP evidence.  A future physical-repair proposal must address
the remaining storage/write-port topology separately; it must not infer a
successful RAM implementation or timing result from this incomplete run.
