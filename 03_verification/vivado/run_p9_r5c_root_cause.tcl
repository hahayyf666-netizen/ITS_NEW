# Step12F-P9-R5C read-only setup/hold root-cause qualification.
#
# This script opens one already-routed checkpoint and emits evidence only.
# It does not synthesize, optimize, place, route, alter constraints, or save a
# modified checkpoint.  The intent is to separate input-interface hold paths
# from internal physical paths and to classify every negative setup endpoint.

if {$argc < 2} {
    puts stderr "Usage: vivado -mode batch -source run_p9_r5c_root_cause.tcl -- <routed.dcp> <out_dir> ?xdc?"
    exit 2
}

set dcp [lindex $argv 0]
set out_dir [lindex $argv 1]
set xdc ""
if {$argc >= 3} { set xdc [lindex $argv 2] }
file mkdir $out_dir
catch {set_param general.maxThreads 4}

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

proc object_name {obj} {
    if {$obj eq ""} { return "" }
    return [safe_prop $obj NAME ""]
}

proc first_cell {pin_name} {
    if {$pin_name eq ""} { return "" }
    set pins [get_pins -quiet $pin_name]
    if {[llength $pins] == 0} { return "" }
    set cells [get_cells -quiet -of_objects $pins]
    if {[llength $cells] == 0} { return "" }
    return [lindex $cells 0]
}

proc cell_prop {cell key} {
    if {$cell eq ""} { return "" }
    return [safe_prop $cell $key ""]
}

proc path_family_setup {start endpoint} {
    set text [string tolower "$start $endpoint"]
    if {[regexp {slot_state_q_reg} $text]} { return "P4_slot_state" }
    if {[regexp {rd_cmd_addr_q_reg|input_rd_addr|input_cache|ramd64e} $text]} { return "cache_read_command" }
    if {[regexp {fifo_rd_ptr_q_reg|ready_rd_ptr_q_reg|fifo_data_q_reg} $text]} { return "P4_fifo_control" }
    if {[regexp {kernel_vector_q_reg} $text]} { return "wrapper_kernel_vector" }
    if {[regexp {lfnst_ntrs|lfnst_grid|lfnst_case|lfnst_mem_resp|lfnst_tail|bounded_lfnst} $text]} { return "LFNST_control" }
    if {[regexp {kernel_h_rd|kernel_rd_req|kernel_phase|kernel_stage|kernel_feed|kernel_drain} $text]} { return "H_read_or_kernel_control" }
    if {[regexp {u_unified_p4_kernel} $text]} { return "P4_other_control" }
    return "other"
}

proc path_family_hold {start endpoint path_group path_type} {
    set text [string tolower "$start $endpoint $path_group $path_type"]
    if {[regexp {removal|recovery|async_default|/clr|/pre} $text]} { return "async_reset_removal_or_recovery" }
    if {[regexp {^it_info(\[|$)} [string tolower $start]]} { return "input_it_info" }
    if {[regexp {^it_data_in(\[|$)} [string tolower $start]]} { return "input_it_data_in" }
    if {[regexp {^it_data_addr(\[|$)} [string tolower $start]]} { return "input_it_data_addr" }
    if {[regexp {^it_data_in_vld(\[|$)|^it_data_end(\[|$)|^it_info_vld(\[|$)|^it_data_out_req(\[|$)} [string tolower $start]]} { return "input_protocol_control" }
    if {[regexp {^rst_n(\[|$)} [string tolower $start]]} { return "input_reset" }
    if {[regexp {^\S+\s*$} $start] && [string match *\[* $start]} { return "other_input" }
    return "internal_or_other"
}

proc pin_is_port {pin_name} {
    if {$pin_name eq ""} { return 0 }
    set ports [get_ports -quiet $pin_name]
    return [expr {[llength $ports] != 0}]
}

proc get_source_net_fanout {pin_name} {
    if {$pin_name eq ""} { return "" }
    set pins [get_pins -quiet $pin_name]
    if {[llength $pins] == 0} { return "" }
    set nets [get_nets -quiet -of_objects $pins]
    if {[llength $nets] == 0} { return "" }
    set value [safe_prop [lindex $nets 0] FANOUT ""]
    if {$value eq ""} { return "" }
    return $value
}

if {![file exists $dcp]} { error "Missing routed checkpoint: $dcp" }
open_checkpoint $dcp

set meta [open [file join $out_dir R5C_TOOL_CONTEXT.txt] w]
puts $meta "analysis=Step12F-P9-R5C setup/hold root-cause qualification"
puts $meta "dcp=$dcp"
puts $meta "vivado_version=[version -short]"
puts $meta "part=[safe_prop [current_design] PART ""]"
puts $meta "design_state=[safe_prop [current_design] STATE ""]"
puts $meta "maxThreads=[get_param general.maxThreads]"
puts $meta "read_only=true"
puts $meta "rtl_changed=false"
puts $meta "xdc_changed=false"
puts $meta "resynthesis=false"
puts $meta "implementation_rerun=false"
close $meta

report_timing_summary -file [file join $out_dir timing_summary_setup.rpt]
report_timing_summary -delay_type min -file [file join $out_dir timing_summary_hold.rpt]
check_timing -verbose -file [file join $out_dir check_timing.rpt]
report_exceptions -file [file join $out_dir exceptions.rpt]
report_io -file [file join $out_dir io_report.rpt]
set port_prop_file [open [file join $out_dir port_properties.rpt] w]
puts $port_prop_file "Port-level physical/clock property snapshot"
foreach port [get_ports] {
    puts $port_prop_file "PORT=[safe_prop $port NAME \"\"]"
    foreach key {DIRECTION LOC IOB IOBDELAY IS_CLOCK CLOCK_DEDICATED_ROUTE PACKAGE_PIN} {
        puts $port_prop_file "  $key=[safe_prop $port $key \"\"]"
    }
}
close $port_prop_file

set constraint_file [open [file join $out_dir input_delay_constraint_provenance.txt] w]
puts $constraint_file "source_xdc=$xdc"
if {$xdc ne "" && [file exists $xdc]} {
    set xdc_f [open $xdc r]
    while {[gets $xdc_f line] >= 0} {
        if {[regexp {create_clock|set_input_delay|step12f_inputs|set_output_delay} $line]} {
            puts $constraint_file $line
        }
    }
    close $xdc_f
} else {
    puts $constraint_file "STATUS=SOURCE_XDC_NOT_SUPPLIED_OR_NOT_FOUND"
}
close $constraint_file

# Full negative endpoint census.  -nworst 1 makes one representative path per
# endpoint; negative paths are filtered again in Tcl for a conservative audit.
set setup_paths [get_timing_paths -delay_type max -max_paths 100000 -nworst 1 -slack_lesser_than 0.0 -sort_by slack]
set hold_paths  [get_timing_paths -delay_type min -max_paths 100000 -nworst 1 -slack_lesser_than 0.0 -sort_by slack]

set setup_csv [open [file join $out_dir setup_endpoint_census.csv] w]
puts $setup_csv "index,family,slack_ns,datapath_delay_ns,logic_delay_ns,route_delay_ns,logic_levels,path_group,path_type,startpoint,endpoint,start_cell,start_loc,start_bel,start_ref,start_fanout,end_cell,end_loc,end_bel,end_ref"
set hold_csv [open [file join $out_dir hold_endpoint_census.csv] w]
puts $hold_csv "index,family,slack_ns,datapath_delay_ns,logic_delay_ns,route_delay_ns,logic_levels,path_group,path_type,startpoint,endpoint,start_cell,start_loc,start_bel,start_ref,start_fanout,end_cell,end_loc,end_bel,end_ref,end_iob,end_is_iob,source_port,source_is_port,first_register"

array set setup_count {}
array set setup_tns {}
array set setup_worst {}
array set setup_seen_endpoint {}
array set hold_count {}
array set hold_tns {}
array set hold_worst {}
array set hold_seen_endpoint {}
set setup_families {P4_slot_state cache_read_command P4_fifo_control wrapper_kernel_vector LFNST_control H_read_or_kernel_control P4_other_control other}
set hold_families {input_it_info input_it_data_in input_it_data_addr input_protocol_control input_reset async_reset_removal_or_recovery internal_or_other other_input}
foreach f $setup_families { set setup_count($f) 0; set setup_tns($f) 0.0; set setup_worst($f) 0.0 }
foreach f $hold_families { set hold_count($f) 0; set hold_tns($f) 0.0; set hold_worst($f) 0.0 }

set setup_index 0
set setup_unique 0
foreach path $setup_paths {
    set slack [safe_num $path SLACK 0.0]
    if {$slack >= 0.0} { continue }
    set sp [safe_prop $path STARTPOINT_PIN ""]
    set ep [safe_prop $path ENDPOINT_PIN ""]
    set spn [object_name $sp]
    set epn [object_name $ep]
    set fam [path_family_setup $spn $epn]
    if {![info exists setup_count($fam)]} { set setup_count($fam) 0; set setup_tns($fam) 0.0; set setup_worst($fam) 0.0 }
    set spc [first_cell $spn]
    set epc [first_cell $epn]
    set path_group [safe_prop $path PATH_GROUP ""]
    set path_type [safe_prop $path PATH_TYPE ""]
    set spfan [get_source_net_fanout $spn]
    set endpoint_key $epn
    if {![info exists setup_seen_endpoint($endpoint_key)]} { set setup_seen_endpoint($endpoint_key) 1; incr setup_unique }
    puts $setup_csv [join [list $setup_index $fam [format %.6f $slack] [format %.6f [safe_num $path DATAPATH_DELAY]] [format %.6f [safe_num $path DATAPATH_LOGIC_DELAY]] [format %.6f [safe_num $path DATAPATH_NET_DELAY]] [csv_escape [safe_prop $path LOGIC_LEVELS ""]] [csv_escape $path_group] [csv_escape $path_type] [csv_escape $spn] [csv_escape $epn] [csv_escape [cell_prop $spc NAME]] [csv_escape [cell_prop $spc LOC]] [csv_escape [cell_prop $spc BEL]] [csv_escape [cell_prop $spc REF_NAME]] [csv_escape $spfan] [csv_escape [cell_prop $epc NAME]] [csv_escape [cell_prop $epc LOC]] [csv_escape [cell_prop $epc BEL]] [csv_escape [cell_prop $epc REF_NAME]]] ","]
    incr setup_count($fam)
    set setup_tns($fam) [expr {$setup_tns($fam) + double($slack)}]
    if {$setup_count($fam) == 1 || $slack < $setup_worst($fam)} { set setup_worst($fam) $slack }
    incr setup_index
}
close $setup_csv

set hold_index 0
set hold_unique 0
foreach path $hold_paths {
    set slack [safe_num $path SLACK 0.0]
    if {$slack >= 0.0} { continue }
    set sp [safe_prop $path STARTPOINT_PIN ""]
    set ep [safe_prop $path ENDPOINT_PIN ""]
    set spn [object_name $sp]
    set epn [object_name $ep]
    set path_group [safe_prop $path PATH_GROUP ""]
    set path_type [safe_prop $path PATH_TYPE ""]
    set fam [path_family_hold $spn $epn $path_group $path_type]
    if {![info exists hold_count($fam)]} { set hold_count($fam) 0; set hold_tns($fam) 0.0; set hold_worst($fam) 0.0 }
    set spc [first_cell $spn]
    set epc [first_cell $epn]
    set source_is_port [pin_is_port $spn]
    set first_register [expr {$source_is_port && [safe_prop $path LOGIC_LEVELS ""] == 0 && [regexp {/(D|CE)$} $epn]}]
    set endpoint_key $epn
    if {![info exists hold_seen_endpoint($endpoint_key)]} { set hold_seen_endpoint($endpoint_key) 1; incr hold_unique }
    set source_port $spn
    set end_iob [cell_prop $epc IOB]
    set end_is_iob [cell_prop $epc IS_IOB]
    puts $hold_csv [join [list $hold_index $fam [format %.6f $slack] [format %.6f [safe_num $path DATAPATH_DELAY]] [format %.6f [safe_num $path DATAPATH_LOGIC_DELAY]] [format %.6f [safe_num $path DATAPATH_NET_DELAY]] [csv_escape [safe_prop $path LOGIC_LEVELS ""]] [csv_escape $path_group] [csv_escape $path_type] [csv_escape $spn] [csv_escape $epn] [csv_escape [cell_prop $spc NAME]] [csv_escape [cell_prop $spc LOC]] [csv_escape [cell_prop $spc BEL]] [csv_escape [cell_prop $spc REF_NAME]] [csv_escape [get_source_net_fanout $spn]] [csv_escape [cell_prop $epc NAME]] [csv_escape [cell_prop $epc LOC]] [csv_escape [cell_prop $epc BEL]] [csv_escape [cell_prop $epc REF_NAME]] [csv_escape $end_iob] [csv_escape $end_is_iob] [csv_escape $source_port] $source_is_port $first_register] ","]
    incr hold_count($fam)
    set hold_tns($fam) [expr {$hold_tns($fam) + double($slack)}]
    if {$hold_count($fam) == 1 || $slack < $hold_worst($fam)} { set hold_worst($fam) $slack }
    incr hold_index
}
close $hold_csv

# Keep full path text for independent audit and for checking whether a reset
# removal path was accidentally mixed into the synchronous data-hold census.
report_timing -delay_type max -max_paths 1000 -slack_lesser_than 0.0 -path_type full -file [file join $out_dir negative_setup_paths.rpt]
report_timing -delay_type min -max_paths 1000 -slack_lesser_than 0.0 -path_type full -file [file join $out_dir negative_hold_paths.rpt]

set summary [open [file join $out_dir R5C_CENSUS_SUMMARY.json] w]
puts $summary "{"
puts $summary "  \"schema\": \"step12f.p9.r5c.census.v1\","
puts $summary "  \"read_only\": true,"
puts $summary "  \"dcp\": \"[json_escape $dcp]\","
puts $summary "  \"setup_negative_path_count\": $setup_index,"
puts $summary "  \"setup_unique_endpoint_count\": $setup_unique,"
puts $summary "  \"hold_negative_path_count\": $hold_index,"
puts $summary "  \"hold_unique_endpoint_count\": $hold_unique,"
puts $summary "  \"setup_families\": {"
set first 1
foreach f $setup_families {
    if {!$first} { puts $summary "," }
    set first 0
    puts -nonewline $summary "    \"$f\": {\"count\": $setup_count($f), \"tns_ns\": [format %.6f $setup_tns($f)], \"worst_slack_ns\": [format %.6f $setup_worst($f)]}"
}
puts $summary ""
puts $summary "  },"
puts $summary "  \"hold_families\": {"
set first 1
foreach f $hold_families {
    if {!$first} { puts $summary "," }
    set first 0
    puts -nonewline $summary "    \"$f\": {\"count\": $hold_count($f), \"tns_ns\": [format %.6f $hold_tns($f)], \"worst_slack_ns\": [format %.6f $hold_worst($f)]}"
}
puts $summary ""
puts $summary "  },"
puts $summary "  \"interpretation\": {"
puts $summary "    \"hold\": \"Classify negative min-delay paths by source port, path type, endpoint register and I/O packing; do not change XDC in this read-only batch.\","
puts $summary "    \"setup\": \"Classify one representative negative max-delay path per endpoint by source/destination family and physical delay; a worst-path sample is not treated as a new timing constraint.\","
puts $summary "    \"signoff\": \"This census does not sign off 500 MHz and does not authorize R6 RTL.\""
puts $summary "  }"
puts $summary "}"
close $summary

puts "P9_R5C_DONE"
puts "SETUP_NEGATIVE_PATHS=$setup_index UNIQUE_ENDPOINTS=$setup_unique"
puts "HOLD_NEGATIVE_PATHS=$hold_index UNIQUE_ENDPOINTS=$hold_unique"
puts "SETUP_CSV=[file join $out_dir setup_endpoint_census.csv]"
puts "HOLD_CSV=[file join $out_dir hold_endpoint_census.csv]"
puts "SUMMARY=[file join $out_dir R5C_CENSUS_SUMMARY.json]"
close_project

