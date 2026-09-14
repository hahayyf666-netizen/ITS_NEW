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
- Gate B arithmetic and transaction contract: PASS in both normal and
  `SYNTHESIS`-define ModelSim for 156 cases spanning 13 modes, two stages and
  six input classes. Four outputs per group, ready-high group II=1, and a
  seven-mode vector-II regression are verified. The four-slot kernel overlaps
  loading and draining and meets vector II=N/4 in the tested modes.
- Gate C model: PASS for 369 tuples (169 LFNST-off plus 200 active cases),
  45,636 output beats, sparse full-raster input, rectangles/mixed H/V,
  LFNST, two-slot ownership, backpressure and exactly-once completion.  The
  model reports zero dropped/duplicated beats and zero ownership violations.

## Gate B/C HDL evidence and architecture boundary

The earlier PATH-only simulator detector was wrong. ModelSim SE-64 2020.4 is
installed at `D:/software/Modelsim/win64` and was executed successfully.
Normal and `SYNTHESIS`-define compilation each complete with zero errors and
zero warnings. In both modes the Gate-B numeric test passes 156 cases, the
Gate-C two-TU smoke test passes 16/16 beats and exactly one done per TU, and
the Gate-C numeric test passes 19 cases / 2,368 beats against independently
generated Oracle vectors.

Those runs exposed and corrected real HDL defects: a descriptor pointer-width
error, a 64x64 point-count truncation, LFNST diagonal scan/nonzero handling,
and the 48-output LFNST ROM scenario base. The corrected HDL is numerically
and procedurally verified by the recorded regression.

The simulator availability issue was environmental and is closed. The
integrated Gate-C wrapper instantiates the P4 kernel for LFNST-off vertical and
horizontal passes; active LFNST continues to use the independently checked
VTM-profile reference path. The recorded HDL suite covers all 13 one-dimensional
modes, 19 directed 2-D/LFNST cases (2,368 beats), and the two-TU smoke test in
both compile modes. The independent software model remains the exhaustive
369-tuple source; full 369-tuple HDL simulation and physical timing are not
claimed by this batch.

The final state is therefore:

`PASS_FUNCTIONAL_BASELINE_PHYSICAL_TIMING_PENDING`

The functional P4 integration blockers are closed for the recorded coverage.
The next action is a separate coverage/physical-implementation decision: if
required, extend HDL vectors to all 369 model tuples and then run a dedicated
synthesis/implementation flow. No source-contract, 500 MHz, or physical PPA
claim is implied by this functional result.
