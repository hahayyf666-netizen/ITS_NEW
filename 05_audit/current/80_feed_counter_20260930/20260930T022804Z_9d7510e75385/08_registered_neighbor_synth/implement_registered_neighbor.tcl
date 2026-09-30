set dcp [lindex $argv 0]
set out [lindex $argv 1]
if {$dcp eq "" || $out eq ""} { error "usage: implement_registered_neighbor.tcl <postsynth.dcp> <out>" }
file mkdir $out
set_param general.maxThreads 4
puts "TOOL=[version -short]"
puts "THREADS=[get_param general.maxThreads]"
puts "INPUT_DCP=$dcp"
open_checkpoint $dcp
puts "DESIGN=[current_design]"
puts "PART=[get_property PART [current_design]]"

opt_design -directive Default
place_design -directive ExtraNetDelay_high
phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation

report_route_status -file [file join $out report_route_status_postroute.rpt]
report_utilization -file [file join $out report_utilization_postroute.rpt]
report_utilization -hierarchical -file [file join $out report_hierarchy_utilization_postroute.rpt]
report_timing_summary -delay_type max -max_paths 100 \
    -file [file join $out report_timing_summary_postroute.rpt]
report_timing_summary -delay_type min -max_paths 100 \
    -file [file join $out report_timing_hold_summary_postroute.rpt]
report_timing -delay_type max -max_paths 100 \
    -file [file join $out report_timing_worst100_postroute.rpt]
report_timing -delay_type min -max_paths 100 \
    -file [file join $out report_hold_worst100_postroute.rpt]
report_high_fanout_nets -max_nets 200 \
    -file [file join $out report_high_fanout_postroute.rpt]
check_timing -verbose -file [file join $out report_check_timing_postroute.rpt]
report_exceptions -file [file join $out report_exceptions_postroute.rpt]
report_drc -file [file join $out report_drc_postroute.rpt]
report_methodology -file [file join $out report_methodology_postroute.rpt]
report_power -file [file join $out report_power_postroute.rpt]
write_checkpoint -force [file join $out registered_neighbor_postroute.dcp]
close_design
puts "REGISTERED_NEIGHBOR_IMPL_DONE"
