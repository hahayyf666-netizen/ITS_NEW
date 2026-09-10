# R4B_PRE: read-only timing/topology census. No synthesis or implementation.
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set ROOT [file normalize [file join $SCRIPT_DIR .. ..]]
set DCP [file join $ROOT 03_verification vivado reports_r4a_postroute p2f_b2_controlled_postroute.dcp]
set OUT [file join $ROOT 03_verification vivado reports_r4b_pre_readonly]
file mkdir $OUT

puts "R4B_PRE_READONLY_START"
puts "DCP=$DCP"
open_checkpoint $DCP

report_timing_summary -delay_type max -max_paths 20 -file [file join $OUT timing_summary.rpt]
report_timing -delay_type max -max_paths 1000 -nworst 1 -sort_by slack -file [file join $OUT top1000_setup_paths.rpt]
report_high_fanout_nets -max_nets 300 -file [file join $OUT high_fanout.rpt]
report_route_status -file [file join $OUT route_status.rpt]
report_utilization -hierarchical -file [file join $OUT hierarchical_utilization.rpt]
catch {report_design_analysis -congestion -file [file join $OUT congestion.rpt]} congestion_rc
if {$congestion_rc ne ""} { puts "CONGESTION_NOTE=$congestion_rc" }

# Export all paths with negative setup slack. The limit is deliberately above
# the known 6320 failing endpoints; the row count is checked by the Python audit.
set fh [open [file join $OUT all_failing_setup_paths.csv] w]
puts $fh "index,slack,datapath_delay,logic_levels,startpoint,endpoint"
set paths [get_timing_paths -delay_type max -max_paths 20000 -slack_lesser_than 0.0 -sort_by slack]
set idx 0
foreach p $paths {
    incr idx
    set slack [get_property SLACK $p]
    set delay [get_property DATAPATH_DELAY $p]
    set levels [get_property LOGIC_LEVELS $p]
    set sp [get_property STARTPOINT_PIN $p]
    set ep [get_property ENDPOINT_PIN $p]
    foreach var {slack delay levels sp ep} {
        set $$var [string map [list " " "_" "," ";" ";" "_"] [set $var]]
    }
    puts $fh "$idx,$slack,$delay,$levels,$sp,$ep"
}
close $fh
puts "FAIL_PATH_ROWS=$idx"

set fh2 [open [file join $OUT all_failing_setup_paths.rpt] w]
puts $fh2 "R4B_PRE all failing setup path count = $idx"
close $fh2
close_project
puts "R4B_PRE_READONLY_DONE"
