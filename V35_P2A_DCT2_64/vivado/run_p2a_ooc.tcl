# P2A DCT2-64 standalone OOC implementation script.
# Execute with Vivado in batch mode from this directory when Vivado is available.
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set ROOT [file normalize [file join $SCRIPT_DIR ..]]
set RTL [file join $ROOT rtl p2a_dct2_64_p4.sv]
set COEFF [file join $ROOT rtl dct2_64_coeff.hex]
set REPORT [file join $ROOT vivado reports]
file mkdir $REPORT

set_param general.maxThreads 8
create_project -in_memory -part xcku5p-ffvb676-2-e -force
set_property include_dirs [list [file join $ROOT rtl]] [current_fileset]
add_files -fileset sources_1 $RTL
set_property file_type {SystemVerilog} [get_files $RTL]
update_compile_order -fileset sources_1

# Keep the relative $readmemh filename resolvable during synthesis.
cd [file join $ROOT rtl]
# This is a reference-array feasibility run.  Preserve RTL hierarchy and use
# the runtime-oriented synthesis directive so Vivado does not spend an
# unbounded amount of time on cross-boundary area rewriting of 256 DSPs.
# The generated netlist is still the actual post-route implementation of the
# supplied P2A RTL; no arithmetic is removed or hard-wired for the testbench.
synth_design -top p2a_dct2_64_p4 -part xcku5p-ffvb676-2-e -mode out_of_context \
    -flatten_hierarchy none -directive RuntimeOptimized
create_clock -name clk -period 2.000 [get_ports clk]
# opt_design's Cross Boundary and Area Optimization is prohibitively slow for
# this deliberately wide 256-lane reference array.  The P2A gate is measured
# on the actual post-route result, so use a bounded Quick implementation pass
# here rather than silently timing out before placement starts.
place_design -directive Quick
route_design -directive Quick

report_timing_summary -delay_type max -max_paths 20 -file [file join $REPORT p2a_timing_summary.rpt]
report_timing_summary -delay_type min -max_paths 20 -file [file join $REPORT p2a_hold_summary.rpt]
report_timing -delay_type max -max_paths 20 -file [file join $REPORT p2a_setup_paths.rpt]
report_timing -delay_type min -max_paths 20 -file [file join $REPORT p2a_hold_paths.rpt]
report_utilization -file [file join $REPORT p2a_utilization.rpt]
report_power -file [file join $REPORT p2a_power.rpt]
write_checkpoint -force [file join $REPORT p2a_dct2_64_ooc.dcp]

close_project
