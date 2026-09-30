# SAT10 post-route Explore qualification

Date: 2026-09-30 (Asia/Shanghai)
Source: `cddb7f7f68a59e349a71343cf5aa06f6b1dd410a`
Branch: `sat10-functional-evidence`

## Result

The bounded post-route optimization completed successfully, but **did not change timing or the netlist**. Vivado reported zero WNS/TNS gain, zero added/removed/optimized cells, and the same setup/hold summary before and after. This experiment does not close setup; stop physical strategy trials on this checkpoint.

| Metric | Frozen routed input | After `phys_opt_design -directive Explore` |
|---|---:|---:|
| Setup WNS | -0.005 ns | -0.005 ns |
| Setup TNS | -0.015 ns | -0.015 ns |
| Setup failing endpoints | 4 | 4 |
| Hold WHS | +0.010 ns | +0.010 ns |
| Hold THS | 0.000 ns | 0.000 ns |
| Hold failing endpoints | 0 | 0 |
| Routable / fully routed nets | 43,489 / 43,489 | 43,489 / 43,489 |
| Routing error nets | 0 | 0 |

The four setup paths remain the same:

1. `kernel_ctx_output_size_q` → `kernel_feed_group_q/CE`, -0.005 ns; 7 LUT levels; 1.802 ns data delay (0.749 logic, 1.053 route); effective clock skew -0.108 ns.
2. `kernel_stage_q` → P4 `ingress_data_q[13]/D`, -0.005 ns; 5 logic levels; 1.891 ns data delay (0.689 logic, 1.202 route); skew -0.104 ns.
3. `slot_state[0][1]` → `lfnst_grid[56][2]/CE`, -0.002 ns; 3 LUT levels; 1.793 ns data delay (0.428 logic, 1.365 route); skew -0.114 ns.
4. P4 `ready_rd_ptr_q` → `issue_desc_bundle_addr_q[5]_rep__5/D`, -0.002 ns; 5 logic levels; 1.926 ns data delay (0.452 logic, 1.474 route); skew -0.066 ns.

The post-route Explore summary records `WNS Gain=0.000 ns`, `TNS Gain=0.000 ns`, `Added Cells=0`, `Removed Cells=0`, and `Optimized Cells/Nets=0`. The result is therefore a no-op on this DCP, not evidence that all physical optimization methods are exhausted.

## Structural and implementation checks

- Candidate checkpoint remains in `Physopt postRoute` state and has 43,489/43,489 routable nets fully routed.
- DRC errors: 0. The harness still has the expected `NSTD-1` and `UCIO-1` critical warnings for its unassigned `clk` and `rst_n` package properties; this is not package-level signoff.
- Unconstrained internal endpoints: 0. The one `no_input_delay` item is the harness `rst_n` input.
- Valid timing exceptions: none.
- Reset timing was queried by async control pins: worst clear recovery `+0.003 ns`, clear removal `+0.212 ns`, preset recovery `+0.041 ns`, and preset removal `+0.281 ns`. The asynchronous path group has WNS `+0.003 ns`, TNS `0`, and 0 failing endpoints.
- Post-route registered-neighbor boundary census: 54/54 source FFs and 44/44 sink FFs.
- H-read negative structural checks used nonempty source, through, and destination object sets: `pending`, `kernel_run_q`, and `kernel_stage_q` each had no timing path through RAMD64E cells to H-response D pins. Positive control: registered H-read address Q through RAMD64E to H-response D had a path (representative slack 0.000 ns). The address-to-response path remains critical-near-zero.
- No synthesis, placement, routing, RTL edit, XDC edit, clock change, or exception change occurred.

## Tool and provenance

```yaml
vivado: 2025.2 Build 6299465
part: xcku5p-ffvb676-2-e
threads: 4
input_postroute_dcp_sha256: E93F18866F4063E0460F9F35F4E82FD7E837174A9F912C5D02616463722B1911
candidate_postroute_dcp_sha256: C3124E785EA4F6B81D24D54CD0DA5312237671F383C8D60748545B2B9DC3F993
candidate_setup_report_sha256: 9FBB7456EBAD0A6B0B215E99E79216B357DBE353ADCB48A1088321EAEB0A66CF
candidate_hold_report_sha256: 792EAD7FF5AA156E48694E91ED5D24427C322A77DAEB986FF295353180E3B8B1
candidate_worst100_sha256: 7354529CFA0AB385EE56CBF044D2C74B57E98A072D650E6032AA33C6970FC423
candidate_route_status_sha256: 8B00DFD76E3D08CD22D5CA27100F8CB4DEA4BF785597D84B7EC65278AE4EAEE3
vivado_log_sha256: F4E367E89DA7BEE2247FE4EF1E0BD285B3877F4A32FA0ADFA9A3B45086C68B78
structure_query_log_sha256: 8D6A9971CAD4AEBA8E13AE036C77FE31BBE5296354914E8490CAB84CA02B6F6E
positive_control_log_sha256: 8E35E1E0C54B4CF2F12E28078B20B37CCC20AA77B7CF9E89978ECC6DDBF939DC
reset_query_log_sha256: E3B45CA677C84A842EEEC2E0A83DEBFF2CD7DE13173B19EED0BAA7C8A3D36EA4
reset_recovery_report_sha256: 502B743F41D63A6BA46992FABDEBF1ECBEC3F3F8E0A8FBCBA2E06552CE8F861B
reset_removal_report_sha256: 186B27454B57756F666E51D63853C7239C8E34245E5929BA5A4CD1F7004007E6
preset_recovery_report_sha256: 2F28E3AE3F51FDBCD5344B4D0C3EC46FA28ED36DDDECA9B66EDD59E54B9F3889
preset_removal_report_sha256: E482B6910075B6D3DDDFEA7C77BE7FFE420168573D763D10A3128FF5C94B60DD
```

The sole implementation command was `phys_opt_design -directive Explore`, run in a fresh Vivado process after opening the frozen routed DCP. Two additional Vivado processes performed read-only structural queries. Full candidate DCP is retained locally at `C:/Users/Fine/Documents/Codex/2026-07-23/ni/outputs/sat10_postroute_explore_20260930/candidate_postroute_explore.dcp` and is not included in this compact evidence commit.

The earlier transpose evidence manifest had a duplicated `vivado.log` hash typo. This evidence update corrects that field to the hash of the committed log; no run result changed.

## Decision and next action

```yaml
postroute_explore: NO_TIMING_CHANGE
registered_neighbor_hold: PASS
registered_neighbor_setup: FAIL
500mhz_signoff: NOT_ACHIEVED
```

Retain the LFNST transpose. Do not repeat LFNST grid-clear removal: the prior R7 experiment on this project removed that synchronous data clear and worsened fresh routed setup from -0.045/-4.882/312 to -0.134/-42.408/1006; that change was rejected.

The next RTL proposal should target the remaining worst path, `kernel_ctx_output_size_q → kernel_feed_group_q/CE`, by locally factoring feed-counter enable/update control while preserving same-edge `input_group_fire`, registered `input_vector_done`, accept/commit separation, H commit-wait, and N=4 vector II=1. It must be a one-hunk candidate with directed acceptance/commit and continuous N=4 tests before a fresh full implementation. No claim is made that this single edit will close the other three path families.

Functional evidence remains bound to source commit `17496666f3192cd3e1f96ae4e590c2b3b77919f4`; no RTL changed in this physical-only experiment. Official equivalence remains `NOT_PROVEN`; package-level timing remains `NOT_EVALUATED`.
