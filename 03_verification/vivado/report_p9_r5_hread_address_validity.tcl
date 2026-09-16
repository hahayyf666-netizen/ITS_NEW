# Step12F-P9 Round 5 read-only qualification.
#
# Opens an already routed checkpoint and records the actual H-read address,
# validity/control, RAM, and response objects and timing path availability.
# This script is diagnostic only: it does not modify, optimize, or save the
# checkpoint.

if {$argc < 2} {
    puts stderr "Usage: vivado -mode batch -source report_p9_r5_hread_address_validity.tcl -- <postroute.dcp> <out_dir>"
    exit 2
}

set dcp [lindex $argv 0]
set out_dir [lindex $argv 1]
file mkdir $out_dir

proc safe_prop {obj key {default ""}} {
    if {$obj eq ""} { return $default }
    if {[catch {get_property $key $obj} value]} { return $default }
    return $value
}

proc json_escape {value} {
    return [string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $value]
}

proc names_of {objs} {
    if {[llength $objs] == 0} { return "" }
    return [join [get_property NAME $objs] "\n"]
}

proc count_path {from through to} {
    set rc 0
    set paths {}
    set msg ""
    if {[catch {
        if {[llength $through] != 0} {
            set paths [get_timing_paths -from $from -through $through -to $to \
                -delay_type max -max_paths 20 -nworst 1]
        } else {
            set paths [get_timing_paths -from $from -to $to \
                -delay_type max -max_paths 20 -nworst 1]
        }
    } msg]} {
        set rc 1
    }
    return [list $rc [llength $paths] $msg]
}

proc report_path {from through to title out_file} {
    set f [open $out_file a]
    puts $f "\n=== $title ==="
    puts $f "FROM_COUNT=[llength $from] THROUGH_COUNT=[llength $through] TO_COUNT=[llength $to]"
    close $f
    if {[llength $from] == 0 || [llength $to] == 0} {
        set f [open $out_file a]
        puts $f "STATUS=NO_SOURCE_OR_DEST_OBJECT"
        close $f
        return [list 0 0 "NO_SOURCE_OR_DEST_OBJECT"]
    }
    set q [count_path $from $through $to]
    set rc [lindex $q 0]
    set count [lindex $q 1]
    set msg [lindex $q 2]
    set report_rc [catch {
        if {[llength $through] != 0} {
            report_timing -from $from -through $through -to $to -delay_type max \
                -max_paths 20 -path_type full -file $out_file -append
        } else {
            report_timing -from $from -to $to -delay_type max \
                -max_paths 20 -path_type full -file $out_file -append
        }
    } report_msg]
    set f [open $out_file a]
    puts $f "PATH_QUERY_RC=$rc PATH_COUNT=$count"
    if {$rc} { puts $f "PATH_QUERY_MSG=[json_escape $msg]" }
    if {$count == 0 && !$rc} { puts $f "STATUS=NO_TIMING_PATHS" }
    if {$count > 0 && !$rc} { puts $f "STATUS=PATHS_FOUND" }
    puts $f "REPORT_RC=$report_rc"
    if {$report_rc} { puts $f "REPORT_MSG=[json_escape $report_msg]" }
    close $f
    return [list $rc $count $msg]
}

if {![file exists $dcp]} { error "Missing routed checkpoint: $dcp" }
open_checkpoint $dcp

set haddr_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_h_rd_addr_q_reg*}]
set hpend_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_h_rd_pending_q_reg*}]
set hrun_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_run_q_reg*}]
set hstage_q [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_stage_q_reg*}]
set hresp_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && (NAME =~ *kernel_h_rd_data_q_reg* || NAME =~ *kernel_h_rd_data_tail_q_reg*)}]
set lresp_d [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *lfnst_mem_resp_data_q_reg*}]
set ram_cells {}
set tmp_candidates [get_cells -hier -quiet -filter {NAME =~ "*u_kernel_tmp_bank*"}]
foreach c $tmp_candidates {
    if {[string equal [safe_prop $c REF_NAME] "RAMD64E"]} {
        lappend ram_cells $c
    }
}
if {[llength $ram_cells] == 0} {
    foreach c [get_cells -hier -quiet *] {
        if {[string equal [safe_prop $c REF_NAME] "RAMD64E"]} {
            lappend ram_cells $c
        }
    }
}
set tmp_nets [get_nets -hier -quiet *tmp_rd_addr*]
set haddr_nets [get_nets -hier -quiet *kernel_h_rd_addr_q*]

set report_file [file join $out_dir P9_R5_HREAD_ADDRESS_VALIDITY.rpt]
set rf [open $report_file w]
puts $rf "Step12F-P9 Round 5 H-read address-validity routed qualification"
puts $rf "DCP=$dcp"
puts $rf "haddr_q=[llength $haddr_q] hpend_q=[llength $hpend_q] hrun_q=[llength $hrun_q] hstage_q=[llength $hstage_q]"
puts $rf "hresp_d=[llength $hresp_d] lresp_d=[llength $lresp_d] ram_cells=[llength $ram_cells] tmp_rd_addr_nets=[llength $tmp_nets] haddr_nets=[llength $haddr_nets]"
puts $rf "-- tmp_rd_addr net drivers/loads --"
foreach n $tmp_nets {
    set drv [get_pins -quiet -of_objects $n -filter {DIRECTION == OUT}]
    set loads [get_pins -quiet -of_objects $n -filter {DIRECTION == IN}]
    puts $rf "NET=[safe_prop $n NAME] FANOUT=[safe_prop $n FANOUT] DRIVERS=[names_of $drv] LOAD_COUNT=[llength $loads]"
}
puts $rf "-- kernel_h_rd_addr_q net drivers/loads --"
foreach n $haddr_nets {
    set drv [get_pins -quiet -of_objects $n -filter {DIRECTION == OUT}]
    set loads [get_pins -quiet -of_objects $n -filter {DIRECTION == IN}]
    puts $rf "NET=[safe_prop $n NAME] FANOUT=[safe_prop $n FANOUT] DRIVERS=[names_of $drv] LOAD_COUNT=[llength $loads]"
}
close $rf

set results {}
lappend results haddr_to_hresp [report_path $haddr_q $ram_cells $hresp_d "address_q_through_tmp_ram_to_hread_response" $report_file]
lappend results hpend_to_hresp [report_path $hpend_q $ram_cells $hresp_d "pending_q_through_tmp_ram_to_hread_response" $report_file]
lappend results hrun_to_hresp [report_path $hrun_q $ram_cells $hresp_d "run_q_through_tmp_ram_to_hread_response" $report_file]
lappend results hstage_to_hresp [report_path $hstage_q $ram_cells $hresp_d "stage_q_through_tmp_ram_to_hread_response" $report_file]
lappend results haddr_to_lresp [report_path $haddr_q $ram_cells $lresp_d "address_q_through_ram_to_lfnst_response" $report_file]
lappend results hpend_to_lresp [report_path $hpend_q $ram_cells $lresp_d "pending_q_through_ram_to_lfnst_response" $report_file]

set obj_file [file join $out_dir P9_R5_HREAD_OBJECTS.txt]
set of [open $obj_file w]
foreach {label objs} [list HADDR_Q $haddr_q HPEND_Q $hpend_q HRUN_Q $hrun_q HSTAGE_Q $hstage_q \
    HRESP_D $hresp_d LRESP_D $lresp_d RAM_CELLS $ram_cells TMP_ADDR_NETS $tmp_nets HADDR_NETS $haddr_nets] {
    puts $of "-- $label --"
    puts $of "COUNT=[llength $objs]"
    puts $of [names_of $objs]
}
close $of

set json_file [file join $out_dir P9_R5_HREAD_ADDRESS_VALIDITY.json]
set jf [open $json_file w]
puts $jf "{"
puts $jf "  \"schema\": \"step12f.p9.r5.hread_address_validity.v1\","
puts $jf "  \"read_only\": true,"
puts $jf "  \"dcp\": \"[json_escape $dcp]\","
puts $jf "  \"objects\": {\"haddr_q\": [llength $haddr_q], \"hpend_q\": [llength $hpend_q], \"hrun_q\": [llength $hrun_q], \"hstage_q\": [llength $hstage_q], \"hresp_d\": [llength $hresp_d], \"lfnst_resp_d\": [llength $lresp_d], \"ramd64e\": [llength $ram_cells], \"tmp_rd_addr_nets\": [llength $tmp_nets]},"
puts $jf "  \"paths\": {"
set first 1
foreach {label value} $results {
    if {!$first} { puts $jf "," }
    set first 0
    puts -nonewline $jf "    \"$label\": {\"query_rc\": [lindex $value 0], \"path_count\": [lindex $value 1], \"message\": \"[json_escape [lindex $value 2]]\"}"
}
puts $jf ""
puts $jf "  },"
puts $jf "  \"address_policy\": \"tmp_rd_addr is expected to be driven unconditionally by registered kernel_h_rd_addr_q; valid/pending qualifies transaction meaning\","
puts $jf "  \"decision_status\": \"READ_ONLY_TARGET_QUALIFICATION_NO_RTL_AUTHORIZATION\""
puts $jf "}"
close $jf

close_design
puts "P9_R5_HREAD_ADDRESS_VALIDITY_DONE"
puts "OUT_DIR=$out_dir"
exit
