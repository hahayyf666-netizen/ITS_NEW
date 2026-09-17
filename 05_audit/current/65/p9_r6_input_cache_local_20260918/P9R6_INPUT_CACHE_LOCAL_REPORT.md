# Step12F P9 R6 — Input-cache write-command fanout localization

## Verdict

`P9-R6` is a functional and physical-target-effective checkpoint, but it is
not a 500 MHz signoff.  The producer-only locality branch is closed, and the
small RTL change that replicates the already-accepted sparse-fill command at
each physical slot/bank boundary was qualified with the full available
ModelSim campaign and a fresh registered-neighbor Vivado implementation.

```yaml
locality_producer_only: CLOSED_NO_D_NEAR_ONLY_CANDIDATE
functional_regression: PASS
registered_neighbor_synthesis: PASS
registered_neighbor_route: FULLY_ROUTED
target_effect: EFFECTIVE_PARTIAL
setup: FAIL
hold: PASS
500mhz_signoff: NOT_ACHIEVED
new_tag: NO
```

## Step A — locality branch close

The existing frozen 32-row bounded screening table was evaluated read-only.
It contains 4 rows mentioning a `d_near_*` rejection, but zero rows rejected
only for that reason.  No relaxed re-score, new region, pblock, RTL, XDC,
synthesis, or implementation was used.  The producer-only locality branch is
therefore closed for this decision point.

Source and result:

```text
source: 05_audit/current/64/p9_r5g_g06_bounded_screen_20260918/bounded_screen_candidates.csv
source_sha256: 60548B5D64B2B4BB572AB637A7F845217594BA2B5E6B4C6C3B196CD67E51C6AD
rows_evaluated: 32
rows_with_any_d_near_reason: 4
rows_rejected_only_by_d_near: 0
```

## Step B — R6 RTL change

Only `02_rtl/rtl/unified_its_wrapper.sv` was changed.  The existing atomic
`fill_wr_cmd_*_q` command remains the lifecycle/equivalence record, while its
accepted address, data, and one-hot target are replicated into
`fill_wr_bank_addr_q`, `fill_wr_bank_data_q`, and `fill_wr_bank_target_q`.
The input-cache data and valid write ports are driven only by these local
registers.  Old-command commit and new-command refill remain legal on the
same edge, and data/valid writes remain paired.

The change does not add a protocol-visible cycle, does not change the cache
memory type, and preserves sparse-input acceptance, final-data-plus-end
completion, scrub ownership, and the existing throughput contract.  Assertions
cover global/local target equivalence, one-hot ownership, address/data
equivalence, data/valid pairing, and scrub conflict.

The physical interpretation is deliberately limited: global cross-bank
command fanout is split, but local address registers still fan out to the
distributed-RAM fragments of their bank (about 368–373 loads in the routed
report).  This is not claimed to be zero-fanout replication.

Frozen: Oracle/profile, P4 arithmetic and coefficient organization, bounded
LFNST arithmetic, read-command boundary, cache memory implementation,
harness/XDC contract, R4C, and `v3.5-18`.

## Step C — functional qualification

ModelSim SE-64 2020.4 ran both normal and `SYNTHESIS` modes with zero compile
errors and all required markers passing:

```text
Gate-B numeric:                 156 cases
Gate-B vector-II legacy:          7 modes
Gate-F vector-II:                13 modes
Gate-C wrapper numeric:         369 cases
Gate-C beats:                45,636
LFNST engine specialty:       1,088 cases
LFNST wrapper specialty:        258 cases
P3 V-write contract:            PASS
P4 Stage-0 N=4 stream: 16/16/16/16 PASS
```

The authoritative machine-readable record is
`coverage_modelsim/STEP12F_COVERAGE_MODELSIM_RUN.json`.  Both normal and
`SYNTHESIS` runs report the same case/beat totals and preserve group II = 1
and vector II = N/4 evidence.

## Step D — fresh registered-neighbor implementation

The enclosing `step12f_registered_neighbor_harness` was freshly synthesized
and implemented; the R5E harness contract was retained (54 live source FF
bits, 44 live sink FF bits, 2.000 ns clock, nominal 0.000 ns uncertainty,
Vivado 2025.2, `xcku5p-ffvb676-2-e`, four threads).  The flow was:

```text
synth_design -flatten_hierarchy none -directive Default
opt_design -directive Default
place_design -directive ExtraNetDelay_high
phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation
```

The run completed in approximately 3,068 seconds.  Synthesis and route
completed without errors; 48,657/48,657 routable nets are fully routed and
there are zero routing errors.  Post-route DRC has zero errors.  The expected
top-level package-pin warning (UCIO-1 for `clk`/`rst_n`) remains a boundary
warning, not a hidden timing waiver; there are zero unconstrained internal
endpoints and no valid timing exceptions.  `rst_n` is the one intentional
no-input-delay control port in `check_timing`.

Post-route timing at 2.000 ns:

| measure | R5E registered-neighbor reference | R6 localized command | result |
|---|---:|---:|---|
| setup WNS | -0.139 ns | **-0.045 ns** | improved, not closed |
| setup TNS | -74.139 ns | **-4.882 ns** | improved |
| setup failing endpoints | 1,808 | **312** | improved |
| hold WHS | +0.010 ns | **+0.006 ns** | PASS |
| hold THS | 0.000 ns | **0.000 ns** | PASS |
| hold failing endpoints | 0 | **0** | PASS |

The R6 setup improvement is `+0.094 ns` WNS, a `69.257 ns` reduction in the
absolute TNS, and 1,496 fewer failing endpoints versus the R5E reference.
This is a fresh implementation comparison, not a same-placement A/B proof.

The R6 post-route global leader is now a different distributed control/read
tail (`slot_state_q → lfnst_grid_reg` at -0.045 ns); the old fill-command
family is absent from the post-route worst-100 report.  The high-fanout report
shows local bank address registers rather than the old global command address
as the physical drivers.  These observations support `EFFECTIVE_PARTIAL`,
not a claim that every fill-write path is positive slack.

Post-route utilization is 320 DSP48E2, 28,043 CLB LUTs (5,632 distributed-RAM
LUTs), 25,831 CLB registers, 1,487 CARRY8, 1,743 F7 muxes, 592 F8 muxes, zero
block-RAM tiles, and zero URAM.  The detailed reports and DCPs remain in the
local evidence directory; the public mirror carries this concise audit rather
than multi-megabyte implementation artifacts.

## Decision and next boundary

`P9-R6` is retained as the current RTL checkpoint because it preserves all
functional/throughput evidence and materially improves the registered-neighbor
setup result.  It remains a setup-stop, not a signoff:

```yaml
R6_RTL: RETAINED / FROZEN
R6_functional: PASS
R6_target: EFFECTIVE_PARTIAL
registered_neighbor_hold: PASS
registered_neighbor_setup: FAIL (-0.045 ns / -4.882 ns / 312)
package_level_timing: NOT_EVALUATED
R6_500MHz_signoff: NOT_ACHIEVED
R7_or_new_RTL: NOT_AUTHORIZED_BY_THIS_CHECKPOINT
```

The next action should be a short classification of the new distributed
setup tail (especially `slot_state`, `kernel_cut_h`, and `rd_cmd_addr` paths),
not another broad locality search and not an immediate additional RTL cut.

