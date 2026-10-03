# Registered-neighbor old-postsynth replay

Date: 2026-10-03  
Purpose: test whether the earlier near-zero result is reproducible from the exact same pre-feed-counter postsynthesis checkpoint, without changing RTL or rerunning synthesis.

## Result

The replay completed successfully and was fully routed, but the earlier near-zero setup result did **not** reproduce.

| Run | Input postsynth DCP | Setup WNS | Setup TNS | Setup failing endpoints | Hold WHS | Hold THS / fails |
|---|---|---:|---:|---:|---:|---:|
| Original implementation | `86AADA61…25CF427` | −0.005 ns | −0.015 ns | 4 | +0.010 ns | 0 / 0 |
| Same-DCP replay | `86AADA61…25CF427` | −0.103 ns | −18.379 ns | 512 | +0.006 ns | 0 / 0 |
| Feed-counter candidate (context only; fresh synthesis) | `4813F4F6…FAD6D27C` | −0.110 ns | −35.277 ns | 929 | +0.011 ns | 0 / 0 |

The same-DCP replay is 98 ps worse in WNS and has 508 more failing endpoints than the original implementation. It is only 7 ps better in WNS than the feed-counter candidate, while its TNS is 16.898 ns less negative. The candidate row is **not** a same-netlist A/B: it came from a different fresh synthesis and is included only as context.

## Provenance and flow

- Replay input: pre-feed-counter registered-neighbor postsynth DCP from source commit `17496666f3192cd3e1f96ae4e590c2b3b77919f4`; SHA-256 `86AADA6150CA1E786E14A4D5EA03F68BFB162729BACFD66BB1F001ECA25CF427` (30,067,123 bytes).
- The replay opened that checkpoint directly. **No RTL read, synthesis, XDC edit, or resynthesis occurred.** Constraints were restored from the checkpoint.
- Vivado 2025.2, build 6299465; device `xcku5p-ffvb676-2-e`; `general.maxThreads=4`; 2.000 ns clock.
- Physical directives: `opt_design -directive Default`; `place_design -directive ExtraNetDelay_high`; `phys_opt_design -directive AggressiveExplore`; `route_design -directive NoTimingRelaxation`.
- Implementation Tcl SHA-256: `A09E99A089A6C44C6947C684D95C999F5DA0BB86A2714F646B9E9810227093CA`.
- Vivado exited 0 and printed `REGISTERED_NEIGHBOR_IMPL_DONE`.

## Timing and implementation details

The replay's worst setup path is `kernel_phase_q_reg[0]/C → kernel_feed_group_q_reg[0]/D`: slack −0.103 ns, 7 LUT levels, data delay 2.099 ns (0.646 ns logic, 1.453 ns route; 69.2% route). A second representative path, `ingress_data_q_reg[52]/C → input_mem_reg[0][19][4]/D`, is −0.102 ns with 1.954 ns data delay, of which 1.875 ns (96.0%) is route. The global tail is therefore not explained by only one counter cone.

- Route state: Fully Routed; 43,489/43,489 routable nets fully routed; 0 routing errors.
- DRC: 0 errors. The report contains 1 `NSTD-1` and 1 `UCIO-1` critical warning (package I/O standard/pin assignment is outside this registered-neighbor core harness); these are disclosed, not waived. Other reported DPIP/DPOP advisories are retained in the raw DRC report.
- Internal endpoints without max-delay constraints: 0.
- Valid timing exceptions: none.
- `check_timing` reports one input without input delay, corresponding to the harness reset treatment; package-level timing is not evaluated here.
- Post-route power is a vectorless estimate of 1.501 W at medium confidence and is not a measured activity-based PPA result.

## Interpretation

This replay establishes that the original `−0.005 ns` WNS / `−0.015 ns` TNS result is **not reproducible** from the same postsynthesis DCP under the same recorded implementation directives and tool/part/thread settings. The evidence supports significant implementation-result sensitivity. It does **not** establish the precise source of that sensitivity, nor does it prove that the feed-counter RTL change has no physical cost: the candidate was freshly synthesized, so its netlist differs.

Accordingly:

- Do not call the feed-counter change the proven cause of the apparent regression.
- Do not claim timing closure: setup fails at −0.103 ns / −18.379 ns TNS; hold passes.
- Do not roll back or authorize another RTL timing edit solely from these cross-netlist numbers.
- A bounded next experiment, if authorized, is one replay of the **fixed candidate postsynth DCP** with this exact implementation Tcl and settings. Compare it with this fixed baseline replay and the already-recorded candidate run; then stop and make a decision. This report itself makes no authorization for that additional route.

Raw Vivado log, journal, timing summaries, worst-100 reports, route status, DRC, check-timing, exceptions, utilization, and power reports are in this directory. The generated routed DCP is retained locally and identified in `BASELINE_REPLAY_STATUS.json`; it is not committed because it is a large binary checkpoint.

No RTL/XDC or functional evidence was changed by this replay. No tag was created.
