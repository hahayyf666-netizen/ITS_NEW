set root [lindex $argv 0]
set out [lindex $argv 1]
set rtl [file join $root 02_rtl rtl]
set viv [file join $root 03_verification vivado]
set part xcku5p-ffvb676-2-e
if {$root eq "" || $out eq ""} { error "usage: synth_registered_neighbor_only.tcl <root> <out>" }
file mkdir $out
set_param general.maxThreads 4
create_project -in_memory -part $part -force
set_property include_dirs [list $rtl] [current_fileset]
set files [list \
    [file join $rtl its_simple_ram.sv] \
    [file join $rtl its_input_cache_bank.sv] \
    [file join $rtl unified_p4_kernel.sv] \
    [file join $rtl bounded_lfnst_engine.sv] \
    [file join $rtl unified_its_wrapper.sv] \
    [file join $rtl step12f_registered_neighbor_harness.sv]]
add_files -norecurse -fileset sources_1 $files
foreach f $files { set_property file_type SystemVerilog [get_files $f] }
set_property top step12f_registered_neighbor_harness [current_fileset]
read_xdc [file join $viv step12f_registered_neighbor_2ns.xdc]
puts "TOOL=[version -short]"
puts "PART=$part"
puts "THREADS=[get_param general.maxThreads]"
puts "TOP=step12f_registered_neighbor_harness"
puts "RTL_DIR=$rtl"

synth_design -top step12f_registered_neighbor_harness -part $part \
    -flatten_hierarchy none -directive Default

set src_q [get_pins -hier -quiet -regexp {.*kernel_ctx_output_size_q_reg.*/Q$}]
set feed_cells [get_cells -hier -quiet -regexp {.*kernel_feed_group_q_reg.*}]
set feed_ce [get_pins -of_objects $feed_cells -filter {REF_PIN_NAME == CE}]
set feed_d [get_pins -of_objects $feed_cells -filter {REF_PIN_NAME == D}]
set output_group_nets [get_nets -hier -quiet -filter {NAME =~ *output_group_count*}]
puts "OUTPUT_SIZE_Q_COUNT=[llength $src_q]"
puts "FEED_REG_COUNT=[llength $feed_cells]"
puts "FEED_CE_COUNT=[llength $feed_ce]"
puts "FEED_D_COUNT=[llength $feed_d]"
puts "OUTPUT_GROUP_COUNT_NETS=[llength $output_group_nets]"

if {[llength $src_q] && [llength $feed_ce]} {
    set src_to_ce [get_timing_paths -from $src_q -to $feed_ce \
        -delay_type max -max_paths 20 -nworst 1]
    puts "OUTPUT_SIZE_TO_FEED_CE_PATHS=[llength $src_to_ce]"
    report_timing -from $src_q -to $feed_ce -delay_type max -max_paths 20 \
        -file [file join $out output_size_to_feed_ce.rpt]
}
if {[llength $feed_ce]} {
    report_timing -to $feed_ce -delay_type max -max_paths 20 \
        -file [file join $out worst_to_feed_ce.rpt]
}
if {[llength $feed_d]} {
    report_timing -to $feed_d -delay_type max -max_paths 20 \
        -file [file join $out worst_to_feed_d.rpt]
}
report_timing_summary -delay_type max -max_paths 100 \
    -file [file join $out registered_neighbor_postsynth_timing.rpt]
report_utilization -file [file join $out registered_neighbor_postsynth_utilization.rpt]
write_checkpoint -force [file join $out registered_neighbor_postsynth.dcp]
close_project
puts "REGISTERED_NEIGHBOR_SYNTH_ONLY_DONE"
