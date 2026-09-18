# Step12F P9-R6B: one physical-convergence branch from common_postopt.dcp.
#
# MODE=CONTROL uses ExtraNetDelay_high.  MODE=TREATMENT uses ExtraTimingOpt.
# All other implementation directives are identical.  The script does not
# synthesize or read any new XDC/RTL.

set root_dir [file normalize [file join [file dirname [info script]] .. ..]]
set default_out [file join $root_dir 05_audit current 67 p9_r6b_physical_convergence_20260918]
set mode CONTROL
if {[info exists ::env(STEP12F_R6B_MODE)] && $::env(STEP12F_R6B_MODE) ne ""} {
    set mode [string toupper $::env(STEP12F_R6B_MODE)]
}
set common_dcp [file join $default_out common_postopt.dcp]
if {[info exists ::env(STEP12F_R6B_COMMON_POSTOPT_DCP)] && $::env(STEP12F_R6B_COMMON_POSTOPT_DCP) ne ""} {
    set common_dcp $::env(STEP12F_R6B_COMMON_POSTOPT_DCP)
}
set out_dir [file join $default_out $mode]
if {[info exists ::env(STEP12F_R6B_BRANCH_DIR)] && $::env(STEP12F_R6B_BRANCH_DIR) ne ""} {
    set out_dir $::env(STEP12F_R6B_BRANCH_DIR)
}
set max_threads 4
if {[info exists ::env(STEP12F_MAX_THREADS)] && $::env(STEP12F_MAX_THREADS) ne ""} {
    set max_threads $::env(STEP12F_MAX_THREADS)
}
if {$mode ni {CONTROL TREATMENT}} { error "MODE must be CONTROL or TREATMENT" }
set place_dir ExtraNetDelay_high
if {$mode eq "TREATMENT"} { set place_dir ExtraTimingOpt }
puts "R6B_DEBUG_OUT_DIR=$out_dir"
if {![file isdirectory $out_dir]} { file mkdir $out_dir }
set_param general.maxThreads $max_threads

puts "P9R6B_BRANCH_START"
puts "MODE=$mode"
puts "VIVADO_VERSION=[version -short]"
puts "MAX_THREADS=$max_threads"
puts "COMMON_POSTOPT_DCP=$common_dcp"
puts "PART_EXPECTED=xcku5p-ffvb676-2-e"
puts "TOP_EXPECTED=step12f_registered_neighbor_harness"
puts "PERIOD_NS=2.000"
puts "CLOCK_UNCERTAINTY_SETUP_NS=0.000"
puts "CLOCK_UNCERTAINTY_HOLD_NS=0.000"
puts "OPT_DIRECTIVE=Default_common_checkpoint"
puts "PLACE_DIRECTIVE=$place_dir"
puts "PHYS_OPT_DIRECTIVE=AggressiveExplore"
puts "ROUTE_DIRECTIVE=NoTimingRelaxation"

open_checkpoint $common_dcp
set design [current_design]
set top [get_property TOP $design]
set part [get_property PART $design]
puts "TOP_ACTUAL=$top"
puts "PART_ACTUAL=$part"
if {$top ne "step12f_registered_neighbor_harness"} { error "Unexpected top: $top" }
if {$part ne "xcku5p-ffvb676-2-e"} { error "Unexpected part: $part" }

set start [clock seconds]
place_design -directive $place_dir
puts "PLACE_ELAPSED_SEC=[expr {[clock seconds] - $start}]"
report_timing_summary -delay_type max -max_paths 100 -file [file join $out_dir report_timing_summary_postplace.rpt]
report_timing_summary -delay_type min -max_paths 100 -file [file join $out_dir report_hold_summary_postplace.rpt]

set start [clock seconds]
phys_opt_design -directive AggressiveExplore
puts "PHYS_OPT_ELAPSED_SEC=[expr {[clock seconds] - $start}]"

set start [clock seconds]
route_design -directive NoTimingRelaxation
puts "ROUTE_ELAPSED_SEC=[expr {[clock seconds] - $start}]"

report_route_status -file [file join $out_dir report_route_status_postroute.rpt]
report_timing_summary -delay_type max -max_paths 100 -file [file join $out_dir report_timing_summary_postroute.rpt]
report_timing_summary -delay_type min -max_paths 100 -file [file join $out_dir report_timing_hold_summary_postroute.rpt]
report_timing -delay_type max -max_paths 100 -file [file join $out_dir report_timing_worst100_postroute.rpt]
report_timing -delay_type min -max_paths 100 -file [file join $out_dir report_hold_worst100_postroute.rpt]
report_high_fanout_nets -max_nets 200 -file [file join $out_dir report_high_fanout_postroute.rpt]
report_utilization -file [file join $out_dir report_utilization_postroute.rpt]
report_utilization -hierarchical -file [file join $out_dir report_hierarchy_utilization_postroute.rpt]
report_power -file [file join $out_dir report_power_postroute.rpt]
check_timing -verbose -file [file join $out_dir report_check_timing_postroute.rpt]
report_exceptions -file [file join $out_dir report_exceptions_postroute.rpt]
report_drc -file [file join $out_dir report_drc_postroute.rpt]
report_methodology -file [file join $out_dir report_methodology_postroute.rpt]

set final_dcp [file join $out_dir final.dcp]
write_checkpoint -force $final_dcp
puts "FINAL_DCP=$final_dcp"
puts "P9R6B_BRANCH_DONE"
close_project
