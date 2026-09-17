# Step12F-P9-R5B bounded implementation convergence / hold-closure runner.
# No RTL is read or synthesized.  Modes either replay the fixed R5 postsynth
# flow or apply one explicitly recorded post-route phys_opt operation to a
# routed checkpoint.

if {$argc < 3} {
    puts stderr "Usage: vivado -mode batch -source run_p9_r5b_postroute.tcl -tclargs <mode> <input_dcp> <out_dir> ?<reference_dcp>?"
    puts stderr "modes: b0_netdelay_replay b1_setup_opt b2_hold_fix b3_combined b4_aggressive_hold final_flow"
    exit 2
}

set mode     [lindex $argv 0]
set input_dcp [lindex $argv 1]
set out_dir  [lindex $argv 2]
set ref_dcp  ""
if {$argc >= 4} { set ref_dcp [lindex $argv 3] }

if {![file exists $input_dcp]} { error "Missing input checkpoint: $input_dcp" }
if {$mode eq "final_flow" && $ref_dcp eq ""} {
    error "final_flow requires the selected final-flow descriptor as reference argument"
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

set flow_description ""
switch -- $mode {
    b0_netdelay_replay {
        set flow_description "full R5 NetDelay replay from postsynth"
        run_logged $tf "opt_design -directive Default" [list opt_design -directive Default]
        run_logged $tf "place_design -directive ExtraNetDelay_high" [list place_design -directive ExtraNetDelay_high]
        run_logged $tf "phys_opt_design -directive AggressiveExplore" [list phys_opt_design -directive AggressiveExplore]
        run_logged $tf "route_design -directive NoTimingRelaxation" [list route_design -directive NoTimingRelaxation]
    }
    b1_setup_opt {
        set flow_description "post-route setup optimization from fixed NetDelay routed DCP"
        run_logged $tf "phys_opt_design -directive Explore (post-route)" [list phys_opt_design -directive Explore]
    }
    b2_hold_fix {
        set flow_description "post-route ordinary hold fix from fixed NetDelay routed DCP"
        run_logged $tf "phys_opt_design -hold_fix (post-route)" [list phys_opt_design -hold_fix]
    }
    b3_combined {
        set flow_description "post-route setup Explore followed by ordinary hold fix"
        run_logged $tf "phys_opt_design -directive Explore (post-route setup)" [list phys_opt_design -directive Explore]
        run_logged $tf "phys_opt_design -hold_fix (post-route hold)" [list phys_opt_design -hold_fix]
    }
    b4_aggressive_hold {
        set flow_description "post-route aggressive hold fix"
        run_logged $tf "phys_opt_design -aggressive_hold_fix (post-route)" [list phys_opt_design -aggressive_hold_fix]
    }
    final_flow {
        set flow_description "selected final flow replay from postsynth; descriptor=$ref_dcp"
        # ref_dcp is a compact descriptor string: setup_mode,hold_mode.
        set parts [split $ref_dcp ","]
        set setup_mode [lindex $parts 0]
        set hold_mode [lindex $parts 1]
        run_logged $tf "opt_design -directive Default" [list opt_design -directive Default]
        run_logged $tf "place_design -directive ExtraNetDelay_high" [list place_design -directive ExtraNetDelay_high]
        run_logged $tf "phys_opt_design -directive AggressiveExplore" [list phys_opt_design -directive AggressiveExplore]
        run_logged $tf "route_design -directive NoTimingRelaxation" [list route_design -directive NoTimingRelaxation]
        if {$setup_mode eq "Explore"} {
            run_logged $tf "phys_opt_design -directive Explore (post-route setup)" [list phys_opt_design -directive Explore]
        }
        if {$hold_mode eq "hold_fix"} {
            run_logged $tf "phys_opt_design -hold_fix (post-route hold)" [list phys_opt_design -hold_fix]
        } elseif {$hold_mode eq "aggressive_hold_fix"} {
            run_logged $tf "phys_opt_design -aggressive_hold_fix (post-route hold)" [list phys_opt_design -aggressive_hold_fix]
        }
    }
    default { error "Unknown mode: $mode" }
}

log_line $tf "flow_description=$flow_description"

set final_dcp [file join $out_dir final.dcp]
run_logged $tf "write_checkpoint -force $final_dcp" [list write_checkpoint -force $final_dcp]

safe_report $tf "report_utilization" [list report_utilization -file [file join $out_dir report_utilization.rpt]]
safe_report $tf "report_utilization -hierarchical" [list report_utilization -hierarchical -file [file join $out_dir report_hierarchy_utilization.rpt]]
safe_report $tf "report_timing_summary -delay_type max" [list report_timing_summary -delay_type max -max_paths 100 -file [file join $out_dir report_timing_summary_setup.rpt]]
safe_report $tf "report_timing_summary -delay_type min" [list report_timing_summary -delay_type min -max_paths 100 -file [file join $out_dir report_timing_summary_hold.rpt]]
safe_report $tf "report_timing -delay_type max -max_paths 100" [list report_timing -delay_type max -max_paths 100 -path_type full -file [file join $out_dir report_timing_worst100_setup.rpt]]
safe_report $tf "report_timing -delay_type min -max_paths 100" [list report_timing -delay_type min -max_paths 100 -path_type full -file [file join $out_dir report_timing_worst100_hold.rpt]]
safe_report $tf "report_timing -delay_type max -max_paths 500" [list report_timing -delay_type max -max_paths 500 -path_type full -file [file join $out_dir report_timing_worst500_setup.rpt]]
safe_report $tf "report_timing -delay_type min -max_paths 500" [list report_timing -delay_type min -max_paths 500 -path_type full -file [file join $out_dir report_timing_worst500_hold.rpt]]
safe_report $tf "report_high_fanout_nets" [list report_high_fanout_nets -max_nets 200 -file [file join $out_dir report_high_fanout.rpt]]
safe_report $tf "check_timing -verbose" [list check_timing -verbose -file [file join $out_dir report_check_timing.rpt]]
safe_report $tf "report_exceptions" [list report_exceptions -file [file join $out_dir report_exceptions.rpt]]
safe_report $tf "report_drc" [list report_drc -file [file join $out_dir report_drc.rpt]]
safe_report $tf "report_methodology" [list report_methodology -file [file join $out_dir report_methodology.rpt]]
safe_report $tf "report_power" [list report_power -file [file join $out_dir report_power.rpt]]
safe_report $tf "report_route_status" [list report_route_status -file [file join $out_dir report_route_status.rpt]]

close $tf
close_design
puts "P9_R5B_POSTROUTE_DONE mode=$mode out_dir=$out_dir"
exit

