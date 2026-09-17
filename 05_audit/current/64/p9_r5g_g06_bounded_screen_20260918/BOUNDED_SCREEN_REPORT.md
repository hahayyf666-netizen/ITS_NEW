# Step12F-P9-R5G bounded producer-only screening

Decision: **NO_PRODUCER_ONLY_CANDIDATE_IN_BOUNDED_SCREEN**

- Baseline commit: `167b11c96c5658cdfa3f0182213ce89f5b40d5c7`
- Fixed routed DCP SHA-256: `D18A6213468C4EE270D03AF924BE53BE7298DD71A70C5B2651ED0DDB8767552C` (match=True)
- Fresh inventory: `9198` rows; bbox `{'x_min': 40, 'x_max': 112, 'y_min': 55, 'y_max': 180}`; complete=`True`
- Evaluated pairs: `32` (4 fixed corridors × 8 fixed subsets)
- Passing pairs: `0`

## Fixed gates

The gates were fixed before scoring: bounded upstream-negative/pass risk, clear aggregate improvement for negative downstream paths, no downstream increases in the negative/near-zero sets, and two-FF-per-moved-bit capacity headroom. This is a geometric proxy, not a timing guarantee.

## Result

No fixed producer-only corridor/subset passed the bounded gates. This is not a proof that every producer-only placement is impossible; do not expand the virtual search, and return to the R5F timing census/physical-convergence path.
