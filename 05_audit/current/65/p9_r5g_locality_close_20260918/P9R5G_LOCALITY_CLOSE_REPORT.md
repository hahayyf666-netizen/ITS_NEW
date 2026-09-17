# Step12F P9-R5G locality close (read-only)

## Decision

`PRODUCER_ONLY_LOCALITY_CLOSED_NO_D_NEAR_ONLY_CANDIDATE`

The bounded producer-only screening was closed from the existing 32-row
`bounded_screen_candidates.csv`.  No new region, subset, pblock, synthesis,
implementation, RTL, or XDC work was performed for this check.

## Census

| item | value |
|---|---:|
| candidate rows evaluated | 32 |
| rows mentioning a `d_near_*` rejection | 4 |
| rows rejected only by `d_near_*` reasons | 0 |
| rows with any non-`d_near` rejection | 32 |
| relaxed D_NEAR re-score | not run |
| G0.7 / G1 producer-only intervention | not authorized |

The four rows that mention D_NEAR also contain at least one upstream or other
rejection reason.  Therefore relaxing the D_NEAR thresholds would not create a
candidate that is cleanly attributable to D_NEAR alone under the frozen
screening data.

## Provenance

- Source: `05_audit/current/64/p9_r5g_g06_bounded_screen_20260918/bounded_screen_candidates.csv`
- Source SHA-256: `60548B5D64B2B4BB572AB637A7F845217594BA2B5E6B4C6C3B196CD67E51C6AD`
- Evaluation is read-only and uses the already generated 32 candidate rows.
- The source file is retained in the prior G0.6 evidence tree; this report does
  not duplicate the detailed layout CSV in the public mirror.

## Consequence

The producer-only locality branch is closed for this decision point.  The next
engineering action is a narrow R6 candidate review targeting the existing
`input_cache_bank` write-command fanout (`fill_wr_cmd_addr_q`,
`fill_wr_cmd_target_q`, and `fill_wr_cmd_data_q`) while preserving the current
atomic data+valid commit, input acceptance semantics, and throughput contract.

Frozen for the next review: profile/Oracle, R5 DUT and harness behavior, XDC,
LFNST arithmetic, P4 arithmetic, cache memory type, R4C, and `v3.5-18`.

