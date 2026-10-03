set input_dcp [lindex $argv 0]
set out_dir [lindex $argv 1]
set directive [lindex $argv 2]
if {$input_dcp eq "" || $out_dir eq "" || $directive eq ""} {
    error "usage: route_from_common_postphysopt.tcl <common_postphysopt.dcp> <out_dir> <directive>"
}
if {$directive ni {NoTimingRelaxation MoreGlobalIterations}} {
    error "directive not authorized for this experiment: $directive"
}
file mkdir $out_dir
set_param general.maxThreads 4
puts "ROUTE_AB_BRANCH_START"
puts "VIVADO_VERSION=[version -short]"
puts "MAX_THREADS=[get_param general.maxThreads]"
puts "INPUT_DCP=$input_dcp"
puts "ROUTE_DIRECTIVE=$directive"
open_checkpoint $input_dcp
puts "DESIGN=[current_design]"
puts "PART=[get_property PART [current_design]]"
report_timing_summary -delay_type max -max_paths 100 \
    -file [file join $out_dir timing_before_route_setup.rpt]
report_timing_summary -delay_type min -max_paths 100 \
    -file [file join $out_dir timing_before_route_hold.rpt]

route_design -directive $directive

report_route_status -file [file join $out_dir route_status_postroute.rpt]
report_timing_summary -delay_type max -max_paths 100 \
    -file [file join $out_dir timing_postroute_setup.rpt]
report_timing_summary -delay_type min -max_paths 100 \
    -file [file join $out_dir timing_postroute_hold.rpt]
report_timing -delay_type max -max_paths 100 \
    -file [file join $out_dir worst100_postroute_setup.rpt]
report_timing -delay_type min -max_paths 100 \
    -file [file join $out_dir worst100_postroute_hold.rpt]
report_utilization -file [file join $out_dir utilization_postroute.rpt]
report_high_fanout_nets -max_nets 200 \
    -file [file join $out_dir high_fanout_postroute.rpt]
check_timing -verbose -file [file join $out_dir check_timing_postroute.rpt]
report_exceptions -file [file join $out_dir exceptions_postroute.rpt]
report_drc -file [file join $out_dir drc_postroute.rpt]
report_methodology -file [file join $out_dir methodology_postroute.rpt]
report_power -file [file join $out_dir power_postroute.rpt]
write_checkpoint -force [file join $out_dir postroute.dcp]
puts "ROUTE_AB_BRANCH_DONE"
close_design
