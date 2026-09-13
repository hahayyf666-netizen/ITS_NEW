# Step12C M6 implementation-only timing sweep.
# Each invocation opens the same M6 post-synthesis checkpoint in a fresh
# Vivado process and applies exactly one fixed implementation flow.

if {$argc != 4} {
    puts stderr "usage: vivado -mode batch -source run_m6_sweep.tcl -tclargs <strategy> <report_dir> <run_dir> <postsynth_dcp>"
    exit 2
}

set strategy   [lindex $argv 0]
set report_raw [lindex $argv 1]
set run_raw    [lindex $argv 2]
set dcp_raw    [lindex $argv 3]
# Keep forward-slash absolute paths exactly as supplied.  Vivado's Windows Tcl
# file normalize can incorrectly collapse the Documents component on this host.
set report_dir $report_raw
set run_dir    $run_raw
set input_dcp  $dcp_raw

file mkdir $report_dir
file mkdir $run_dir
set_param general.maxThreads 4

set command_log [file join $report_dir strategy_commands.txt]
set fh [open $command_log w]
puts $fh "strategy=$strategy"
puts $fh "input_dcp=$input_dcp"
puts $fh "maxThreads=4"

proc record_command {fh text} {
    puts $fh $text
    flush $fh
}

proc run_step {fh text script} {
    record_command $fh $text
    uplevel 1 $script
}

record_command $fh "open_checkpoint $input_dcp"
open_checkpoint $input_dcp
set part [get_property PART [current_design]]
set top  [get_property TOP [current_design]]
puts $fh "part=$part"
puts $fh "top=$top"
flush $fh

switch -- $strategy {
    Performance_Explore {
        set opt_dir  Explore
        set place_dir Explore
        set phys_dir Explore
        set route_dir Explore
        set post_route_phys 0
    }
    Performance_NetDelay_high {
        set opt_dir  Default
        set place_dir ExtraNetDelay_high
        set phys_dir AggressiveExplore
        set route_dir NoTimingRelaxation
        set post_route_phys 0
    }
    Performance_ExtraTimingOpt {
        set opt_dir  Default
        set place_dir ExtraTimingOpt
        set phys_dir Explore
        set route_dir NoTimingRelaxation
        set post_route_phys 0
    }
    Performance_ExplorePostRoutePhysOpt {
        set opt_dir  Explore
        set place_dir Explore
        set phys_dir Explore
        set route_dir Explore
        set post_route_phys 1
    }
    default {
        puts stderr "unknown strategy: $strategy"
        close $fh
        close_design
        exit 2
    }
}

puts $fh "opt_design=-directive $opt_dir"
puts $fh "place_design=-directive $place_dir"
puts $fh "phys_opt_design=-directive $phys_dir"
puts $fh "route_design=-directive $route_dir"
puts $fh "post_route_phys_opt=$post_route_phys"
flush $fh

run_step $fh "opt_design -directive $opt_dir" [list opt_design -directive $opt_dir]
run_step $fh "place_design -directive $place_dir" [list place_design -directive $place_dir]
run_step $fh "phys_opt_design -directive $phys_dir" [list phys_opt_design -directive $phys_dir]
run_step $fh "route_design -directive $route_dir" [list route_design -directive $route_dir]

if {$post_route_phys} {
    run_step $fh "phys_opt_design -directive Explore (post-route)" [list phys_opt_design -directive Explore]
}

record_command $fh "write_checkpoint [file join $report_dir final.dcp]"
write_checkpoint -force [file join $report_dir final.dcp]

report_utilization -file [file join $report_dir report_utilization.rpt]
report_utilization -hierarchical -file [file join $report_dir report_hierarchy_utilization.rpt]
report_timing_summary -delay_type max -max_paths 100 -file [file join $report_dir report_timing_summary_setup.rpt]
report_timing_summary -delay_type min -max_paths 100 -file [file join $report_dir report_timing_summary_hold.rpt]
report_timing -delay_type max -max_paths 100 -file [file join $report_dir report_timing_worst100_setup.rpt]
report_timing -delay_type min -max_paths 100 -file [file join $report_dir report_timing_worst100_hold.rpt]
report_high_fanout_nets -max_nets 200 -file [file join $report_dir report_high_fanout.rpt]
check_timing -verbose -file [file join $report_dir report_check_timing.rpt]
report_exceptions -file [file join $report_dir report_exceptions.rpt]
report_drc -file [file join $report_dir report_drc.rpt]
report_methodology -file [file join $report_dir report_methodology.rpt]
report_power -file [file join $report_dir report_power.rpt]

close $fh
close_design
puts "M6_SWEEP_DONE strategy=$strategy report_dir=$report_dir"
