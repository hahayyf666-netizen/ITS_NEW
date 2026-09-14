# Step12D Engineering Closure → Step12E Unified Functional RTL

## Frozen boundary

`v3.5-18`, the frozen R4C, the historical Step12B wrapper, the 22-bit
interface contract, and the existing XDC remain immutable.  The unified RTL
is new code beside the historical baseline.  This batch does not run Vivado
and does not claim a 500 MHz result.

The reproducible engineering profile is
`contest_engineering_vtm10_v1`: bit depth 10, extended precision off,
transform dynamic range 15, VTM inverse shifts 7/10 with rounding additions
64/512 and signed-16 intermediate clipping.  The default final adapter is
LOW10 two's-complement; SAT10 is an explicitly labelled alternate.  Official
equivalence and historical hidden-golden equivalence remain unproven.

## Gate results

- Gate A: PASS for the documented engineering profile.  The H/V off-mode
  tuple set is an explicitly labelled per-axis implementation superset, not
  an official Cartesian-product claim.  LFNST active cases are DCT2×DCT2
  with the source-backed set/index matrix.
- Gate B: PASS for the independent 13-case P4 schedule contract (156 vectors,
  2,928 scalar values, zero mismatches).  It is a functional schedule proof,
  not a physical resource/timing proof.
- Gate C model: PASS for 369 tuples (169 LFNST-off plus 200 active cases),
  45,636 output beats, sparse full-raster input, rectangles/mixed H/V,
  LFNST, two-slot ownership, backpressure and exactly-once completion.  The
  model reports zero dropped/duplicated beats and zero ownership violations.

## Gate C HDL boundary

`unified_its_wrapper.sv` and `unified_its_wrapper_tb.sv` are present and
contain the complete protocol/ownership reference structure.  The current
environment has no `vsim`, `vlog`, `iverilog`, `verilator`, or `xvlog` on PATH.
Consequently normal and `SYNTHESIS`-mode HDL simulation were not run and are
not represented as PASS.

The final state is therefore:

`STOP_GATE_C_HDL_SIMULATOR_UNAVAILABLE`

This is one finite P1 evidence blocker.  The next action is to run the new
testbench in both compile modes with an available HDL simulator, then update
the final manifest.  No new RTL, timing, source, or optional audit gates are
introduced by this STOP.
