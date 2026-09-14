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
- Gate B arithmetic: PASS in both normal and `SYNTHESIS`-define ModelSim for
  156 cases spanning 13 modes, two stages and six input classes. Four outputs
  per group and ready-high group II=1 are verified. Gate B overall remains
  STOP because the RTL serializes `S_LOAD(N)` and `S_OUTPUT(N/4)` and cannot
  meet the frozen vector-start II of `N/4`.
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

The remaining STOP is architectural, not environmental. The Gate-B kernel
cannot overlap vector loading and output, so its vector II is not `N/4`.
The Gate-C wrapper is intentionally a direct-matrix functional reference and
does not instantiate the Gate-B kernel in the two-dimensional path.

The final state is therefore:

`STOP_GATE_B_VECTOR_II_AND_GATE_C_KERNEL_INTEGRATION`

These are two dependent P1 architecture blockers. The next action is to
replace the serial reference kernel with a buffered/overlapping P4 path that
meets vector II `N/4`, then instantiate that passing kernel in the Gate-C
vertical/horizontal datapath and rerun the existing tests. No source-contract,
physical timing, or optional audit gate is added by this correction.
