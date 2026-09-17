# Step12F P9-R5E: registered-neighbor integration synthesis/implementation.
# The DUT sources and all R5 arithmetic are frozen; only the enclosing
# registered-neighbor context is new in this flow.

set script_dir [file dirname [info script]]
set root_dir   [file join $script_dir .. ..]
set rtl_dir    [file join $root_dir 02_rtl rtl]
set harness    [file join $rtl_dir step12f_registered_neighbor_harness.sv]
set wrapper    [file join $rtl_dir unified_its_wrapper.sv]
set kernel     [file join $rtl_dir unified_p4_kernel.sv]
set simple_ram [file join $rtl_dir its_simple_ram.sv]
set input_bank [file join $rtl_dir its_input_cache_bank.sv]
set lfnst_engine [file join $rtl_dir bounded_lfnst_engine.sv]
set xdc        [file join $script_dir step12f_registered_neighbor_2ns.xdc]
set part       xcku5p-ffvb676-2-e

if {[info exists ::env(STEP12F_R5E_REPORT_DIR)] && $::env(STEP12F_R5E_REPORT_DIR) ne ""} {
    set report_dir $::env(STEP12F_R5E_REPORT_DIR)
} else {
    set report_dir [file join $root_dir 05_audit current 59 p9_r5e_registered_neighbor_20260917]
}
file mkdir $report_dir
set max_threads 4
if {[info exists ::env(STEP12F_MAX_THREADS)] && $::env(STEP12F_MAX_THREADS) ne ""} {
    set max_threads $::env(STEP12F_MAX_THREADS)
}
set_param general.maxThreads $max_threads
cd $root_dir

puts "P9R5E_START"
puts "VIVADO_VERSION=[version -short]"
puts "MAX_THREADS=$max_threads"
puts "PART=$part"
puts "TOP=step12f_registered_neighbor_harness"
puts "PERIOD_NS=2.000"
puts "CLOCK_UNCERTAINTY_SETUP_NS=0.000"
puts "CLOCK_UNCERTAINTY_HOLD_NS=0.000"
puts "OLD_OOC_XDC=NOT_LOADED"
puts "IMPLEMENTATION_FLOW=Default_ExtraNetDelay_high_AggressiveExplore_NoTimingRelaxation"

create_project -in_memory -part $part -force
set_property include_dirs [list $rtl_dir] [current_fileset]
add_files -norecurse -fileset sources_1 [list $simple_ram $input_bank $kernel $lfnst_engine $wrapper $harness]
foreach f [list $simple_ram $input_bank $kernel $lfnst_engine $wrapper $harness] {
    set_property file_type {SystemVerilog} [get_files $f]
}
set_property top step12f_registered_neighbor_harness [current_fileset]
add_files -norecurse -fileset constrs_1 $xdc
set_property used_in_synthesis true [get_files $xdc]
set_property used_in_implementation true [get_files $xdc]
update_compile_order -fileset sources_1
read_xdc $xdc

set synth_start [clock seconds]
synth_design -top step12f_registered_neighbor_harness \
    -part $part \
    -flatten_hierarchy none -directive Default
set synth_elapsed [expr {[clock seconds] - $synth_start}]
puts "P9R5E_SYNTH_ELAPSED_SEC=$synth_elapsed"

# Boundary anti-pruning gate.  The six source groups total 54 FF bits and the
# five sink groups total 44 FF bits; reset conditioner FFs are excluded.
set src_q [get_pins -hier -quiet -regexp {.*src_(it_info|it_info_vld|it_data_in|it_data_addr|it_data_in_vld|it_data_end|it_data_out_req)_q_reg.*/Q$}]
set sink_d [get_pins -hier -quiet -regexp {.*sink_(it_data_in_req|it_data_out|it_data_out_vld|it_done|protocol_error)_q_reg.*/D$}]
set src_cells [get_cells -quiet -of_objects $src_q]
set sink_cells [get_cells -quiet -of_objects $sink_d]
puts "SOURCE_Q_PIN_FOUND=[llength $src_q]"
puts "SINK_D_PIN_FOUND=[llength $sink_d]"
puts "SOURCE_FF_FOUND=[llength $src_cells]"
puts "SINK_FF_FOUND=[llength $sink_cells]"
if {[llength $src_cells] != 54 || [llength $sink_cells] != 44} {
    puts "BOUNDARY_ANTI_PRUNING=FAIL"
    error "Expected 54 source FF bits and 44 sink FF bits"
}
puts "BOUNDARY_ANTI_PRUNING=PASS"

write_checkpoint -force [file join $report_dir step12f_registered_neighbor_postsynth.dcp]
report_utilization -file [file join $report_dir report_utilization_postsynth.rpt]
report_utilization -hierarchical -file [file join $report_dir report_hierarchy_utilization_postsynth.rpt]
report_timing_summary -delay_type max -max_paths 100 -file [file join $report_dir report_timing_summary_postsynth.rpt]
report_timing_summary -delay_type min -max_paths 100 -file [file join $report_dir report_timing_hold_summary_postsynth.rpt]
report_timing -delay_type max -max_paths 100 -file [file join $report_dir report_timing_worst100_postsynth.rpt]
report_timing -delay_type min -max_paths 100 -file [file join $report_dir report_hold_worst100_postsynth.rpt]
check_timing -verbose -file [file join $report_dir report_check_timing_postsynth.rpt]
report_exceptions -file [file join $report_dir report_exceptions_postsynth.rpt]
report_drc -file [file join $report_dir report_drc_postsynth.rpt]
report_methodology -file [file join $report_dir report_methodology_postsynth.rpt]

set src_q [get_pins -hier -quiet -regexp {.*src_(it_info|it_info_vld|it_data_in|it_data_addr|it_data_in_vld|it_data_end|it_data_out_req)_q_reg.*/Q}]
set dut_d [get_pins -hier -quiet -regexp {.*u_dut/.*/D}]
set dut_q [get_pins -hier -quiet -regexp {.*u_dut/.*/Q}]
set sink_d [get_pins -hier -quiet -regexp {.*sink_(it_data_in_req|it_data_out|it_data_out_vld|it_done|protocol_error)_q_reg.*/D}]
if {[llength $src_q] > 0 && [llength $dut_d] > 0} {
    report_timing -from $src_q -to $dut_d -max_paths 100 -file [file join $report_dir report_paths_source_ff_to_dut.rpt]
}
if {[llength $dut_q] > 0 && [llength $dut_d] > 0} {
    report_timing -from $dut_q -to $dut_d -max_paths 100 -file [file join $report_dir report_paths_dut_internal.rpt]
}
if {[llength $dut_q] > 0 && [llength $sink_d] > 0} {
    report_timing -from $dut_q -to $sink_d -max_paths 100 -file [file join $report_dir report_paths_dut_to_sink_ff.rpt]
}

set impl_start [clock seconds]
opt_design -directive Default
place_design -directive ExtraNetDelay_high
phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation
set impl_elapsed [expr {[clock seconds] - $impl_start}]
puts "P9R5E_IMPL_ELAPSED_SEC=$impl_elapsed"

report_route_status -file [file join $report_dir report_route_status_postroute.rpt]
report_utilization -file [file join $report_dir report_utilization_postroute.rpt]
report_utilization -hierarchical -file [file join $report_dir report_hierarchy_utilization_postroute.rpt]
report_timing_summary -delay_type max -max_paths 100 -file [file join $report_dir report_timing_summary_postroute.rpt]
report_timing_summary -delay_type min -max_paths 100 -file [file join $report_dir report_timing_hold_summary_postroute.rpt]
report_timing -delay_type max -max_paths 100 -file [file join $report_dir report_timing_worst100_postroute.rpt]
report_timing -delay_type min -max_paths 100 -file [file join $report_dir report_hold_worst100_postroute.rpt]
report_high_fanout_nets -max_nets 200 -file [file join $report_dir report_high_fanout_postroute.rpt]
check_timing -verbose -file [file join $report_dir report_check_timing_postroute.rpt]
report_exceptions -file [file join $report_dir report_exceptions_postroute.rpt]
report_drc -file [file join $report_dir report_drc_postroute.rpt]
report_methodology -file [file join $report_dir report_methodology_postroute.rpt]
report_power -file [file join $report_dir report_power_postroute.rpt]
write_checkpoint -force [file join $report_dir step12f_registered_neighbor_postroute.dcp]

close_project
puts "P9R5E_DONE"

