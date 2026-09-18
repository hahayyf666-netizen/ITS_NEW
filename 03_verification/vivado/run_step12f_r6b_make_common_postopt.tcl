# Step12F P9-R6B: create the single common post-opt branch point.
#
# This script starts from the frozen R6 post-synthesis DCP, runs opt_design
# exactly once, and writes a checkpoint used by both R6B branches.  It does
# not synthesize, place, phys_opt, route, or modify RTL/XDC.

set root_dir [file normalize [file join [file dirname [info script]] .. ..]]
set default_dcp [file join $root_dir 05_audit current 65 p9_r6_input_cache_local_20260918 vivado step12f_registered_neighbor_postsynth.dcp]
set default_out [file join $root_dir 05_audit current 67 p9_r6b_physical_convergence_20260918]

set dcp_path $default_dcp
if {[info exists ::env(STEP12F_R6B_POSTSYNTH_DCP)] && $::env(STEP12F_R6B_POSTSYNTH_DCP) ne ""} {
    set dcp_path $::env(STEP12F_R6B_POSTSYNTH_DCP)
}
set out_dir $default_out
if {[info exists ::env(STEP12F_R6B_OUT_DIR)] && $::env(STEP12F_R6B_OUT_DIR) ne ""} {
    puts "R6B_DEBUG_ENV_OUT=$::env(STEP12F_R6B_OUT_DIR)"
    set out_dir $::env(STEP12F_R6B_OUT_DIR)
}
set max_threads 4
if {[info exists ::env(STEP12F_MAX_THREADS)] && $::env(STEP12F_MAX_THREADS) ne ""} {
    set max_threads $::env(STEP12F_MAX_THREADS)
}
puts "R6B_DEBUG_OUT_DIR=$out_dir"
if {![file isdirectory $out_dir]} { file mkdir $out_dir }
set_param general.maxThreads $max_threads

puts "P9R6B_COMMON_START"
puts "VIVADO_VERSION=[version -short]"
puts "MAX_THREADS=$max_threads"
puts "DCP=$dcp_path"
puts "PART_EXPECTED=xcku5p-ffvb676-2-e"
puts "TOP_EXPECTED=step12f_registered_neighbor_harness"
puts "PERIOD_NS=2.000"
puts "CLOCK_UNCERTAINTY_SETUP_NS=0.000"
puts "CLOCK_UNCERTAINTY_HOLD_NS=0.000"
puts "FLOW=OPEN_POSTSYNTH_then_opt_design_Default_only"

open_checkpoint $dcp_path
set design [current_design]
set top [get_property TOP $design]
set part [get_property PART $design]
puts "TOP_ACTUAL=$top"
puts "PART_ACTUAL=$part"
if {$top ne "step12f_registered_neighbor_harness"} { error "Unexpected top: $top" }
if {$part ne "xcku5p-ffvb676-2-e"} { error "Unexpected part: $part" }

set src_q [get_pins -hier -quiet -regexp {.*src_(it_info|it_info_vld|it_data_in|it_data_addr|it_data_in_vld|it_data_end|it_data_out_req)_q_reg.*/Q$}]
set sink_d [get_pins -hier -quiet -regexp {.*sink_(it_data_in_req|it_data_out|it_data_out_vld|it_done|protocol_error)_q_reg.*/D$}]
set src_cells [get_cells -quiet -of_objects $src_q]
set sink_cells [get_cells -quiet -of_objects $sink_d]
puts "SOURCE_FF_FOUND=[llength $src_cells]"
puts "SINK_FF_FOUND=[llength $sink_cells]"
if {[llength $src_cells] != 54 || [llength $sink_cells] != 44} {
    error "Boundary anti-pruning gate failed"
}

set start [clock seconds]
opt_design -directive Default
puts "OPT_ELAPSED_SEC=[expr {[clock seconds] - $start}]"

set common_dcp [file join $out_dir common_postopt.dcp]
write_checkpoint -force $common_dcp
report_timing_summary -delay_type max -max_paths 100 -file [file join $out_dir common_postopt_timing_summary_max.rpt]
report_timing_summary -delay_type min -max_paths 100 -file [file join $out_dir common_postopt_timing_summary_min.rpt]
report_utilization -file [file join $out_dir common_postopt_utilization.rpt]
check_timing -verbose -file [file join $out_dir common_postopt_check_timing.rpt]
report_exceptions -file [file join $out_dir common_postopt_exceptions.rpt]

puts "COMMON_POSTOPT_DCP=$common_dcp"
puts "P9R6B_COMMON_DONE"
close_project
