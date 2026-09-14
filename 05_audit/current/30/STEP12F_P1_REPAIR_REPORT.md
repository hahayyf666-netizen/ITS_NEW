# Step12F-P1 bounded datapath repair — execution result

## Result

**Coverage PASS; fresh Vivado synthesis STOP at a bounded observation limit.**

The bounded RTL refactor was exercised with ModelSim SE-64 2020.4 in both normal and `+define+SYNTHESIS` modes:

- Gate-B numeric: 156 cases per mode.
- All 13 one-dimensional vector-II modes: PASS.
- Gate-C full campaign: 369 tuples and 45,636 beats per mode.
- Bounded LFNST engine specialty: 1,088 cases per mode, including 1,024 basis cases.
- LFNST wrapper specialty: 258 cases / 4,644 beats per mode.
- Compilation and runtime error counts: zero.

The machine-readable coverage summary is [STEP12F_COVERAGE_MODELSIM_RUN.json](step12f_p1_coverage/STEP12F_COVERAGE_MODELSIM_RUN.json).

## Physical observation

A fresh Vivado 2025.2 OOC run targeted `unified_its_wrapper` on `xcku5p-ffvb676-2-e` with a 2.000 ns clock and four synthesis threads. It successfully elaborated the new bounded modules and reached RTL component statistics. Logged peak memory was about 5.2 GB; the earlier unbounded-wrapper 42 GB behavior did not recur.

The run then remained in **Cross Boundary and Area Optimization** for approximately 45 minutes. It was stopped under the bounded observation policy. No synthesis checkpoint, utilization report, timing report, implementation result, or power report was generated. The complete transcript is [step12f_p1_synth_vivado.log](step12f_p1_physical/step12f_p1_synth_vivado.log), with the corresponding journal at [step12f_p1_synth_vivado.jou](step12f_p1_physical/step12f_p1_synth_vivado.jou).

Therefore this is a P1 physical-implementation STOP, not a functional or timing result. The full Vivado log hash is recorded in the manifest; no 500 MHz or PPA claim is made.

## Scope and boundaries

The change adds fixed-bank `its_simple_ram`/`its_input_cache_bank` modules, removes the wrapper's large direct memory arrays and bulk memory operations, and adds bounded LFNST gather/grid handling. The historical `v3.5-18` baseline, frozen R4C, historical Step12B wrapper, external interface, and XDC were not changed.

Next action is a separately reviewed storage/write-port/synthesis-topology experiment. No tag is created and no route is attempted from this incomplete run.
