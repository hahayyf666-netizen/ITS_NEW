# Step12C-M7 staging-address localization flow.
# This uses the frozen registered-neighbor boundary harness and isolates all
# M7 synthesis/implementation evidence from prior M6 runs.
set base_dir [file dirname [info script]]
set root_dir [file join $base_dir .. ..]
set ::env(STEP12C_BOUNDARY_REPORT_DIR) [file join $root_dir 05_audit current 23 m7_timing]
set ::env(STEP12C_BOUNDARY_RUN_DIR) [file join $root_dir 03_verification vivado run_step12c_m7]
source [file join $base_dir run_step12c_boundary_pre.tcl]
