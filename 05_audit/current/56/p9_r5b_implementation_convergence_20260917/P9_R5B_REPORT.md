# Step12F-P9-R5B — Limited Implementation Convergence + Hold Closure

Status: **COMPLETE_LIMITED_IMPLEMENTATION_CONVERGENCE_NO_SIGNOFF**

Baseline is commit `64219104be0e3afd313c180f7d3b85f36e8694de`. RTL, XDC, Oracle/profile, frozen R4C, and `v3.5-18` were not changed. No resynthesis or ModelSim rerun was performed. Vivado 2025.2 used part `xcku5p-ffvb676-2-e`, a 2.000 ns clock, and `general.maxThreads=4`.

## Result matrix

| Run | Flow | Setup WNS/TNS/failing | Hold WHS/THS/failing | Route | Final DCP SHA-256 |
|---|---|---:|---:|---|---|
| `B0_NETDELAY_REPLAY` | `Default / ExtraNetDelay_high / AggressiveExplore / NoTimingRelaxation` from R5 postsynth | `-0.063 / -1.776 / 84` | `-0.080 / -4.764 / 65` | Fully routed | `39DE741B...50002A` |
| `B1_SETUP_OPT` | post-route `phys_opt_design -directive Explore` | `-0.063 / -1.776 / 84` | `-0.080 / -4.764 / 65` | Fully routed | `4B87E80F...7F293E` |
| `B2_HOLD_FIX` | post-route `phys_opt_design -hold_fix` | `-0.258 / -2.034 / 85` | `-0.080 / -4.658 / 62` | Fully routed | `33133DE6...203E9B` |
| `B4_AGGRESSIVE_HOLD` | post-route `phys_opt_design -aggressive_hold_fix` from B2 | `-0.258 / -2.034 / 85` | `-0.080 / -4.658 / 62` | Fully routed | `DAA036B3...29E1BA4` |

B3 was not run because B1 did not improve setup over B0 while retaining a hold violation. All runs had zero routing errors, zero unconstrained internal endpoints, no valid timing exceptions, and DRC reported warnings only (no errors). The B2 transcript records three inserted buffers; B4 found no further optimization.

## Targeted structural evidence

The corrected read-only qualification was run against all four final DCPs. For each one, the H-read structural gate reported:

```text
pending → H-response   0 paths
run     → H-response   0 paths
stage   → H-response   0 paths
registered H address → H-response   20 paths
```

Thus the R5 unconditional registered-address topology remains present. This is a structural qualification result, not a timing signoff.

## Decision

R5 is retained. The best observed setup result is B0/B1 at `WNS=-0.063 ns`; no run passes both setup and hold, so 500 MHz signoff and a new tag are not authorized. Ordinary hold fixing reduces hold TNS slightly but worsens setup; aggressive hold fixing makes no additional change. R6 RTL changes are not authorized by this batch.

This batch answers only whether the frozen R5 netlist can converge under a finite set of allowed post-route options. If a later candidate reaches non-negative setup and hold, it must be independently reproduced from the fixed R5 postsynth DCP with the exact final Tcl flow before signoff. The full local DCP/report evidence is under this directory; any compact remote mirror must explicitly identify that binary artifacts remain local.

## Evidence pointers

- `P9_R5B_MANIFEST.json`
- `P9_R5B_EXECUTION.json`
- `R5B_ORCHESTRATOR_TRANSCRIPT.txt`
- `R5B_TARGETED_QUALIFICATION_TRANSCRIPT.txt`
- `B0_NETDELAY_REPLAY/`, `B1_SETUP_OPT/`, `B2_HOLD_FIX/`, `B4_AGGRESSIVE_HOLD/`

