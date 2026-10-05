# Step12F H-read raw-capture physical qualification

## Result

The H-read raw-response capture boundary is functionally qualified and its targeted structural timing gate passes. The fresh registered-neighbor implementation is fully routed, but **500 MHz setup is not closed**.

| Metric | Result |
|---|---:|
| Setup WNS / TNS | `-0.107 ns / -26.406 ns` |
| Setup failing endpoints | `695` |
| Hold WHS / THS | `+0.012 ns / 0.000 ns` |
| Hold failing endpoints | `0` |
| Fully routed nets | `43,307 / 43,307` |
| Routing errors | `0` |
| Unconstrained internal endpoints | `0` |
| Valid timing exceptions | `0` |

Disposition: `FUNCTIONAL_PASS / TARGETED_HREAD_BOUNDARY_PASS / PHYSICAL_SETUP_FAIL / HOLD_PASS / NO_SIGNOFF`.

## Provenance and flow

- Source commit: `ae31551931107ab4f41da1ed6c1992732be1ba06` (`Step12F isolate H-read raw response capture`), parent `41ce8c279e6f15bb0674e1eda61ce1b353cf3611`.
- Functional evidence: `05_audit/current/86_hread_raw_capture_functional_20261005/20261005T094452Z_ae3155193110/CHECKPOINT_MANIFEST.json`; SHA-256 `FD8A8147576C042958DED9A91DFB47C5B5AB1D4796D55899CC9E18CB2E5E31E1`.
- Profile: `contest_engineering_vtm10_sat10_v2`, canonical SHA-256 `FEA3ACB18C5C35EB0FD8A8DBF533C3A6BE7536BCC8EF5FDB87135DF512643746`; `official_equivalence=NOT_PROVEN`.
- Physical top: `step12f_registered_neighbor_harness`; the DUT RTL was freshly synthesized in this harness. This is not a replay of an earlier postsynthesis netlist.
- Vivado: `2025.2`, build `6299465`; part `xcku5p-ffvb676-2-e`; `maxThreads=4`; clock period `2.000 ns`; clock uncertainty `0`.
- Flow: `synth_design -directive Default`; `opt_design -directive Default`; `place_design -directive ExtraNetDelay_high`; `phys_opt_design -directive AggressiveExplore`; `route_design -directive NoTimingRelaxation`.
- Registered-neighbor harness XDC was used. The old OOC wrapper XDC was not loaded. No RTL/XDC waiver, multicycle path, or false path was added for this run.
- Main Vivado log SHA-256: `9BC5553901B278DB764EDB95AD7886BF845E2D6CD867E6F5A15EF5715F0F9B4E`.
- Main Vivado journal SHA-256: `362A26D2A72CABEE00436F753621F7151F2B2EB6E82FEE18CB5526F29479315B`.

## Functional qualification

The source commit's SAT10 checkpoint passed in both normal and `SYNTHESIS` modes, including Gate-B 156 cases, Gate-F 13 modes, Gate-C 369 tuples / 45,636 beats per mode, LFNST engine 1,088 cases, LFNST wrapper 388 cases, SAT10 exhaustive 65,536 signed-16 inputs, submission-top overflow/backpressure/two-TU/done/4x10 packing, and the new H-read test.

The H-read test reported `H_READ_RAW_CAPTURE_PASS captures=32 consumes=32 stall_cycles=6`; it verifies ordered data and metadata through a six-cycle forced stall, followed by II=1 capture cadence and complete queue drain.

## Targeted H-read structural timing

The read-only Tcl audit opened the exact post-route checkpoint and performed no design mutation or implementation command. Object counts were nonzero for all queried source/destination groups: H address Q `40`, pending Q `1`, run Q `2`, stage Q `1`, raw capture D/Q `64/64`, head D `64`, tail D `64`; temporary-bank RAMD64E `1,280`, total RAMD64E `5,706`.

- `pending`, `run`, and `stage` through temporary RAM to raw-capture D: `NO_TIMING_PATHS` for each query.
- H address Q through temporary RAM to raw-capture D: `PATHS_FOUND` (5 reports). Worst sampled path slack `-0.033 ns`, data delay `1.859 ns` (`0.410 ns` logic + `1.449 ns` routing), four logic levels (`RAMD64E/LUT6/MUXF7/MUXF8`). Thus the address-to-raw stage remains a small local setup violation; it is not claimed closed.
- H address Q through RAM to old head/tail D: `NO_TIMING_PATHS`.
- Raw-capture Q to head D: path exists, representative slack `+0.173 ns`.
- Raw-capture Q to tail D: path exists, representative slack `+0.456 ns`.

This confirms the intended structural cut: live pending/run/stage controls no longer traverse the asynchronous temporary-RAM read cone into response capture. It does not prove global timing closure.

The current global WNS leader is elsewhere: `kernel_phase_q` replica to `rd_cmd_addr_q` CE, `-0.107 ns`, 7 logic levels, data delay `2.024 ns` (`0.467 ns` logic + `1.557 ns` routing; routing fraction about `76.9%`). Other near-leading paths include read-command address to raw response capture and wrapper/kernel control paths.

## Global physical result and caveats

DRC reported zero errors. The routed harness has two package-I/O-related critical warnings (`NSTD-1` / `UCIO-1`) for harness top ports `clk` and `rst_n`, which are intentionally not assigned package pins/IO standards in this registered-neighbor core experiment. This is not package-level FPGA signoff. Timing check reports zero unconstrained internal endpoints; the asynchronous reset port has no input delay as expected for this harness boundary. No valid timing exceptions were reported.

Post-route utilization: LUT `26,374`; LUTRAM `5,706`; FF `21,312`; DSP `320`; BRAM `0`; URAM `0`; CLB `4,617`; F7 `1,231`; F8 `402`.

Vectorless power estimate: total `1.415 W` (`0.957 W` dynamic, `0.458 W` static), medium confidence. Treat as a tool estimate, not application-activity power signoff.

The earlier registered-neighbor result (`WNS=-0.139 ns`, `TNS=-74.139 ns`, `1,808` failing endpoints) is only a historical comparison. This run freshly synthesized and reimplemented a changed RTL source and used tool physical optimization, including DSP-register restructuring; it is not a same-netlist/same-placement A/B and does not establish that the H-read change alone caused the global QoR delta. Relative to that historical run, this result has better TNS and fewer failures, but WNS is 12 ps worse. Hold passes in this run.

## Key artifact hashes

All hashes are SHA-256. DCPs are retained locally for traceability but excluded from Git because of their size.

| Artifact | SHA-256 |
|---|---|
| Postsynthesis DCP (`30,064,113` bytes) | `7A45584D4E361BC5C671D92D4D9855D7A22A75A05FDCA11B904ABB7819A0095F` |
| Postroute DCP (`50,099,878` bytes) | `08A4823DEB659259E6AC8D853001426D7C80D17C5057FF1EF2F093579CFE19B1` |
| Setup timing summary | `B0033AA25095062FA8432AD142AB084E7266D41409788C1330CE8B0BD3DEBCCC` |
| Hold timing summary | `B63C32BD6CB836AFFCB52E0D9BC7EA750983CB7FFA3868722DF8655DB3A38814` |
| Worst-100 setup | `C2E030055972DD65DC473BCB78661EFECDBA4056B3FBF4C0DD2BC05DBAABFDE9` |
| Route status | `D077CAF5B45DCC8BEF212407626525BE9DA474D5B44FA5FE651C7EA0D42868E7` |
| Utilization | `8DFA021268321FFF49EEA34CC4A202A4F9E3DC290CDEDA12E99096AD2D6DCEBE` |
| Power | `C2803821D7A906E49134BAE4CE7183DD4FD1BD6FF82BAEF2D91799A9719E2F3E` |
| Check timing | `C950E1F2D740014A698547F06319CBA850074E627989A0776ED63139046FB513` |
| Exceptions | `BA1EBD263220BB2E5A7A50F1A7F3F5753A12A7831DDD3A87347AEF62744F3547` |
| DRC | `9340FFF22004E3AEB2332F3622770CD2AE7E276DA6635F70E4C5C50B43A72B00` |
| Methodology | `C4CEF56027631E00F6316CBCABB1FB20E934A47BF1948BC58D5D08802D43966F` |
| Targeted STA summary | `1C7984B1A16C25EE3B2031A315983E78A4DC6C5C81E89EF3FB0DF791BEBAD0D4` |
| H address to raw-capture report | `3C55978EC9DE5737A75846F670F1D951C96BF4FC28D1C912E8E5511183FBC01B` |
| Raw capture to head report | `F7FC93EA89B5DE864929FCB8DD097E106BD1A602263613C15FFEAF059A4FE737` |
| Raw capture to tail report | `5D90B2A168F7547E02F79FE5A141543D79CA07ED1D2DC7AEAB9A79CD0CB6047B` |
| Targeted audit Tcl | `6F77054DD172AEA94F1B5B1FA4EDB74367D043CC2C2C08E1F234D25406640266` |
| Targeted Vivado log | `4D4FBFC826DC0B63C924EA1479FA69F8673A0DD09B94FAC7058DC03325A78671` |

The detailed machine-readable record, including source Git blob IDs, byte hashes and report hashes, is `P9_HREAD_RAW_CAPTURE_PHYSICAL_MANIFEST.json`.

## Final status

```yaml
functional: PASS
H_read_structural_cut: PASS
fresh_synthesis_and_full_route: COMPLETE
registered_neighbor_hold: PASS
registered_neighbor_setup: FAIL
500_MHz_signoff: NOT_ACHIEVED
package_level_signoff: NOT_EVALUATED
official_equivalence: NOT_PROVEN
```

The next timing investigation should start from the routed global leader (`kernel_phase_q -> rd_cmd_addr_q CE`) and classify its endpoint family/TNS against the other near-leading families. Do not treat this checkpoint as closure, and do not attribute the global improvement to the H-read edit alone.
