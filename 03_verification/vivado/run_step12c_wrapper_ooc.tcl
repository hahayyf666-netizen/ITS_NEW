# Step12C: frozen Step12B wrapper synthesis/implementation gate.
# The default invocation is synthesis-only.  Set STEP12C_RUN_IMPL=1 to run
# place/route after the synthesis reports have been reviewed.

set script_dir [file dirname [info script]]
set root_dir   [file join $script_dir .. ..]
set rtl_dir    [file join $root_dir 02_rtl rtl]
set wrapper    [file join $rtl_dir step12b_dct2_64_wrapper.sv]
set r4c        [file join $rtl_dir p2f_dct2_64_b1_step102.sv]
set xdc        [file join $script_dir step12c_wrapper_2ns.xdc]
set part       xcku5p-ffvb676-2-e

if {[info exists ::env(STEP12C_REPORT_DIR)] && $::env(STEP12C_REPORT_DIR) ne ""} {
    set report_dir $::env(STEP12C_REPORT_DIR)
} else {
    set report_dir [file join $root_dir 05_audit current 18 step12c_synth]
}
if {[info exists ::env(STEP12C_RUN_DIR)] && $::env(STEP12C_RUN_DIR) ne ""} {
    set run_dir $::env(STEP12C_RUN_DIR)
} else {
    set run_dir [file join $root_dir 03_verification vivado run_step12c]
}

file mkdir $report_dir
file mkdir $run_dir
set_param general.maxThreads 8

puts "STEP12C_START"
puts "ROOT=$root_dir"
puts "PART=$part"
puts "WRAPPER=$wrapper"
puts "R4C=$r4c"
puts "XDC=$xdc"
puts "PERIOD_NS=2.000"
puts "BOUNDARY_CONTRACT=registered-neighbor-zero-delay"

create_project -in_memory -part $part -force
set_property include_dirs [list $rtl_dir] [current_fileset]
add_files -norecurse -fileset sources_1 [list $wrapper $r4c]
set_property file_type {SystemVerilog} [get_files $wrapper]
set_property file_type {SystemVerilog} [get_files $r4c]
set_property top step12b_dct2_64_wrapper [current_fileset]
add_files -norecurse -fileset constrs_1 $xdc
set_property used_in_synthesis true [get_files $xdc]
set_property used_in_implementation true [get_files $xdc]
update_compile_order -fileset sources_1
read_xdc $xdc

set synth_start [clock seconds]
synth_design -top step12b_dct2_64_wrapper \
    -part $part -mode out_of_context \
    -flatten_hierarchy none -directive Default
set synth_elapsed [expr {[clock seconds] - $synth_start}]
puts "STEP12C_SYNTH_ELAPSED_SEC=$synth_elapsed"

report_utilization -file [file join $report_dir report_utilization_postsynth.rpt]
report_utilization -hierarchical -file [file join $report_dir report_hierarchy_utilization_postsynth.rpt]
report_timing_summary -delay_type max -max_paths 50 \
    -file [file join $report_dir report_timing_summary_postsynth.rpt]
report_timing_summary -delay_type min -max_paths 50 \
    -file [file join $report_dir report_timing_hold_summary_postsynth.rpt]
report_timing -delay_type max -max_paths 100 \
    -file [file join $report_dir report_timing_worst100_postsynth.rpt]
report_high_fanout_nets -max_nets 200 \
    -file [file join $report_dir report_high_fanout_postsynth.rpt]
check_timing -verbose -file [file join $report_dir report_check_timing_postsynth.rpt]
report_exceptions -file [file join $report_dir report_exceptions_postsynth.rpt]
report_methodology -file [file join $report_dir report_methodology_postsynth.rpt]
report_drc -file [file join $report_dir report_drc_postsynth.rpt]
write_checkpoint -force [file join $report_dir step12c_wrapper_postsynth.dcp]

if {![info exists ::env(STEP12C_RUN_IMPL)] || $::env(STEP12C_RUN_IMPL) ne "1"} {
    puts "STEP12C_POSTSYNTH_ONLY"
    close_project
    puts "STEP12C_DONE"
    return
}

set impl_start [clock seconds]
opt_design
place_design
phys_opt_design
route_design
set impl_elapsed [expr {[clock seconds] - $impl_start}]
puts "STEP12C_IMPL_ELAPSED_SEC=$impl_elapsed"

report_utilization -file [file join $report_dir report_utilization_postroute.rpt]
report_utilization -hierarchical -file [file join $report_dir report_hierarchy_utilization_postroute.rpt]
report_timing_summary -delay_type max -max_paths 50 \
    -file [file join $report_dir report_timing_summary_postroute.rpt]
report_timing_summary -delay_type min -max_paths 50 \
    -file [file join $report_dir report_timing_hold_summary_postroute.rpt]
report_timing -delay_type max -max_paths 100 \
    -file [file join $report_dir report_timing_worst100_postroute.rpt]
report_timing -delay_type min -max_paths 100 \
    -file [file join $report_dir report_hold_worst100_postroute.rpt]
report_high_fanout_nets -max_nets 200 \
    -file [file join $report_dir report_high_fanout_postroute.rpt]
check_timing -verbose -file [file join $report_dir report_check_timing_postroute.rpt]
report_exceptions -file [file join $report_dir report_exceptions_postroute.rpt]
report_methodology -file [file join $report_dir report_methodology_postroute.rpt]
report_drc -file [file join $report_dir report_drc_postroute.rpt]
report_power -file [file join $report_dir report_power_postroute.rpt]
write_checkpoint -force [file join $report_dir step12c_wrapper_postroute.dcp]

close_project
puts "STEP12C_DONE"
