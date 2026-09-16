if {$argc < 2} {
    puts stderr "Usage: vivado -mode batch -source run_read_command_targeted.tcl -- <postroute.dcp> <out_dir>"
    exit 2
}

set dcp [lindex $argv 0]
set out_dir [lindex $argv 1]
file mkdir $out_dir
if {![file exists $dcp]} { error "Missing DCP: $dcp" }
open_checkpoint $dcp

proc count_obj {objs} { return [llength $objs] }
proc report_safe {arglist} {
    set rc [catch {report_timing {*}$arglist} msg]
    return [list $rc $msg]
}

set cmd_addr_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *rd_cmd_addr_q_reg*}]
set cmd_addr_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *rd_cmd_addr_q_reg*}]
set cmd_valid_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *rd_cmd_valid_q_reg*}]
set live_ctrl_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && (NAME =~ *compute_slot_q_reg* || NAME =~ *kernel_stage_q_reg* || NAME =~ *lfnst_case_q_reg* || NAME =~ *kernel_rd_req_pending_q_reg*)}]
set live_addr_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *input_rd_addr*}]
set lfnst_resp_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *lfnst_mem_resp_data_q_reg*}]
set ramd [get_cells -hier -quiet -filter {REF_NAME == RAMD64E}]
set ram_addr_pins [get_pins -of_objects $ramd -quiet -filter {REF_PIN_NAME =~ ADDR*}]

set out_file [file join $out_dir P9_SECOND_READ_COMMAND_TARGETED.rpt]
set f [open $out_file w]
puts $f "Step12F-P9 second-round atomic elastic read-command targeted qualification"
puts $f "DCP=$dcp"
puts $f "command_addr_q_count=[count_obj $cmd_addr_q] command_addr_d_count=[count_obj $cmd_addr_d] command_valid_q_count=[count_obj $cmd_valid_q]"
puts $f "live_control_q_count=[count_obj $live_ctrl_q] live_addr_q_count=[count_obj $live_addr_q] lfnst_response_d_count=[count_obj $lfnst_resp_d] ramd64e_count=[count_obj $ramd] ram_addr_pin_count=[count_obj $ram_addr_pins]"

puts $f "\n=== live control -> LFNST response (old direct cone) ==="
puts $f "[join [report_safe [list -from $live_ctrl_q -to $lfnst_resp_d -delay_type max -max_paths 20 -nworst 1 -path_type full -file $out_file -append]] { }]"

puts $f "\n=== live control -> physical command D (allowed pre-boundary cone) ==="
puts $f "[join [report_safe [list -from $live_ctrl_q -to $cmd_addr_d -delay_type max -max_paths 20 -nworst 1 -path_type full -file $out_file -append]] { }]"

puts $f "\n=== registered command Q -> LFNST response D ==="
puts $f "[join [report_safe [list -from $cmd_addr_q -to $lfnst_resp_d -delay_type max -max_paths 20 -nworst 1 -path_type full -file $out_file -append]] { }]"

puts $f "\n=== registered command Q -> through RAMD64E -> LFNST response D ==="
puts $f "[join [report_safe [list -from $cmd_addr_q -through $ramd -to $lfnst_resp_d -delay_type max -max_paths 20 -nworst 1 -path_type full -file $out_file -append]] { }]"

puts $f "\n=== live control -> through RAMD64E -> LFNST response D ==="
puts $f "[join [report_safe [list -from $live_ctrl_q -through $ramd -to $lfnst_resp_d -delay_type max -max_paths 20 -nworst 1 -path_type full -file $out_file -append]] { }]"
close $f
close_design
puts "P9_SECOND_READ_COMMAND_TARGETED_DONE"
