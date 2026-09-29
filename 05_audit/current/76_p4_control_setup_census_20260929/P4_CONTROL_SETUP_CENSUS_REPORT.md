# P4 physical CONTROL setup-tail census

## Decision

The bounded placement A/B is complete: `Explore` is rejected, while `ExtraNetDelay_high` remains the best observed implementation in that experiment. A read-only census of that CONTROL routed checkpoint shows that the residual setup tail is still multi-family and routing-heavy. This does **not** establish 500 MHz closure or justify a broad RTL pipeline rewrite.

The current CONTROL result is a useful, fully routed optimization baseline, but it is only one completed physical run. It is not a repeatability result or signoff.

## Frozen experiment identity

```yaml
repository: hahayyf666-netizen/ITS_NEW
branch: sat10-functional-evidence
experiment_evidence_commit: bf838a7345131067f8cea9cfd612899e38984ff3
rtl_source_commit: 9e67d4aa2696255f8b527a614e872cb367e654ce
experiment: P4 FIFO physical placement A/B, CONTROL_REPLAY branch
design_top: step12f_registered_neighbor_harness
part: xcku5p-ffvb676-2-e
vivado: 2025.2 build 6299465
clock_period_ns: 2.000
effective_path_uncertainty_ns: 0.035
max_threads: 4
profile: contest_engineering_vtm10_sat10_v2
profile_canonical_sha256: FEA3ACB18C5C35EB0FD8A8DBF533C3A6BE7536BCC8EF5FDB87135DF512643746
profile_file_sha256: AD11CA8EB0FDE362079EAB10312C48B33F4A2EC5684D0296521B60E59665CA2C
official_equivalence: NOT_PROVEN
control_postroute_dcp_sha256: 7387AB1F15F233498E58DDD3A8672434AA99C82479E0557273436487C64F26F4
census_tcl_sha256: 2FC2D1F89817FC86F4D6848D2AB0F3BB94CB6F94B4CCD23029BBACED4C8764F7
registered_neighbor_harness_sha256: BB6BEE87957E2E399461184AEE0F054B2EF070F51426605719025623D67806A3
registered_neighbor_xdc_sha256: 346E4D1BAA867FD7F16E8474FC3E903B3616633450F487AB168383BAE38A3786
unified_p4_kernel_sha256: AB79E6AF55F42E76B9B56E86C628E57A93F477E40DDF21F7298DDB25D4541064
unified_its_wrapper_sha256: 19A133460E851A17C2A870E1433968AB4B515A0695A7D6BA1436ABD1313E06AC
submission_top_sha256: 39CAF8E3BBA2992FFAD8C2407F9AD10341E2AA8C03EA0A07F5C0A0E6744436D1
```

The exact DCP remains in the local Vivado output directory and is not committed. Its hash was rechecked before and after the census. The audit consumed this existing routed checkpoint; it did not synthesize, optimize, place, run physical optimization, route, alter constraints, or write a design checkpoint.

The census was launched with Vivado batch using `run_step12f_r5f_setup_census.tcl`, the DCP above as `STEP12F_R5F_POSTROUTE_DCP`, and the dedicated `control_census` output directory. `STEP12F_SKIP_PATH_SIGNATURE=1` was set: the custom primitive-signature extraction is therefore explicitly incomplete. The raw endpoint CSV and the archived CONTROL `setup_worst100.rpt` remain available for independent review of actual path endpoints and primitive detail.

## Global timing and accounting

CONTROL's authoritative routed setup summary is:

```text
WNS = -0.034 ns
TNS = -2.026 ns
failing endpoints = 134
WHS = +0.007 ns
THS = 0
hold failing endpoints = 0
Fully Routed; routing errors = 0; DRC errors = 0
unconstrained internal endpoints = 0
valid timing exceptions = 0
```

The read-only census returned 134 negative setup path objects and 134 unique endpoints: duplicate endpoints 0, unclassified endpoints 0. Reconstructing TNS from the per-path slacks rounded to three decimal places gives `-2.032 ns`, 6 ps more negative than Vivado's summary authority (`-2.026 ns`). This is a reporting-precision reconciliation, not a second timing result.

| Boundary bucket | Endpoints | Reconstructed TNS | Share of reconstructed negative TNS |
|---|---:|---:|---:|
| DUT internal | 128 | -1.937 ns | 95.3% |
| DUT to sink FF | 6 | -0.095 ns | 4.7% |
| Source FF to DUT | 0 | 0 ns | 0% |

For DUT-internal failures, median logic depth is 5 levels, median logic delay `0.489 ns`, median route delay `1.408 ns`, median route fraction `73.9%` (P90 `82.1%`). Thus routing is the majority contributor across the internal tail, but path logic is not uniformly shallow.

## Family distribution

Using the repository's R6A-style family canonicalization (remove bit indices and implementation replica suffixes, then collapse repeated underscores), the CSV aggregates into 37 source/endpoint family pairs. No single family dominates: the largest pair contributes 14.4% of reconstructed negative TNS; the top five contribute 46.9%.

| Canonical source → endpoint family | Endpoints | Reconstructed TNS | TNS share |
|---|---:|---:|---:|
| `kernel_h_rd_addr_q` → `kernel_h_rd_data_q` | 18 | -0.293 ns | 14.4% |
| `rd_cmd_addr_q` → `kernel_rd_raw_data_q` | 11 | -0.228 ns | 11.2% |
| `lfnst_grid_reg` → P4 `ingress_data_q` | 10 | -0.192 ns | 9.4% |
| P4 `reduce_l4_q` → `reduce_l5_q` | 6 | -0.128 ns | 6.3% |
| P4 `ingress_data_q` → `input_mem_reg` | 7 | -0.113 ns | 5.6% |

These are family aggregates, not claims that every member has the same criticality. The H-read family has the largest aggregate TNS, but is not the unique global WNS leader.

## Representative global leaders

The first two paths in the CONTROL routed worst-path report tie at `-0.034 ns`:

1. `lfnst_grid_reg[18][4]` → P4 `ingress_data_q_reg[4]/D`: data delay `1.890 ns`, logic `0.634 ns`, routing `1.256 ns` (66.5%), five LUT levels. The path is the wrapper's dynamic LFNST sample gather/selection feeding the P4 ingress register.
2. P4 `ingress_group_q_reg[0]` → `input_mem_reg[1][62][15]/CE`: data delay `1.849 ns`, logic `0.318 ns`, routing `1.531 ns` (82.8%), two LUT5 levels. The path report shows source fanout 68 and a second LUT output fanout 32, indicating a short but physically broad memory-write enable/decode cone.
3. H-read `kernel_h_rd_addr_q_reg[3][2]` → `kernel_h_rd_data_q_reg[59]/D`: `-0.031 ns`, data delay `1.977 ns`, route fraction 80.5%, through LUT/RAMD64E/read mux elements.

The first two leaders are separate cones and both need attention to close the current WNS. Therefore do not infer that fixing only the H-read aggregate-TNS leader will close timing.

## Reset and constraints side results

- `check_timing` reports 0 unconstrained internal endpoints. The one no-input-delay item is `rst_n`, as expected for this registered-neighbor harness.
- `report_exceptions` reports no valid timing exceptions.
- Directional reset recovery query: 5,109 paths, worst `+0.037 ns`, negative TNS 0.
- Reset removal query: no paths returned. This is recorded as “no removal paths,” not as an assumed numerical margin.
- Clock-region properties remain unavailable/empty in this DCP query. No region-locality conclusion is made from them.
- The `NSTD-1` / `UCIO-1` warnings recorded by the parent A/B are harness package-pin warnings; this is not package-level timing signoff.

## Engineering conclusion and next step

The `Explore` placement treatment is rejected by the matched A/B (`WNS -0.106 ns`, clock TNS `-27.423 ns`, 824 clock failures, plus 144 `async_default` failures). Keep `ExtraNetDelay_high` as the best *observed* physical candidate, not as a proven repeatable winner. The CONTROL hold passes, but with only 7 ps WHS; setup remains failed.

Do not launch a broad R7 pipeline change based only on the family census. If proceeding with one bounded RTL experiment, the most directly evidenced low-latency candidate is the existing P4 ingress commit/write-enable selection: carry a registered one-hot group/slot write-select alongside the current ingress metadata and consume it at the existing commit edge. It could reduce the `ingress_group_q` decode/fanout cone without adding a protocol-visible cycle, but it must preserve old-commit/new-accept same-edge refill and group II=1. This is only a candidate: the `lfnst_grid_reg → ingress_data_q` path ties the global WNS and would remain, so the expected result is a targeted family reduction, not guaranteed closure. Run functional regression and one same-contract implementation against the fixed CONTROL flow before retaining it.

Alternative: a separately authorized LFNST gather-layout experiment could target the other co-leader, but do not combine both changes in one trial. No RTL/XDC was changed in this census. Registered-neighbor 500 MHz setup signoff remains **NOT ACHIEVED**; package-level signoff remains **NOT EVALUATED**.

## Evidence files

- `setup_endpoint_census.csv`: all 134 negative setup endpoints, one row per endpoint.
- `setup_family_summary.csv`, `setup_bucket_summary.csv`: Vivado-generated census summaries.
- `structural_signature_summary.csv`: coarse primitive signatures only; detailed per-path signatures were skipped.
- `physical_region_summary.csv`: region fields unavailable, retained as empty.
- `control_setup_worst100.rpt`: routed representative paths and physical delay decomposition.
- `reset_recovery_detail.zip`, `reset_recovery_removal_summary.txt`, `reset_removal.rpt`: reset checks.
- `check_timing_read_only.rpt`, `exceptions_read_only.rpt`, `vivado_control_census.log`, `vivado_control_census.jou`, `r5f_census_metrics.txt`: read-only tool record and counters.
- `P4_CONTROL_SETUP_CENSUS_STATUS.json`: machine-readable provenance and findings.
- `SHA256SUMS.json`: hashes of the evidence payload files (excluding the hash list itself).
