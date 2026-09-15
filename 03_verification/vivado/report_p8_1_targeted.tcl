# Step12F-P8.1 diagnostic timing queries.
# This script is read-only: it opens a synthesized checkpoint and emits
# source/destination object counts plus targeted timing reports for the
# same-edge input-fire control boundary.  It never changes the checkpoint or
# timing constraints.

if {$argc < 2} {
    puts "Usage: vivado -mode batch -source report_p8_1_targeted.tcl -- <dcp> <out_dir>"
    exit 2
}

set dcp [lindex $argv 0]
set out_dir [lindex $argv 1]
file mkdir $out_dir
open_checkpoint $dcp

proc names_or_none {objs} {
    if {[llength $objs] == 0} { return "<none>" }
    return [join [get_property NAME $objs] "\n"]
}

proc report_family {path title from_objs to_objs} {
    set f [open $path a]
    puts $f "\n=== $title ==="
    puts $f "FROM_COUNT=[llength $from_objs] TO_COUNT=[llength $to_objs]"
    if {[llength $from_objs] == 0 || [llength $to_objs] == 0} {
        puts $f "STATUS=NO_SOURCE_OR_DEST_OBJECT"
    } else {
        set rc [catch {
            report_timing -from $from_objs -to $to_objs -delay_type max \
                -max_paths 20 -path_type full -file $path -append
        } msg]
        puts $f "REPORT_RC=$rc"
        if {$rc} { puts $f "REPORT_MSG=$msg" }
    }
    close $f
}

set phase_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_phase_q_reg*}]
set phase_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *kernel_phase_q_reg*}]
set feed_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_feed_group_q_reg*}]
set feed_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *kernel_feed_group_q_reg*}]
set drain_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_drain_group_q_reg*}]
set drain_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *kernel_drain_group_q_reg*}]
set old_group_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_group_q_reg*}]
set issue_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *issue_desc_*_q_reg*}]
set issue_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *issue_desc_*_q_reg*}]
set wrapper_state_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *state_q_reg*}]
set wrapper_phase_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *phase_q_reg*}]
set wrapper_group_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *group_q_reg*}]
set input_fire_nets [get_nets -hier -quiet *kernel_input_group_fire*]
set input_fire_pins [get_pins -hier -quiet -filter {NAME =~ *kernel_input_group_fire*}]
set result_we [get_pins -hier -quiet -filter {REF_PIN_NAME == WE && NAME =~ *u_result_bank*}]

set q [open [file join $out_dir P8_1_TARGETED_OBJECTS.txt] w]
foreach {name objs} [list \
    PHASE_Q $phase_q PHASE_D $phase_d FEED_Q $feed_q FEED_D $feed_d \
    DRAIN_Q $drain_q DRAIN_D $drain_d OLD_GROUP_Q $old_group_q \
    ISSUE_D $issue_d ISSUE_Q $issue_q WRAPPER_STATE_D $wrapper_state_d \
    WRAPPER_PHASE_D $wrapper_phase_d WRAPPER_GROUP_D $wrapper_group_d \
    INPUT_FIRE_NETS $input_fire_nets INPUT_FIRE_PINS $input_fire_pins \
    RESULT_WE $result_we] {
    puts $q "-- $name --"
    puts $q "COUNT=[llength $objs]"
    puts $q [names_or_none $objs]
}
close $q

set r [file join $out_dir P8_1_TARGETED_TIMING.rpt]
set f [open $r w]
puts $f "Step12F-P8.1 targeted timing checks"
puts $f "DCP=$dcp"
puts $f "phase_q=[llength $phase_q] phase_d=[llength $phase_d]"
puts $f "feed_q=[llength $feed_q] feed_d=[llength $feed_d]"
puts $f "drain_q=[llength $drain_q] drain_d=[llength $drain_d]"
puts $f "old_group_q=[llength $old_group_q]"
puts $f "issue_d=[llength $issue_d] issue_q=[llength $issue_q]"
puts $f "wrapper_state_d=[llength $wrapper_state_d] wrapper_phase_d=[llength $wrapper_phase_d] wrapper_group_d=[llength $wrapper_group_d]"
puts $f "input_fire_nets=[llength $input_fire_nets] input_fire_pins=[llength $input_fire_pins]"
puts $f "result_we=[llength $result_we]"
close $f

report_family $r "phase_to_issue_descriptor" $phase_q $issue_d
report_family $r "phase_to_phase_next_state" $phase_q $phase_d
report_family $r "input_fire_to_phase" $input_fire_pins $phase_d
report_family $r "input_fire_to_wrapper_state" $input_fire_pins $wrapper_state_d
report_family $r "input_fire_to_wrapper_phase" $input_fire_pins $wrapper_phase_d
report_family $r "input_fire_to_wrapper_group" $input_fire_pins $wrapper_group_d
report_family $r "feed_q_to_descriptor" $feed_q $issue_d
report_family $r "drain_q_to_result_we" $drain_q $result_we
report_family $r "phase_q_to_result_we" $phase_q $result_we

close_design
puts "P8_1_TARGETED_DONE"
exit
