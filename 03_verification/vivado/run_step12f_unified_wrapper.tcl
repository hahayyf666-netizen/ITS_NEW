# Step12F: fresh synthesis/implementation baseline for the new unified ITS
# functional wrapper.  No v3.5-18 DCP or timing result is reused.

set script_dir [file dirname [info script]]
set root_dir   [file join $script_dir .. ..]
set rtl_dir    [file join $root_dir 02_rtl rtl]
set wrapper    [file join $rtl_dir unified_its_wrapper.sv]
set kernel     [file join $rtl_dir unified_p4_kernel.sv]
set simple_ram [file join $rtl_dir its_simple_ram.sv]
set input_bank [file join $rtl_dir its_input_cache_bank.sv]
set lfnst_engine [file join $rtl_dir bounded_lfnst_engine.sv]
set xdc        [file join $script_dir step12f_unified_wrapper_2ns.xdc]
set part       xcku5p-ffvb676-2-e

if {[info exists ::env(STEP12F_REPORT_DIR)] && $::env(STEP12F_REPORT_DIR) ne ""} {
    set report_dir $::env(STEP12F_REPORT_DIR)
} else {
    set report_dir [file join $root_dir 05_audit current 28 step12f_physical]
}
if {[info exists ::env(STEP12F_RUN_DIR)] && $::env(STEP12F_RUN_DIR) ne ""} {
    set run_dir $::env(STEP12F_RUN_DIR)
} else {
    set run_dir [file join $root_dir 03_verification vivado run_step12f_unified]
}

file mkdir $report_dir
file mkdir $run_dir
set max_threads 4
if {[info exists ::env(STEP12F_MAX_THREADS)] && $::env(STEP12F_MAX_THREADS) ne ""} {
    set max_threads $::env(STEP12F_MAX_THREADS)
}
set_param general.maxThreads $max_threads
cd $root_dir

puts "STEP12F_START"
puts "ROOT=$root_dir"
puts "PART=$part"
puts "TOP=unified_its_wrapper"
puts "WRAPPER=$wrapper"
puts "KERNEL=$kernel"
puts "SIMPLE_RAM=$simple_ram"
puts "INPUT_BANK=$input_bank"
puts "LFNST_ENGINE=$lfnst_engine"
puts "XDC=$xdc"
puts "PERIOD_NS=2.000"
puts "BOUNDARY_CONTRACT=registered-neighbor-zero-delay"
puts "MAX_THREADS=$max_threads"
puts "IMPLEMENTATION_FLOW=opt_Explore_place_Explore_physopt_Explore_route_Explore"

create_project -in_memory -part $part -force
set_property include_dirs [list $rtl_dir] [current_fileset]
add_files -norecurse -fileset sources_1 [list $simple_ram $input_bank $kernel $lfnst_engine $wrapper]
set_property file_type {SystemVerilog} [get_files $simple_ram]
set_property file_type {SystemVerilog} [get_files $input_bank]
set_property file_type {SystemVerilog} [get_files $kernel]
set_property file_type {SystemVerilog} [get_files $lfnst_engine]
set_property file_type {SystemVerilog} [get_files $wrapper]
set_property top unified_its_wrapper [current_fileset]
add_files -norecurse -fileset constrs_1 $xdc
set_property used_in_synthesis true [get_files $xdc]
set_property used_in_implementation true [get_files $xdc]
update_compile_order -fileset sources_1
read_xdc $xdc

set synth_start [clock seconds]
synth_design -top unified_its_wrapper \
    -part $part -mode out_of_context \
    -flatten_hierarchy none -directive Default
set synth_elapsed [expr {[clock seconds] - $synth_start}]
puts "STEP12F_SYNTH_ELAPSED_SEC=$synth_elapsed"

report_utilization -file [file join $report_dir report_utilization_postsynth.rpt]
report_utilization -hierarchical -file [file join $report_dir report_hierarchy_utilization_postsynth.rpt]
report_timing_summary -delay_type max -max_paths 100 \
    -file [file join $report_dir report_timing_summary_postsynth.rpt]
report_timing_summary -delay_type min -max_paths 100 \
    -file [file join $report_dir report_timing_hold_summary_postsynth.rpt]
report_timing -delay_type max -max_paths 100 \
    -file [file join $report_dir report_timing_worst100_postsynth.rpt]
report_timing -delay_type min -max_paths 100 \
    -file [file join $report_dir report_hold_worst100_postsynth.rpt]
report_high_fanout_nets -max_nets 200 \
    -file [file join $report_dir report_high_fanout_postsynth.rpt]
check_timing -verbose -file [file join $report_dir report_check_timing_postsynth.rpt]
report_exceptions -file [file join $report_dir report_exceptions_postsynth.rpt]
report_methodology -file [file join $report_dir report_methodology_postsynth.rpt]
report_drc -file [file join $report_dir report_drc_postsynth.rpt]
write_checkpoint -force [file join $report_dir step12f_unified_wrapper_postsynth.dcp]

if {![info exists ::env(STEP12F_RUN_IMPL)] || $::env(STEP12F_RUN_IMPL) ne "1"} {
    puts "STEP12F_POSTSYNTH_ONLY"
    close_project
    puts "STEP12F_DONE"
    return
}

set impl_start [clock seconds]
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore
set impl_elapsed [expr {[clock seconds] - $impl_start}]
puts "STEP12F_IMPL_ELAPSED_SEC=$impl_elapsed"

report_utilization -file [file join $report_dir report_utilization_postroute.rpt]
report_utilization -hierarchical -file [file join $report_dir report_hierarchy_utilization_postroute.rpt]
report_timing_summary -delay_type max -max_paths 100 \
    -file [file join $report_dir report_timing_summary_postroute.rpt]
report_timing_summary -delay_type min -max_paths 100 \
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
write_checkpoint -force [file join $report_dir step12f_unified_wrapper_postroute.dcp]

close_project
puts "STEP12F_DONE"
