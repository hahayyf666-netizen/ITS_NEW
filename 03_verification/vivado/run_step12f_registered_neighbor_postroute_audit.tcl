# Step12F P9-R5E read-only audit of a completed registered-neighbor route.
# No synthesis, optimization, placement, routing, or constraint changes are
# permitted here.  The DCP already contains the frozen harness constraints.

set dcp_path $::env(STEP12F_R5E_POSTROUTE_DCP)
set out_dir  $::env(STEP12F_R5E_AUDIT_DIR)
file mkdir $out_dir

open_checkpoint $dcp_path

set src_q [get_pins -hier -quiet -regexp {.*src_(it_info|it_info_vld|it_data_in|it_data_addr|it_data_in_vld|it_data_end|it_data_out_req)_q_reg.*/Q$}]
set dut_q [get_pins -hier -quiet -regexp {.*u_dut/.*/Q$}]
set dut_d [get_pins -hier -quiet -regexp {.*u_dut/.*/D$}]
set sink_d [get_pins -hier -quiet -regexp {.*sink_(it_data_in_req|it_data_out|it_data_out_vld|it_done|protocol_error)_q_reg.*/D$}]

puts "POSTROUTE_SOURCE_Q_PIN_FOUND=[llength $src_q]"
puts "POSTROUTE_DUT_Q_PIN_FOUND=[llength $dut_q]"
puts "POSTROUTE_DUT_D_PIN_FOUND=[llength $dut_d]"
puts "POSTROUTE_SINK_D_PIN_FOUND=[llength $sink_d]"

if {[llength $src_q] > 0 && [llength $dut_d] > 0} {
    report_timing -from $src_q -to $dut_d -delay_type max -max_paths 100 \
        -file [file join $out_dir report_paths_source_ff_to_dut_postroute.rpt]
}
if {[llength $dut_q] > 0 && [llength $dut_d] > 0} {
    report_timing -from $dut_q -to $dut_d -delay_type max -max_paths 100 \
        -file [file join $out_dir report_paths_dut_internal_postroute.rpt]
}
if {[llength $dut_q] > 0 && [llength $sink_d] > 0} {
    report_timing -from $dut_q -to $sink_d -delay_type max -max_paths 100 \
        -file [file join $out_dir report_paths_dut_to_sink_ff_postroute.rpt]
}

# Preserve a direct, routed structural query for the R5 H-read gate.  The
# query is intentionally diagnostic: no-path means no selected path object in
# this routed DCP, while a valid path is emitted for the registered-address
# control.  It does not alter the netlist.
set h_resp_d [get_pins -hier -quiet -regexp {.*kernel_h_rd_(data|raw_tail_data)_q_reg.*/D$}]
set h_pending_q [get_pins -hier -quiet -regexp {.*kernel_h_rd_pending_q_reg.*/Q$}]
set h_run_q [get_pins -hier -quiet -regexp {.*kernel_run_q_reg.*/Q$}]
set h_stage_q [get_pins -hier -quiet -regexp {.*kernel_stage_q_reg.*/Q$}]
set h_addr_q [get_pins -hier -quiet -regexp {.*kernel_h_rd_addr_q_reg.*/Q$}]
# In the implemented DCP primitive instances are named RAMA/RAMB/... and
# carry REF_NAME=RAMD64E; do not rely on the primitive type appearing in the
# hierarchical instance path.
set ram_cells [get_cells -hier -quiet -filter {REF_NAME =~ RAMD64E*}]
set ram_addr_pins {}
foreach ram_cell $ram_cells {
    foreach ram_pin [get_pins -of_objects $ram_cell -quiet] {
        if {[regexp {^RADR[0-5]$} [get_property REF_PIN_NAME $ram_pin]]} {
            lappend ram_addr_pins $ram_pin
        }
    }
}
puts "H_GATE_PENDING_Q_FOUND=[llength $h_pending_q]"
puts "H_GATE_RUN_Q_FOUND=[llength $h_run_q]"
puts "H_GATE_STAGE_Q_FOUND=[llength $h_stage_q]"
puts "H_GATE_ADDR_Q_FOUND=[llength $h_addr_q]"
puts "H_GATE_RESPONSE_D_FOUND=[llength $h_resp_d]"
puts "H_GATE_RAM_ADDR_PIN_FOUND=[llength $ram_addr_pins]"
if {[llength $h_resp_d] > 0 && [llength $ram_addr_pins] > 0 && [llength $h_pending_q] > 0} {
    report_timing -from $h_pending_q -through $ram_addr_pins -to $h_resp_d -delay_type max -max_paths 20 \
        -file [file join $out_dir report_h_gate_pending_through_ram_postroute.rpt]
}
if {[llength $h_resp_d] > 0 && [llength $ram_addr_pins] > 0 && [llength $h_run_q] > 0} {
    report_timing -from $h_run_q -through $ram_addr_pins -to $h_resp_d -delay_type max -max_paths 20 \
        -file [file join $out_dir report_h_gate_run_through_ram_postroute.rpt]
}
if {[llength $h_resp_d] > 0 && [llength $ram_addr_pins] > 0 && [llength $h_stage_q] > 0} {
    report_timing -from $h_stage_q -through $ram_addr_pins -to $h_resp_d -delay_type max -max_paths 20 \
        -file [file join $out_dir report_h_gate_stage_through_ram_postroute.rpt]
}
if {[llength $h_resp_d] > 0 && [llength $ram_addr_pins] > 0 && [llength $h_addr_q] > 0} {
    report_timing -from $h_addr_q -through $ram_addr_pins -to $h_resp_d -delay_type max -max_paths 20 \
        -file [file join $out_dir report_h_gate_registered_addr_through_ram_postroute.rpt]
}
if {[llength $h_resp_d] > 0 && [llength $h_pending_q] > 0} {
    report_timing -from $h_pending_q -to $h_resp_d -delay_type max -max_paths 20 \
        -file [file join $out_dir report_h_gate_pending_to_response_postroute.rpt]
}
if {[llength $h_resp_d] > 0 && [llength $h_run_q] > 0} {
    report_timing -from $h_run_q -to $h_resp_d -delay_type max -max_paths 20 \
        -file [file join $out_dir report_h_gate_run_to_response_postroute.rpt]
}
if {[llength $h_resp_d] > 0 && [llength $h_stage_q] > 0} {
    report_timing -from $h_stage_q -to $h_resp_d -delay_type max -max_paths 20 \
        -file [file join $out_dir report_h_gate_stage_to_response_postroute.rpt]
}
if {[llength $h_resp_d] > 0 && [llength $h_addr_q] > 0} {
    report_timing -from $h_addr_q -to $h_resp_d -delay_type max -max_paths 20 \
        -file [file join $out_dir report_h_gate_registered_addr_to_response_postroute.rpt]
}

check_timing -verbose -file [file join $out_dir report_check_timing_postroute_audit.rpt]
report_exceptions -file [file join $out_dir report_exceptions_postroute_audit.rpt]
close_project
puts "P9R5E_POSTROUTE_AUDIT_DONE"

