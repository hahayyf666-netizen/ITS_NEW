# Step12F-P9-R5G-G0.6 — Balanced Producer Locality Frontier

Status: `CLOSED_READ_ONLY`; no RTL/XDC/implementation command, pblock, or modified checkpoint was created.

- Baseline commit: `d4c28ba7385e1cf44539c31e03a3b39ee84cf450`
- Fixed routed DCP SHA-256: `D18A6213468C4EE270D03AF924BE53BE7298DD71A70C5B2651ED0DDB8767552C` (match=True)
- Decision: **PRODUCER_ONLY_LOCALITY_NOT_VIABLE**

## Complete populations

- Upstream: `64` total = `58` negative + `6` nonnegative.
- Downstream: `4032` total = `201` negative + `384` near-zero nonnegative subset.
- Every candidate/subset pair is emitted to `g06_candidate_frontier.csv`, including rejected pairs and rejection reasons.

## Frozen candidate universe

- Anchor lattice: X `56..100` step `4`, Y `76..116` step `4`.
- Window: half-width `12`, half-height `16`; no window is selected after scoring.
- Candidates: `132`; subset definitions: `8`; evaluated pairs: `1056`.
- Subsets are generated deterministically from geometry features; slack is not used for cluster assignment.

## Frontier decision

- Basic geometry-eligible pairs: `1056`.
- Non-dominated Pareto pairs: `61`.
- Proxy tradeoff pairs (upstream non-worsening + downstream improvement): `0`.
- Tradeoff pairs blocked by unproven control/congestion gates: `0`.
- Minimum `U_NEG` increase count over all pairs: `4` (zero is required for a no-worsening proxy).
- Best upstream-risk pair: `{'candidate_id': 'A_X068_Y116', 'subset_id': 'FEATURE_BIN_3', 'u_neg_median': 0.0, 'u_neg_increase_count': 4, 'd_neg_median': 0.0}`.
- Best downstream-benefit pair: `{'candidate_id': 'A_X088_Y092', 'subset_id': 'ALL_64', 'u_neg_median': 65.0, 'u_neg_increase_count': 58, 'd_neg_median': -84.0, 'd_near_median': -74.0}`.

The frontier is a multi-objective result; no arbitrary weighted score is used. A distance improvement is not a timing guarantee.

## Required interpretation

**PRODUCER_ONLY_LOCALITY_NOT_VIABLE** is a read-only geometry/risk conclusion only. It does not authorize G1-PREP, G1 CONTROL/TREATMENT, a pblock, or R6 RTL.
Any future `BALANCED_PRODUCER_CANDIDATE_FOUND` must still pass real control-set compatibility and local congestion checks after a common post-opt branch point.

