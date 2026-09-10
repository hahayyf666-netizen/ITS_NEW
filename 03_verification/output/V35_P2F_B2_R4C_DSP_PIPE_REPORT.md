# V3.5 P2F-B2 R4C — DSP Pipeline Repair Report

日期：2026-09-10

## 1. Scope and baseline

R4C is an independent full-project copy of the frozen R4B project. The V3.4 functional baseline, canonical matrices, ROMs, legacy vectors, and previous R4B reports were not modified. Because the current execution environment does not grant write access to `D:\Workspace`, the complete R4C copy is stored at:

`C:\Users\Fine\Documents\Codex\2026-07-23\ni\ITS_STUDY_V35_P2F_B2_R4C_DSP_PIPE`

The copy contained 28,179 files before the R4C audit artifacts were added; no source-file copy failures or content mismatches were reported. The original requested D:-drive location was not silently substituted or modified.

An independent recursive comparison against the R4B source found no missing files. Among source-like files (`.v/.sv/.py/.tcl/.xdc/.hex/.json/.md/.txt/.do`), the only content difference is the intended `p2f_dct2_64_b1_step102.sv` change. The other differences are generated ModelSim state/trace files and new R4C simulation/Vivado/audit artifacts.

## 2. RTL change

Only the P2F-B2 DCT2-64 prototype RTL was changed:

`02_rtl/rtl/p2f_dct2_64_b1_step102.sv`

The change is limited to the multiplier front end:

- product data now has a separate synchronous `lane_product_mreg` and `lane_product_reg` pipeline;
- the multiplier expression is unconditional after invalid operands have been zeroed, avoiding a post-DSP validity mux;
- reduction/butterfly context is delayed from `d2` to `d3`;
- valid, vector ID, and the reduction/butterfly launch context are delayed in lock-step with the product data;
- the operation schedule, 128 physical lanes, reduction connectivity, butterfly schedule, group II, and vector II are unchanged.

Vivado synthesis absorbed the data boundaries into DSP48E2 pipeline resources. The routed-checkpoint property audit (`03_verification/vivado/reports_r4c_postroute/r4c_dsp_properties.txt`) reports 128 DSP48E2 instances, all with `MREG=1` and `PREG=1` (the A/B input registers remain disabled); this is the intended DSP internal-pipeline repair.

## 3. Functional simulation

Simulation scripts:

- `03_verification/sim/run_r4c_dsp_pipe.do`
- `03_verification/sim/run_r4c_dsp_pipe_synthesis.do`

Logs:

- `03_verification/sim/r4c_func_run.log`
- `03_verification/sim/r4c_synthesis_run.log`

Both ordinary and `+define+SYNTHESIS` ModelSim runs completed with compile errors 0 and warnings 0:

| Check | Result |
|---|---:|
| Cases | 49/49 |
| Result beats | 784/784 (=49×16) |
| Raw/biased/shifted/stage16/final10 comparisons | PASS |
| Group order and first/last tags | PASS |
| Positive wrap observations | 950 |
| Negative wrap observations | 935 |
| Errors / warnings | 0 / 0 |

The first observable beat moved by exactly one clock (old R4B tick 23 to R4C tick 24), while the schedule remained unchanged. For each vector, the testbench checks 16 groups, group span 15 clocks, and total 16 beats; adjacent vector groups retain the expected vector-II=16 behavior. The testbench compares four complete outputs per beat, not partial sums.

## 4. Postsynthesis result

Reports are in:

`03_verification/vivado/reports_r4c_postsynth/`

| Metric | Result |
|---|---:|
| Clock constraint | 2.000 ns (500 MHz) |
| WNS | +0.398 ns |
| TNS | 0 ns |
| Setup failing endpoints | 0 |
| LUT | 12,090 |
| FF | 18,140 |
| DSP48E2 | 128 |
| BRAM | 0 |
| F7/F8/F9 | 0 |

The postsynthesis worst path is a control path; the former product-to-DSP path is no longer the top path. Postsynthesis timing is a screening result only; final acceptance uses the routed checkpoint below.

## 5. Post-route 500 MHz result

Vivado OOC flow:

- Vivado 2025.2
- device `xcku5p-ffvb676-2-e`
- `synth_design -mode out_of_context`
- period `2.000 ns`
- `opt_design`, `place_design`, `phys_opt_design`, `route_design`
- same controlled Tcl flow as R4B, with a clean Vivado user-data/TclStore area

Reports and checkpoint are in:

`03_verification/vivado/reports_r4c_postroute/`

| Metric | Result |
|---|---:|
| WNS | **+0.090 ns** |
| TNS | **0.000 ns** |
| Setup failing endpoints | **0** |
| WHS | **+0.044 ns** |
| THS | **0.000 ns** |
| Hold failing endpoints | **0** |
| Pulse-width worst slack | +0.725 ns |
| Clock | 2.000 ns / 500 MHz |
| LUT | 11,630 |
| FF | 18,140 |
| DSP48E2 | 128 |
| Block RAM Tile | 0 |
| URAM | 0 |
| Power estimate | 1.515 W (vectorless, medium confidence) |

For reference, the R4B post-route baseline was WNS `-0.462 ns`; R4C improves this by approximately `+0.552 ns` while retaining the same 128-DSP lane count.

The worst setup path is now a local reduction-storage path:

`red_s0_data_reg[7][0]/C -> dot_value_bank_reg[0][5][23]/D`

with 1.890 ns data delay (0.649 ns logic, 1.241 ns routing) and +0.090 ns slack. This confirms that the previous coefficient/operand-to-product path was removed from the critical path by the DSP internal pipeline. The remaining critical cone is route-dominated reduction-to-local-storage logic, not the multiplier front end.

`check_timing` reports zero unconstrained internal endpoints. As this is OOC, 1,042 input ports and 128 output ports have no external delay constraints; this is an OOC methodology limitation, not an internal unconstrained-register failure. The result must therefore be described as **module-level OOC post-route closure at 500 MHz**, not as board-level operating-frequency proof.

## 6. R4C status

The R4C DSP-pipeline change is functionally and physically successful:

- bit-exact stage-level behavior: PASS;
- four complete results per valid beat: PASS;
- group II=1 and vector II=16: PASS;
- positive/negative wrap coverage: PASS;
- tags and one-clock latency retiming: PASS;
- 128 DSP lanes retained: PASS;
- post-route 2.000 ns timing: PASS.

Therefore **R4C P2F-B2 DSP-pipeline gate = PASS** for the standalone DCT2-64 prototype.

This does not yet prove the complete ITS core, other transform types/sizes, LFNST integration, or full contest-top timing. Those remain separate integration gates.

## 7. Evidence hashes

| Artifact | SHA-256 |
|---|---|
| `p2f_dct2_64_b1_step102.sv` | `15AA962C197C4CE0B9DAF2E5478B64C51F3C6712E582F8950DF6BF1C339C31B1` |
| `p2f_dct2_64_b1_tb.sv` | `0CCAC19BC19FBAE3BD34C6B7A0376B5CDC0206A70DBCF3A544E6092E92401CB8` |
| `p2f_b2_controlled_postroute.dcp` | `CD90063751216B8778FBC78DB3BD45F4D58E2F082395D03F0A182DD915B69E98` |
| `report_timing_summary_postroute.rpt` | `142563F20261801735791564F60C65DD7A3A474A2F8320B6A2075D8365655ED2` |
| `r4c_dsp_properties.txt` | generated from routed DCP; 128/128 `MREG=1,PREG=1` |
