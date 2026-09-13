# Step12C Boundary-PRE: implementation-only registered-neighbor experiment.
# This script does not edit or synthesize a modified DUT.  It instantiates the
# frozen wrapper below a source/sink register harness, then reports the actual
# routed boundary paths and complete timing summary.

set script_dir [file dirname [info script]]
set root_dir   [file join $script_dir .. ..]
set rtl_dir    [file join $root_dir 02_rtl rtl]
set pre_dir    [file join $script_dir boundary_pre]
set wrapper    [file join $rtl_dir step12b_dct2_64_wrapper.sv]
set r4c        [file join $rtl_dir p2f_dct2_64_b1_step102.sv]
set harness    [file join $pre_dir step12c_registered_neighbor_harness.sv]
set xdc        [file join $pre_dir step12c_registered_neighbor_harness.xdc]
set part       xcku5p-ffvb676-2-e

if {[info exists ::env(STEP12C_BOUNDARY_REPORT_DIR)] && $::env(STEP12C_BOUNDARY_REPORT_DIR) ne ""} {
    set report_dir $::env(STEP12C_BOUNDARY_REPORT_DIR)
} else {
    set report_dir [file join $root_dir 05_audit current 22 boundary_pre_core2]
}
if {[info exists ::env(STEP12C_BOUNDARY_RUN_DIR)] && $::env(STEP12C_BOUNDARY_RUN_DIR) ne ""} {
    set run_dir $::env(STEP12C_BOUNDARY_RUN_DIR)
} else {
    set run_dir [file join $root_dir 03_verification vivado run_step12c_boundary_pre_core2]
}

file mkdir $report_dir
file mkdir $run_dir
set_param general.maxThreads 4

puts "STEP12C_BOUNDARY_PRE_START"
puts "ROOT=$root_dir"
puts "PART=$part"
puts "HARNESS=$harness"
puts "WRAPPER=$wrapper"
puts "R4C=$r4c"
puts "XDC=$xdc"
puts "PERIOD_NS=2.000"

create_project -in_memory -part $part -force
set_property include_dirs [list $rtl_dir] [current_fileset]
add_files -norecurse -fileset sources_1 [list $harness $wrapper $r4c]
set_property file_type {SystemVerilog} [get_files $harness]
set_property file_type {SystemVerilog} [get_files $wrapper]
set_property file_type {SystemVerilog} [get_files $r4c]
set_property top step12c_registered_neighbor_harness [current_fileset]
add_files -norecurse -fileset constrs_1 $xdc
set_property used_in_synthesis true [get_files $xdc]
set_property used_in_implementation true [get_files $xdc]
update_compile_order -fileset sources_1
read_xdc $xdc

synth_design -top step12c_registered_neighbor_harness \
    -part $part -flatten_hierarchy none -directive Default
report_utilization -file [file join $report_dir report_utilization_postsynth.rpt]
report_timing_summary -delay_type max -max_paths 50 \
    -file [file join $report_dir report_timing_summary_postsynth.rpt]
report_timing_summary -delay_type min -max_paths 50 \
    -file [file join $report_dir report_timing_hold_summary_postsynth.rpt]
check_timing -verbose -file [file join $report_dir report_check_timing_postsynth.rpt]
report_exceptions -file [file join $report_dir report_exceptions_postsynth.rpt]
report_methodology -file [file join $report_dir report_methodology_postsynth.rpt]
write_checkpoint -force [file join $report_dir step12c_boundary_pre_postsynth.dcp]

if {[info exists ::env(STEP12C_BOUNDARY_SYNTH_ONLY)] && $::env(STEP12C_BOUNDARY_SYNTH_ONLY) eq "1"} {
    close_project
    puts "STEP12C_BOUNDARY_PRE_SYNTH_ONLY_DONE"
    return
}

opt_design
place_design
phys_opt_design
route_design

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
proc safe_report_timing {args out_file} {
    # Optional directional reports must never prevent the complete boundary
    # checkpoint from being written when synthesis naming changes.
    set rc [catch {eval report_timing $args -file $out_file} msg]
    if {$rc != 0} {
        set fh [open $out_file w]
        puts $fh "OPTIONAL_BOUNDARY_REPORT_UNAVAILABLE"
        puts $fh $msg
        close $fh
    }
}
set src_qs [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *src_*}]
set dut_ds [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *u_dut*}]
set sink_ds [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *sink_*}]
set dut_qs [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *u_dut*}]
if {[llength $src_qs] > 0 && [llength $dut_ds] > 0} {
    safe_report_timing [list -from $src_qs -to $dut_ds -max_paths 100 -delay_type max] \
        [file join $report_dir report_boundary_setup_paths.rpt]
    safe_report_timing [list -from $src_qs -to $dut_ds -max_paths 100 -delay_type min] \
        [file join $report_dir report_boundary_hold_paths.rpt]
} else {
    set fh [open [file join $report_dir report_boundary_setup_paths.rpt] w]
    puts $fh "OPTIONAL_BOUNDARY_REPORT_UNAVAILABLE: source/DUT pins not found"
    close $fh
    file copy -force [file join $report_dir report_boundary_setup_paths.rpt] \
        [file join $report_dir report_boundary_hold_paths.rpt]
}
if {[llength $dut_qs] > 0 && [llength $sink_ds] > 0} {
    safe_report_timing [list -from $dut_qs -to $sink_ds -max_paths 100 -delay_type max] \
        [file join $report_dir report_boundary_output_paths.rpt]
} else {
    set fh [open [file join $report_dir report_boundary_output_paths.rpt] w]
    puts $fh "OPTIONAL_BOUNDARY_REPORT_UNAVAILABLE: DUT/sink pins not found"
    close $fh
}
write_checkpoint -force [file join $report_dir step12c_boundary_pre_postroute.dcp]

close_project
puts "STEP12C_BOUNDARY_PRE_DONE"
