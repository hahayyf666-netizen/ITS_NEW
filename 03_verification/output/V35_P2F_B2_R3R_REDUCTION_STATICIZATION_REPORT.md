# V35 P2F-B2-R3R Reduction Staticization Report

## Status (Step 11.3R-R, 2026-09-09)

**RE-GATE COMPLETE / TIMING FAIL**

The R3R reduction RTL is frozen and its structural and normal functional
gates pass. The earlier Vivado startup failure was recovered by launching
Vivado with a clean temporary user profile; it was an environment/TclStore
problem, not an RTL or project-creation failure. A fair R3-vs-R3R
synthesis-only comparison and one R3R post-route run were completed.

The reduction staticization is therefore validated as a functional/structural
change, but it does **not** close the 2.000 ns (500 MHz) physical timing gate.
No further RTL optimization was started in this step.

## Structural gate

- authoritative reduction events: 1304
- physical reduction slots: 124
- fixed source-pair slots: 96
- two-choice source-pair slots: 28
- static reduction writes parsed from RTL: 1304
- terminal dots parsed from RTL: 64, exactly 0..63
- dynamic `p2f102_red_src0/1` in static reduction blocks: none
- terminal uses current-cycle `sum_now`: yes
- negative mutations: all rejected by the actual-RTL checker

Checker outputs:

- `p2f_b2_r3r_actual_rtl_connectivity.json`
- `p2f_b2_r3r_structure_audit.json`
- `p2f_b2_r3r_negative_tests.md`

## RTL functional gate

Normal ModelSim:

- compile: 0 errors, 0 warnings
- 49/49 cases
- 784/784 result beats
- stage-level raw/biased/shifted/stage16/final10 comparison: PASS
- positive wrap outputs: 950
- negative wrap outputs: 935
- group/tag/first/last checks: PASS

`+define+SYNTHESIS`:

- compile: 0 errors, 0 warnings
- effective checks: 49/49 cases and 784/784 fires, PASS

This is not an R3R-only regression: the unchanged R3 baseline produces the
same 2310 errors with the unpatched legacy checker. The existing DUT
intentionally removes the raw/biased/shifted debug memories and output
assignments under `SYNTHESIS`; the compatibility guard now omits only those
compiled-out stage comparisons and retains final result/tag/beat checks.
Using that same checker contract for both baselines gives R3 = 49/49,
784/784 and R3R = 49/49, 784/784.

## Vivado recovery and gate

The controlled script was located at:

`03_verification/vivado/run_p2f_b2_controlled_ooc.tcl`

Vivado executable:

`D:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat`

The original user-profile start exited before project creation with:

`ERROR: [Common 17-356] Failed to install all user apps.`

The same executable then completed successfully with a clean temporary
`APPDATA/LOCALAPPDATA/USERPROFILE/HOME` profile. The controlled flow used the
same part (`xcku5p-ffvb676-2-e`), XDC and 2.000 ns constraint for both designs.

### Synthesis-only comparison

| Metric | R3 | R3R |
|---|---:|---:|
| WNS | -0.276 ns | -0.276 ns |
| TNS | -475.368 ns | -483.790 ns |
| setup failing endpoints | 3078 | 3300 |
| CLB LUTs | 42884 | 39632 |
| CLB registers | 22600 | 22486 |
| F7/F8 | 9321 / 3328 | 9011 / 3530 |
| DSP | 128 | 128 |
| BRAM tile | 0 | 0 |

Static reduction lowered LUTs by 3252 (about 7.6%) and did not cause resource
explosion, but the synthesis critical path remained the multiplier front end
(`operand_coeff_reg_reg[...] -> DSP`-class path).

### R3R post-route result

Reports are under:

`03_verification/vivado/reports_r3r_postroute/`

| Metric | R3 baseline | R3R post-route |
|---|---:|---:|
| WNS | -0.904 ns | **-0.862 ns** |
| TNS | -5649.723 ns | **-5116.327 ns** |
| setup failing endpoints | 16806 | **14287** |
| WHS | +0.042 ns | **+0.044 ns** |
| hold failing endpoints | 0 | **0** |
| CLB LUTs | 42493 | **39331** |
| CLB registers | 22677 | **22563** |
| F7/F8 | 9226 / 3328 | **8963 / 3530** |
| DSP | 128 | **128** |
| BRAM tile | 0 | **0** |
| total on-chip power | historical | 3.519 W |

The R3R worst setup path is `bf_cycle_reg[5]/C` to
`signal_reg_reg[121][21]/D`, with 2.841 ns data-path delay (1.917 ns routing).
`check_timing` reports zero unconstrained internal endpoints. The post-route
WNS improvement is real but insufficient: the 2.000 ns / 500 MHz setup gate
still fails by 0.862 ns.

## Final STOP conditions

1. **Physical timing gate remains FAIL:** R3R WNS = -0.862 ns at 2.000 ns;
   therefore this step cannot claim 500 MHz closure.
2. The remaining dominant paths are registered control/data routing and
   butterfly/reduction-side logic, not a Vivado startup problem.
3. The old 2310-error `SYNTHESIS` result was a checker-observability mismatch;
   under the corrected common contract both R3 and R3R pass.

Frozen R3R hashes:

- `02_rtl/rtl/p2f_dct2_64_b1_step102.sv`:
  `AF1959DAA22BACF164C82FDBE2FE39C5A0A79D1006B92C00F72BFF676E83A3BA`
- `03_verification/tb/p2f_dct2_64_b1_tb.sv`:
  `0CCAC19BC19FBAE3BD34C6B7A0376B5CDC0206A70DBCF3A544E6092E92401CB8`
- `03_verification/vivado/run_p2f_b2_controlled_ooc.tcl`:
  `E0FBACBDF10F7F5B611804221837AFD01E40F358DBC4B7433A7BE3877AE7288D`

No Step 11.3B, butterfly, DSP, vector, pipeline, R4, or full-core integration
was started after this re-gate.
