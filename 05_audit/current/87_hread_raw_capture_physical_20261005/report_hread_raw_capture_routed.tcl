# Read-only targeted STA for the H-read raw-response capture stage.
# Usage: vivado -mode batch -source report_hread_raw_capture_routed.tcl -- <postroute.dcp> <out_dir>

if {$argc < 2} {
    puts stderr "Usage: vivado -mode batch -source report_hread_raw_capture_routed.tcl -- <postroute.dcp> <out_dir>"
    exit 2
}

set dcp [lindex $argv 0]
set out_dir [lindex $argv 1]
file mkdir $out_dir
if {![file exists $dcp]} { error "Missing post-route DCP: $dcp" }

proc names_of {objs} {
    set out {}
    foreach obj $objs { lappend out [get_property NAME $obj] }
    return $out
}

proc emit_query {label from through to out_dir summary_fh} {
    set rpt [file join $out_dir "${label}.rpt"]
    set result {}
    set rc [catch {
        if {[llength $through] > 0} {
            set result [get_timing_paths -quiet -from $from -through $through -to $to \
                -delay_type max -max_paths 5 -nworst 1]
        } else {
            set result [get_timing_paths -quiet -from $from -to $to \
                -delay_type max -max_paths 5 -nworst 1]
        }
    } msg]
    if {$rc} {
        set rf [open $rpt w]
        puts $rf "QUERY_ERROR=$msg"
        close $rf
        puts $summary_fh "$label STATUS=QUERY_ERROR MESSAGE=$msg"
    } elseif {[llength $from] == 0 || [llength $to] == 0} {
        set rf [open $rpt w]
        puts $rf "STATUS=NO_SOURCE_OR_DEST_OBJECT"
        close $rf
        puts $summary_fh "$label STATUS=NO_SOURCE_OR_DEST_OBJECT FROM=[llength $from] THROUGH=[llength $through] TO=[llength $to]"
    } elseif {[llength $result] == 0} {
        set rf [open $rpt w]
        puts $rf "STATUS=NO_TIMING_PATHS"
        close $rf
        puts $summary_fh "$label STATUS=NO_TIMING_PATHS FROM=[llength $from] THROUGH=[llength $through] TO=[llength $to]"
    } else {
        if {[llength $through] > 0} {
            report_timing -from $from -through $through -to $to \
                -delay_type max -max_paths 5 -nworst 1 -path_type full -file $rpt
        } else {
            report_timing -from $from -to $to -delay_type max \
                -max_paths 5 -nworst 1 -path_type full -file $rpt
        }
        puts $summary_fh "$label STATUS=PATHS_FOUND COUNT=[llength $result] FROM=[llength $from] THROUGH=[llength $through] TO=[llength $to] REPORT=$rpt"
    }
}

open_checkpoint $dcp
set report_dir $out_dir
set sf [open [file join $report_dir hread_raw_capture_targeted_summary.txt] w]
puts $sf "READ_ONLY=1"
puts $sf "DCP=$dcp"
puts $sf "VIVADO=[version -short]"

set haddr_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_h_rd_addr_q_reg*}]
set pending_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_h_rd_pending_q_reg*}]
set run_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_run_q_reg*}]
set stage_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_stage_q_reg*}]
set raw_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *kernel_h_rd_raw_data_q_reg*}]
set raw_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_h_rd_raw_data_q_reg*}]
set head_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *kernel_h_rd_data_q_reg*}]
set tail_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *kernel_h_rd_data_tail_q_reg*}]
set temp_rams {}
foreach cell [get_cells -hier -quiet -filter {REF_NAME == RAMD64E}] {
    if {[string match *u_kernel_tmp_bank* [get_property NAME $cell]]} {
        lappend temp_rams $cell
    }
}
set all_rams [get_cells -hier -quiet -filter {REF_NAME == RAMD64E}]

set sample_rams [lrange $temp_rams 0 7]
puts $sf "OBJECT_COUNT hread_addr_q=[llength $haddr_q] pending_q=[llength $pending_q] run_q=[llength $run_q] stage_q=[llength $stage_q] raw_data_d=[llength $raw_d] raw_data_q=[llength $raw_q] head_data_d=[llength $head_d] tail_data_d=[llength $tail_d] temp_bank_ramd64e=[llength $temp_rams] all_ramd64e=[llength $all_rams]"
puts $sf "OBJECT_NAMES temp_bank_ramd64e_sample=[names_of $sample_rams]"

# New intended path: registered H address through asynchronous temp RAM to raw capture D.
emit_query hread_addr_to_raw_capture $haddr_q $temp_rams $raw_d $report_dir $sf

# The raw stage must cut the old direct path into the downstream response queues.
emit_query hread_addr_to_head_through_ram $haddr_q $temp_rams $head_d $report_dir $sf
emit_query hread_addr_to_tail_through_ram $haddr_q $temp_rams $tail_d $report_dir $sf

# Data is expected to move from the new raw-stage Q into the head/tail queue D.
emit_query raw_capture_to_head $raw_q {} $head_d $report_dir $sf
emit_query raw_capture_to_tail $raw_q {} $tail_d $report_dir $sf

# Live validity/phase controls must not select RAM address/data on the path to capture.
emit_query pending_through_ram_to_raw_capture $pending_q $temp_rams $raw_d $report_dir $sf
emit_query run_through_ram_to_raw_capture $run_q $temp_rams $raw_d $report_dir $sf
emit_query stage_through_ram_to_raw_capture $stage_q $temp_rams $raw_d $report_dir $sf

close $sf
close_design
puts "HREAD_RAW_CAPTURE_TARGETED_STA_DONE"
exit
