# M6 synthesis/implementation wrapper.  The underlying Boundary-PRE flow is
# unchanged; only its report/run destinations are isolated for this candidate.
set base_dir [file dirname [info script]]
set root_dir [file join $base_dir .. ..]
set ::env(STEP12C_BOUNDARY_REPORT_DIR) [file join $root_dir 05_audit current 22 m6_timing]
set ::env(STEP12C_BOUNDARY_RUN_DIR) [file join $root_dir 03_verification vivado run_step12c_m6]
source [file join $base_dir run_step12c_boundary_pre.tcl]
