# Step12F-P9-R7 — LFNST grid redundant data-clear removal

## Decision

`P9-R7` is **REJECTED / PHYSICAL_SETUP_REGRESSION**. The functional change is correct and the full simulation campaign passes, but the fresh registered-neighbor implementation is materially worse than the retained R6A reference. R6 remains the retained frozen RTL baseline; no follow-on RTL is authorized by this checkpoint.

The change was intentionally limited to removing the redundant active-LFNST admission data clear:

```systemverilog
// removed from the 64-entry admission loop
lfnst_grid[lfnst_grid_i] <= '0;
```

The corresponding `lfnst_grid_valid[...] <= 1'b0` clears remain. Reset-time data and valid clears remain, and all functional writes/valid gating remain unchanged. Since the consumer is guarded by `lfnst_grid_valid`, stale data cannot be observed as a valid LFNST sample.

## Provenance and implementation contract

```yaml
baseline_commit: 89e4c4e10c0a7ff380ec2570c5b596cc582bfa15
rtl_change: one-line removal in 02_rtl/rtl/unified_its_wrapper.sv
rtl_source_hash_from_modelsim: 139A83BF2D66580A62C1FE9DB16EEDC87E8379C544979AFA8D8489E6AA5C0EEC
vivado: 2025.2 Build 6299465
part: xcku5p-ffvb676-2-e
top: step12f_registered_neighbor_harness
clock_period_ns: 2.000
clock_uncertainty_ns: 0.000
max_threads: 4
flow: Default_ExtraNetDelay_high_AggressiveExplore_NoTimingRelaxation
old_r6_postsynth_sha256: 0AC1CA33EBD4A7A993C8B0083F3C2FB1AFA97F081139F64463CD625AA089A374
old_r6_postroute_sha256: 6FCD3084E9166C0A114503D0C1A1062F9E9DAFCF79C549CD27C744C2B09F92FC
r7_postsynth_sha256: 06F6BE58318E28BE9409CC24E06FAB25C8C86A7BFC78F65A12C0DA066586F6A2
r7_postroute_sha256: D071EAC6011F33F5AA4EA0AFCCF6399C85E30A96ED7CC02CD274DD23608614D1
```

R7 is a fresh synthesis and implementation of the changed RTL. The DCPs and full Vivado log remain local evidence; compact reports and the read-only census are published.

## Functional qualification

ModelSim SE-64 2020.4 passed in both normal and `SYNTHESIS` modes:

- Gate-B numeric: 156 cases.
- Legacy vector-II modes: 7; full 13-mode vector-II stress: PASS.
- Gate-C: 369 tuples / 45,636 beats per mode.
- LFNST engine specialty: 1,088; wrapper specialty: 258.
- P3 vwrite and P4 Stage-0 contracts: PASS; N=4 stream: 16/16/16/16 PASS.
- No functional, ordering, ownership, duplicate/drop, or completion regression was observed.

## Fresh routed result

| Run | Setup WNS (ns) | Setup TNS (ns) | Setup failing endpoints | Hold WHS (ns) | Hold THS (ns) | Hold failing endpoints | Route |
|---|---:|---:|---:|---:|---:|---:|---|
| R6A retained reference | -0.045 | -4.882 | 312 | +0.006 | 0.000 | 0 | Fully routed |
| R7 fresh registered-neighbor | **-0.134** | **-42.408** | **1006** | **+0.007** | **0.000** | **0** | Fully routed |

R7 therefore fails the 500 MHz setup signoff and fails the R7 effectiveness criterion. Setup worsened by 89 ps, TNS by 37.526 ns, and failing endpoints increased by 694. Hold remains passing.

Structural checks:

- 48,380/48,380 routable nets fully routed; routing errors: 0.
- DRC reported 0 errors. Expected OOC-harness critical warnings remain for unspecified I/O standard/location on `clk`/`rst_n`; these are not package-level signoff evidence.
- `check_timing` reported 0 unconstrained internal endpoints. The single no-input-delay item is the expected harness `rst_n` port.
- No timing exception was added or used to mask the result.

## R7 read-only setup-tail census

The contract-required frozen R6A classifier was run on the exact R7 post-route DCP without optimization or checkpoint mutation. It found:

```yaml
raw_negative_path_objects: 1006
unique_negative_endpoints: 1006
duplicate_endpoints: 0
unclassified_endpoints: 0
reconstructed_tns_ns: -42.426
authoritative_summary_tns_ns: -42.408
```

The 18 ps reconciliation difference is expected from Vivado path-property rounding; the routed timing summary remains authoritative.

| Bucket | Endpoints | Reconstructed TNS (ns) | TNS share | Median routing fraction |
|---|---:|---:|---:|---:|
| DUT internal | 972 | -40.971 | 96.57% | 0.805 |
| DUT to sink boundary | 24 | -1.227 | 2.89% | 0.748 |
| Source boundary to DUT | 10 | -0.228 | 0.54% | 0.848 |

The largest endpoint pairs are distributed rather than a single newly isolated LFNST-grid cone: `vwrite_cmd_bank_mask_q → temp_bank` (76 / -2.644 ns), H-read address/data (41 / -2.570 ns), P4 ingress data/slot/valid → `input_mem` (199 combined / -6.613 ns), and `rd_cmd_addr_q → kernel_rd_raw_data_q` (31 / -2.161 ns). The census contains 192 family pairs and no duplicate or unclassified endpoint.

This result does not support claiming that removing the data clear improved physical locality or timing. It is consistent with a small RTL/netlist change triggering a different physical solution; regardless of mechanism, the required engineering result is worse and the change is rejected as an active baseline.

## Final state

```yaml
P9-R7:
  functional: PASS
  throughput: PASS
  fresh_synthesis: PASS
  fully_routed: true
  registered_neighbor_hold: PASS
  registered_neighbor_setup: FAIL
  classification: REJECTED_PHYSICAL_SETUP_REGRESSION

R6:
  retained: true
  frozen: true

500mhz_core_signoff: NOT_ACHIEVED
package_level_timing: NOT_EVALUATED
follow_on_rtl: NOT_AUTHORIZED
new_tag: false
```

The practical next step is not to stack another blind RTL change on top of R7. Retain R6/R6A, record R7 as a rejected experiment, and only propose a follow-on after a concrete timing hypothesis and a controlled implementation comparison are defined.
