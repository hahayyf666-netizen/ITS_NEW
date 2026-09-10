# Diagnostic OOC implementation for the standalone P2A DCT2-64 prototype.
# This intentionally skips opt_design: the baseline run spent its bounded
# budget in Cross Boundary and Area Optimization before placement started.
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set ROOT [file normalize [file join $SCRIPT_DIR ..]]
set RTL [file join $ROOT rtl p2a_dct2_64_p4.sv]
set REPORT [file join $ROOT vivado reports_diag]
file mkdir $REPORT

set_param general.maxThreads 8
create_project -in_memory -part xcku5p-ffvb676-2-e -force
set_property include_dirs [list [file join $ROOT rtl]] [current_fileset]
add_files -fileset sources_1 $RTL
set_property file_type {SystemVerilog} [get_files $RTL]
update_compile_order -fileset sources_1

cd [file join $ROOT rtl]
synth_design -top p2a_dct2_64_p4 -part xcku5p-ffvb676-2-e -mode out_of_context -directive AreaOptimized_high
create_clock -name clk -period 2.000 [get_ports clk]

# Diagnostic pass: do not spend unbounded time in opt_design.
place_design -directive Quick
route_design -directive Quick

report_timing_summary -delay_type max -max_paths 20 -file [file join $REPORT p2a_timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -file [file join $REPORT p2a_setup_paths.rpt]
report_timing -delay_type min -max_paths 20 -file [file join $REPORT p2a_hold_paths.rpt]
report_utilization -file [file join $REPORT p2a_utilization.rpt]
report_power -file [file join $REPORT p2a_power.rpt]
write_checkpoint -force [file join $REPORT p2a_dct2_64_diag.dcp]
close_project
