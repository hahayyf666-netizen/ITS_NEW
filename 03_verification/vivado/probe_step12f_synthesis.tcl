# Diagnostic OOC synthesis: real modules, real coefficient files, no stubs.
# Each invocation starts from source. This is not an implementation signoff.
if {$argc < 2} { error "usage: probe_step12f_synthesis.tcl TOP OUTPUT_DIR ?RTL_DIR? ?DIRECTIVE?" }
set top [lindex $argv 0]
set report_dir [file normalize [lindex $argv 1]]
set root_dir [file normalize [file join [file dirname [info script]] .. ..]]
set rtl_dir [file join $root_dir 02_rtl rtl]
if {$argc > 2} { set rtl_dir [file normalize [lindex $argv 2]] }
set directive Default
if {$argc > 3} { set directive [lindex $argv 3] }
if {$directive ni {Default RuntimeOptimized}} { error "unsupported diagnostic directive" }
set allowed {its_simple_ram its_input_cache_bank bounded_lfnst_engine unified_p4_kernel unified_its_wrapper}
if {[lsearch -exact $allowed $top] < 0} { error "unsupported diagnostic top $top" }
file mkdir $report_dir
cd $root_dir
set_param general.maxThreads 4
create_project -in_memory -part xcku5p-ffvb676-2-e
foreach name {its_simple_ram its_input_cache_bank bounded_lfnst_engine unified_p4_kernel unified_its_wrapper} {
    set src [file join $rtl_dir ${name}.sv]
    if {![file exists $src]} { set src [file join $root_dir 02_rtl rtl ${name}.sv] }
    read_verilog -sv $src
}
if {$top eq "unified_its_wrapper"} {
    read_xdc [file join $root_dir 03_verification vivado step12f_unified_wrapper_2ns.xdc]
} else {
    read_xdc [file join $root_dir 03_verification vivado step12f_module_probe_2ns.xdc]
}
puts "PROBE_START top=$top rtl_dir=$rtl_dir directive=$directive at=[clock format [clock seconds]]"
set t0 [clock seconds]
synth_design -top $top -part xcku5p-ffvb676-2-e -mode out_of_context -flatten_hierarchy none -directive $directive
puts "PROBE_SYNTH_DONE top=$top elapsed_seconds=[expr {[clock seconds] - $t0}]"
# Save the completed synthesis before running any potentially expensive report.
write_checkpoint -force [file join $report_dir postsynth.dcp]
report_utilization -file [file join $report_dir utilization.rpt]
report_utilization -hierarchical -file [file join $report_dir hierarchy.rpt]
report_timing_summary -file [file join $report_dir timing.rpt]
check_timing -verbose -file [file join $report_dir check_timing.rpt]
puts "PROBE_DONE top=$top"
close_project
