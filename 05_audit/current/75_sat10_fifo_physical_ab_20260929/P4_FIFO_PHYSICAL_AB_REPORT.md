# SAT10 FIFO physical placement A/B

## Result

This bounded implementation experiment is complete. `Explore` is rejected for this design checkpoint. The matched `ExtraNetDelay_high` control is the best result in this experiment, but setup still fails, so this is not 500 MHz signoff.

| Result | Existing routed reference | CONTROL | TREATMENT |
|---|---:|---:|---:|
| Place directive | `ExtraNetDelay_high` | `ExtraNetDelay_high` | `Explore` |
| Clock setup WNS | -0.045 ns | -0.034 ns | -0.106 ns |
| Clock setup TNS | -3.537 ns | -2.026 ns | -27.423 ns |
| Clock setup failing endpoints | 177 | 134 | 824 |
| `async_default` setup | +0.033 ns recovery WNS, 0 failures in reference report | +0.037 ns, 0 failures | -0.026 ns, -1.757 ns, 144 failures |
| Hold WHS / THS / failing endpoints | +0.003 / 0 / 0 | +0.007 / 0 / 0 | +0.006 / 0 / 0 |
| Fully routed nets / routable nets | 43,864 / 43,864 | 43,864 / 43,864 | 43,453 / 43,453 |
| Routing errors | 0 | 0 | 0 |

The treatment regressed the clock setup WNS by 72 ps relative to its matched control, increased clock TNS by 25.397 ns, and increased failing endpoints by 690. It also introduced negative slack in the `async_default` path group. The small power estimate difference is low confidence because both reports use vectorless activity (CONTROL 1.501 W, TREATMENT 1.524 W; medium confidence).

CONTROL improved on the prior routed reference by 11 ps WNS, 1.511 ns clock TNS, and 43 failing endpoints. This is one physical run and should be treated as a better observed implementation candidate, not a guaranteed repeatable gain. Hold remained passing with only 7 ps WHS.

## Provenance and flow

```yaml
repository: hahayyf666-netizen/ITS_NEW
branch: sat10-functional-evidence
experiment_commit: 29c4df1cd5dd05f820037beacc2aef930307ca48
RTL_source_commit: 9e67d4aa2696255f8b527a614e872cb367e654ce
Vivado: 2025.2 build 6299465
part: xcku5p-ffvb676-2-e
top: step12f_registered_neighbor_harness
threads: 4
clock_period_ns: 2.000
user_clock_uncertainty_ns: 0.000
effective_path_uncertainty_ns: 0.035
```

Both branches opened the same post-opt checkpoint. The checkpoint was produced from the frozen SAT10 registered-neighbor postsynth DCP by `opt_design -directive Default`. CONTROL and TREATMENT then used the same physical optimization and routing commands; the only intended difference was `place_design` directive.

```text
CONTROL:   place_design -directive ExtraNetDelay_high
TREATMENT: place_design -directive Explore
Both:      phys_opt_design -directive AggressiveExplore
Both:      route_design -directive NoTimingRelaxation
```

The postsynth DCP SHA-256 is `24A1EF8CAC6A1F936E56CC47F46633C8DF9BB073B251FE046266835431CF0D4D`. The common post-opt DCP SHA-256 is `CD3B2665ABD66033EE09E40BC246BF375AFB45774CD793639D813360D2A6BADB`. CONTROL final DCP SHA-256 is `7387AB1F15F233498E58DDD3A8672434AA99C82479E0557273436487C64F26F4`; TREATMENT final DCP SHA-256 is `39CBEA2C3C9B00B8A15B910C4338AA3588D02E429D9DCAD5E4A845D90E331CB1`. DCP files remain in the local `outputs/sat10_fifo_physical_ab_20260929` directory and are not included in this commit.

The first CONTROL attempt was stopped after a long stall in post-placement timing optimization and produced no routed checkpoint. It is retained as an interrupted transcript only. `CONTROL_REPLAY` is the complete authoritative control result in the table.

Both complete runs report zero unconstrained internal endpoints, no valid timing exceptions, zero routing errors, and zero DRC errors. The expected OOC harness `NSTD-1` and `UCIO-1` critical warnings remain because `clk` and `rst_n` have no package pin assignments; this experiment is not package-level signoff. The treatment has a negative `async_default` setup group as listed above.

## Decision and next action

```yaml
Explore placement treatment: REJECTED
ExtraNetDelay_high control: RETAIN_AS_BEST_OBSERVED_PHYSICAL_CANDIDATE
Registered-neighbor setup: FAIL
Registered-neighbor hold: PASS
500 MHz core signoff: NOT_ACHIEVED
package-level signoff: NOT_EVALUATED
RTL/XDC changes: NONE
```

Do not continue placement-strategy search on this result. The next useful diagnostic is one read-only full-negative-endpoint census on the completed CONTROL DCP, because it now has a different leader and a smaller residual tail. Use that census to choose at most one concrete RTL or physical hypothesis. Do not claim a repeatable 500 MHz result from this single CONTROL run.

## Evidence files

- `common/`: shared post-opt timing, constraints, and exception reports.
- `control/` and `treatment/`: routed setup/hold summaries, worst-path reports, route status, utilization, power, DRC, timing checks, and exceptions.
- `vivado_transcripts.zip`: named full Vivado logs for common preparation, interrupted initial CONTROL, complete CONTROL replay, and TREATMENT.
- `SHA256SUMS.json`: hashes for committed evidence files. DCP hashes are recorded above and in the status file; the DCPs are not committed.
