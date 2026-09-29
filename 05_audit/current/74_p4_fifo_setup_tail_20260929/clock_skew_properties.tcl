set dcp $::env(STEP12F_R5F_POSTROUTE_DCP)
set_param general.maxThreads 4
open_checkpoint $dcp
set paths [get_timing_paths -delay_type max -slack_lesser_than 0.0 -max_paths 200000 -nworst 1 -sort_by slack]
set f [open $::env(STEP12F_R5F_CENSUS_DIR)/timing_path_properties.txt w]
puts $f "negative_paths=[llength $paths]"
puts $f {endpoint,startpoint,slack_ns,skew_ns,source_clock_delay_ns,endpoint_clock_delay_ns,clock_pessimism_ns,datapath_ns,logic_ns,net_ns,logic_levels}
foreach p $paths {
    set row {}
    foreach key {ENDPOINT_PIN STARTPOINT_PIN SLACK SKEW STARTPOINT_CLOCK_DELAY ENDPOINT_CLOCK_DELAY CLOCK_PESSIMISM DATAPATH_DELAY DATAPATH_LOGIC_DELAY DATAPATH_NET_DELAY LOGIC_LEVELS} {
        if {[catch {set v [get_property $key $p]}]} { set v "" }
        set v [string map [list "\"" "\"\""] $v]
        lappend row "\"$v\""
    }
    puts $f [join $row ","]
}
close $f
close_design
exit
