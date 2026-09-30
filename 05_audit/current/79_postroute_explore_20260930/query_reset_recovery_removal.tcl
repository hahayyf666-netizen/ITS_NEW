set candidate_dcp $::env(STEP12F_CANDIDATE_DCP)
set report_dir $::env(STEP12F_POSTROUTE_EXPLORE_DIR)
set_param general.maxThreads 4
puts "P9_RESET_RECOVERY_REMOVAL_QUERY_START"
puts "VIVADO_VERSION=[version -short]"
puts "MAX_THREADS=[get_param general.maxThreads]"
open_checkpoint $candidate_dcp
set clr_pins [get_pins -hier -quiet -filter {REF_PIN_NAME == CLR}]
set pre_pins [get_pins -hier -quiet -filter {REF_PIN_NAME == PRE}]
puts "ASYNC_CLEAR_PINS=[llength $clr_pins] ASYNC_PRESET_PINS=[llength $pre_pins]"
if {[llength $clr_pins] == 0 && [llength $pre_pins] == 0} {
    error "No async control pins found for recovery/removal query"
}
if {[llength $clr_pins] > 0} {
    report_timing -delay_type max -to $clr_pins -max_paths 100 \
        -file [file join $report_dir candidate_reset_recovery.rpt]
    report_timing -delay_type min -to $clr_pins -max_paths 100 \
        -file [file join $report_dir candidate_reset_removal.rpt]
}
if {[llength $pre_pins] > 0} {
    report_timing -delay_type max -to $pre_pins -max_paths 100 \
        -file [file join $report_dir candidate_preset_recovery.rpt]
    report_timing -delay_type min -to $pre_pins -max_paths 100 \
        -file [file join $report_dir candidate_preset_removal.rpt]
}
report_timing_summary -delay_type max -max_paths 100 \
    -file [file join $report_dir candidate_reset_summary.rpt]
close_design
puts "P9_RESET_RECOVERY_REMOVAL_QUERY_DONE"
