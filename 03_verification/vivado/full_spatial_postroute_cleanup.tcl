# Reproducible incremental physical cleanup of the freshly implemented repair.
# No RTL, clock period, uncertainty or timing exception is changed.
if {![info exists ::env(ITS_REPAIR_INPUT_DCP)] || ![info exists ::env(ITS_REPAIR_OUTPUT_DIR)]} {
    error "Set ITS_REPAIR_INPUT_DCP and ITS_REPAIR_OUTPUT_DIR"
}
set report_dir $::env(ITS_REPAIR_OUTPUT_DIR)
file mkdir $report_dir
set_param general.maxThreads 4
open_checkpoint $::env(ITS_REPAIR_INPUT_DCP)
set period [get_property PERIOD [get_clocks clk]]
if {abs($period - 2.0) > 0.000001} {error "Unexpected clock period: $period"}
puts "REPAIR_CLEANUP_PERIOD_NS=$period"
puts "REPAIR_CLEANUP_INPUT=$::env(ITS_REPAIR_INPUT_DCP)"
report_timing_summary -delay_type max -max_paths 10 -file [file join $report_dir baseline_setup.rpt]
report_timing_summary -delay_type min -max_paths 10 -file [file join $report_dir baseline_hold.rpt]
phys_opt_design -directive AggressiveExplore
report_route_status -file [file join $report_dir after_physopt_route_status.rpt]
set fh [open [file join $report_dir after_physopt_route_status.rpt] r]
set route_text [read $fh]
close $fh
set all_routed 0
if {[regexp {# of routable nets\.+\s*:\s*([0-9]+)} $route_text -> needed] &&
    [regexp {# of fully routed nets\.+\s*:\s*([0-9]+)} $route_text -> routed] &&
    [regexp {# of nets with routing errors\.+\s*:\s*([0-9]+)} $route_text -> errors]} {
    set all_routed [expr {$needed == $routed && $errors == 0}]
}
set worst_setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set worst_hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "REPAIR_AFTER_PHYSOPT_SETUP=$worst_setup HOLD=$worst_hold FULL_ROUTE=$all_routed"
if {!$all_routed || $worst_setup < 0 || $worst_hold < 0} {
    route_design -directive NoTimingRelaxation
}
report_route_status -file [file join $report_dir report_route_status_postroute.rpt]
report_utilization -file [file join $report_dir report_utilization_postroute.rpt]
report_utilization -hierarchical -file [file join $report_dir report_hierarchy_utilization_postroute.rpt]
report_timing_summary -delay_type max -max_paths 100 -file [file join $report_dir report_timing_summary_postroute.rpt]
report_timing_summary -delay_type min -max_paths 100 -file [file join $report_dir report_timing_hold_summary_postroute.rpt]
report_timing -delay_type max -max_paths 100 -file [file join $report_dir report_timing_worst100_postroute.rpt]
report_timing -delay_type min -max_paths 100 -file [file join $report_dir report_hold_worst100_postroute.rpt]
check_timing -verbose -file [file join $report_dir report_check_timing_postroute.rpt]
report_exceptions -file [file join $report_dir report_exceptions_postroute.rpt]
report_drc -file [file join $report_dir report_drc_postroute.rpt]
report_power -file [file join $report_dir report_power_postroute.rpt]
write_checkpoint -force [file join $report_dir step12f_registered_neighbor_postroute.dcp]
close_project
puts "POSTROUTE_REPAIR_DONE"
