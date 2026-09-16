# Step12F-P9-A Routed Read-Only Qualification

Status: `QUALIFICATION_COMPLETE_NO_P9_RTL_AUTHORIZATION`

This batch is diagnostic only. It opens the existing P8.1 post-route DCP and does not synthesize, optimize, place, route, change RTL/XDC, or save a modified checkpoint.

## Provenance and baseline

- Base RTL commit: `9ad14814a72b26d0bc98044d77acb97bb70f586a`
- Input DCP: `05_audit/current/39/step12f_p8_1_impl_20260915_2335/step12f_unified_wrapper_postroute.dcp`
- DCP SHA-256: `05751FE3F7CF341463A3D1A1FC42328D92F699C0788DB326770209004AFB92DE`
- Vivado: 2025.2, `xcku5p-ffvb676-2-e`, 2.000 ns clock
- Route state: fully routed; this is the same DCP used for the P8.1 signoff attempt
- Existing routed baseline: setup `WNS=-1.034 ns`, `TNS=-19931.496 ns`, `49916` failing endpoints; hold `WHS=-0.080 ns`, `THS=-3.438 ns`, `46` failing endpoints
- Constraint coverage: `check_timing` has zero reported gaps; `report_exceptions` says `No valid timing exceptions found`

## Fire/control qualification

The routed netlist contains one `kernel_input_group_fire` net, one driver pin, and three load pins. The object census found four phase D pins, five feed-group D pins, and five drain-group D pins.

| Query | Result | Interpretation |
|---|---:|---|
| fire through `kernel_phase_q` D | 0 paths | No routed path through the fire net to the forbidden phase next-state registers |
| fire through wrapper `state_q` D | 0 paths | No routed path to the wide state next-state registers |
| fire through wrapper `phase_q` D | 0 paths | No routed path to the wrapper phase next-state registers |
| fire through `kernel_drain_group_q` D | 0 paths | No routed path to drain bookkeeping |
| fire through non-feed/non-drain group D | 0 paths | No routed path to the forbidden wide group/read bookkeeping set |
| fire through `kernel_feed_group_q` D | 5 paths | Allowed local feed bookkeeping remains and is timing-critical in this routed implementation |

The group query now excludes the feed and drain counters before timing analysis (`61` destination pins). The five feed paths are reported separately as allowed local bookkeeping; the phase/state/forbidden-group/drain queries are the authoritative forbidden-control checks.

## Worst-500 setup classification

The following aggregates are over the worst 500 negative-slack paths only. `sampled_negative_slack_sum_ns` is explicitly a sampled sum and is **not** full-design TNS.

| Family | Sampled paths | Worst slack (ns) | Sampled negative-slack sum (ns) |
|---|---:|---:|---:|
| A: input-cache → LFNST response | 17 | -1.034 | -16.755 |
| B: kernel control/vector → P4 `input_mem` | 336 | -1.002 | -307.644 |
| C: other cache read/response | 100 | -0.947 | -91.252 |
| C: other cache/kernel/write | 33 | -1.000 | -30.252 |
| D: control/R4C | 3 | -0.912 | -2.709 |
| E: other | 11 | -0.938 | -9.966 |
| **Total sampled window** | **500** | — | **-458.578** |

All 500 sampled paths are at or below `-0.5 ns` in this routed design. The WNS leader is family A, but family B is the dominant family in this sample by both count and sampled negative-slack sum. This does not establish either family’s share of all 49,916 failing endpoints or full-design TNS.

Representative family B path:

```text
kernel_vector_q_reg[0]_rep__0/C
  → LUT6/MUXF7/LUT3/LUT6/LUT2/LUT6
  → u_unified_p4_kernel/input_mem_reg[3][58][12]/D
data delay  = 2.983 ns
logic       = 0.461 ns
routing     = 2.522 ns (84.5%)
```

This representative path contains no `RAMD64E`; it is a kernel input-memory/load path, not evidence that the P4 `input_mem` family is the same physical cone as family A.

## Same-path A-family segmentation

The segment table is derived from the same routed timing paths in `path_reports/lfnst_cache_top20.rpt`, rather than concatenating unrelated reports. For the 16 paths returned by that targeted endpoint query:

- source-Q → RAM address cumulative data delay: average `1.504 ns`, range `1.393–1.607 ns`
- RAM address → `lfnst_mem_resp_data_q` D: average `1.388 ns`, range `1.249–1.486 ns`
- total data-path delay: average `2.971 ns`, range `2.931–3.016 ns`
- total route delay: average `2.217 ns`

The worst representative is:

```text
source:   kernel_rd_req_pending_q_reg_replica/C
endpoint: lfnst_mem_resp_data_q_reg[4]/D
source Q cumulative:       0.108 ns
RAM ADDR cumulative:       1.558 ns
pre-RAM segment:            1.450 ns
post-RAM/read-mux segment:  1.486 ns
total data path:            3.016 ns
total route delay:          2.224 ns
```

The path physically contains live read/control selection, a `RAMD64E` address pin, asynchronous distributed-RAM output, `LUT6/MUXF7/MUXF8` read selection, and the LFNST response register. This supports a cache-read physical risk, but does not prove that adding one address register will close global setup.

## LFNST versus primary/kernel read interpretation

The RTL still has two logical request branches feeding the same `input_rd_addr` array: registered LFNST request metadata selects one physical slot/bank, while the primary transform branch uses live run/stage/case/read-pending conditions and four-row address generation (`unified_its_wrapper.sv`, `input_read_addr_comb`). The cache bank itself has asynchronous LUTRAM reads (`its_input_cache_bank.sv`). The routed high-fanout report also shows `input_rd_addr` nets with fanout up to `1152`.

However, P9-A’s second family is not a cache-address path: it is `kernel_vector_q → u_unified_p4_kernel/input_mem_reg`. Therefore the evidence supports two independent candidates:

1. family A: shared/physical input-cache read and LFNST response path;
2. family B: P4 kernel input-memory load/select path, broader in the worst-500 sample.

Whether family A and the primary transform’s cache address cone share the same slow physical network is **not proven** by this batch. A cache-only RTL change must not be authorized from the WNS line alone.

## Decision

`P9-A` is complete as a read-only qualification checkpoint. It does not authorize P9 RTL.

The next decision must compare a narrow family-A physical read-command boundary against a narrow family-B P4 input-memory/load restructuring. The existing P8.1 DCP, RTL, XDC, Oracle/profile, R4C, and `v3.5-18` remain frozen. Hold remains a separate signoff axis; no setup qualification result changes the routed `WHS=-0.080 ns` conclusion.

Evidence files in this directory include the Vivado reports, targeted timing/object reports, the worst-500 CSV, and `p9_a_path_segments.csv` generated by `parse_p9_a_segments.ps1`.
