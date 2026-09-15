set dcp [lindex $argv 0]
set outdir [lindex $argv 1]
if {$dcp eq "" || $outdir eq ""} { error "usage: vivado -mode batch -source report_p4_targeted.tcl -tclargs <dcp> <outdir>" }
open_checkpoint $dcp
file mkdir $outdir

proc pin_names {pins} {
  set out {}
  foreach p $pins { lappend out [get_property NAME $p] }
  return $out
}
proc write_names {path title pins} {
  set f [open $path w]
  puts $f $title
  foreach n [pin_names $pins] { puts $f $n }
  close $f
}
proc no_path_report {path from_pins to_pins message} {
  if {[llength $from_pins] > 0 && [llength $to_pins] > 0} {
    report_timing -from $from_pins -to $to_pins -delay_type max -max_paths 50 -path_type full -file $path
  } else {
    set f [open $path w]
    puts $f $message
    puts $f "from_count=[llength $from_pins] to_count=[llength $to_pins]"
    close $f
  }
}

# Stage-0 descriptor boundary and capture endpoints.
set desc_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *issue_desc_*_q_reg*}]
set desc_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *issue_desc_*_q_reg*}]
set desc_slot_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *issue_desc_slot_q_reg*}]
set desc_bundle_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *issue_desc_bundle_addr_q_reg*}]
set desc_meta_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && (NAME =~ *issue_desc_group_q_reg* || NAME =~ *issue_desc_active_size_q_reg* || NAME =~ *issue_desc_shift_q_reg* || NAME =~ *issue_desc_last_q_reg* || NAME =~ *issue_desc_valid_q_reg*)}]
set s0_coeff_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *s0_coeff_q_reg*}]
set s0_input_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *s0_input_q_reg*}]
set s0_meta_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && (NAME =~ *s0_valid_q_reg* || NAME =~ *s0_last_q_reg* || NAME =~ *s0_group_q_reg* || NAME =~ *s0_shift_q_reg* || NAME =~ *s0_active_size_q_reg*)}]
set s0_all_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *s0_*_q_reg*}]

# Scheduler/live-control sources used for the non-vacuous no-direct-path checks.
set slot_state_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *slot_state_q_reg*}]
set issue_emit_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *issue_emit*}]
set ready_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && (NAME =~ *ready_slot* || NAME =~ *slot_state* || NAME =~ *issue_active_q_reg*)}]

set f [open [file join $outdir P4_TARGETED_PIN_COUNTS.txt] w]
puts $f "descriptor_q=[llength $desc_q]"
puts $f "descriptor_d=[llength $desc_d]"
puts $f "descriptor_slot_q=[llength $desc_slot_q]"
puts $f "descriptor_bundle_q=[llength $desc_bundle_q]"
puts $f "descriptor_meta_q=[llength $desc_meta_q]"
puts $f "s0_coeff_d=[llength $s0_coeff_d]"
puts $f "s0_input_d=[llength $s0_input_d]"
puts $f "s0_meta_d=[llength $s0_meta_d]"
puts $f "s0_all_d=[llength $s0_all_d]"
puts $f "slot_state_q=[llength $slot_state_q]"
puts $f "issue_emit_q=[llength $issue_emit_q]"
puts $f "ready_q=[llength $ready_q]"
close $f
write_names [file join $outdir P4_DESCRIPTOR_Q_NAMES.txt] DESCRIPTOR_Q $desc_q
write_names [file join $outdir P4_DESCRIPTOR_D_NAMES.txt] DESCRIPTOR_D $desc_d
write_names [file join $outdir P4_S0_COEFF_D_NAMES.txt] S0_COEFF_D $s0_coeff_d
write_names [file join $outdir P4_S0_INPUT_D_NAMES.txt] S0_INPUT_D $s0_input_d
write_names [file join $outdir P4_S0_META_D_NAMES.txt] S0_META_D $s0_meta_d
write_names [file join $outdir P4_SLOT_STATE_Q_NAMES.txt] SLOT_STATE_Q $slot_state_q

# Positive descriptor-to-capture timing families.
no_path_report [file join $outdir P4_PATH_SCHEDULER_TO_DESCRIPTOR.rpt] $ready_q $desc_d "scheduler-to-descriptor object match is empty"
no_path_report [file join $outdir P4_PATH_DESCRIPTOR_TO_COEFF.rpt] $desc_q $s0_coeff_d "descriptor-to-coefficient object match is empty"
no_path_report [file join $outdir P4_PATH_DESCRIPTOR_TO_INPUT.rpt] $desc_q $s0_input_d "descriptor-to-operand object match is empty"
no_path_report [file join $outdir P4_PATH_DESCRIPTOR_TO_META.rpt] $desc_q $s0_meta_d "descriptor-to-metadata object match is empty"

# Required no-direct scheduler/control paths.  These reports are only emitted
# when both ends match, so an empty match is explicitly recorded rather than
# being mistaken for proof of absence.
no_path_report [file join $outdir P4_PATH_NODIRECT_SLOTSTATE_TO_COEFF.rpt] $slot_state_q $s0_coeff_d "no-direct slot-state-to-coefficient path: object match empty"
no_path_report [file join $outdir P4_PATH_NODIRECT_SLOTSTATE_TO_INPUT.rpt] $slot_state_q $s0_input_d "no-direct slot-state-to-input path: object match empty"
no_path_report [file join $outdir P4_PATH_NODIRECT_READY_TO_COEFF.rpt] $ready_q $s0_coeff_d "no-direct ready/control-to-coefficient path: object match empty"
no_path_report [file join $outdir P4_PATH_NODIRECT_READY_TO_INPUT.rpt] $ready_q $s0_input_d "no-direct ready/control-to-input path: object match empty"

close_design
exit
