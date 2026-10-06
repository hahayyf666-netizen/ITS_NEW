# SAT10 registered-neighbor physical baseline

Date: 2026-09-29 (Asia/Shanghai)  
Repository: `hahayyf666-netizen/ITS_NEW`  
Remote `main` at run: `f53e3b213120122bb8efbad16217e64c324ec414`  
SAT10 source commit: `61e0c6b91dcce9fb7d22741c2ce75ff3b141b0e8`  
Tested tree: `2364494e8cf6fa200d66e24ffc9c1cd015ed63f7`

## Result

Fresh Vivado synthesis and a complete registered-neighbor place/route completed successfully for the merged SAT10 source tree. The design is **fully routed**, but 500 MHz timing is **not closed**.

| Metric | Result |
|---|---:|
| Setup WNS (all paths) | `-0.103 ns` |
| Setup TNS (all paths) | `-30.143 ns` |
| Setup failing endpoints (all groups) | `937` |
| Synchronous setup | `WNS -0.103 ns`, `TNS -28.457 ns`, `797` endpoints |
| Async-default setup/recovery group | `WNS -0.038 ns`, `TNS -1.686 ns`, `140` endpoints |
| Hold WHS / THS | `+0.008 ns / 0.000 ns` |
| Hold failing endpoints | `0` |
| Async-default min-delay group | `WHS +0.140 ns`, `THS 0`, `0` failing endpoints; removal is not separately classified in this summary |
| Routable nets | `48,020 / 48,020` fully routed; `0` routing-error nets |
| Unconstrained internal endpoints | `0` |
| Valid timing exceptions | None |

The worst synchronous setup path is `u_dut/kernel_vector_q_reg[0]_rep__1` → `u_dut/u_unified_p4_kernel/ingress_data_q_reg[49]`: data delay `1.892 ns`, logic `0.532 ns`, routing `1.360 ns` (about 71.9% routing), 5 logic levels. The remaining tail is not represented here as a complete family census; the full timing reports are retained locally and their hashes are in `PPA_BASELINE_STATUS.json`.

## Implementation context

- Vivado `2025.2`, build `6299465`; device `xcku5p-ffvb676-2-e`; `maxThreads=4`.
- Top: `step12f_registered_neighbor_harness`; boundary anti-pruning gate passed: `54/54` source FF bits and `44/44` sink FF bits.
- SAT10 was selected in the synthesized DUT (`FINAL_SATURATE=1`).
- Clock period: `2.000 ns` (500 MHz).
- Flow: `synth_design -directive Default`; `opt_design -directive Default`; `place_design -directive ExtraNetDelay_high`; `phys_opt_design -directive AggressiveExplore`; `route_design -directive NoTimingRelaxation`.
- The legacy wrapper OOC XDC was not loaded. Package pins, I/O standards, package delays, and board-level timing are outside this registered-neighbor result.
- The harness XDC explicitly sets user setup/hold uncertainty to `0.000 ns`. Vivado timing paths nevertheless report an effective `0.035 ns` uncertainty from the tool's default `0.071 ns` system-jitter term; no `set_system_jitter` override is present. Treat the measured baseline as using that effective tool default, not as a zero-effective-uncertainty result.

## Area and power estimates

Post-route utilization: `27,326` CLB LUTs (including `5,644` LUTRAM), `25,433` FF, `1,500` CARRY8, `320` DSP, `0` BRAM, `0` URAM.  
Vivado vectorless power estimate: total `1.872 W` (`1.411 W` dynamic, `0.461 W` static), confidence `Medium`. No simulation activity file was supplied; this is an estimate, not measured or activity-annotated power signoff.

## DRC and scope caveats

There were no DRC errors and route completed. DRC reports critical warnings `NSTD-1` and `UCIO-1` for the harness top's `clk` and `rst_n` ports lacking package I/O standards/LOCs; this harness is not a package top, so package-level implementation is not evaluated here. Other reported items include DSP pipelining warnings/advisories. Do not describe this as package-level FPGA signoff.

Historical LOW10/R6 timing values are reference-only and are not a controlled A/B against this fresh SAT10 synthesis/implementation. Official contest equivalence remains `NOT_PROVEN`.

## Evidence files

`PPA_BASELINE_STATUS.json` records source/run identity and SHA-256 hashes. Full Vivado reports, logs, and the 52 MB post-route DCP are retained in this run directory on the implementation machine; the DCP is intentionally not committed to GitHub.

