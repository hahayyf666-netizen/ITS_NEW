set input_dcp $::env(STEP12F_POSTROUTE_DCP)
set report_dir $::env(STEP12F_POSTROUTE_EXPLORE_DIR)

if {![file exists $input_dcp]} {
    error "Missing frozen routed checkpoint: $input_dcp"
}
file mkdir $report_dir

set_param general.maxThreads 4
puts "P9_POSTROUTE_EXPLORE_START"
puts "VIVADO_VERSION=[version -short]"
puts "MAX_THREADS=[get_param general.maxThreads]"
puts "INPUT_DCP=$input_dcp"
puts "INPUT_DCP_SHA256=$::env(STEP12F_POSTROUTE_DCP_SHA256)"

open_checkpoint $input_dcp
puts "OPEN_DESIGN=[current_design]"
puts "PART=[get_property PART [current_design]]"

report_timing_summary -delay_type max -max_paths 100 \
    -file [file join $report_dir baseline_timing_setup.rpt]
report_timing_summary -delay_type min -max_paths 100 \
    -file [file join $report_dir baseline_timing_hold.rpt]
report_route_status -file [file join $report_dir baseline_route_status.rpt]

# The sole physical change in this experiment.
phys_opt_design -directive Explore
puts "POSTROUTE_PHYS_OPT_COMPLETE"

report_route_status -file [file join $report_dir candidate_route_status.rpt]
report_timing_summary -delay_type max -max_paths 100 \
    -file [file join $report_dir candidate_timing_setup.rpt]
report_timing_summary -delay_type min -max_paths 100 \
    -file [file join $report_dir candidate_timing_hold.rpt]
report_timing -delay_type max -max_paths 100 \
    -file [file join $report_dir candidate_timing_worst100.rpt]
report_timing -delay_type min -max_paths 100 \
    -file [file join $report_dir candidate_timing_hold_worst100.rpt]
report_utilization -file [file join $report_dir candidate_utilization.rpt]
report_high_fanout_nets -max_nets 200 \
    -file [file join $report_dir candidate_high_fanout.rpt]
check_timing -verbose -file [file join $report_dir candidate_check_timing.rpt]
report_exceptions -file [file join $report_dir candidate_exceptions.rpt]
report_drc -file [file join $report_dir candidate_drc.rpt]
report_methodology -file [file join $report_dir candidate_methodology.rpt]
report_power -file [file join $report_dir candidate_power.rpt]
write_checkpoint -force [file join $report_dir candidate_postroute_explore.dcp]

close_design
puts "P9_POSTROUTE_EXPLORE_DONE"
