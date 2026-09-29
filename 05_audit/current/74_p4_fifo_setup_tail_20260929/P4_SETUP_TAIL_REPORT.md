# SAT10 P4 FIFO candidate: routed setup tail census

Date: 2026-09-29 (Asia/Shanghai)  
Repository: `hahayyf666-netizen/ITS_NEW`  
Branch baseline: `sat10-functional-evidence` at `ef8d0d758ea1822d74efa6a0286d99f3f54f70a6`  
Design source represented by the routed checkpoint: `9e67d4aa2696255f8b527a614e872cb367e654ce`

## Result

This is a read-only analysis of the existing SAT10 registered-neighbor routed checkpoint. No RTL, XDC, synthesis, placement, physical optimization, routing, or checkpoint writing was performed.

The checkpoint hash was verified against `P4_FIFO_PAYLOAD_RESET_STATUS.json`:

```text
postroute DCP SHA-256 = E6EF3B75FA06E1AEB2F95BAD9C32EA93587B2DECFFE8FBB455CE53A75D8C2239
```

Vivado 2025.2 build 6299465 recovered the routed DCP. The existing R5F read-only census script reported **177 negative path objects, 177 unique endpoints, zero duplicates, zero unclassified endpoints**, and reconstructed TNS `-3.537 ns`, matching the implementation summary at its reported precision.

| Population | Endpoints | TNS |
|---|---:|---:|
| DUT internal | 168 | -3.372 ns |
| DUT to registered sink | 9 | -0.165 ns |
| Source to DUT | 0 | 0 ns |

The endpoint population is spread across 61 source/endpoint family pairs. The largest individual pair is `kernel_phase_q → kernel_h_rd_data_tail_q` (20 endpoints, `-0.503 ns`); the next is `lfnst_grid → P4 ingress_data_q` (17, `-0.403 ns`). Several path families contribute materially to this tail.

## Co-leading paths

Three distinct paths tie at global WNS `-0.045 ns`:

| Path | Data / logic / route delay | Routing share | Clock skew | Related endpoints / TNS |
|---|---:|---:|---:|---:|
| H address Q → async temp-bank RAM/mux → H response data D | 1.860 / 0.469 / 1.391 ns | 74.8% | -0.175 ns | H response data D: 21 / -0.373 ns |
| `kernel_phase_q` → H raw metadata CE | 1.858 / 0.575 / 1.283 ns | 69.1% | -0.090 ns | H metadata/control: 5 / -0.202 ns |
| P4 `ingress_data_q` → `input_mem` D | 1.942 / 0.079 / 1.863 ns | 95.9% | -0.092 ns | `input_mem` destination: 12 / -0.190 ns |

The H response capture enables form a separate near-leading family: `kernel_phase_q` to H data/tail CE contributes 28 endpoints and `-0.663 ns` TNS, with worst slack `-0.043 ns`. The 21 H response data D endpoints contribute `-0.373 ns`; five metadata/control endpoints contribute `-0.202 ns`. A response-boundary proposal needs to account for both address-to-data and phase-derived enable paths.

Across all 177 negative paths, **168 have negative clock skew**. Median skew is `-0.108 ns`, P10 `-0.186 ns`, P90 `-0.024 ns`, minimum `-0.247 ns`, maximum `+0.030 ns`. This makes physical clock/data placement relevant to the remaining tail. It does not prove that clock skew alone is the cause: many paths also have high net delay, and their endpoint families differ.

## Recommended next experiment

Keep the currently qualified functional RTL. Before adding another latency stage, run one bounded, same-netlist physical comparison on the current post-synthesis checkpoint:

1. Apply `opt_design -directive Default` once and save/hash a common post-opt checkpoint.
2. Branch CONTROL and TREATMENT from that exact checkpoint.
3. CONTROL uses the existing `place_design -directive ExtraNetDelay_high`; TREATMENT changes only placement to `place_design -directive Explore`.
4. Both use the same `phys_opt_design -directive AggressiveExplore`, `route_design -directive NoTimingRelaxation`, XDC, part, Vivado build, and four-thread setting.
5. Compare WNS, TNS, failed endpoints, hold, route completion, and the three co-leading families. Stop if the treatment does not improve the global tail without transferring comparable violations elsewhere.

If physical convergence does not materially improve the result, the next RTL proposal should treat H response data and phase-derived CE as one local capture-boundary review, while preserving the existing elastic head/tail behavior and II=1. The separate `ingress_data_q → input_mem` path must remain a watch item because it also ties global WNS.

## Signoff boundary

- SAT10 engineering functional regression at source `9e67d4a`: PASS, as recorded in the preceding functional evidence.
- This census: read-only timing classification complete.
- Current implementation setup: WNS `-0.045 ns`, TNS `-3.537 ns`, 177 failing endpoints; **500 MHz setup not closed**.
- Hold: WHS `+0.003 ns`, THS `0`, zero failing endpoints in the referenced run.
- Official contest equivalence: `NOT_PROVEN`.
- Package-level timing: `NOT_EVALUATED`.

Detailed raw endpoint, family, and clock-skew CSVs plus the exact query scripts and logs are in this directory. The routed DCP is intentionally not committed; its SHA-256 is recorded above and in the source PPA status.
