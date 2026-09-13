# Read-only physical root-cause extraction for the M6 routed checkpoint.
# This script opens the routed DCP, classifies all negative setup paths, and
# records physical placement/fanout evidence. It does not modify the design.

set script_dir [file dirname [info script]]
set root_dir   [file join $script_dir .. ..]
set audit_dir  [file join $root_dir 05_audit current 22 m6_timing]
set dcp        [file join $audit_dir step12c_boundary_pre_postroute.dcp]
set csv_file  [file join $audit_dir m6_physical_paths.csv]
set json_file [file join $audit_dir M6_PHYS_ANALYSIS.json]

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
    set value [string map [list \" \"\"] $value]
    return "\"$value\""
}

proc classify_path {start end} {
    set text "$start $end"
    if {[regexp {stage_rsp_(data|tag|perm).*stage_[ab]} $text]} {
        return "B_staging_capture"
    }
    if {[regexp {stage_bank_addr|stage_rsp_(data|tag)|input_cache|intermediate} $text]} {
        return "A_staging_response"
    }
    if {[regexp {v_wr_|inter_wr_|intermediate_write} $text]} {
        return "F_v_write"
    }
    if {[regexp {result_mem|result_stage16} $text]} {
        return "C_result_write"
    }
    if {[regexp {frozen_r4c|r4c} $text]} {
        return "D_r4c_or_launch"
    }
    return "E_other_wrapper"
}

if {![file exists $dcp]} {
    error "Missing routed checkpoint: $dcp"
}

open_checkpoint $dcp
set paths [get_timing_paths -delay_type max -max_paths 10000 -nworst 1 -slack_lesser_than 0.000]

set fh [open $csv_file w]
puts $fh "index,category,slack_ns,datapath_delay_ns,logic_delay_ns,route_delay_ns,logic_levels,startpoint,endpoint,start_cell,start_loc,end_cell,end_loc,start_net_fanout"

set categories {A_staging_response B_staging_capture C_result_write D_r4c_or_launch E_other_wrapper F_v_write}
array set count {}
array set tns {}
array set worst {}
array set repr {}
foreach category $categories {
    set count($category) 0
    set tns($category) 0.0
    set worst($category) 0.0
    set repr($category) ""
}

set index 0
foreach path $paths {
    set slack [safe_num $path SLACK]
    if {$slack >= 0.0} { continue }
    set sp [safe_prop $path STARTPOINT_PIN]
    set ep [safe_prop $path ENDPOINT_PIN]
    set sp_name [safe_prop $sp NAME]
    set ep_name [safe_prop $ep NAME]
    set category [classify_path $sp_name $ep_name]
    set sp_cells [get_cells -quiet -of_objects [get_pins -quiet $sp_name]]
    set ep_cells [get_cells -quiet -of_objects [get_pins -quiet $ep_name]]
    set sp_cell [safe_prop [lindex $sp_cells 0] NAME]
    set ep_cell [safe_prop [lindex $ep_cells 0] NAME]
    set sp_loc [safe_prop [lindex $sp_cells 0] LOC]
    set ep_loc [safe_prop [lindex $ep_cells 0] LOC]
    set sp_nets [get_nets -quiet -of_objects [get_pins -quiet $sp_name]]
    set sp_fanout [safe_prop $path MAX_FANOUT [safe_prop [lindex $sp_nets 0] FANOUT]]
    set datapath [safe_num $path DATAPATH_DELAY]
    set logic [safe_num $path DATAPATH_LOGIC_DELAY]
    set route [safe_num $path DATAPATH_NET_DELAY]
    set levels [safe_prop $path LOGIC_LEVELS]
    puts $fh [join [list $index $category [format %.6f $slack] [format %.6f $datapath] [format %.6f $logic] [format %.6f $route] [csv_escape $levels] [csv_escape $sp_name] [csv_escape $ep_name] [csv_escape $sp_cell] [csv_escape $sp_loc] [csv_escape $ep_cell] [csv_escape $ep_loc] [csv_escape $sp_fanout]] ","]
    incr count($category)
    set tns($category) [expr {$tns($category) + double($slack)}]
    if {$count($category) == 1 || $slack < $worst($category)} {
        set worst($category) $slack
        set repr($category) [list $sp_name $ep_name $sp_cell $sp_loc $ep_cell $ep_loc $sp_fanout $datapath $logic $route $levels]
    }
    incr index
}
close $fh

set jh [open $json_file w]
puts $jh "{"
puts $jh "  \"analysis\": \"M6 routed physical root-cause extraction\","
puts $jh "  \"dcp\": \"[json_escape $dcp]\","
puts $jh "  \"negative_setup_paths\": $index,"
puts $jh "  \"read_only\": true,"
puts $jh "  \"categories\": {"
set first_cat 1
foreach category $categories {
    if {!$first_cat} { puts $jh "," }
    set first_cat 0
    set rep $repr($category)
    puts -nonewline $jh "    \"$category\": {\"count\": $count($category), \"tns_ns\": [format %.6f $tns($category)], \"worst_slack_ns\": [format %.6f $worst($category)]"
    if {$rep ne ""} {
        puts -nonewline $jh ", \"representative\": {"
        set keys {startpoint endpoint start_cell start_loc end_cell end_loc start_net_fanout datapath_delay_ns logic_delay_ns route_delay_ns logic_levels}
        set first_key 1
        foreach key $keys value $rep {
            if {!$first_key} { puts -nonewline $jh ", " }
            set first_key 0
            if {[string is double -strict $value]} {
                puts -nonewline $jh "\"$key\": $value"
            } else {
                puts -nonewline $jh "\"$key\": \"[json_escape $value]\""
            }
        }
        puts -nonewline $jh "}"
    }
    puts -nonewline $jh "}"
}
puts $jh ""
puts $jh "  },"
puts $jh "  \"interpretation\": {"
puts $jh "    \"A_B\": \"A/B are concentrated in input-cache/tag response and tag-validity-to-staging capture; physical evidence is adjacent but does not prove one common RTL fix.\","
puts $jh "    \"C\": \"ResultMemory write paths are separately dominated by frozen R4C output to distributed-RAM write topology; no common root cause is assumed.\","
puts $jh "    \"D_F\": \"Observed and retained as follow-on paths only; no M7 RTL is approved by this analysis.\""
puts $jh "  },"
puts $jh "  \"decision\": \"ANALYSIS_ONLY_NO_M7_APPROVED\""
puts $jh "}"
close $jh

puts "NEGATIVE_SETUP_PATHS=$index"
puts "CSV=$csv_file"
puts "JSON=$json_file"
close_project
