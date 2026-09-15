# Targeted Step12F-P6 checks on an already synthesized checkpoint.
# This script is diagnostic only; it does not alter the checkpoint or timing
# constraints.  It reports whether live kernel state can still reach Result
# Memory write pins and records the registered-command timing paths.

if {$argc < 2} {
    puts "Usage: vivado -mode batch -source report_step12f_p6_targeted.tcl -- <dcp> <out_dir>"
    exit 2
}

set dcp [lindex $argv 0]
set out_dir [lindex $argv 1]
file mkdir $out_dir
open_checkpoint $dcp

set report_path [file join $out_dir p6_targeted_timing.rpt]
set query_path [file join $out_dir p6_targeted_queries.txt]
set q [open $query_path w]

proc names_or_none {objs} {
    if {[llength $objs] == 0} { return "<none>" }
    return [join [get_property NAME $objs] "\n"]
}

# Limit the destination set to ResultMemory.  The wrapper contains input,
# intermediate, valid-tag, and result RAMs, all of which also expose a WE pin.
set result_we [get_pins -hier -filter {REF_PIN_NAME == WE && NAME =~ *u_result_bank*}]
set kernel_vector_cells [get_cells -hier -filter {NAME =~ *kernel_vector_q_reg*}]
set kernel_group_cells [get_cells -hier -filter {NAME =~ *kernel_group_q_reg*}]
set kernel_phase_cells [get_cells -hier -filter {NAME =~ *kernel_phase_q_reg*}]
set result_cmd_cells [get_cells -hier -filter {NAME =~ *result_cmd*}]
set result_beat_cells [get_cells -hier -filter {NAME =~ *result_write_beat*}]

puts $q "RESULT_WE_COUNT=[llength $result_we]"
puts $q "KERNEL_VECTOR_CELLS=[llength $kernel_vector_cells]"
puts $q "KERNEL_GROUP_CELLS=[llength $kernel_group_cells]"
puts $q "KERNEL_PHASE_CELLS=[llength $kernel_phase_cells]"
puts $q "RESULT_CMD_CELLS=[llength $result_cmd_cells]"
puts $q "RESULT_BEAT_CELLS=[llength $result_beat_cells]"
puts $q "-- result write pins --"
puts $q [names_or_none $result_we]
puts $q "-- kernel vector cells --"
puts $q [names_or_none $kernel_vector_cells]
puts $q "-- kernel group cells --"
puts $q [names_or_none $kernel_group_cells]
puts $q "-- kernel phase cells --"
puts $q [names_or_none $kernel_phase_cells]
puts $q "-- result command cells --"
puts $q [names_or_none $result_cmd_cells]
puts $q "-- result beat cells --"
puts $q [names_or_none $result_beat_cells]
close $q

set rf [open $report_path w]
puts $rf "Step12F-P6 targeted timing checks"
puts $rf "DCP=$dcp"
puts $rf "Result WE pins: [llength $result_we]"
puts $rf "Kernel vector cells: [llength $kernel_vector_cells]"
puts $rf "Kernel group cells: [llength $kernel_group_cells]"
puts $rf "Kernel phase cells: [llength $kernel_phase_cells]"
puts $rf "Result command cells: [llength $result_cmd_cells]"
puts $rf "Result beat cells: [llength $result_beat_cells]"
close $rf

proc append_report {path title from_objs to_objs} {
    set f [open $path a]
    puts $f "\n=== $title ==="
    if {[llength $from_objs] == 0 || [llength $to_objs] == 0} {
        puts $f "NO_PATH: missing source or destination objects"
    } else {
        catch {report_timing -from $from_objs -to $to_objs -delay_type max -max_paths 20 -file $path -append} msg
        if {$msg ne ""} { puts $f "REPORT_STATUS=$msg" }
    }
    close $f
}

# Broad WE endpoint checks are diagnostic.  A path report with no paths is
# the expected evidence that live kernel counters no longer drive Result RAM.
append_report $report_path "kernel_vector_to_result_we" $kernel_vector_cells $result_we
append_report $report_path "kernel_group_to_result_we" $kernel_group_cells $result_we
append_report $report_path "kernel_phase_to_result_we" $kernel_phase_cells $result_we
append_report $report_path "result_command_to_result_we" $result_cmd_cells $result_we
append_report $report_path "result_beat_to_result_we" $result_beat_cells $result_we

write_checkpoint -force [file join $out_dir p6_targeted_copy.dcp]
close_design
puts "P6_TARGETED_DONE"
