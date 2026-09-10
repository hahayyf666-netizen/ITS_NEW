# Controlled P2F-B2 comparison flow: the same script is used for R1_CTRL and R3.
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set ROOT       [file normalize [file join $SCRIPT_DIR .. ..]]
set RTL_DIR    [file join $ROOT 02_rtl rtl]
if {[info exists ::env(P2F_B2_DUT)] && $::env(P2F_B2_DUT) ne ""} {
    set RTL [file normalize $::env(P2F_B2_DUT)]
    set RTL_DIR [file dirname $RTL]
} else {
    set RTL [file join $RTL_DIR p2f_dct2_64_b1_step102.sv]
}
set XDC        [file join $SCRIPT_DIR p2f_b2_controlled_2ns.xdc]
if {[info exists ::env(P2F_B2_REPORT_DIR)] && $::env(P2F_B2_REPORT_DIR) ne ""} {
    set REPORT_DIR [file normalize $::env(P2F_B2_REPORT_DIR)]
} else {
    set REPORT_DIR [file join $SCRIPT_DIR reports_controlled]
}
if {[info exists ::env(P2F_B2_RUN_DIR)] && $::env(P2F_B2_RUN_DIR) ne ""} {
    set RUN_DIR [file normalize $::env(P2F_B2_RUN_DIR)]
} else {
    set RUN_DIR [file join $SCRIPT_DIR run_controlled]
}
set PART       xcku5p-ffvb676-2-e

file mkdir $REPORT_DIR
file mkdir $RUN_DIR
set_param general.maxThreads 8
puts "CONTROLLED_P2F_B2_START"
puts "ROOT=$ROOT"
puts "DUT=$RTL"
puts "XDC=$XDC"
puts "PART=$PART"
puts "PERIOD_NS=2.000"

create_project -in_memory -part $PART -force
set_property include_dirs [list $RTL_DIR] [current_fileset]
add_files -norecurse -fileset sources_1 $RTL
set_property file_type {SystemVerilog} [get_files $RTL]
add_files -norecurse -fileset constrs_1 $XDC
set_property used_in_synthesis true [get_files $XDC]
set_property used_in_implementation true [get_files $XDC]
update_compile_order -fileset sources_1
read_xdc $XDC

set synth_start [clock seconds]
synth_design -top p2f_dct2_64_b1_step102 \
    -part $PART -mode out_of_context \
    -flatten_hierarchy none -directive Default
set synth_elapsed [expr {[clock seconds] - $synth_start}]
puts "CONTROLLED_SYNTH_ELAPSED_SEC=$synth_elapsed"
report_utilization -file [file join $REPORT_DIR report_utilization_postsynth.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $REPORT_DIR report_timing_summary_postsynth.rpt]
report_timing -delay_type max -max_paths 20 \
    -file [file join $REPORT_DIR report_timing_worst20_postsynth.rpt]
report_high_fanout_nets -max_nets 100 \
    -file [file join $REPORT_DIR report_high_fanout_postsynth.rpt]
write_checkpoint -force [file join $REPORT_DIR p2f_b2_controlled_postsynth.dcp]

# The caller must inspect the post-synthesis reports before launching this part.
# This script intentionally supports an explicit IMPLEMENT=1 opt-in only.
if {![info exists ::env(P2F_B2_RUN_IMPL)] || $::env(P2F_B2_RUN_IMPL) ne "1"} {
    puts "CONTROLLED_POSTSYNTH_ONLY"
    close_project
    puts "CONTROLLED_P2F_B2_DONE"
    return
}

set impl_start [clock seconds]
opt_design
place_design
phys_opt_design
route_design
set impl_elapsed [expr {[clock seconds] - $impl_start}]
puts "CONTROLLED_IMPL_ELAPSED_SEC=$impl_elapsed"
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $REPORT_DIR report_timing_summary_postroute.rpt]
report_timing_summary -delay_type min -max_paths 20 \
    -file [file join $REPORT_DIR report_timing_hold_summary_postroute.rpt]
report_timing -delay_type max -max_paths 20 \
    -file [file join $REPORT_DIR report_timing_worst20_postroute.rpt]
report_timing -delay_type min -max_paths 20 \
    -file [file join $REPORT_DIR report_timing_hold_worst20_postroute.rpt]
check_timing -verbose -file [file join $REPORT_DIR report_timing_unconstrained_postroute.rpt]
report_utilization -file [file join $REPORT_DIR report_utilization_postroute.rpt]
report_utilization -hierarchical -file [file join $REPORT_DIR report_hierarchy_utilization.rpt]
report_power -file [file join $REPORT_DIR report_power_postroute.rpt]
write_checkpoint -force [file join $REPORT_DIR p2f_b2_controlled_postroute.dcp]
close_project
puts "CONTROLLED_P2F_B2_DONE"
