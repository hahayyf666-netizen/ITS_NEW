# Re-open the last routed P2A checkpoint and emit a min-delay summary.
set ROOT [file normalize [file join [file dirname [info script]] ..]]
set REPORT [file join $ROOT vivado reports]
open_checkpoint [file join $REPORT p2a_dct2_64_ooc.dcp]
report_timing_summary -delay_type min -max_paths 20 -file [file join $REPORT p2a_hold_summary.rpt]
close_design
