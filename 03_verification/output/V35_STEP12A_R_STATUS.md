# Step 12A-R status

The former Step 12A is recorded as **PARTIAL PASS**: its matrix arithmetic,
basic sparse reconstruction, coordinate mapping and reservation algebra are
useful, but its scheduled II and memory latency were not derived from a
resource-constrained tick model.

Step 12A-R is the executable re-gate.  It uses one frozen R4C black-box
contract (vector admission interval 16, first group latency 24, 16 groups,
four results/group), four single-port banks, a one-cycle read response,
finite epoch tags with full scrub on wrap, and explicit protocol/admission
negative tests.  The result is in `_step12ar_audit/step12ar_results.json`.

The reported throughput is 4 complete results per cycle for each 1-D phase.
It is not a claim that the complete two-dimensional TU has a long-term average
of 4 final coefficients per cycle; one kernel is reused for vertical and
horizontal phases.
