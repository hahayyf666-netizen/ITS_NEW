# V3.5 Step12C-M3 synthesis-only report

## Scope

M3 is limited to the approved staging response pipeline and verification-only removal of the internal R4C vector-ID range sanity cone. R4C RTL, transform math, official interface, ResultMemory reader, V write-command pipeline and descriptor contract were not otherwise changed. No place/route was run.

## Functional gate

- Python cycle model: PASS.
- Normal ModelSim: PASS.
- `SYNTHESIS` ModelSim: PASS.
- Public/internal event checks, two-TU backpressure, vector-ID wrap, epoch scrub and 26 checker mutations: PASS.
- R4C transaction latency: 23 edges; group II=1; vector II=16.

Evidence is under `05_audit/current/19/m3_model/` and `05_audit/current/19/m3/`.

## Vivado synthesis result

| Item | Result |
|---|---:|
| Vivado/device | 2025.2 / xcku5p-ffvb676-2-e |
| Clock | 2.000 ns / 500 MHz |
| LUT | 22,673 |
| LUTRAM | 7,168 |
| FF | 20,918 |
| DSP48E2 | 128 |
| BRAM / URAM | 0 / 0 |
| Synthesis errors / critical warnings | 0 / 0 |
| Setup WNS / TNS | -0.002 ns / -6.030 ns |
| Setup failing endpoints | 2,560 |
| Hold WHS / THS | -0.148 ns / -2521.236 ns |
| Hold failing endpoints | 17,487 |
| Unconstrained internal endpoints | 0 |

Vivado inferred distributed RAM (`RAMD64E`; 7,168 LUTRAM). The memory structure is no longer a register explosion, but the synthesis timing gate is not closed. The worst setup path is currently descriptor/input-cache write control (`desc_slot_q → input_cache_a0.../WE`), with approximately 1.800 ns data-path delay and routing-dominated delay. This is a new measured bottleneck, not a reason to reinterpret the timing result.

## Decision

**Step12C-1: STOP.** Since setup WNS/TNS and hold WHS/THS do not satisfy the frozen 2 ns gate, place/route is not started and `v3.5-18` is not created. Future work must be a separately reviewed, narrow fix based on the new worst paths; no additional M3 changes are included here.

## Reproducibility

- Synthesis Tcl: `03_verification/vivado/run_step12c_wrapper_ooc.tcl`
- XDC: `03_verification/vivado/step12c_wrapper_2ns.xdc`
- DCP: `step12c_wrapper_postsynth.dcp`
- Full reports: this directory.
