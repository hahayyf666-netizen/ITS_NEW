# V3.5 R4A Operand/Coefficient Locality Repair Report

Date: 2026-09-09  
Baseline: `D:/Workspace/ITS_STUDY_V35_P2F_B2_R4_PRE` (R3R contents, read-only)  
Variant: `D:/Workspace/ITS_STUDY_V35_P2F_B2_R4A_OPERAND_LOCAL`

## Scope

R4A changes only the DCT2-64 B1 prototype operand/coefficient selection path. The 1368-operation schedule, 128 DSP lanes, reduction/butterfly timing, tags, and mathematical contract are unchanged. The new tables are generated from the authoritative `r4_lane_source_map.json`; no RTL output or golden file is used to create expected values.

## Functional and structural evidence

| Check | Result | Evidence |
|---|---:|---|
| R4A structural audit | PASS | `03_verification/scripts/run_r4a_structure_audit.py` |
| Authoritative operations | 1368 | Generated-table comparison |
| Lanes / clusters | 128 / 4 (32 lanes/cluster) | `p2f_r4a_local_tables.svh` |
| Max unique x sources/lane | 3 | Structural audit |
| Generated tables vs lane map | Exact | Structural audit |
| Negative self-test | PASS | Deliberate table mutation rejected |
| ModelSim normal | 49/49 cases, 784/784 beats | `03_verification/sim/logs/p2f_b2_r4a_normal.log` |
| ModelSim `SYNTHESIS` | 49/49 cases, 784/784 beats | `03_verification/sim/logs/p2f_b2_r4a_synthesis.log` |
| Positive / negative wrap observations | 950 / 935 outputs | Both functional logs |

The functional checks include stage16/final10 and vector/group/first/last tags. The testbench does not use RTL results to construct expected values.

## Synthesis-only comparison (same Vivado Tcl/XDC, 2.000 ns)

| Metric | R3R baseline | R4A | Change |
|---|---:|---:|---:|
| CLB LUTs | 39,632 | 15,677 | -60.45% |
| CLB registers | 22,486* | 21,324 | see note |
| DSP48E2 | 128 | 128 | unchanged |
| Block RAM tiles | 0 | 0 | unchanged |
| MUXF7 / MUXF8 | 9,011 / 3,530 | 0 / 0 | removed |
| post-synth WNS | -0.276 ns | -0.235 ns | +0.041 ns |
| setup failing endpoints | 3,300 | 3,222 | -78 |

\* The R3R synthesis report used for the direct comparison reports 20,406 FDCE + 2,080 FDRE (22,486 registers); the post-route R3R count is 22,563. R4A reports 21,292 FDCE + 32 FDRE (21,324 registers). Register counts therefore depend on the exact report stage; no claim of a register reduction is made.

R3R evidence: `D:/Workspace/ITS_STUDY_V35_P2F_B2_R4A_OPERAND_LOCAL/03_verification/vivado/reports_r4a_r3r_synth/` (DUT overridden to the R4_PRE copy).  
R4A evidence: `D:/Workspace/ITS_STUDY_V35_P2F_B2_R4A_OPERAND_LOCAL/03_verification/vivado/reports_r4a_synth/`.

## Post-route result

R4A was run once with the same OOC 2.000 ns flow.

| Metric | R3R post-route | R4A post-route |
|---|---:|---:|
| WNS | -0.862 ns | -0.626 ns |
| TNS | -5,116.327 ns | -1,740.066 ns |
| setup failing endpoints | 14,287 | 6,320 |
| WHS / hold failing endpoints | +0.042 ns / 0 | +0.043 ns / 0 |
| CLB LUTs | 39,331 | 15,179 |
| CLB registers | 22,563 | 21,361 |
| DSP48E2 | 128 | 128 |
| Block RAM tiles | 0 | 0 |
| Total on-chip power | 3.519 W | 1.708 W |

Reports: `03_verification/vivado/reports_r4a_postroute/`.

The global worst R4A path is still the unchanged butterfly cone (`bf_cycle_reg[1]` to `signal_reg_reg[118][20]`), with WNS -0.626 ns and 72.9% of the 2.605 ns path in routing. Thus R4A is not a 500 MHz closure; it is a locality repair that materially reduces area and improves the global post-route WNS by 236 ps.

## Remaining issue and next gate

R4A did not fully localize vector sources: synthesis still reports `r4a_vector_buf_a[0]` and `r4a_vector_buf_b[0]` at fanout 1024, and placement inserted BUFGs for those nets. The main operand path is improved, but the residual high-fanout vector distribution and the untouched butterfly network remain.

The R4A gate is therefore:

* **Locality/functional gate: PASS** — large MUX network removed, 49/49 functional regression passes, 128 DSP and 0 BRAM preserved.
* **500 MHz timing gate: FAIL** — post-route WNS -0.626 ns, setup violations remain.

Do not integrate R4A into the full Core or extend to other transform types yet. The next performance experiment should target the remaining measured cone (first remove the 1024-fanout vector distribution or add a verified DSP input pipeline), in a fresh complete copy, with the same synthesis-first stop gate.
