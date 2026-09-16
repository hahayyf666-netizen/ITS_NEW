# Step12F-P9-R5A fixed-DCP implementation stability qualification.
#
# This script never synthesizes RTL.  It opens one immutable post-synthesis
# checkpoint, applies one explicitly recorded implementation flow, and saves
# a final checkpoint plus comparable reports.  The incremental mode is a
# diagnostic flow only; it records reuse and whether Vivado actually entered
# incremental implementation.

if {$argc < 3} {
    puts stderr "Usage: vivado -mode batch -source run_p9_r5a_fixed_dcp.tcl -tclargs <mode> <input_dcp> <out_dir> ?<reference_dcp>?"
    puts stderr "modes: r4_replay r5_replay r5_netdelay r5_extratiming r5_postroute_physopt r5_incremental"
    exit 2
}

set mode     [lindex $argv 0]
set input_dcp [lindex $argv 1]
set out_dir  [lindex $argv 2]
set ref_dcp  ""
if {$argc >= 4} { set ref_dcp [lindex $argv 3] }

if {![file exists $input_dcp]} { error "Missing input checkpoint: $input_dcp" }
if {$mode eq "r5_incremental" && ($ref_dcp eq "" || ![file exists $ref_dcp])} {
    error "Incremental mode requires an existing reference routed DCP"
}

file mkdir $out_dir
set_param general.maxThreads 4

set transcript [file join $out_dir COMMAND_TRANSCRIPT.txt]
set tf [open $transcript w]
proc log_line {fh text} {
    puts $fh $text
    flush $fh
    puts $text
}
proc run_logged {fh text script} {
    log_line $fh $text
    uplevel 1 $script
}
proc safe_report {fh text script} {
    log_line $fh $text
    if {[catch {uplevel 1 $script} msg]} {
        log_line $fh "REPORT_ERROR=$msg"
    }
}

log_line $tf "mode=$mode"
log_line $tf "input_dcp=$input_dcp"
log_line $tf "reference_dcp=$ref_dcp"
log_line $tf "vivado_version=[version -short]"
log_line $tf "maxThreads=[get_param general.maxThreads]"
log_line $tf "host=[info hostname]"

open_checkpoint $input_dcp
log_line $tf "part=[get_property PART [current_design]]"
log_line $tf "top=[get_property TOP [current_design]]"

switch -- $mode {
    r4_replay -
    r5_replay {
        set opt_dir Explore
        set place_dir Explore
        set phys_dir Explore
        set route_dir Explore
        set postroute_phys 0
        set incremental 0
    }
    r5_netdelay {
        set opt_dir Default
        set place_dir ExtraNetDelay_high
        set phys_dir AggressiveExplore
        set route_dir NoTimingRelaxation
        set postroute_phys 0
        set incremental 0
    }
    r5_extratiming {
        set opt_dir Default
        set place_dir ExtraTimingOpt
        set phys_dir Explore
        set route_dir NoTimingRelaxation
        set postroute_phys 0
        set incremental 0
    }
    r5_postroute_physopt {
        set opt_dir Explore
        set place_dir Explore
        set phys_dir Explore
        set route_dir Explore
        set postroute_phys 1
        set incremental 0
    }
    r5_incremental {
        set opt_dir Explore
        set place_dir Explore
        set phys_dir Explore
        set route_dir Explore
        set postroute_phys 0
        set incremental 1
    }
    default { error "Unknown mode: $mode" }
}

log_line $tf "opt_design=-directive $opt_dir"
log_line $tf "place_design=-directive $place_dir"
log_line $tf "phys_opt_design=-directive $phys_dir"
log_line $tf "route_design=-directive $route_dir"
log_line $tf "postroute_phys_opt=$postroute_phys"

run_logged $tf "opt_design -directive $opt_dir" [list opt_design -directive $opt_dir]

if {$incremental} {
    run_logged $tf "read_checkpoint -incremental -directive TimingClosure $ref_dcp" \
        [list read_checkpoint -incremental -directive TimingClosure $ref_dcp]
    safe_report $tf "report_incremental_reuse -file [file join $out_dir reuse_after_read.rpt]" \
        [list report_incremental_reuse -file [file join $out_dir reuse_after_read.rpt]]
}

run_logged $tf "place_design -directive $place_dir" [list place_design -directive $place_dir]
if {$incremental} {
    safe_report $tf "report_incremental_reuse -file [file join $out_dir reuse_postplace.rpt]" \
        [list report_incremental_reuse -file [file join $out_dir reuse_postplace.rpt]]
}
run_logged $tf "phys_opt_design -directive $phys_dir" [list phys_opt_design -directive $phys_dir]
run_logged $tf "route_design -directive $route_dir" [list route_design -directive $route_dir]

if {$postroute_phys} {
    run_logged $tf "phys_opt_design -directive Explore (post-route)" [list phys_opt_design -directive Explore]
}
if {$incremental} {
    safe_report $tf "report_incremental_reuse -file [file join $out_dir reuse_postroute.rpt]" \
        [list report_incremental_reuse -file [file join $out_dir reuse_postroute.rpt]]
}

set final_dcp [file join $out_dir final.dcp]
run_logged $tf "write_checkpoint -force $final_dcp" [list write_checkpoint -force $final_dcp]

safe_report $tf "report_utilization" [list report_utilization -file [file join $out_dir report_utilization.rpt]]
safe_report $tf "report_utilization -hierarchical" [list report_utilization -hierarchical -file [file join $out_dir report_hierarchy_utilization.rpt]]
safe_report $tf "report_timing_summary -delay_type max" [list report_timing_summary -delay_type max -max_paths 100 -file [file join $out_dir report_timing_summary_setup.rpt]]
safe_report $tf "report_timing_summary -delay_type min" [list report_timing_summary -delay_type min -max_paths 100 -file [file join $out_dir report_timing_summary_hold.rpt]]
safe_report $tf "report_timing -delay_type max -max_paths 100" [list report_timing -delay_type max -max_paths 100 -path_type full -file [file join $out_dir report_timing_worst100_setup.rpt]]
safe_report $tf "report_timing -delay_type min -max_paths 100" [list report_timing -delay_type min -max_paths 100 -path_type full -file [file join $out_dir report_timing_worst100_hold.rpt]]
safe_report $tf "report_timing -delay_type max -max_paths 500" [list report_timing -delay_type max -max_paths 500 -path_type full -file [file join $out_dir report_timing_worst500_setup.rpt]]
safe_report $tf "report_high_fanout_nets" [list report_high_fanout_nets -max_nets 200 -file [file join $out_dir report_high_fanout.rpt]]
safe_report $tf "check_timing -verbose" [list check_timing -verbose -file [file join $out_dir report_check_timing.rpt]]
safe_report $tf "report_exceptions" [list report_exceptions -file [file join $out_dir report_exceptions.rpt]]
safe_report $tf "report_drc" [list report_drc -file [file join $out_dir report_drc.rpt]]
safe_report $tf "report_methodology" [list report_methodology -file [file join $out_dir report_methodology.rpt]]
safe_report $tf "report_power" [list report_power -file [file join $out_dir report_power.rpt]]
safe_report $tf "report_route_status" [list report_route_status -file [file join $out_dir report_route_status.rpt]]

close $tf
close_design
puts "P9_R5A_FIXED_DCP_DONE mode=$mode out_dir=$out_dir"
exit

