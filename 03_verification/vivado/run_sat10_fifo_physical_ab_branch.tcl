# One placement-directive experiment from a common post-opt checkpoint.
# CONTROL and TREATMENT use identical commands except for place_design.
if {![info exists ::env(SAT10_AB_COMMON_DCP)]} { error "SAT10_AB_COMMON_DCP is required" }
if {![info exists ::env(SAT10_AB_OUT_DIR)]} { error "SAT10_AB_OUT_DIR is required" }
if {![info exists ::env(SAT10_AB_MODE)]} { error "SAT10_AB_MODE is required" }

set mode $::env(SAT10_AB_MODE)
if {$mode ni {CONTROL TREATMENT}} { error "Unexpected mode: $mode" }
set place_directive [expr {$mode eq "CONTROL" ? "ExtraNetDelay_high" : "Explore"}]
set out_dir [file normalize $::env(SAT10_AB_OUT_DIR)]
file mkdir $out_dir
set_param general.maxThreads 4

puts "AB_MODE=$mode"
puts "VIVADO_VERSION=[version -short]"
puts "MAX_THREADS=[get_param general.maxThreads]"
puts "INPUT_DCP=$::env(SAT10_AB_COMMON_DCP)"
puts "PLACE_DIRECTIVE=$place_directive"
puts "PHYS_OPT_DIRECTIVE=AggressiveExplore"
puts "ROUTE_DIRECTIVE=NoTimingRelaxation"

open_checkpoint $::env(SAT10_AB_COMMON_DCP)
set design [current_design]
if {[get_property TOP $design] ne "step12f_registered_neighbor_harness"} { error "Unexpected top" }
if {[get_property PART $design] ne "xcku5p-ffvb676-2-e"} { error "Unexpected part" }

place_design -directive $place_directive
report_timing_summary -delay_type max -max_paths 100 -file [file join $out_dir setup_postplace.rpt]
report_timing_summary -delay_type min -max_paths 100 -file [file join $out_dir hold_postplace.rpt]

phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation

report_route_status -file [file join $out_dir route_status.rpt]
report_timing_summary -delay_type max -max_paths 100 -file [file join $out_dir setup_postroute.rpt]
report_timing_summary -delay_type min -max_paths 100 -file [file join $out_dir hold_postroute.rpt]
report_timing -delay_type max -max_paths 100 -file [file join $out_dir setup_worst100.rpt]
report_timing -delay_type min -max_paths 100 -file [file join $out_dir hold_worst100.rpt]
report_utilization -file [file join $out_dir utilization.rpt]
report_power -file [file join $out_dir power.rpt]
report_drc -file [file join $out_dir drc.rpt]
check_timing -verbose -file [file join $out_dir check_timing.rpt]
report_exceptions -file [file join $out_dir exceptions.rpt]
write_checkpoint -force [file join $out_dir final.dcp]
puts "SAT10_AB_BRANCH_DONE"
close_project
