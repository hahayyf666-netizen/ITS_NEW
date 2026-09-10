# Step 11 report-only follow-up.  Opens the already routed checkpoint and
# emits the standard (non-hierarchical) utilization table with percentages.
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set B2_ROOT    [file normalize [file join $SCRIPT_DIR .. ..]]
set REPORT_DIR [file join $SCRIPT_DIR reports]
set DCP        [file join $REPORT_DIR p2f_b2_postroute.dcp]

open_checkpoint $DCP
report_utilization -file [file join $REPORT_DIR report_utilization_postroute.rpt]
report_utilization -hierarchical -file [file join $REPORT_DIR report_hierarchy_utilization.rpt]
close_design
puts "STEP11_B2_REPORT_ONLY_DONE"
