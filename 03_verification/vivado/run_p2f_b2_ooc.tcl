# Step 11 / P2F-B2: first unmodified Vivado OOC baseline gate.
# This script measures the frozen Step 10.2 DUT only.  It deliberately makes
# no RTL, timing-exception, floorplan, or performance-optimization changes.

set SCRIPT_DIR [file normalize [file dirname [info script]]]
set B2_ROOT    [file normalize [file join $SCRIPT_DIR .. ..]]
set RTL_DIR    [file join $B2_ROOT 02_rtl rtl]
set RTL        [file join $RTL_DIR p2f_dct2_64_b1_step102.sv]
set REPORT_DIR [file join $SCRIPT_DIR reports]
set RUN_DIR    [file join $SCRIPT_DIR run]
set PART       xcku5p-ffvb676-2-e

file mkdir $REPORT_DIR
file mkdir $RUN_DIR

set_param general.maxThreads 8

puts "STEP11_B2_START"
puts "B2_ROOT=$B2_ROOT"
puts "DUT=$RTL"
puts "PART=$PART"
puts "PERIOD_NS=2.000"

# In-memory OOC project: only the DUT is added.  The two .svh files are
# included by the DUT and are found through this explicit include directory.
create_project -in_memory -part $PART -force
set_property include_dirs [list $RTL_DIR] [current_fileset]
add_files -norecurse -fileset sources_1 $RTL
set_property file_type {SystemVerilog} [get_files $RTL]
update_compile_order -fileset sources_1

cd $RTL_DIR
synth_design -top p2f_dct2_64_b1_step102 \
    -part $PART -mode out_of_context \
    -flatten_hierarchy none -directive Default

# The only timing constraint in this baseline is the required 500 MHz clock.
# No false paths, multicycle paths, uncertainty reduction, or I/O exceptions.
create_clock -name clk -period 2.000 [get_ports clk]

opt_design
place_design
phys_opt_design
route_design

# Required post-route evidence.
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $REPORT_DIR report_timing_summary_postroute.rpt]
report_timing_summary -delay_type min -max_paths 20 \
    -file [file join $REPORT_DIR report_timing_hold_summary_postroute.rpt]
report_timing -delay_type max -max_paths 20 \
    -file [file join $REPORT_DIR report_timing_worst20_postroute.rpt]
report_timing -delay_type min -max_paths 20 \
    -file [file join $REPORT_DIR report_timing_hold_worst20_postroute.rpt]
check_timing -verbose \
    -file [file join $REPORT_DIR report_timing_unconstrained_postroute.rpt]
report_utilization \
    -file [file join $REPORT_DIR report_utilization_postroute.rpt]
report_utilization -hierarchical \
    -file [file join $REPORT_DIR report_hierarchy_utilization.rpt]

# Vectorless/default-activity estimate only; no SAIF/VCD is supplied here.
report_power -file [file join $REPORT_DIR report_power_postroute.rpt]

write_checkpoint -force [file join $REPORT_DIR p2f_b2_postroute.dcp]

puts "STEP11_B2_POSTROUTE_REPORTS_WRITTEN"
close_project
puts "STEP11_B2_DONE"
