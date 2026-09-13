# V3.5 Step12C-1 — Step12C-M2 Wrapper Synthesis Gate

Status: **STOP — 2.000 ns synthesis timing gate not closed**  
Date: 2026-09-13

## Scope

- Top: `step12b_dct2_64_wrapper`
- Configuration: 64×64 DCT2×DCT2, LFNST OFF, one frozen R4C
- Device: `xcku5p-ffvb676-2-e`
- Vivado: 2025.2
- Clock: `clk = 2.000 ns` / 500 MHz
- Flow: synthesis-only, clean Vivado user-data/TclStore directories
- No place/route was run

M2 changes are limited to fixed-bank staging read metadata/permutation, registered V→intermediate write command/commit barrier, and removal of internal verification invariant logic from the synthesized `protocol_error` cone. R4C source and mathematics were not modified.

## Functional gate

Normal and `SYNTHESIS` ModelSim regression, the M2 cycle model, public/internal event traces, two-TU backpressure, descriptor, random/extreme, vector-ID wrap, epoch scrub and mutation gates all passed. The exact evidence is under:

- `05_audit/current/18/m2/`
- `05_audit/current/18/m2_model/`

## Frozen hashes

| File | SHA-256 |
|---|---|
| `02_rtl/rtl/p2f_dct2_64_b1_step102.sv` | `15AA962C197C4CE0B9DAF2E5478B64C51F3C6712E582F8950DF6BF1C339C31B1` |
| `02_rtl/rtl/step12b_dct2_64_wrapper.sv` | `55C639331BF003CF338DC64F5EF4C99A2551B3B334DA64BC1030CE2452109838` |

The R4C hash is unchanged from the frozen baseline. The wrapper hash changes because M2 is the intentional wrapper repair revision.

## Synthesis result

| Metric | M1 synthesis | M2 synthesis | Decision |
|---|---:|---:|---|
| CLB LUTs | 35,817 | 22,044 | improved |
| LUT as distributed RAM | 18,688 | 7,168 | improved |
| CLB registers | 20,716 | 20,829 | comparable |
| DSP48E2 | 128 | 128 | unchanged |
| BRAM / URAM | 0 / 0 | 0 / 0 | distributed RAM mapping |
| WNS (ns) | -1.640 | **-0.252** | **FAIL** |
| TNS (ns) | -3,639.102 | **-156.002** | **FAIL** |
| setup failing endpoints | 18,433 | **4,609** | **FAIL** |

Vivado completed synthesis with 0 errors and 0 critical warnings (69 ordinary warnings). `check_timing` reports zero unconstrained internal endpoints, zero missing input/output delays, zero loops and zero missing clocks. No valid timing exceptions were found.

The memories are recognized as distributed RAM primitives (`RAM64M`, `RAM64M8`, `RAM64X1D`), including the 1K×40 result storage and the banked input/intermediate/tag arrays. This removes the prior bulk register-memory expansion, but the resulting control/read topology is not yet a 2 ns solution.

## Remaining synthesis bottlenecks

The worst setup path is:

```text
frozen_r4c/output_bank_reg[0]_rep__4
  → bank/write-address decode and protocol_error cone
  → protocol_error_reg/D
```

It has 2.233 ns data-path delay (0.810 ns logic + 1.423 ns estimated routing), 9 logic levels, and WNS -0.252 ns. The next repeated path is:

```text
stage_bank_addr0_reg[1]_rep__20
  → RAMD64E + lane/permutation logic
  → stage_a_reg[*]
```

with WNS about -0.074 ns and route-dominated delay. High fanout remains visible on `frozen_r4c/output_active_i_2_n_0` (18,217 loads) and several `it_data_addr` bits (4,096 loads).

## Gate decision

`Step12C-1 = STOP / NOT PASS`.

M2 is a substantive improvement: synthesis now completes, distributed-memory mapping is visible, LUT usage and timing violations drop sharply, and DSP/R4C resources remain unchanged. However, WNS/TNS and setup failing endpoints are still negative/nonzero, so the design must not enter place/route and `v3.5-18` must not be created.

The next revision must be defined only from these new synthesized critical paths; no other transform sizes, DST7/DCT8, LFNST expansion, full-core integration, or unrelated verification gates are in scope.

## Evidence files

- `05_audit/current/18/m2_synth/report_utilization_postsynth.rpt`
- `05_audit/current/18/m2_synth/report_timing_summary_postsynth.rpt`
- `05_audit/current/18/m2_synth/report_timing_worst100_postsynth.rpt`
- `05_audit/current/18/m2_synth/report_high_fanout_postsynth.rpt`
- `05_audit/current/18/m2_synth/report_check_timing_postsynth.rpt`
- `05_audit/current/18/m2_synth/report_exceptions_postsynth.rpt`
- `05_audit/current/18/m2_synth/report_methodology_postsynth.rpt`
- `05_audit/current/18/m2_synth/report_drc_postsynth.rpt`
- `05_audit/current/18/m2_synth/step12c_wrapper_postsynth.dcp`
