# Step12F-P9 Round 3 — Qualification After Scrub-Priority Fix

## Decision

The P9 Round 3 input-cache fill write accept/commit boundary is functionally qualified after a small RTL correction. Fresh synthesis and full implementation both completed, and the design is fully routed. The 500 MHz setup/hold gate is **not closed**.

```text
RTL correction                         APPLIED
ModelSim normal                        PASS
ModelSim SYNTHESIS                    PASS
Fresh Vivado synthesis                PASS_COMPLETED_BUT_TIMING_FAIL
Fresh Vivado implementation           FULLY_ROUTED_BUT_TIMING_FAIL
Step12F 500 MHz signoff               STOP
New tag                                NOT AUTHORIZED
```

## Qualification finding and correction

The first post-P9-R3 simulation exposed a real priority bug: the fill-write loop unconditionally assigned the valid-memory write controls after the scrub loop. During a scrub cycle this overwrote the valid-clear command with zero-valued fill controls, allowing stale valid tags to survive slot reuse.

The correction is limited to `unified_its_wrapper.sv`. Valid-memory controls are now overridden only when the registered fill command actually targets that slot/bank. With no fill target, the scrub valid-clear assignment is preserved. Data and valid writes remain paired on the registered fill-command commit edge, and the existing ownership assertion still rejects a delayed fill command targeting the scrub slot.

## Frozen boundaries

The following remain unchanged:

- `unified_p4_kernel.sv`, `its_input_cache_bank.sv`, and `bounded_lfnst_engine.sv`;
- the Gate-A Oracle and `contest_engineering_vtm10_v1` profile;
- the 2.000 ns XDC constraint;
- frozen R4C and annotated tag `v3.5-18` (target commit `7415b0acb33481af1845f63e16b93ce7c33b977b`);
- the external protocol, sparse raster semantics, result ordering, and throughput contract.

No XDC, Oracle/profile, R4C, or tag was changed.

## HDL functional qualification

ModelSim SE-64 2020.4 was run in both normal and `+define+SYNTHESIS` modes by `run_step12f_coverage_modelsim.ps1`. Both modes compiled without errors and passed the existing full qualification set:

| Check | Result |
|---|---:|
| Gate-B numeric | 156 cases PASS |
| Gate-B legacy vector-II | 7 modes PASS |
| Full 13-mode vector-II | 13 modes PASS |
| Gate-C wrapper smoke | PASS |
| P3 V-write contract | PASS |
| P4 Stage-0 issue/slot-release | 16 N=4 vectors PASS |
| Gate-C engineering tuples | 369 cases PASS |
| Gate-C beats | 45,636 per mode PASS |
| LFNST engine specialty | 1,088 cases PASS |
| LFNST wrapper specialty | 258 cases PASS |
| group II | 1 |
| sparse/rectangle/LFNST/backpressure coverage | PASS in recorded Gate-C vectors |

The authoritative machine-readable result is `STEP12F_COVERAGE_MODELSIM_RUN.json`. The logs report zero simulator errors; three legacy kernel testbenches retain benign ModelSim warning counts about omitted newer ports, while all PASS markers are present.

The existing static P9 protocol model remains evidence for the specific final-data-plus-end, end-only, continuous sparse-stream, and scrub/fill ownership cases. This qualification does not promote that abstract model to HDL evidence beyond the recorded HDL regressions.

## Fresh synthesis

Command: `03_verification/vivado/run_step12f_fresh_synth.ps1`  
Tool: Vivado 2025.2 (Build 6299465)  
Device: `xcku5p-ffvb676-2-e`  
Clock: 2.000 ns / 500 MHz  
Elapsed: 242 s (script-reported)

| Metric | Post-synthesis |
|---|---:|
| WNS | -0.565 ns |
| TNS | -218.875 ns |
| Setup failing endpoints | 1,386 |
| Clock | 2.000 ns |
| Unconstrained internal endpoints | 0 |

Post-synthesis resources were 30,039 CLB LUTs (24,398 logic LUTs + 5,641 LUTRAM), 27,494 FFs, 1,637 CARRY8, 1,743 F7 muxes, 592 F8 muxes, and 320 DSP48E2; BRAM and URAM were both 0. The inferred memories remain distributed/LUTRAM structures.

## Fresh implementation

The existing Step12F implementation flow was rerun from the fresh synthesis checkpoint with the same device and constraint harness. Vivado completed `opt_design`, placement, physical optimization, and routing; the post-route DRC report states `Design State : Fully Routed`, with zero DRC errors. The report contains the known OOC diagnostic warnings (including DSP input/MREG/PREG pipelining advisories); these are not treated as timing signoff.

| Metric | Post-route |
|---|---:|
| Setup WNS | -0.407 ns |
| Setup TNS | -453.888 ns |
| Setup failing endpoints | 3,806 |
| Hold WHS | -0.080 ns |
| Hold THS | -5.135 ns |
| Hold failing endpoints | 81 |
| Clock | 2.000 ns / 500 MHz |
| Unconstrained internal endpoints | 0 |
| Valid timing exceptions | None |
| Route state | Fully Routed |
| Estimated total on-chip power | 1.849 W |

The leading routed setup path is now the bounded LFNST product/DSP path:

```text
u_bounded_lfnst_engine/coeff_bundle_q_reg[255]/C
  -> u_bounded_lfnst_engine/products_q_reg[15][23]/D
WNS       -0.407 ns
data      2.388 ns
logic     1.631 ns (68.3%)
routing   0.757 ns (31.7%)
logic levels 7 (DSP primitives plus LUT3)
```

This is a new physical timing blocker; it is not evidence that the P9 fill-write boundary failed functionally. The current route also reports high fanout on registered command-address nets (up to 2,952 for the fill command address bus) and the expected OOC reset/command fanout. No claim is made that the fill-write timing family is globally eliminated solely from the top-100 report.

## Qualification status

```yaml
P9_R3_RTL_review: PASS
P9_R3_functional_qualification: PASS
P9_R3_fresh_synthesis: PASS_COMPLETED_BUT_TIMING_FAIL
P9_R3_full_route: PASS_COMPLETED_FULLY_ROUTED_BUT_TIMING_FAIL
Step12F_setup: FAIL
Step12F_hold: FAIL
Step12F_500MHz: STOP
tag: NOT_CREATED
```

The correction and the qualification evidence are a valid checkpoint, but they do not authorize a performance tag. The next RTL timing action must be selected from the new routed worst-path census, with the bounded-LFNST product/DSP family currently the leading candidate. The fill-write, P3 intermediate, read-command boundary, P4 coefficient/DSP organization, Oracle/profile, XDC, R4C, and `v3.5-18` remain frozen until that decision.

## Evidence index

All paths are relative to this directory unless noted otherwise.

```text
STEP12F_COVERAGE_MODELSIM_RUN.json
vivado_synth/step12f_unified_wrapper_postsynth.dcp
vivado_synth/report_timing_summary_postsynth.rpt
vivado_synth/report_utilization_postsynth.rpt
vivado_synth/report_check_timing_postsynth.rpt
vivado_synth/report_exceptions_postsynth.rpt
vivado_impl/step12f_unified_wrapper_postroute.dcp
vivado_impl/report_timing_summary_postroute.rpt
vivado_impl/report_timing_hold_summary_postroute.rpt
vivado_impl/report_timing_worst100_postroute.rpt
vivado_impl/report_utilization_postroute.rpt
vivado_impl/report_high_fanout_postroute.rpt
vivado_impl/report_check_timing_postroute.rpt
vivado_impl/report_exceptions_postroute.rpt
vivado_impl/report_drc_postroute.rpt
vivado_impl/report_power_postroute.rpt
```

