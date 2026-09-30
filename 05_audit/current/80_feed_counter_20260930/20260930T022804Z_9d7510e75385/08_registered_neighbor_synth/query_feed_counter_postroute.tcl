set dcp [lindex $argv 0]
set out [lindex $argv 1]
if {$dcp eq "" || $out eq ""} { error "usage: query_feed_counter_postroute.tcl <routed.dcp> <out>" }
file mkdir $out
set_param general.maxThreads 4
puts "TOOL=[version -short]"
puts "THREADS=[get_param general.maxThreads]"
open_checkpoint $dcp
puts "DESIGN=[current_design]"
set size_q [get_pins -hier -quiet -regexp {.*kernel_ctx_output_size_q_reg.*/Q$}]
set feed_ce [get_pins -hier -quiet -regexp {.*kernel_feed_group_q_reg.*/CE$}]
set feed_d [get_pins -hier -quiet -regexp {.*kernel_feed_group_q_reg.*/D$}]
puts "OUTPUT_SIZE_Q=[llength $size_q] FEED_CE=[llength $feed_ce] FEED_D=[llength $feed_d]"
if {[llength $size_q] == 0 || [llength $feed_ce] == 0 || [llength $feed_d] == 0} {
    error "feed counter source/destination objects missing"
}
report_timing -delay_type max -from $size_q -to $feed_ce -max_paths 100 \
    -input_pins -nets -file [file join $out postroute_output_size_to_feed_ce.rpt]
report_timing -delay_type max -to $feed_ce -max_paths 100 \
    -input_pins -nets -file [file join $out postroute_worst_to_feed_ce.rpt]
report_timing -delay_type max -from $size_q -to $feed_d -max_paths 100 \
    -input_pins -nets -file [file join $out postroute_output_size_to_feed_d.rpt]
check_timing -verbose -file [file join $out postroute_target_check_timing.rpt]
close_design
puts "FEED_COUNTER_QUERY_DONE"
