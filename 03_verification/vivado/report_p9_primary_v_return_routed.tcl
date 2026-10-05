# Read-only supplemental path census for a completed P9 primary-V routed DCP.
# This script does not alter the checkpoint, constraints, or implementation.

if {![info exists ::env(P9_ROUTED_DCP)] || $::env(P9_ROUTED_DCP) eq ""} {
    error "P9_ROUTED_DCP must name the frozen routed checkpoint"
}
if {![info exists ::env(P9_REPORT_DIR)] || $::env(P9_REPORT_DIR) eq ""} {
    error "P9_REPORT_DIR must name a fresh evidence directory"
}

set_param general.maxThreads 4
file mkdir $::env(P9_REPORT_DIR)
open_checkpoint $::env(P9_ROUTED_DCP)

puts "P9_READ_ONLY_DCP=$::env(P9_ROUTED_DCP)"
puts "P9_VIVADO=[version -short]"
puts "P9_MAX_THREADS=[get_param general.maxThreads]"

set return_q [get_pins -hier -quiet -regexp {.*primary_return_data_q_reg.*/Q$}]
set ingress_q [get_pins -hier -quiet -regexp {.*ingress_data_q_reg.*/Q$}]
set ingress_d [get_pins -hier -quiet -regexp {.*ingress_data_q_reg.*/D$}]
set input_mem_d [get_pins -hier -quiet -regexp {.*input_mem_reg.*/D$}]

puts "P9_RETURN_FIFO_Q_COUNT=[llength $return_q]"
puts "P9_P4_INGRESS_Q_COUNT=[llength $ingress_q]"
puts "P9_P4_INGRESS_D_COUNT=[llength $ingress_d]"
puts "P9_P4_INPUT_MEM_D_COUNT=[llength $input_mem_d]"

if {[llength $return_q] && [llength $ingress_d]} {
    report_timing -from $return_q -to $ingress_d -delay_type max \
        -max_paths 100 -file [file join $::env(P9_REPORT_DIR) \
        report_p9_return_fifo_to_p4_ingress.rpt]
} else {
    puts "P9_RETURN_FIFO_TO_INGRESS=NO_SOURCE_OR_DEST_OBJECT"
}

if {[llength $ingress_q] && [llength $input_mem_d]} {
    report_timing -from $ingress_q -to $input_mem_d -delay_type max \
        -max_paths 100 -file [file join $::env(P9_REPORT_DIR) \
        report_p9_p4_ingress_to_input_mem.rpt]
} else {
    puts "P9_INGRESS_TO_INPUT_MEM=NO_SOURCE_OR_DEST_OBJECT"
}

report_timing_summary -delay_type max -max_paths 100 \
    -file [file join $::env(P9_REPORT_DIR) report_p9_same_dcp_setup_summary.rpt]
report_timing_summary -delay_type min -max_paths 100 \
    -file [file join $::env(P9_REPORT_DIR) report_p9_same_dcp_hold_summary.rpt]
report_exceptions -file [file join $::env(P9_REPORT_DIR) \
    report_p9_same_dcp_exceptions.rpt]
check_timing -verbose -file [file join $::env(P9_REPORT_DIR) \
    report_p9_same_dcp_check_timing.rpt]

close_design
puts "P9_READ_ONLY_DIAGNOSTICS_DONE"
