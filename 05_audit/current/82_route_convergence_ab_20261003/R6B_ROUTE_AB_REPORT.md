# P9-R6B — Fixed-Netlist Route-Directive A/B

Date: 2026-10-04  
Repository checkout: `sat10-feed-counter-replay-evidence` at `300099de18470ca681322c3b32284a861d969c89`  
Vivado: 2025.2, build 6299465  
Part: `xcku5p-ffvb676-2-e`  
Clock: 2.000 ns, 500 MHz  
Threads: 4

## Result

**The treatment improved this fixed-netlist route result, but did not close setup timing.**

| Metric | Control: `NoTimingRelaxation` | Treatment: `MoreGlobalIterations` | Change |
|---|---:|---:|---:|
| Setup WNS | −0.103 ns | −0.063 ns | +0.040 ns |
| Setup TNS | −18.379 ns | −4.669 ns | +13.710 ns |
| Setup failing endpoints | 512 | 203 | −309 (−60.4%) |
| Hold WHS | +0.006 ns | 0.000 ns | −0.006 ns |
| Hold THS / failing endpoints | 0 / 0 | 0 / 0 | unchanged at report precision |

Both flows completed successfully and fully routed all 43,489 routable nets with zero routing errors. The treatment used four global routing iterations (0–3); the control used three (0–2). Both used the same common post-phys-opt checkpoint, and the only explicit Tcl delta was the `route_design` directive.

The setup leader changed. Control's worst path was `kernel_phase_q_reg[0] → kernel_feed_group_q_reg[0]/D`, 7 LUT levels, 2.099 ns data delay (0.646 ns logic, 1.453 ns route). Treatment's worst path was `reserved_groups_q_reg[3] → kernel_rd_req_group_q_reg[0]/CE`, 8 LUT levels, 1.870 ns data delay (0.628 ns logic, 1.242 ns route; 66.4% route). A separately queried registered H-read address → RAMD64E → H-response path remained negative in both runs: −0.088 ns control and −0.056 ns treatment.

Thus `MoreGlobalIterations` is an **effective partial physical improvement on the exact netlist tested**, not a timing pass. Treatment hold is exactly 0.000 ns at report precision, leaving no hold margin. No independent replay was run because setup still fails.

## Critical provenance boundary

This A/B used the immutable postsynthesis DCP with SHA-256 `86AADA6150CA1E786E14A4D5EA03F68BFB162729BACFD66BB1F001ECA25CF427`. Its recorded originating source commit is **`17496666f3192cd3e1f96ae4e590c2b3b77919f4`**, before the accepted-input feed-counter change.

The latest functional source lineage is `9d7510e75385c3b83cee7afd799c9e6db0b4d95e` (the current checkout's later commits add evidence only; `02_rtl`, `03_verification`, and profile files are unchanged from that source commit). Its registered-neighbor postsynthesis DCP has SHA-256 `4813F4F6AB0977AAFDE383443E05CD70A14BDA7D7CD3BF10B52747B7FAD6D27C`; that DCP was **not** used in this A/B.

Therefore these results establish the route-directive effect only for the pre-feed-counter netlist. They must not be reported as timing results for the latest functional RTL. Applying `MoreGlobalIterations` to the latest source remains unqualified.

## Common branch point and commands

Input postsynthesis DCP: `86AADA6150CA1E786E14A4D5EA03F68BFB162729BACFD66BB1F001ECA25CF427`  
Common post-phys-opt DCP: `86713A3C74910AEAD4601E18A51FAD639468A14135F4F0CF8EA14D34FD646396`

Preparation commands, executed once:

```tcl
opt_design -directive Default
place_design -directive ExtraNetDelay_high
phys_opt_design -directive AggressiveExplore
write_checkpoint -force common_postphysopt.dcp
```

The same common checkpoint was reopened independently for both branches. Route commands:

```tcl
# Control
route_design -directive NoTimingRelaxation

# Treatment
route_design -directive MoreGlobalIterations
```

Vivado logs show identical route-entry PlaceDB (`5ae9e92c`), Shape (`234f6158`), RouteDB (`2ba02511`), and NetGraph (`2f9dbc33`) checksums.

## Structural and constraint checks

- Registered-neighbor boundary population was `54/54` source FFs and `44/44` sink FFs in both routed DCPs.
- For both DCPs, `kernel_h_rd_pending_q`, `kernel_run_q`, and `kernel_stage_q` through RAMD64E to H-read response D returned **No paths found**.
- The positive control query found the registered H-read address → RAMD64E → response path in both DCPs.
- `check_timing`: 0 unconstrained internal endpoints; `rst_n` is the one top input with no input delay in this harness.
- `report_exceptions`: no valid timing exceptions.
- DRC: zero Error-severity violations and zero routing errors. Both runs retain the same harness/package-related `NSTD-1` and `UCIO-1` critical warnings, plus the documented DSP/unused-net warnings/advisory. This is not package-level signoff.

Resource counts were identical (26,391 CLB LUTs, 21,202 CLB registers, 320 DSPs, 0 BRAM tiles). Vectorless power estimates were 1.501 W control and 1.485 W treatment at medium confidence; with no activity file, this small estimated difference is not treated as a measured power result.

No RTL, XDC, functional tests, synthesis, or source netlist were changed or rerun in this physical-only experiment. Official contest equivalence remains `NOT_PROVEN`; package-level timing remains `NOT_EVALUATED`.

## Next decision

Do not start another RTL timing patch based on the old-netlist leader. The shortest decision-useful follow-up is the same one-variable A/B on the latest functional postsynthesis DCP (`4813F4F6…FAD6D27C`): build one shared post-phys-opt branch point, then route once with each directive. Only if the treatment helps on that netlist should it become the current physical-flow candidate. If setup remains negative, classify the latest candidate's own worst-path population before proposing an RTL change.

**Status:** `ROUTE_AB_COMPLETE / PARTIAL_IMPROVEMENT / CURRENT_RTL_APPLICABILITY_UNVERIFIED / 500_MHZ_NOT_CLOSED`.
