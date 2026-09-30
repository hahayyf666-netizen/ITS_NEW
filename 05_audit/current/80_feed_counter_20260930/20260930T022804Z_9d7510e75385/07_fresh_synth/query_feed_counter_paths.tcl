set dcp [lindex $argv 0]
set report_dir [lindex $argv 1]
if {$dcp eq "" || $report_dir eq ""} {
    error "usage: query_feed_counter_paths.tcl <postsynth.dcp> <report_dir>"
}
open_checkpoint $dcp
puts "QUERY_DESIGN=[current_design]"

set feed_cells [get_cells -hier -filter {NAME =~ *kernel_feed_group_q_reg*}]
set count_cells [get_cells -hier -filter {NAME =~ *kernel_ctx_output_size_q_reg*}]
set fire_nets [get_nets -hier -filter {NAME =~ *kernel_input_group_fire*}]
puts "FEED_REG_COUNT=[llength $feed_cells]"
puts "FEED_REGS=$feed_cells"
puts "OUTPUT_SIZE_REG_COUNT=[llength $count_cells]"
puts "OUTPUT_SIZE_REGS=$count_cells"
puts "INPUT_FIRE_NET_COUNT=[llength $fire_nets]"
puts "INPUT_FIRE_NETS=$fire_nets"

set feed_ce [get_pins -of_objects $feed_cells -filter {REF_PIN_NAME == CE}]
set feed_d [get_pins -of_objects $feed_cells -filter {REF_PIN_NAME == D}]
set count_q [get_pins -of_objects $count_cells -filter {REF_PIN_NAME == Q}]
puts "FEED_CE_COUNT=[llength $feed_ce]"
puts "FEED_D_COUNT=[llength $feed_d]"
puts "COUNT_Q_COUNT=[llength $count_q]"

if {[llength $count_q] && [llength $feed_ce]} {
    report_timing -from $count_q -to $feed_ce -delay_type max -max_paths 20 \
        -file [file join $report_dir output_size_to_feed_counter.rpt]
}
if {[llength $fire_nets] && [llength $feed_ce]} {
    set fire_drivers [get_pins -leaf -of_objects $fire_nets -filter {DIRECTION == OUT}]
    puts "INPUT_FIRE_DRIVER_COUNT=[llength $fire_drivers]"
    puts "INPUT_FIRE_DRIVERS=$fire_drivers"
    if {[llength $fire_drivers]} {
        report_timing -from $fire_drivers -to $feed_ce -delay_type max -max_paths 20 \
            -file [file join $report_dir input_fire_to_feed_counter.rpt]
    }
}

report_timing_summary -delay_type max -max_paths 100 \
    -file [file join $report_dir query_timing_summary.rpt]
close_design
puts "FEED_COUNTER_QUERY_DONE"
