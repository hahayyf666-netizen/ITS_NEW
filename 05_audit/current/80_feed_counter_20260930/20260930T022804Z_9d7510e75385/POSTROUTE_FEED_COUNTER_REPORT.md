# Feed-counter candidate: functional and physical qualification

Date: 2026-09-30 (Asia/Shanghai)  
Source commit: `9d7510e75385c3b83cee7afd799c9e6db0b4d95e`  
Branch: `sat10-functional-evidence`

## Decision

- Functional qualification: **PASS** in both normal and `SYNTHESIS` modes.
- Intended local logic reduction: **observed**; the routed `kernel_ctx_output_size_q → kernel_feed_group_q/CE` path is 6 LUT levels rather than the prior 7.
- Registered-neighbor setup: **FAIL**; this fresh routed implementation is materially worse than the prior near-closed run.
- Registered-neighbor hold: **PASS**.
- 500 MHz signoff: **NOT ACHIEVED**.

This is one fresh implementation, not a fixed-placement A/B. The source RTL changed only in the feed-counter update, but its synthesized netlist and physical solution differ from the prior run. The result shows a real QoR regression in this run; it does not isolate how much came from the RTL topology versus physical-placement sensitivity.

## Functional evidence

The source-bound SAT10 checkpoint completed with `FUNCTIONAL_PASS` at this exact source commit. Normal and `SYNTHESIS` both passed the profile/Gate-A/Oracle/Python Gate-C/full ModelSim chain, including Gate-B 156, Gate-F 13 modes, Gate-C 369 cases / 45,636 beats, LFNST engine 1,088, LFNST wrapper 388, exhaustive 65,536-value SAT10 adapter checking, wrapper boundary/backpressure/two-TU cases, and submission-top smoke. The source-bound manifest is `CHECKPOINT_MANIFEST.json`; its SHA-256 is recorded in `POSTROUTE_FEED_COUNTER_STATUS.json`.

SAT10 remains an engineering profile; official equivalence remains `NOT_PROVEN`. No LOW10 historical audit was changed.

Evidence-index correction before publication: the functional runner was invoked with a relative evidence-directory argument, so its initial `evidence_files` paths were truncated even though all 54 recorded byte counts and SHA-256 values matched the files. The paths have been normalized to run-relative paths, and the target branch metadata corrected to `sat10-functional-evidence`. No source RTL or raw run artifact was changed. The original manifest SHA-256 was `36D65FB8F6923EE63A172C24BBE2C6560DC72E7E4E3F9E498F10BF9088106E3E`; the corrected manifest SHA-256 is `9DD246D7D5C1BC97217D20A45032F06AC82C33D4F976A5E8305F015C0E792A4C`.

## Routed implementation result

| Metric | Prior routed reference (`cddb7f7`) | Feed-counter candidate (`9d7510e`) |
|---|---:|---:|
| Setup WNS | -0.005 ns | **-0.110 ns** |
| Setup TNS | -0.015 ns | **-35.277 ns** |
| Setup failing endpoints | 4 | **929** |
| Hold WHS | +0.010 ns | +0.011 ns |
| Hold THS / failing endpoints | 0.000 ns / 0 | 0.000 ns / 0 |
| Routable / fully routed nets | 43,489 / 43,489 | 43,639 / 43,639 |
| Routing-error nets | 0 | 0 |

The candidate's global worst path is `src_it_data_end_q_reg/C → u_dut/slot_state_reg[0][0]/CE`: slack `-0.110 ns`, data delay `1.863 ns`, logic `0.402 ns`, routing `1.461 ns` (78.4% of data delay), 3 LUT levels. The worst-100 report also contains distinct H-read, physical read-command, P4 ingress/input-memory, slot-state/LFNST-grid, and wrapper-control paths; the remaining tail is not represented by one feed-counter path alone.

The targeted path itself is:

```text
kernel_ctx_output_size_q → kernel_feed_group_q/CE
slack        -0.041 ns
data delay    1.810 ns = 0.671 logic + 1.139 route
logic levels  6 LUTs
```

Prior reference for that path: `-0.005 ns`, 7 LUT levels, `1.802 ns = 0.749 logic + 1.053 route`. The edit removed one LUT level and reduced estimated logic delay by 78 ps, but routing increased by 86 ps and clock skew worsened; the target path therefore remains negative. The exact post-synthesis registered-neighbor query had shown this path at `+0.067 ns` and 6 LUT levels, demonstrating that the post-route physical result did not preserve the synthesis estimate.

## Structural and implementation checks

- 54/54 source boundary FFs and 44/44 sink boundary FFs remain present.
- `kernel_h_rd_pending_q`, `kernel_run_q`, and `kernel_stage_q` each had nonempty source objects and were independently queried through 5,706 RAMD64E cells to 128 H-response D pins; all three queries returned **NO PATH**.
- Positive control: registered H-read address Q through RAMD64E to H-response D has a path; representative slack is `-0.109 ns` (5 logic levels including RAMD64E, 75.9% routed delay). Thus the negative queries did not result from empty source/through/destination collections.
- Async reset/preset checks have no negative paths in the sampled reports: clear recovery `+0.046 ns`, clear removal `+0.177 ns`, preset recovery `+0.210 ns`, preset removal `+0.332 ns`.
- `check_timing`: zero unconstrained internal endpoints; the only `no_input_delay` port is harness reset `rst_n`. No valid timing exceptions were found.
- Route state: Fully Routed; 43,639/43,639 routable nets; zero routing errors.
- DRC: zero errors. Expected registered-neighbor harness I/O critical warnings remain (`NSTD-1`, `UCIO-1`); DSP advisories/warnings are recorded in the full report and are not package-level signoff.
- Utilization: 26,376 CLB LUTs, 21,378 CLB registers, 320 DSPs, 0 BRAM, 0 URAM.
- Vector-less power estimate: 1.492 W total (1.034 W dynamic, 0.458 W static), medium confidence; not a board-measured power result.

## Interpretation and next step

The local counter logic was simplified, but this run does **not** advance global timing closure. The old near-zero result and this candidate were produced from different synthesized netlists and implementation instances, so do not label the change a proven RTL-caused regression or a successful timing fix.

Do not stack another feed-counter edit or start a strategy sweep. The next useful experiment is one controlled replay of the pre-counter source (`cddb7f7f68a59e349a71343cf5aa06f6b1dd410a`) through the same registered-neighbor synthesis/implementation Tcl, part, XDC, directives, Vivado build, and thread count. If the baseline reproduces near-zero timing while the candidate remains materially worse, discuss reverting this one RTL hunk. If the baseline also moves toward the candidate result, treat the prior near-zero run as a favorable physical solution and choose the next narrow target from the observed routed families. No further RTL change is included or authorized by this report.

The full routed DCP is retained locally and identified by hash in the status JSON; it is not committed because it is a large generated binary. The timing, hold, route, DRC, utilization, power, targeted-query reports and Vivado transcript are included as compact review evidence.
