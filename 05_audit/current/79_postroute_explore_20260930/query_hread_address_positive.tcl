set candidate_dcp $::env(STEP12F_CANDIDATE_DCP)
set report_dir $::env(STEP12F_POSTROUTE_EXPLORE_DIR)
set_param general.maxThreads 4
puts "P9_HREAD_ADDRESS_POSITIVE_QUERY_START"
puts "VIVADO_VERSION=[version -short]"
puts "MAX_THREADS=[get_param general.maxThreads]"
open_checkpoint $candidate_dcp
set addr_q [get_pins -hier -quiet -regexp {.*kernel_h_rd_addr_q_reg.*/Q$}]
set ram_cells [get_cells -hier -quiet -filter {REF_NAME == RAMD64E}]
set response_d [get_pins -hier -quiet -regexp {.*kernel_h_rd_data(_tail)?_q_reg.*/D$}]
puts "HREAD_ADDR_Q_PINS=[llength $addr_q] RAMD64E_CELLS=[llength $ram_cells] RESPONSE_D_PINS=[llength $response_d]"
if {[llength $addr_q] == 0 || [llength $ram_cells] == 0 || [llength $response_d] == 0} {
    error "H-read address positive control has an empty object set"
}
report_timing -delay_type max -from $addr_q -through $ram_cells -to $response_d \
    -max_paths 20 -file [file join $report_dir hread_address_through_ramd64e_to_response.rpt]
close_design
puts "P9_HREAD_ADDRESS_POSITIVE_QUERY_DONE"
