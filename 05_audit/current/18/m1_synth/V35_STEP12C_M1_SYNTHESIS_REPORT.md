# V3.5 Step12C-M1 synthesis-only report

Date: 2026-09-13  
Target: `xcku5p-ffvb676-2-e`  
Vivado: 2025.2 (Build 6299465)  
Clock constraint: 2.000 ns  
Run mode: out-of-context synthesis only (`general.maxThreads=4`)

## Scope

M1 only changes the wrapper memory write topology and removes the synthesis-only
stage16 verification shadow. The frozen R4C and the functional/protocol contract
are unchanged. Place/route was intentionally not run.

## Functional gate

`run_step12b_checks.ps1` completed with:

```text
V35_STEP12C_M1_FUNCTIONAL_REGRESSION_PASS
```

Normal and `SYNTHESIS` ModelSim, random/extreme, two-TU, descriptor, epoch,
latency, public/internal trace and mutation gates remained PASS. The R4C source
hash is unchanged.

## Synthesis result

Vivado completed synthesis successfully:

```text
Synthesis finished with 0 errors, 0 critical warnings and 101 warnings.
```

The previous register-write inference failure did not recur. The logical data
stores are now recognized as distributed RAM (`RAM64M/RAM64M8`) rather than
being dissolved into ordinary registers:

| Resource | Post-synthesis use |
|---|---:|
| DSP48E2 | 128 |
| CLB LUTs | 35,817 |
| LUT as logic | 17,129 |
| LUT as distributed RAM | 18,688 |
| CLB registers | 20,716 |
| RAMB18/RAMB36 | 0 |
| URAM | 0 |

Hierarchy split:

| Hierarchy | LUT | LUTRAM | FF | DSP |
|---|---:|---:|---:|---:|
| wrapper logic/memory | 24,608 | 18,688 | 2,619 | 0 |
| frozen R4C | 11,209 | 0 | 18,097 | 128 |

## Structural/timing decision

`Step12C-1 = STOP`.

The memory-inference failure and synthesis resource-exhaustion problem are
fixed, but the synthesized structure is not yet a credible 2 ns implementation
candidate:

- post-synthesis setup WNS: **-1.640 ns**;
- setup failing endpoints: **18,433**;
- setup TNS: **-3,639.102 ns**;
- repeated RAM write timing paths: approximately **-0.803 ns**;
- worst path data delay: 3.621 ns, with 64.43% routing estimate;
- high-fanout nets include `frozen_r4c/output_active_i_2_n_0` (18,321 loads)
  and staging-vector/control nets above 13,000 loads;
- unconstrained internal endpoints: 0, but this does not compensate for the
  observed setup failure.

The implementation flow must therefore **not** proceed to place/route from this
M1 result. A separate, evidence-driven memory/selector or physical-structure
repair is required before another synthesis gate.

## Evidence files

- `report_utilization_postsynth.rpt`
- `report_hierarchy_utilization_postsynth.rpt`
- `report_timing_summary_postsynth.rpt`
- `report_timing_worst100_postsynth.rpt`
- `report_high_fanout_postsynth.rpt`
- `report_check_timing_postsynth.rpt`
- `report_methodology_postsynth.rpt`
- `report_drc_postsynth.rpt`
- `step12c_wrapper_postsynth.dcp`
- `vivado_m1_synthesis.log`

Key hashes:

```text
wrapper  DABF207BA97578F130AEE0A05D9653905E586832BE9A96B1C6DBCF42BAA5C00E
R4C      15AA962C197C4CE0B9DAF2E5478B64C51F3C6712E582F8950DF6BF1C339C31B1
Tcl      EB09A8D604837FC27A2BDD9691962C2B26CAC0416AF6AAE5609206972080FE19
```

No `v3.5-18` tag is created from this STOP result.
