# Step12F-P9-A routed read-only qualification.
#
# This script opens an existing routed checkpoint and emits diagnostics only.
# It does not synthesize, optimize, place, route, alter constraints, or save
# a modified checkpoint.  The output is intended to decide whether a future
# P9 RTL change should target a physical input-cache read-command boundary,
# a cache response boundary, or the P4 input-memory load family.

if {$argc < 2} {
    puts stderr "Usage: vivado -mode batch -source report_p9_a_routed_qualification.tcl -- <postroute.dcp> <out_dir>"
    exit 2
}

# Keep forward-slash absolute paths exactly as supplied.  On this host
# Vivado's Windows Tcl file normalize can incorrectly collapse the
# Documents component of a path.
set dcp [lindex $argv 0]
set out_dir [lindex $argv 1]
file mkdir $out_dir
file mkdir [file join $out_dir path_reports]

proc safe_prop {obj key {default ""}} {
    if {$obj eq ""} { return $default }
    if {[catch {get_property $key $obj} value]} { return $default }
    return $value
}

proc safe_num {obj key {default 0.0}} {
    set value [safe_prop $obj $key ""]
    if {$value eq "" || ![string is double -strict $value]} { return $default }
    return $value
}

proc json_escape {value} {
    return [string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $value]
}

proc csv_escape {value} {
    return "\"[string map [list \" \"\"] $value]\""
}

proc object_names {objs} {
    if {[llength $objs] == 0} { return "" }
    return [join [get_property NAME $objs] "\n"]
}

proc first_cell {pin_obj} {
    if {$pin_obj eq ""} { return "" }
    set cells [get_cells -quiet -of_objects $pin_obj]
    if {[llength $cells] == 0} { return "" }
    return [lindex $cells 0]
}

proc path_family {start endpoint} {
    set text [string tolower "$start $endpoint"]
    if {[regexp {lfnst_mem_resp_data_q|lfnst_mem_resp_valid_q} $text]} {
        return "A_cache_to_lfnst_response"
    }
    if {[regexp {u_unified_p4_kernel/input_mem_reg|/input_mem_reg} $text]} {
        return "B_kernel_control_to_p4_input_mem"
    }
    if {[regexp {input_cache|input_rd_data|data_mem_reg|valid_mem_reg|ramd64e|lfnst_gather} $text]} {
        return "C_other_cache_read_or_response"
    }
    if {[regexp {result_mem|vwrite|intermediate|kernel_h_rd|kernel_rd} $text]} {
        return "C_other_cache_kernel_or_write"
    }
    if {[regexp {frozen_r4c|r4c|kernel_stage|kernel_phase|kernel_vector|lfnst_case|lfnst_grid} $text]} {
        return "D_control_or_r4c"
    }
    return "E_other"
}

proc write_targeted_report {path title from_objs through_objs to_objs out_file} {
    set f [open $out_file a]
    puts $f "\n=== $title ==="
    puts $f "FROM_COUNT=[llength $from_objs] THROUGH_COUNT=[llength $through_objs] TO_COUNT=[llength $to_objs]"
    if {[llength $to_objs] == 0 || ([llength $from_objs] == 0 && [llength $through_objs] == 0)} {
        puts $f "STATUS=NO_SOURCE_OR_DEST_OBJECT"
        close $f
        return
    }
    close $f
    set rc 0
    set msg ""
    set path_count -1
    set path_query_rc 0
    if {[llength $through_objs] != 0} {
        set path_query_rc [catch {
            set path_objs [get_timing_paths -through $through_objs -to $to_objs \
                -delay_type max -max_paths 20 -nworst 1]
            set path_count [llength $path_objs]
        } path_query_msg]
        set rc [catch {
            if {[llength $to_objs] != 0} {
                report_timing -through $through_objs -to $to_objs -delay_type max \
                    -max_paths 20 -path_type full -file $out_file -append
            } else {
                report_timing -through $through_objs -delay_type max \
                    -max_paths 20 -path_type full -file $out_file -append
            }
        } msg]
    } else {
        set path_query_rc [catch {
            set path_objs [get_timing_paths -from $from_objs -to $to_objs \
                -delay_type max -max_paths 20 -nworst 1]
            set path_count [llength $path_objs]
        } path_query_msg]
        set rc [catch {
        report_timing -from $from_objs -to $to_objs -delay_type max \
                -max_paths 20 -path_type full -file $out_file -append
        } msg]
    }
    set f [open $out_file a]
    puts $f "PATH_QUERY_RC=$path_query_rc PATH_COUNT=$path_count"
    if {$path_query_rc} {
        puts $f "PATH_QUERY_MSG=[json_escape $path_query_msg]"
    } elseif {$path_count == 0} {
        puts $f "STATUS=NO_TIMING_PATHS"
    } else {
        puts $f "STATUS=PATHS_FOUND"
    }
    puts $f "REPORT_RC=$rc"
    if {$rc} { puts $f "REPORT_MSG=[json_escape $msg]" }
    close $f
}

if {![file exists $dcp]} {
    error "Missing routed checkpoint: $dcp"
}

open_checkpoint $dcp

set timing_summary [file join $out_dir report_timing_summary_postroute.rpt]
set hold_summary [file join $out_dir report_timing_hold_summary_postroute.rpt]
set check_timing [file join $out_dir report_check_timing_postroute.rpt]
set exceptions [file join $out_dir report_exceptions_postroute.rpt]
set fanout [file join $out_dir report_high_fanout_postroute.rpt]
report_timing_summary -file $timing_summary
report_timing_summary -delay_type min -file $hold_summary
check_timing -verbose -file $check_timing
report_exceptions -file $exceptions
report_high_fanout_nets -max_nets 200 -file $fanout

set phase_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_phase_q_reg*}]
set phase_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *kernel_phase_q_reg*}]
set feed_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_feed_group_q_reg*}]
set feed_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *kernel_feed_group_q_reg*}]
set drain_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_drain_group_q_reg*}]
set drain_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *kernel_drain_group_q_reg*}]
set wrapper_state_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *state_q_reg*}]
set wrapper_phase_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *phase_q_reg*}]
set wrapper_group_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *group_q_reg*}]
set wrapper_group_forbidden_d {}
foreach group_pin $wrapper_group_d {
    set group_name [safe_prop $group_pin NAME]
    if {[string match *kernel_feed_group_q_reg* $group_name]} { continue }
    if {[string match *kernel_drain_group_q_reg* $group_name]} { continue }
    lappend wrapper_group_forbidden_d $group_pin
}
set fire_nets [get_nets -hier -quiet *kernel_input_group_fire*]
set fire_drv [get_pins -quiet -of_objects $fire_nets -filter {DIRECTION == OUT}]
set fire_loads [get_pins -quiet -of_objects $fire_nets -filter {DIRECTION == IN}]
set result_we [get_pins -hier -quiet -filter {REF_PIN_NAME == WE && (NAME =~ *u_result_bank* || NAME =~ *result_mem*)}]
set lfnst_resp_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *lfnst_mem_resp_data_q_reg*}]
set lfnst_resp_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *lfnst_mem_resp_data_q_reg*}]
set p4_input_mem_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ */input_mem_reg*}]
set kernel_rd_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && (NAME =~ *kernel_rd_req_pending_q_reg* || NAME =~ *kernel_stage_q_reg* || NAME =~ *lfnst_case_q_reg*)}]

set objects_file [file join $out_dir P9_A_TARGETED_OBJECTS.txt]
set of [open $objects_file w]
foreach {name objs} [list \
    PHASE_Q $phase_q PHASE_D $phase_d FEED_Q $feed_q FEED_D $feed_d \
    DRAIN_Q $drain_q DRAIN_D $drain_d WRAPPER_STATE_D $wrapper_state_d \
    WRAPPER_PHASE_D $wrapper_phase_d WRAPPER_GROUP_D $wrapper_group_d \
    WRAPPER_GROUP_FORBIDDEN_D $wrapper_group_forbidden_d \
    INPUT_FIRE_NETS $fire_nets INPUT_FIRE_DRIVER_PINS $fire_drv \
    INPUT_FIRE_LOAD_PINS $fire_loads RESULT_WE $result_we \
    LFNST_RESPONSE_D $lfnst_resp_d LFNST_RESPONSE_Q $lfnst_resp_q \
    P4_INPUT_MEM_D $p4_input_mem_d KERNEL_READ_CONTROL_Q $kernel_rd_q] {
    puts $of "-- $name --"
    puts $of "COUNT=[llength $objs]"
    puts $of [object_names $objs]
}
close $of

set targeted_file [file join $out_dir P9_A_TARGETED_TIMING.rpt]
set tf [open $targeted_file w]
puts $tf "Step12F-P9-A routed read-only qualification"
puts $tf "DCP=$dcp"
puts $tf "phase_q=[llength $phase_q] phase_d=[llength $phase_d]"
puts $tf "feed_q=[llength $feed_q] feed_d=[llength $feed_d]"
puts $tf "drain_q=[llength $drain_q] drain_d=[llength $drain_d]"
puts $tf "input_fire_nets=[llength $fire_nets] input_fire_driver_pins=[llength $fire_drv] input_fire_load_pins=[llength $fire_loads]"
puts $tf "lfnst_response_d=[llength $lfnst_resp_d] p4_input_mem_d=[llength $p4_input_mem_d]"
close $tf

# Allowed local paths and forbidden wide-control paths are reported separately.
write_targeted_report $targeted_file "fire_to_phase_forbidden_wide_control" $fire_drv $fire_nets $phase_d $targeted_file
write_targeted_report $targeted_file "fire_to_wrapper_state_forbidden_wide_control" $fire_drv $fire_nets $wrapper_state_d $targeted_file
write_targeted_report $targeted_file "fire_to_wrapper_phase_forbidden_wide_control" $fire_drv $fire_nets $wrapper_phase_d $targeted_file
write_targeted_report $targeted_file "fire_to_wrapper_group_forbidden_wide_control" $fire_drv $fire_nets $wrapper_group_forbidden_d $targeted_file
write_targeted_report $targeted_file "fire_to_feed_allowed_local_bookkeeping" $fire_drv $fire_nets $feed_d $targeted_file
write_targeted_report $targeted_file "fire_to_drain_forbidden_drain_bookkeeping" $fire_drv $fire_nets $drain_d $targeted_file
write_targeted_report $targeted_file "kernel_read_control_to_lfnst_response" $kernel_rd_q {} $lfnst_resp_d $targeted_file
write_targeted_report $targeted_file "kernel_vector_control_to_p4_input_mem" [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_vector_q_reg*}] {} $p4_input_mem_d $targeted_file

# Emit full reports for the selected routed families.  These are parsed later
# into same-path pre-RAM/post-RAM timing segments without changing the DCP.
set family_reports [file join $out_dir path_reports]
if {[llength $kernel_rd_q] != 0 && [llength $lfnst_resp_d] != 0} {
    catch {report_timing -from $kernel_rd_q -to $lfnst_resp_d -delay_type max -max_paths 20 \
        -path_type full -file [file join $family_reports lfnst_cache_top20.rpt]} msg
}
set kernel_vector_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_vector_q_reg*}]
if {[llength $kernel_vector_q] != 0 && [llength $p4_input_mem_d] != 0} {
    catch {report_timing -from $kernel_vector_q -to $p4_input_mem_d -delay_type max -max_paths 20 -path_type full \
        -file [file join $family_reports p4_input_mem_top20.rpt]} msg
}
set ram_cells [get_cells -hier -quiet -filter {REF_NAME == RAMD64E}]
if {[llength $ram_cells] != 0 && [llength $lfnst_resp_d] != 0} {
    catch {report_timing -through $ram_cells -to $lfnst_resp_d -delay_type max -max_paths 20 -path_type full \
        -file [file join $family_reports lfnst_through_ramd_top20.rpt]} msg
}

# The full worst-500 text is retained as the authoritative sample window.
report_timing -delay_type max -max_paths 500 -path_type full \
    -file [file join $out_dir report_timing_worst500_postroute.rpt]

# Machine-readable path census.  This deliberately labels the aggregate as a
# worst-500 sample, not as full-design TNS.
set paths [get_timing_paths -delay_type max -max_paths 500 -nworst 1 -slack_lesser_than 0.0]
set csv [open [file join $out_dir p9_a_worst500.csv] w]
puts $csv "index,family,slack_ns,datapath_delay_ns,logic_delay_ns,route_delay_ns,logic_levels,startpoint,endpoint,start_loc,end_loc,start_fanout"

array set counts {}
array set sample_sum {}
array set worst {}
array set repr {}
set families {A_cache_to_lfnst_response B_kernel_control_to_p4_input_mem C_other_cache_read_or_response C_other_cache_kernel_or_write D_control_or_r4c E_other}
foreach fam $families {
    set counts($fam) 0
    set sample_sum($fam) 0.0
    set worst($fam) 0.0
    set repr($fam) ""
}

set idx 0
foreach path $paths {
    set slack [safe_num $path SLACK]
    if {$slack >= 0.0} { continue }
    set sp [safe_prop $path STARTPOINT_PIN]
    set ep [safe_prop $path ENDPOINT_PIN]
    set spn [safe_prop $sp NAME]
    set epn [safe_prop $ep NAME]
    set fam [path_family $spn $epn]
    set spcell [first_cell $sp]
    set epcell [first_cell $ep]
    set spname [safe_prop $spcell NAME]
    set epname [safe_prop $epcell NAME]
    set sploc [safe_prop $spcell LOC]
    set eploc [safe_prop $epcell LOC]
    set spnets [get_nets -quiet -of_objects $sp]
    set sfanout [safe_prop [lindex $spnets 0] FANOUT ""]
    set datapath [safe_num $path DATAPATH_DELAY]
    set logic [safe_num $path DATAPATH_LOGIC_DELAY]
    set route [safe_num $path DATAPATH_NET_DELAY]
    set levels [safe_prop $path LOGIC_LEVELS]
    puts $csv [join [list $idx $fam [format %.6f $slack] [format %.6f $datapath] \
        [format %.6f $logic] [format %.6f $route] [csv_escape $levels] \
        [csv_escape $spn] [csv_escape $epn] [csv_escape $sploc] [csv_escape $eploc] \
        [csv_escape $sfanout]] ","]
    incr counts($fam)
    set sample_sum($fam) [expr {$sample_sum($fam) + double($slack)}]
    if {$counts($fam) == 1 || $slack < $worst($fam)} {
        set worst($fam) $slack
        set repr($fam) [list $spn $epn $sploc $eploc $datapath $logic $route $levels $sfanout]
    }
    incr idx
}
close $csv

set json [open [file join $out_dir P9_A_ROUTED_READ_QUALIFICATION.json] w]
puts $json "{"
puts $json "  \"schema\": \"step12f.p9_a.routed_qualification.v1\","
puts $json "  \"read_only\": true,"
puts $json "  \"dcp\": \"[json_escape $dcp]\","
puts $json "  \"worst500_sample_path_count\": $idx,"
puts $json "  \"aggregate_label\": \"sampled_negative_slack_sum_not_full_design_tns\","
puts $json "  \"object_counts\": {\"fire_net\": [llength $fire_nets], \"fire_driver_pins\": [llength $fire_drv], \"fire_load_pins\": [llength $fire_loads], \"phase_d\": [llength $phase_d], \"feed_d\": [llength $feed_d], \"drain_d\": [llength $drain_d], \"lfnst_response_d\": [llength $lfnst_resp_d], \"p4_input_mem_d\": [llength $p4_input_mem_d]},"
puts $json "  \"families\": {"
set first 1
foreach fam $families {
    if {!$first} { puts $json "," }
    set first 0
    set rep $repr($fam)
    puts -nonewline $json "    \"$fam\": {\"sampled_path_count\": $counts($fam), \"sampled_negative_slack_sum_ns\": [format %.6f $sample_sum($fam)], \"worst_slack_ns\": [format %.6f $worst($fam)]"
    if {$rep ne ""} {
        puts -nonewline $json ", \"representative\": {\"startpoint\": \"[json_escape [lindex $rep 0]]\", \"endpoint\": \"[json_escape [lindex $rep 1]]\", \"start_loc\": \"[json_escape [lindex $rep 2]]\", \"end_loc\": \"[json_escape [lindex $rep 3]]\", \"datapath_delay_ns\": [lindex $rep 4], \"logic_delay_ns\": [lindex $rep 5], \"route_delay_ns\": [lindex $rep 6], \"logic_levels\": \"[json_escape [lindex $rep 7]]\", \"start_fanout\": \"[json_escape [lindex $rep 8]]\"}"
    }
    puts -nonewline $json "}"
}
puts $json ""
puts $json "  },"
puts $json "  \"decision_status\": \"QUALIFICATION_ONLY_NO_P9_RTL_AUTHORIZATION\","
puts $json "  \"hold_is_separate_signoff\": true"
puts $json "}"
close $json

set summary [open [file join $out_dir P9_A_ROUTED_READ_QUALIFICATION_SUMMARY.txt] w]
puts $summary "P9-A routed read-only qualification"
puts $summary "DCP=$dcp"
puts $summary "worst500_sample_path_count=$idx"
puts $summary "fire_net_count=[llength $fire_nets] fire_driver_pin_count=[llength $fire_drv] fire_load_pin_count=[llength $fire_loads]"
foreach fam $families {
    puts $summary "$fam count=$counts($fam) sampled_negative_slack_sum_ns=[format %.6f $sample_sum($fam)] worst_slack_ns=[format %.6f $worst($fam)]"
}
puts $summary "decision=QUALIFICATION_ONLY_NO_P9_RTL_AUTHORIZATION"
puts $summary "note=worst500 aggregates are sampled and are not full-design TNS"
close $summary

close_design
puts "P9_A_ROUTED_QUALIFICATION_DONE"
puts "OUT_DIR=$out_dir"
puts "WORST500_PATHS=$idx"
exit
