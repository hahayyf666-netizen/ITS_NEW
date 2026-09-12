# V3.5 Step12C-1 — Step12B Wrapper Synthesis Gate

Status: **STOP — synthesis-only gate not closed**

Date: 2026-09-13

## Scope

- Top: `step12b_dct2_64_wrapper`
- Configuration: 64×64 DCT2×DCT2, LFNST OFF, one frozen R4C
- Device: `xcku5p-ffvb676-2-e`
- Vivado: 2025.2
- Clock: `clk = 2.000 ns`
- Boundary contract: registered-neighbor, explicit zero-delay input/output budget
- RTL: no modifications

## Frozen source hashes

| File | SHA-256 |
|---|---|
| `02_rtl/rtl/p2f_dct2_64_b1_step102.sv` | `15AA962C197C4CE0B9DAF2E5478B64C51F3C6712E582F8950DF6BF1C339C31B1` |
| `02_rtl/rtl/step12b_dct2_64_wrapper.sv` | `1CF3D2554A6A54A4A0B0DB820FFB290A80544D6C1E6C13FAF1D5334B2483C584` |

## Observed synthesis evidence

Vivado successfully loaded the part, elaborated the wrapper and frozen R4C, parsed the 2 ns XDC, and entered RTL optimization. It did not reach the report-generation commands within the controlled run. The process was stopped after more than one hour because the synthesis remained in cross-boundary/area optimization with approximately 9 GB main-process memory and multi-GB helper processes.

Before termination, Vivado reported:

- `input_cache_a_reg`: 65,536 registers
- `input_cache_b_reg`: 65,536 registers
- `intermediate_mem_reg`: 65,536 registers
- `input_tag_a_reg`: 32,768 registers
- `input_tag_b_reg`: 32,768 registers
- approximately 8,257 4:1 16-bit muxes
- approximately 22,528 2:1 8-bit muxes
- approximately 4,096 4:1 8-bit muxes
- approximately 42,340 2:1 1-bit muxes
- approximately 250 two-input 40-bit adders and 62 three-input 40-bit adders

These are synthesis component statistics, not post-synthesis utilization numbers. No utilization, timing summary, checkpoint, or post-route report was available at termination.

## Gate decision

`Step12C-1 = STOP / NOT PASS`.

The current wrapper cannot yet be advanced to place/route because synthesis did not complete and the observed RTL component structure already shows large register-memory and mux expansion. This is a structural implementation blocker, not a functional-oracle failure.

No RTL, R4C source, canonical data, or functional evidence was modified. Step12C-2, `v3.5-18`, other transform sizes, DST7/DCT8, LFNST expansion, and full-core integration remain blocked.

## Files used

- `03_verification/vivado/run_step12c_wrapper_ooc.tcl`
- `03_verification/vivado/step12c_wrapper_2ns.xdc`

