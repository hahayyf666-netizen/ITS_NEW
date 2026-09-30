set candidate_dcp $::env(STEP12F_CANDIDATE_DCP)
set report_dir $::env(STEP12F_POSTROUTE_EXPLORE_DIR)
if {![file exists $candidate_dcp]} { error "Missing candidate DCP: $candidate_dcp" }
set_param general.maxThreads 4
puts "P9_POSTROUTE_STRUCTURE_QUERY_START"
puts "VIVADO_VERSION=[version -short]"
puts "MAX_THREADS=[get_param general.maxThreads]"
open_checkpoint $candidate_dcp

set source_q [get_pins -hier -quiet -regexp {.*src_(it_info|it_info_vld|it_data_in|it_data_addr|it_data_in_vld|it_data_end|it_data_out_req)_q_reg.*/Q$}]
set sink_d [get_pins -hier -quiet -regexp {.*sink_(it_data_in_req|it_data_out|it_data_out_vld|it_done|protocol_error)_q_reg.*/D$}]
set source_cells [get_cells -quiet -of_objects $source_q]
set sink_cells [get_cells -quiet -of_objects $sink_d]
puts "SOURCE_Q_PINS=[llength $source_q] SOURCE_FFS=[llength $source_cells]"
puts "SINK_D_PINS=[llength $sink_d] SINK_FFS=[llength $sink_cells]"

set pending_q [get_pins -hier -quiet -regexp {.*kernel_h_rd_pending_q_reg.*/Q$}]
set run_q [get_pins -hier -quiet -regexp {.*kernel_run_q_reg.*/Q$}]
set stage_q [get_pins -hier -quiet -regexp {.*kernel_stage_q_reg.*/Q$}]
set ram_cells [get_cells -hier -quiet -filter {REF_NAME == RAMD64E}]
set response_d [get_pins -hier -quiet -regexp {.*kernel_h_rd_data(_tail)?_q_reg.*/D$}]
puts "HREAD_SOURCE_PINS pending=[llength $pending_q] run=[llength $run_q] stage=[llength $stage_q]"
puts "HREAD_RAMD64E_CELLS=[llength $ram_cells] HREAD_RESPONSE_D_PINS=[llength $response_d]"
if {[llength $source_cells] != 54 || [llength $sink_cells] != 44} {
    error "Post-route boundary FF population mismatch"
}
if {[llength $pending_q] == 0 || [llength $run_q] == 0 || [llength $stage_q] == 0 ||
    [llength $ram_cells] == 0 || [llength $response_d] == 0} {
    error "H-read structural query has empty source/through/destination object set"
}

set idx 0
foreach {label src} [list pending $pending_q run $run_q stage $stage_q] {
    incr idx
    set rpt [file join $report_dir hread_${label}_through_ramd64e.rpt]
    report_timing -delay_type max -from $src -through $ram_cells -to $response_d \
        -max_paths 100 -file $rpt
    puts "HREAD_QUERY_${label}=NONEMPTY_OBJECTS; report=$rpt"
}
check_timing -verbose -file [file join $report_dir candidate_structure_check_timing.rpt]
close_design
puts "P9_POSTROUTE_STRUCTURE_QUERY_DONE"
