# Bounded post-route refinement. Preserve every candidate and select the best
# fully routed design with nonnegative hold slack. Timing constraints unchanged.
if {![info exists ::env(ITS_REPAIR_INPUT_DCP)] || ![info exists ::env(ITS_REPAIR_OUTPUT_DIR)]} {error "Missing input/output env"}
set report_dir $::env(ITS_REPAIR_OUTPUT_DIR)
file mkdir $report_dir
set_param general.maxThreads 4
proc route_complete {path} {
    report_route_status -file $path
    set fh [open $path r];set s [read $fh];close $fh
    if {![regexp {# of routable nets\.+\s*:\s*([0-9]+)} $s -> needed]} {return 0}
    if {![regexp {# of fully routed nets\.+\s*:\s*([0-9]+)} $s -> routed]} {return 0}
    if {![regexp {# of nets with routing errors\.+\s*:\s*([0-9]+)} $s -> errors]} {return 0}
    return [expr {$needed == $routed && $errors == 0}]
}
open_checkpoint $::env(ITS_REPAIR_INPUT_DCP)
if {abs([get_property PERIOD [get_clocks clk]] - 2.0)>0.000001} {error "Clock changed"}
set best_path $::env(ITS_REPAIR_INPUT_DCP)
set best_setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set best_hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
set best_pass 0
puts "BOUNDED_BASELINE setup=$best_setup hold=$best_hold period=2.000"
for {set pass 1} {$pass <= 2} {incr pass} {
    if {$best_setup>=0 && $best_hold>=0} {break}
    phys_opt_design -directive AggressiveExplore
    if {![route_complete [file join $report_dir pass${pass}_route.rpt]]} {
        route_design -directive NoTimingRelaxation
    }
    set full [route_complete [file join $report_dir pass${pass}_route_final.rpt]]
    set setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
    set hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
    report_timing_summary -delay_type max -max_paths 10 -file [file join $report_dir pass${pass}_setup.rpt]
    report_timing_summary -delay_type min -max_paths 10 -file [file join $report_dir pass${pass}_hold.rpt]
    set candidate [file join $report_dir candidate_pass${pass}.dcp]
    write_checkpoint -force $candidate
    puts "BOUNDED_CANDIDATE pass=$pass setup=$setup hold=$hold full_route=$full"
    if {$full && $hold>=0 && $setup>$best_setup} {
        set best_setup $setup;set best_hold $hold;set best_path $candidate;set best_pass $pass
    } else {
        puts "BOUNDED_NO_FURTHER_IMPROVEMENT"
        break
    }
}
close_project
open_checkpoint $best_path
if {abs([get_property PERIOD [get_clocks clk]] - 2.0)>0.000001} {error "Clock changed"}
puts "BOUNDED_SELECTED pass=$best_pass setup=$best_setup hold=$best_hold checkpoint=$best_path"
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
puts "BOUNDED_POSTROUTE_REPAIR_DONE"
