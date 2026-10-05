# Step12F LFNST grid initialization: physical qualification

## Verdict

The RTL change passed the SAT10 functional checkpoint, and the registered-neighbor implementation completed a full route. It did **not** close 500 MHz setup timing.

| Metric | Post-route result | Status |
|---|---:|---|
| Setup WNS | -0.095 ns | FAIL |
| Setup TNS | -46.653 ns | FAIL |
| Setup failing endpoints | 1,321 | FAIL |
| Hold WHS | +0.007 ns | PASS |
| Hold THS / failing endpoints | 0.000 ns / 0 | PASS |
| Routing | 43,205 / 43,205 routable nets fully routed; 0 routing errors | PASS |
| Unconstrained internal endpoints | 0 | PASS |
| Valid timing exceptions | none | PASS |

Overall: `FUNCTIONAL_PASS / REGISTERED_NEIGHBOR_HOLD_PASS / SETUP_STOP`. This is not 500 MHz signoff and is not package-level FPGA signoff.

## Source and functional evidence

- Tested source commit: `a1525da7d3ee299c63adbede27f32f734403edc3`.
- Source parent: `3cc0899fb06635740d7efcf271923cee5433c629`.
- Functional evidence: `../84_lfnst_grid_init_20261005/20261005T064354Z_a1525da7d3ee/CHECKPOINT_MANIFEST.json`.
- Functional checkpoint status: PASS, normal and `SYNTHESIS`; Gate-B 156, Gate-F 13, Gate-C 369 / 45,636 beats per mode, LFNST engine 1,088, LFNST wrapper 388, SAT10 exhaustive adapter 65,536 signed-16 inputs, wrapper and submission-top overflow/backpressure/two-TU smoke PASS.
- Profile: `contest_engineering_vtm10_sat10_v2`; official equivalence remains `NOT_PROVEN`.
- Exact per-stage commands, exit codes, log hashes, vectors and manifests are retained in the functional evidence directory above.

The RTL change defers the 64-word LFNST payload clear from admission to the following cycle and sequences it with eight retained group tokens. The directed test verifies stale payload is cleared before it can be consumed, while the complete functional/throughput regression remains green.

## Physical run

- Vivado: 2025.2, build 6299465.
- Part: `xcku5p-ffvb676-2-e`.
- Top: `step12f_registered_neighbor_harness`.
- Contract: 2.000 ns clock; user setup/hold uncertainty 0; Vivado-reported total uncertainty 0.035 ns. The old wrapper OOC XDC was not loaded. Package pins/IO standards are outside this registered-neighbor experiment.
- Flow: `synth_design -directive Default`; `opt_design -directive Default`; `place_design -directive ExtraNetDelay_high`; `phys_opt_design -directive AggressiveExplore`; `route_design -directive NoTimingRelaxation`.
- Threads: 4.
- Runner exit code: 0; `P9R5E_DONE` recorded.
- Route status: Fully Routed.
- DCPs are intentionally not committed; their SHA-256 values are in `PHYSICAL_RESULT.json`.
- SHA-256 for the published functional and text-report artifacts is listed in `ARTIFACT_SHA256SUMS.csv`; the omitted DCP binaries are pinned separately by SHA-256 in `PHYSICAL_RESULT.json`.
- Hashes in this manifest are over the pre-clean-filter working-tree bytes captured for this evidence package; Git may normalize line endings when storing blobs. The tested source commit and its Git blob identities remain the canonical source provenance.

The DRC report has 0 errors. It contains two expected top-level OOC harness critical warnings: `NSTD-1` and `UCIO-1` for `clk` and `rst_n` (no package I/O standard or package pin assignment in this core-only contract). Methodology reports 32 `SYNTH-5` distributed-RAM mapping warnings and one `TIMING-18` missing input-delay warning for `rst_n`. `check_timing` reports 0 unconstrained internal endpoints; the single input without an input delay is `rst_n`. No valid timing exceptions were found.

## Timing diagnosis

The worst post-route setup path remains the H-read temporary-bank asynchronous read:

```text
kernel_h_rd_addr_q_reg[1][1]/C
  -> RAMD64E -> LUT6 -> MUXF7 -> MUXF8 -> LUT4
  -> kernel_h_rd_data_q_reg[19]/D
```

It has 5 logic levels, 1.966 ns data delay, split into 0.362 ns logic and 1.604 ns routing (81.6% routing), with -0.095 ns slack. A representative secondary path is `lfnst_ntrs48_q -> lfnst_grid_reg[*]/CE` at -0.077 ns; this is not the new grid-init token path. A read-only post-route DCP query confirms all eight `lfnst_grid_init_q` registers survived. The worst of 32 queried init-token-to-grid-CE paths is +0.318 ns (1.457 ns data delay, 0.178 ns logic, 1.279 ns routing); there is no direct token-to-grid-D path because the clear is implemented through the write-enable/CE control. This establishes that the new local initialization-control path meets timing in this run, but without a same-netlist baseline it does not quantify causal QoR improvement.

The preceding 2026-10-04 fixed-placement router CONTROL run recorded -0.110 ns WNS / -35.277 ns TNS / 929 setup failures. It is a **historical context only**, not a controlled comparison: the source/netlist and implementation starting point differ. The present result therefore does not prove that this RTL change improved or regressed QoR. It does prove the current full-route checkpoint still misses setup.

## Next engineering direction

Do not continue optimizing LFNST initialization based on this run. The measured global leader is the H-read temp-bank RAM/read-mux/response-register path. The next narrow proposal should evaluate a registered raw H-read response boundary, with command/metadata alignment and an elastic slot that permits same-cycle consume/refill. Preserve one H group per cycle and the existing vector-II contract; run focused H-read recurrence, row-boundary, backpressure and full regressions before another fresh registered-neighbor implementation. This is a proposal only; it is not implemented in this checkpoint.

Fresh physical result: setup FAIL, hold PASS. `official_equivalence=NOT_PROVEN`; package-level timing not evaluated.
