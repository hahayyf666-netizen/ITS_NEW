# R4A Vivado run manifest

Tool: `D:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat`  
Part: `xcku5p-ffvb676-2-e`  
Constraint: `p2f_b2_controlled_2ns.xdc` (2.000 ns)  
Flow: out-of-context, `flatten_hierarchy none`, `directive Default`.

## R3R synthesis comparison

`P2F_B2_DUT` was set to the read-only R4_PRE/R3R RTL. Reports were written to `reports_r4a_r3r_synth/` and run files to `run_r4a_r3r_synth/`. `P2F_B2_RUN_IMPL` was unset, so this was synthesis-only.

## R4A synthesis

The R4A RTL was synthesized with the same Tcl/XDC and reports were written to `reports_r4a_synth/` and `run_r4a_synth/`. `P2F_B2_RUN_IMPL` was unset.

## R4A post-route

The R4A RTL was run once with `P2F_B2_RUN_IMPL=1`; reports and checkpoint were written to `reports_r4a_postroute/` and run files to `run_r4a_postroute/`. The run completed with zero Vivado errors and zero unrouted nets. Timing signoff is in `report_timing_summary_postroute.rpt`; utilization and power are in the corresponding reports in that directory.

The interactive Vivado stdout is not treated as the result. The report files and checkpoints above are the retained evidence.
