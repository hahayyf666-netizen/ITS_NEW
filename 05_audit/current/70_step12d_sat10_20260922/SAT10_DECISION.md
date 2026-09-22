# SAT10 engineering-profile checkpoint

This checkpoint selects `Clip3(-512,511,wide_value)` as the final signed-10
adapter for the new `contest_engineering_vtm10_sat10_v2` profile.  It is a
provisional engineering decision; the supplied contest material and VTM do
not prove the hidden-golden LOW10-versus-SAT10 rule.

The profile is fail-closed and profile-addressable.  Its SHA-256 is
`EF9467EABBE9DB697BC7F8F9F0AC51D387800C3E701C21AF094FE16D099674F8`.
The historical `contest_engineering_vtm10_v1` LOW10 profile and its audit
records are not rewritten.

The arithmetic core, VTM shifts, signed-16 intermediate clipping, LFNST
contract, coefficients, protocol and throughput contract are inherited from
`contest_engineering_vtm10_v1`.  The historical LOW10 profile and all of its
audits remain immutable.

## Functional evidence

- SAT10 profile inheritance validator: PASS.
- Independent Gate-C Python model: 369 tuples / 45,636 beats PASS.
- Normal and `SYNTHESIS` ModelSim compilation/regression: PASS.
- Gate-B numeric: 156 cases PASS.
- 13-mode vector-II: PASS; existing group/vector-II contract retained.
- LFNST engine: 1,088 cases PASS.
- LFNST wrapper: 388 cases PASS.
- Exhaustive actual RTL adapter test: 65,536 signed-16 values PASS.
- End-to-end wrapper overflow boundary, output-stall, and two-TU ownership
  test: 3 cases / 16 beats PASS.

The full Gate-C campaign contains no out-of-range signed-10 values, so its
non-regression PASS is not by itself evidence for SAT10.  The two dedicated
SAT10 tests provide that missing discrimination.

## Physical status

No synthesis, place or route result is inherited by this profile.  The old
LOW10/R6 timing numbers are historical references only.  A fresh SAT10
physical baseline is required after the functional checkpoint.

