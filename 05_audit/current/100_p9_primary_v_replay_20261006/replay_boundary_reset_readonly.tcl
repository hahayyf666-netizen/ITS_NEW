# Supplemental read-only checks on the independently generated routed DCP.
# No optimization, constraints, placement, routing, or checkpoint write.
set_param general.maxThreads 4
open_checkpoint $::env(P9_ROUTED_DCP)
set out $::env(P9_REPORT_DIR)
file mkdir $out
puts "REPLAY_CHECK_TOOL=[version -short]"
set src_q [get_pins -hier -quiet -regexp {.*src_(it_info|it_info_vld|it_data_in|it_data_addr|it_data_in_vld|it_data_end|it_data_out_req)_q_reg.*/Q$}]
set sink_d [get_pins -hier -quiet -regexp {.*sink_(it_data_in_req|it_data_out|it_data_out_vld|it_done|protocol_error)_q_reg.*/D$}]
set src_cells [get_cells -quiet -of_objects $src_q]
set sink_cells [get_cells -quiet -of_objects $sink_d]
puts "POSTROUTE_SOURCE_FF_FOUND=[llength $src_cells]"
puts "POSTROUTE_SINK_FF_FOUND=[llength $sink_cells]"
if {[llength $src_cells] != 54 || [llength $sink_cells] != 44} {
    error "Postroute registered-neighbor boundary count mismatch"
}
set dut_q [get_pins -hier -quiet -regexp {.*u_dut/.*/Q$}]
set dut_d [get_pins -hier -quiet -regexp {.*u_dut/.*/D$}]
report_timing -from $src_q -to $dut_d -delay_type max -max_paths 100 -file [file join $out source_to_dut_postroute.rpt]
report_timing -from $dut_q -to $dut_d -delay_type max -max_paths 100 -file [file join $out dut_internal_postroute.rpt]
report_timing -from $dut_q -to $sink_d -delay_type max -max_paths 100 -file [file join $out dut_to_sink_postroute.rpt]
set async_pins [get_pins -hier -quiet -regexp {.*\/(CLR|PRE)$}]
puts "ASYNC_RESET_ENDPOINT_PINS=[llength $async_pins]"
if {[llength $async_pins]} {
    foreach kind {max min} {
        set paths [get_timing_paths -to $async_pins -delay_type $kind -max_paths 20]
        puts "ASYNC_RESET_${kind}_PATH_COUNT=[llength $paths]"
        if {[llength $paths]} {
            puts "ASYNC_RESET_${kind}_WORST_SLACK=[get_property SLACK [lindex $paths 0]]"
            report_timing -of_objects $paths -file [file join $out reset_${kind}_postroute.rpt]
        }
    }
}
close_design
puts "REPLAY_BOUNDARY_RESET_READONLY_DONE"
