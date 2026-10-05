# Step12F P9 primary-V read-return isolation — qualification

## Outcome

The functional change and its targeted primary-V return path checks passed. One fresh, fully routed registered-neighbor implementation met the 500 MHz setup and hold constraints, but with only 1 ps setup margin. Treat this as a **single-run registered-neighbor closure candidate**, not yet a reproducibility-qualified or package-level FPGA signoff.

| Metric | Result |
|---|---:|
| Setup WNS / TNS | `+0.001 ns / 0.000 ns` |
| Setup failing endpoints | `0` |
| Hold WHS / THS | `+0.011 ns / 0.000 ns` |
| Hold failing endpoints | `0` |
| Pulse-width WNS / TNS | `+0.468 ns / 0.000 ns` |
| Unconstrained internal endpoints | `0` |
| Valid timing exceptions | `0` |
| Route status | `Fully Routed; 43,544 / 43,544 routable nets; 0 routing errors` |
| DRC errors | `0` |
| DRC caveat | `NSTD-1` and `UCIO-1` critical warnings on harness `clk`/`rst_n`; package pins and I/O standards are intentionally outside this registered-neighbor experiment |

The limiting setup path is `output_index_reg[2]_replica_2/Q → ResultMemory RAMD64E read/mux → sink_it_data_out_q_reg[21]/D`: `WNS=+0.001 ns`, data delay `1.855 ns` (`0.410 ns` logic, `1.445 ns` routing; 5 logic levels). The limiting hold path is LFNST `reduce_l2_q_reg → reduce_l3_q_reg`, `WHS=+0.011 ns`.

## Functional qualification

The source RTL commit `9b33d9f62de49f022765cd594704353edeaa352c` passed the frozen full regression in both normal and `SYNTHESIS` modes. The run manifest and per-test logs are under `functional/`.

- Gate-B: 156 numerical cases; Gate-F: 13 throughput modes.
- Gate-C: 369 tuples / 45,636 beats per mode.
- LFNST engine: 1,088 cases; LFNST wrapper: 388 cases.
- SAT10 adapter: exhaustive 65,536 signed-16 inputs; submission-top overflow, backpressure, two-TU and done smoke passed.
- New primary-V return-credit test: 4-entry reservation under an actual 8-cycle P4 stall; 64 ordered beats, exactly one done, no residual in-flight credit, and resumed request II=1.

The profile is `contest_engineering_vtm10_sat10_v2`, SHA-256 `FEA3ACB18C5C35EB0FD8A8DBF533C3A6BE7536BCC8EF5FDB87135DF512643746`; `official_equivalence=NOT_PROVEN` remains unchanged.

## Targeted routed read-return evidence

All queries below were made on the exact routed checkpoint. Counts show the queried source and destination objects existed; `NO_TIMING_PATHS` is therefore distinct from a missing-object result.

| Cone | Result |
|---|---|
| `kernel_input_group_fire` driver → command address D/CE | `NO_TIMING_PATHS` |
| `kernel_input_group_fire` driver → bank raw-capture D/CE | `NO_TIMING_PATHS` |
| Registered command address Q → through RAMD64E address → raw bank-data D | Path exists; worst sampled slack `+0.080 ns`, delay `1.812 ns` (`0.335 ns` logic / `1.477 ns` route) |
| Bank raw-data Q → return FIFO D | Path exists; worst sampled slack `+0.108 ns`, delay `1.777 ns` (`0.311 ns` logic / `1.466 ns` route) |
| Return FIFO Q → P4 ingress-data D | Path exists; worst sampled slack `+0.598 ns`, delay `1.267 ns` (`0.375 ns` logic / `0.892 ns` route) |
| P4 ingress-data Q → input-memory D | Path exists; worst sampled slack `+0.014 ns`, delay `1.841 ns` (`0.079 ns` logic / `1.762 ns` route) |

The initial FIFO→`input_mem` probe returned no timing paths because it skipped the real P4 `ingress_data_q` register boundary; the supplemental read-only DCP query corrected this and reports both sides of that boundary. Do not treat the first empty report as proof that the FIFO has no path into P4.

## Comparison and interpretation

The preceding H-read raw-capture registered-neighbor run reported `WNS=-0.107 ns`, `TNS=-26.406 ns`, 695 setup-failing endpoints, and `WHS=+0.012 ns`. This run reports `WNS=+0.001 ns`, `TNS=0`, zero failing endpoints, and `WHS=+0.011 ns`. The runs used the same registered-neighbor harness/flow family but are separate fresh synthesis and implementation instances; the delta is strong evidence of effective convergence, not a same-placement causal A/B.

The primary-V request/return subpaths are now positive slack. The new global leader is the output-side ResultMemory read into the registered-neighbor sink, not the primary-V read-return chain. Because the global setup margin is just `1 ps`, the next useful qualification is one independent fresh replay with the same frozen source, harness, XDC, tool build, thread count, and directives. Do not make another RTL change before that replay establishes whether this narrow pass is reproducible.

## Provenance and implementation

- Baseline: `c3bdefcb5068088db4d375ba0a4ca5298eced48d`.
- Functional RTL source commit: `9b33d9f62de49f022765cd594704353edeaa352c`.
- Physical implementation/diagnostic Tcl commit: `48b6bfc47ec4b5d285520aeb14f8bcb34f59443d`; the RTL source hashes match the functional source commit.
- Vivado `2025.2`, build `6299465`; part `xcku5p-ffvb676-2-e`; top `step12f_registered_neighbor_harness`; 4 threads; 2.000 ns clock; user clock uncertainty `0`; old OOC wrapper XDC not loaded.
- Flow: `synth_design -directive Default` → `opt_design -directive Default` → `place_design -directive ExtraNetDelay_high` → `phys_opt_design -directive AggressiveExplore` → `route_design -directive NoTimingRelaxation`.
- Vivado completed with exit code `0` and `P9R5E_DONE`; source, constraint, command and report byte hashes are recorded in `P9_PRIMARY_V_RETURN_PHYSICAL_MANIFEST.json`.
- DCPs are retained locally but excluded from Git due their size. Their SHA-256 values are in the machine manifest; public evidence includes the full Vivado log/journal, timing/hold summaries, worst-100 reports, route/DRC/check-timing/exceptions/utilization/power reports, targeted STA reports, functional logs, vectors, and Python/oracle evidence.

## Status

```yaml
functional_regression: PASS
primary_v_read_return_target: PASS
fresh_synthesis_and_full_route: COMPLETE
registered_neighbor_setup_hold: PASS_ON_ONE_RUN (1 ps setup margin)
independent_replay: NOT_RUN
registered_neighbor_signoff_candidate: PENDING_REPLAY
package_level_signoff: NOT_EVALUATED
official_equivalence: NOT_PROVEN
```
