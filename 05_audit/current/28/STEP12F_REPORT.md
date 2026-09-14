# Step12F — Unified Coverage Completion + 500 MHz Physical Closure

## Status

`STOP_PHYSICAL_SYNTHESIS`.

The coverage lane is closed for the current engineering-profile RTL.  The
fresh physical lane stopped during Vivado RTL elaboration before synthesis
reports or a checkpoint were produced; therefore no 500 MHz, RAM-inference,
PPA, or post-route claim is made.

## Coverage lane

The vector generator consumes the Gate-A engineering tuple matrix directly;
it does not reconstruct a local Cartesian product.  ModelSim SE-64 2020.4
ran both normal and `+define+SYNTHESIS` compilations and simulations:

- Gate-B numeric: 156 cases per mode.
- Full one-dimensional vector-II stress: all 13 modes, with II `N/4`.
- Gate-C wrapper smoke: 16/16 beats for each of two TUs, one done pulse per TU.
- Full Gate-C tuple campaign: 369 tuples and 45,636 beats per mode.
- Compilation and simulation logs reported zero errors.

These vectors are sparse deterministic inputs and prove tuple/configuration
coverage plus the existing protocol checks; they do not claim exhaustive
data-pattern coverage or official hidden-golden equivalence.

## Physical lane

The flow used a fresh in-memory project for `unified_its_wrapper`,
`unified_p4_kernel`, device `xcku5p-ffvb676-2-e`, a 2.000 ns clock, and the
registered-neighbor zero-delay XDC.  The first attempt exposed a variable
loop-bound elaboration error in the LFNST scan helper.  The helper was changed
to a statically bounded 15-iteration loop with the same runtime guard; the
existing coverage lane was rerun and remained PASS.

A fresh single-thread synthesis retry then ran for 2,464 seconds and reached
a Vivado peak memory of 42,097.105 MB before reporting `RTL Elaboration
failed` / `synth_design failed`.  No place, route, timing, utilization, or
power result exists for this design.

The direct profile reference calculation in `unified_its_wrapper.sv` is
currently elaborated as synthesizable logic (including 4,096-entry arrays and
runtime-sized nested transform loops).  The STOP is therefore a bounded
physical-implementation blocker, not a functional regression.

## Frozen boundaries

`v3.5-18`, the frozen R4C, the historical Step12B wrapper, and its XDC were
not modified.  This Step12F change is new unified RTL and verification flow
work only.  No new tag is created and no old tag is moved.

## Next finite action

Keep the Gate-A Oracle and functional contract unchanged.  Define a bounded
synthesizable implementation for the profile reference/LFNST and 2-D path
(or an explicitly resource-bounded equivalent), rerun the existing Step12F
coverage gates, then perform a new fresh physical baseline.  Do not infer
500 MHz viability from this failed elaboration attempt.
