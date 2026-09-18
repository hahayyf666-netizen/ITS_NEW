# P9-R6B — Bounded Physical-Convergence A/B

## Decision

`P9-R6B` is **CLOSED / PHYSICAL_TREATMENT_REJECTED**. The experiment did not achieve 500 MHz closure and does not authorize an RTL R7. R6 remains the retained frozen RTL baseline; R6A remains the best observed registered-neighbor physical result.

The experiment was controlled from one common post-opt checkpoint. CONTROL and TREATMENT used the same Vivado build, device, clock, uncertainty, thread count, phys-opt directive, and route directive. The only intended implementation delta was the placement directive:

```text
CONTROL:   ExtraNetDelay_high
TREATMENT: ExtraTimingOpt
```

No RTL, XDC, synthesis, or package-level assumptions were changed.

## Provenance

```yaml
baseline_r6a_commit: 2a04edb93836c5771f7fda26fd559372d7d2f6a8
r6b_common_input_postsynth_sha256: 0AC1CA33EBD4A7A993C8B0083F3C2FB1AFA97F081139F64463CD625AA089A374
common_postopt_sha256: 1134315A2760F08D217E687A2F64093AA75BE4EFD5C113F9582FD318A64873CC
control_final_dcp_sha256: 624F515AB9F5556E4807E5A74BBEDB8F7BD71219C0BE2C1853D65B61C2FCD587
treatment_final_dcp_sha256: AF90905B545A29E5B02DA0BBBF7F1DDD1B599E7BB29E820F249A0CA6899189DB
vivado: 2025.2 Build 6299465
part: xcku5p-ffvb676-2-e
clock_period_ns: 2.000
clock_uncertainty_ns: 0.000
max_threads: 4
top: step12f_registered_neighbor_harness
```

The DCPs and full Vivado logs remain local evidence; this public checkpoint contains only compact reports, status, classifiers, and reproducible Tcl entry points.

## Routed QoR

| Run | Placement directive | Setup WNS (ns) | Setup TNS (ns) | Setup failing endpoints | Hold WHS (ns) | Hold THS (ns) | Hold failing endpoints | Fully routed | Routing errors |
|---|---|---:|---:|---:|---:|---:|---:|---|---:|
| R6A retained reference | prior R6 implementation | -0.045 | -4.882 | 312 | +0.006 | 0.000 | 0 | yes | 0 |
| R6B CONTROL | ExtraNetDelay_high | -0.055 | -5.960 | 320 | +0.011 | 0.000 | 0 | yes | 0 |
| R6B TREATMENT | ExtraTimingOpt | -0.188 | -416.302 | 6047 | +0.007 | 0.000 | 0 | yes | 0 |

The TREATMENT design-timing total includes an `async_default` setup group (`WNS=-0.149 ns`, `TNS=-125.253 ns`, 1470 endpoints) in addition to the primary `clk` group (`WNS=-0.188 ns`, `TNS=-291.049 ns`, 4577 endpoints). This is a final routed result, not an intermediate placement estimate.

CONTROL is therefore not an improvement over R6A, and TREATMENT is decisively worse. No candidate met the condition for an independent signoff replay.

## Read-only residual census

The same frozen R6A classifier was run on each final DCP without optimization or checkpoint mutation. Rounded path-property sums reconcile to the routed summaries within the expected report precision.

| Run | Raw/unique negative endpoints | Reconstructed TNS (ns) | DUT internal | Reset-related setup | DUT→sink | Source→DUT |
|---|---:|---:|---:|---:|---:|---:|
| CONTROL | 320 / 320 | -5.965 | 307 / -5.855 | 2 / -0.022 | 5 / -0.072 | 6 / -0.016 |
| TREATMENT | 6047 / 6047 | -416.315 | 4492 / -284.189 | 1513 / -127.357 | 39 / -4.692 | 3 / -0.077 |

The classifier found no duplicate or unclassified endpoints in either run. The treatment census shows a broad physical regression rather than a narrow improvement: the former residual tail is joined by thousands of new internal and async-default violations.

## Structural and signoff checks

- R6 RTL and harness RTL unchanged.
- Existing constraints unchanged; no timing exceptions were added.
- `check_timing` reported zero unconstrained internal endpoints for both runs.
- `report_exceptions` found no valid timing exceptions for either run.
- Both runs completed fully routed with zero routing errors.
- The registered-neighbor hold contract remained passing in both runs.
- Expected OOC harness DRC warnings (`NSTD-1`, `UCIO-1` for unassigned `clk`/`rst_n` pins) remain; these are not package-level signoff evidence.
- No independent treatment replay is authorized because TREATMENT failed the first-pass setup criterion.

## Final status

```yaml
P9-R6: RETAINED / FROZEN
P9-R6A: CLOSED / ACCEPTED / READ_ONLY
P9-R6B: CLOSED / PHYSICAL_TREATMENT_REJECTED
R6B_control: NO_IMPROVEMENT_OVER_R6A
R6B_treatment: REGRESSION
registered_neighbor_hold: PASS
registered_neighbor_setup: FAIL
500mhz_core_signoff: NOT_ACHIEVED
package_level_timing: NOT_EVALUATED
R7_RTL: NOT_AUTHORIZED
new_tag: NO
```

The practical conclusion is to stop this single-variable placement experiment and retain the R6A solution. A later RTL or physical intervention needs a concrete, narrow hypothesis; this A/B does not justify another blind strategy sweep.
