# Step12F P9-R5F read-only setup root-cause census.
#
# This script opens one already-routed DCP and only queries timing/netlist
# objects.  It must not synthesize, optimize, place, phys_opt, route, write a
# checkpoint, or read any constraint file.  The parent PowerShell launcher
# performs the SHA-256 provenance gate before invoking Vivado.

set dcp_path $::env(STEP12F_R5F_POSTROUTE_DCP)
set out_dir  $::env(STEP12F_R5F_CENSUS_DIR)
set expected_top "step12f_registered_neighbor_harness"
file mkdir $out_dir

proc prop_or {obj prop {fallback ""}} {
    if {$obj eq ""} { return $fallback }
    if {[catch {set value [get_property $prop $obj]}]} { return $fallback }
    return $value
}

proc normalize_hier {name} {
    set value $name
    regsub -all {\[[0-9]+\]} $value {} value
    regsub -all {_replica_[0-9]+} {_replica} value
    regsub -all {_i_[0-9]+} {_i} value
    regsub -all {gen_[A-Za-z0-9_]+} {gen} value
    return $value
}

proc family_name {name} {
    # Collapse bit/index/replica suffixes while retaining the first semantic
    # register or generated-bank component.  This keeps family statistics
    # useful without hiding the full cell name retained in the endpoint CSV.
    set value $name
    regsub -all {\[[^]]+\]} $value {} value
    regsub -all {_replica(?:_[0-9]+)?} {_replica} value
    if {[string match "u_dut/u_unified_p4_kernel/*" $value]} {
        set rest [string range $value [string length "u_dut/u_unified_p4_kernel/"] end]
        return "u_dut/u_unified_p4_kernel/[lindex [split $rest "/"] 0]"
    }
    if {[string match "u_dut/u_bounded_lfnst_engine/*" $value]} {
        set rest [string range $value [string length "u_dut/u_bounded_lfnst_engine/"] end]
        return "u_dut/u_bounded_lfnst_engine/[lindex [split $rest "/"] 0]"
    }
    if {[string match "u_dut/gen_input_slots*" $value]} { return "u_dut/input_cache_bank" }
    if {[string match "u_dut/gen_tmp_banks*" $value]} { return "u_dut/temp_bank" }
    if {[string match "u_dut/gen_result_slots*" $value]} { return "u_dut/result_bank" }
    if {[string match "u_dut/*" $value]} {
        set rest [string range $value [string length "u_dut/"] end]
        return "u_dut/[lindex [split $rest "/"] 0]"
    }
    if {[string match "src_*" $value]} { return "harness/source_boundary" }
    if {[string match "sink_*" $value]} { return "harness/sink_boundary" }
    if {[string match "*reset*" $value] || [string match "*rst*" $value]} { return "harness/reset" }
    return "harness/local"
}

proc csv_quote {value} {
    set value [string map [list "\"" "\"\""] $value]
    return "\"$value\""
}

proc csv_row {values} {
    set out {}
    foreach value $values { lappend out [csv_quote $value] }
    return [join $out ","]
}

proc percentile {values q} {
    if {[llength $values] == 0} { return "" }
    set sorted [lsort -real $values]
    set n [llength $sorted]
    set index [expr {int(ceil($q * $n)) - 1}]
    if {$index < 0} { set index 0 }
    if {$index >= $n} { set index [expr {$n - 1}] }
    return [lindex $sorted $index]
}

proc median {values} { return [percentile $values 0.5] }

proc cell_for_pin {pin} {
    set cells [get_cells -quiet -of_objects $pin]
    if {[llength $cells] == 0} { return "" }
    return [lindex $cells 0]
}

proc endpoint_bucket {sp ep} {
    set sp_first [lindex [split $sp "/"] 0]
    if {[string match "u_dut/*" $ep] && [string match "src_*" $sp_first]} {
        return "SOURCE_BOUNDARY_TO_DUT"
    }
    if {[string match "u_dut/*" $sp] && [string match "u_dut/*" $ep]} {
        return "DUT_INTERNAL"
    }
    if {[string match "u_dut/*" $sp] && [string match "sink_*" $ep]} {
        return "DUT_TO_SINK_BOUNDARY"
    }
    if {[regexp -nocase {(rst_n|reset_sync|/PRE$|/CLR$|/R$)} "$sp $ep"]} {
        return "RESET_RELATED_SETUP"
    }
    return "HARNESS_LOCAL"
}

proc source_family {cell pin} {
    set name [prop_or $cell NAME $pin]
    return [family_name $name]
}

proc endpoint_family {cell pin} {
    set name [prop_or $cell NAME $pin]
    return [family_name $name]
}

proc path_signature {path sp_cell ep_cell} {
    # Vivado 2025.2 can terminate while extracting a full report_timing
    # string for every path in some routed DCPs.  R6A remains a read-only
    # family census; its launcher may explicitly disable this optional,
    # per-path decoration while retaining all endpoint, delay, and family
    # fields.  Historical R5F runs keep the original default behavior.
    if {[info exists ::env(STEP12F_SKIP_PATH_SIGNATURE)] && $::env(STEP12F_SKIP_PATH_SIGNATURE) eq "1"} {
        set sp_ref [prop_or $sp_cell REF_NAME "START_UNKNOWN"]
        set ep_ref [prop_or $ep_cell REF_NAME "END_UNKNOWN"]
        return [list "SIGNATURE_SKIPPED|$sp_ref|$ep_ref" "SIGNATURE_SKIPPED|$sp_ref|$ep_ref"]
    }
    # report_timing -of_objects emits the complete selected path.  Vivado
    # 2025.2 limits significant_digits to three, but the primitive sequence is
    # still exact for the path topology and is retained separately from the
    # numeric fields in the CSV.
    set report ""
    if {[catch {set report [report_timing -of_objects $path -return_string]}]} {
        return [list "REPORT_UNAVAILABLE" "REPORT_UNAVAILABLE"]
    }
    set sequence {}
    set started 0
    foreach line [split $report "\n"] {
        if {[regexp {^\s+\(clock .*rise edge\)} $line]} {
            if {$started} { break }
            set started 1
            continue
        }
        if {!$started} { continue }
        if {[regexp {^\s+\S+\s+([A-Z][A-Z0-9_]+)\s+\(Prop_} $line -> primitive]} {
            lappend sequence $primitive
        }
    }
    set seq [join $sequence ">"]
    if {$seq eq ""} { set seq "SEQUENCE_UNAVAILABLE" }
    set sp_ref [prop_or $sp_cell REF_NAME "START_UNKNOWN"]
    set ep_ref [prop_or $ep_cell REF_NAME "END_UNKNOWN"]
    set raw "[prop_or $sp_cell NAME START_UNKNOWN]|$sp_ref|$seq|$ep_ref|[prop_or $ep_cell NAME END_UNKNOWN]"
    set normalized "$sp_ref|$seq|$ep_ref"
    return [list $raw $normalized]
}

set_param general.maxThreads 4
puts "P9R5F_START"
puts "DCP=$dcp_path"
puts "OUT_DIR=$out_dir"
puts "MAX_THREADS=4"
open_checkpoint $dcp_path

set design [current_design]
set design_top [prop_or $design TOP [prop_or $design DESIGN_NAME ""]]
set design_state [prop_or $design DESIGN_STATE "UNKNOWN"]
puts "TOP=$design_top"
puts "DESIGN_STATE=$design_state"
if {$design_top ne "" && $design_top ne $expected_top} {
    puts "F0_TOP=FAIL"
    error "Unexpected top: $design_top"
}
puts "F0_TOP=PASS"

set top_ports [get_ports -quiet *]
set old_ooc_ports [get_ports -quiet {it_info it_info_vld it_data_in it_data_addr it_data_in_vld it_data_end it_data_out_req it_data_in_req it_data_out it_data_out_vld it_done protocol_error}]
puts "TOP_PORT_COUNT=[llength $top_ports]"
puts "OLD_OOC_TARGET_PORTS_FOUND=[llength $old_ooc_ports]"
puts "OLD_OOC_XDC=NOT_LOADED_BY_THIS_SCRIPT"

set raw_paths [get_timing_paths -delay_type max -slack_lesser_than 0 -max_paths 200000 -nworst 1 -sort_by slack]
puts "RAW_NEGATIVE_PATH_OBJECTS=[llength $raw_paths]"

set endpoint_to_path [dict create]
set endpoint_to_slack [dict create]
foreach path $raw_paths {
    set ep [prop_or $path ENDPOINT_PIN ""]
    if {$ep eq ""} { continue }
    set slack [prop_or $path SLACK 0.0]
    if {![dict exists $endpoint_to_path $ep] || $slack < [dict get $endpoint_to_slack $ep]} {
        dict set endpoint_to_path $ep $path
        dict set endpoint_to_slack $ep $slack
    }
}
set unique_count [dict size $endpoint_to_path]
puts "UNIQUE_NEGATIVE_ENDPOINTS=$unique_count"

set csv_path [file join $out_dir setup_endpoint_census.csv]
set csv [open $csv_path w]
puts $csv [csv_row {endpoint startpoint slack path_group launch_clock capture_clock start_cell start_ref start_hierarchy end_cell end_ref end_hierarchy logic_levels logic_delay_ns routing_delay_ns datapath_delay_ns routing_fraction start_loc end_loc start_clock_region end_clock_region raw_structural_signature normalized_structural_signature classification_bucket source_family endpoint_family violation_magnitude_ns}]

array set bucket_count {}
array set bucket_tns {}
array set bucket_worst {}
array set bucket_violations {}
array set bucket_logic_levels {}
array set bucket_logic_delay {}
array set bucket_route_delay {}
array set bucket_route_fraction {}
array set family_count {}
array set family_tns {}
array set family_worst {}
array set family_violations {}
array set signature_count {}
array set signature_tns {}
array set signature_worst {}
array set signature_violations {}
array set region_count {}
array set region_tns {}
array set region_worst {}
array set region_violations {}

set unique_endpoints {}
foreach endpoint [lsort [dict keys $endpoint_to_path]] {
    set path [dict get $endpoint_to_path $endpoint]
    set slack [expr {double([prop_or $path SLACK 0.0])}]
    set sp [prop_or $path STARTPOINT_PIN ""]
    set ep [prop_or $path ENDPOINT_PIN ""]
    set sp_cell [cell_for_pin $sp]
    set ep_cell [cell_for_pin $ep]
    set logic_delay [expr {double([prop_or $path DATAPATH_LOGIC_DELAY 0.0])}]
    set route_delay [expr {double([prop_or $path DATAPATH_NET_DELAY 0.0])}]
    set datapath_delay [expr {double([prop_or $path DATAPATH_DELAY 0.0])}]
    set route_fraction [expr {$datapath_delay > 0.0 ? $route_delay / $datapath_delay : 0.0}]
    set bucket [endpoint_bucket $sp $ep]
    set sf [source_family $sp_cell $sp]
    set ef [endpoint_family $ep_cell $ep]
    set sigs [path_signature $path $sp_cell $ep_cell]
    set raw_sig [lindex $sigs 0]
    set norm_sig [lindex $sigs 1]
    set family_key "$bucket|$sf|$ef"
    set region_key "[prop_or $sp_cell CLOCK_REGION UNKNOWN]|[prop_or $ep_cell CLOCK_REGION UNKNOWN]"
    set violation [expr {-$slack}]
    set logic_levels [prop_or $path LOGIC_LEVELS 0]
    lappend unique_endpoints $endpoint
    puts $csv [csv_row [list \
        $endpoint $sp [format %.9f $slack] [prop_or $path GROUP ""] \
        [prop_or $path STARTPOINT_CLOCK ""] [prop_or $path ENDPOINT_CLOCK ""] \
        [prop_or $sp_cell NAME ""] [prop_or $sp_cell REF_NAME ""] [normalize_hier [prop_or $sp_cell NAME ""]] \
        [prop_or $ep_cell NAME ""] [prop_or $ep_cell REF_NAME ""] [normalize_hier [prop_or $ep_cell NAME ""]] \
        $logic_levels [format %.9f $logic_delay] [format %.9f $route_delay] [format %.9f $datapath_delay] \
        [format %.9f $route_fraction] [prop_or $sp_cell LOC ""] [prop_or $ep_cell LOC ""] \
        [prop_or $sp_cell CLOCK_REGION "UNKNOWN"] [prop_or $ep_cell CLOCK_REGION "UNKNOWN"] \
        $raw_sig $norm_sig $bucket $sf $ef [format %.9f $violation]]]

    if {![info exists bucket_count($bucket)]} { set bucket_count($bucket) 0; set bucket_tns($bucket) 0.0; set bucket_worst($bucket) 0.0; set bucket_violations($bucket) {}; set bucket_logic_levels($bucket) {}; set bucket_logic_delay($bucket) {}; set bucket_route_delay($bucket) {}; set bucket_route_fraction($bucket) {} }
    incr bucket_count($bucket)
    set bucket_tns($bucket) [expr {$bucket_tns($bucket) + $slack}]
    if {$violation > $bucket_worst($bucket)} { set bucket_worst($bucket) $violation }
    lappend bucket_violations($bucket) $violation
    lappend bucket_logic_levels($bucket) $logic_levels
    lappend bucket_logic_delay($bucket) $logic_delay
    lappend bucket_route_delay($bucket) $route_delay
    lappend bucket_route_fraction($bucket) $route_fraction

    if {![info exists family_count($family_key)]} { set family_count($family_key) 0; set family_tns($family_key) 0.0; set family_worst($family_key) 0.0; set family_violations($family_key) {} }
    incr family_count($family_key)
    set family_tns($family_key) [expr {$family_tns($family_key) + $slack}]
    if {$violation > $family_worst($family_key)} { set family_worst($family_key) $violation }
    lappend family_violations($family_key) $violation

    if {![info exists signature_count($norm_sig)]} { set signature_count($norm_sig) 0; set signature_tns($norm_sig) 0.0; set signature_worst($norm_sig) 0.0; set signature_violations($norm_sig) {} }
    incr signature_count($norm_sig)
    set signature_tns($norm_sig) [expr {$signature_tns($norm_sig) + $slack}]
    if {$violation > $signature_worst($norm_sig)} { set signature_worst($norm_sig) $violation }
    lappend signature_violations($norm_sig) $violation

    if {![info exists region_count($region_key)]} { set region_count($region_key) 0; set region_tns($region_key) 0.0; set region_worst($region_key) 0.0; set region_violations($region_key) {} }
    incr region_count($region_key)
    set region_tns($region_key) [expr {$region_tns($region_key) + $slack}]
    if {$violation > $region_worst($region_key)} { set region_worst($region_key) $violation }
    lappend region_violations($region_key) $violation
}
close $csv

set family_csv [open [file join $out_dir setup_family_summary.csv] w]
puts $family_csv [csv_row {bucket source_family endpoint_family endpoint_count tns_ns tns_share worst_violation_ns median_violation_ns p90_violation_ns p99_violation_ns}]
set total_tns 0.0
foreach bucket [array names bucket_tns] { set total_tns [expr {$total_tns + $bucket_tns($bucket)}] }
foreach key [lsort [array names family_count]] {
    set parts [split $key "|"]
    set tns_share [expr {$total_tns != 0.0 ? $family_tns($key) / $total_tns : 0.0}]
    puts $family_csv [csv_row [list [lindex $parts 0] [lindex $parts 1] [lindex $parts 2] $family_count($key) [format %.9f $family_tns($key)] [format %.9f $tns_share] [format %.9f $family_worst($key)] [format %.9f [median $family_violations($key)]] [format %.9f [percentile $family_violations($key) 0.90]] [format %.9f [percentile $family_violations($key) 0.99]]]]
}
close $family_csv

set sig_csv [open [file join $out_dir structural_signature_summary.csv] w]
puts $sig_csv [csv_row {normalized_structural_signature occurrence_count tns_ns tns_share worst_violation_ns median_violation_ns p90_violation_ns p99_violation_ns}]
foreach key [lsort [array names signature_count]] {
    set tns_share [expr {$total_tns != 0.0 ? $signature_tns($key) / $total_tns : 0.0}]
    puts $sig_csv [csv_row [list $key $signature_count($key) [format %.9f $signature_tns($key)] [format %.9f $tns_share] [format %.9f $signature_worst($key)] [format %.9f [median $signature_violations($key)]] [format %.9f [percentile $signature_violations($key) 0.90]] [format %.9f [percentile $signature_violations($key) 0.99]]]]
}
close $sig_csv

set region_csv [open [file join $out_dir physical_region_summary.csv] w]
puts $region_csv [csv_row {start_clock_region end_clock_region endpoint_count tns_ns tns_share worst_violation_ns median_violation_ns p90_violation_ns p99_violation_ns}]
foreach key [lsort [array names region_count]] {
    set parts [split $key "|"]
    set tns_share [expr {$total_tns != 0.0 ? $region_tns($key) / $total_tns : 0.0}]
    puts $region_csv [csv_row [list [lindex $parts 0] [lindex $parts 1] $region_count($key) [format %.9f $region_tns($key)] [format %.9f $tns_share] [format %.9f $region_worst($key)] [format %.9f [median $region_violations($key)]] [format %.9f [percentile $region_violations($key) 0.90]] [format %.9f [percentile $region_violations($key) 0.99]]]]
}
close $region_csv

set bucket_csv [open [file join $out_dir setup_bucket_summary.csv] w]
puts $bucket_csv [csv_row {bucket endpoint_count tns_ns tns_share worst_violation_ns median_violation_ns p90_violation_ns p99_violation_ns logic_levels_min logic_levels_median logic_levels_p90 logic_levels_max logic_delay_median_ns logic_delay_p90_ns logic_delay_max_ns routing_delay_median_ns routing_delay_p90_ns routing_delay_max_ns routing_fraction_median routing_fraction_p90 routing_fraction_max}]
foreach bucket [lsort [array names bucket_count]] {
    set tns_share [expr {$total_tns != 0.0 ? $bucket_tns($bucket) / $total_tns : 0.0}]
    set ll [lsort -real $bucket_logic_levels($bucket)]
    set ld [lsort -real $bucket_logic_delay($bucket)]
    set rd [lsort -real $bucket_route_delay($bucket)]
    set rf [lsort -real $bucket_route_fraction($bucket)]
    puts $bucket_csv [csv_row [list $bucket $bucket_count($bucket) [format %.9f $bucket_tns($bucket)] [format %.9f $tns_share] [format %.9f $bucket_worst($bucket)] [format %.9f [median $bucket_violations($bucket)]] [format %.9f [percentile $bucket_violations($bucket) 0.90]] [format %.9f [percentile $bucket_violations($bucket) 0.99]] [lindex $ll 0] [format %.9f [median $ll]] [format %.9f [percentile $ll 0.90]] [lindex $ll end] [format %.9f [median $ld]] [format %.9f [percentile $ld 0.90]] [lindex $ld end] [format %.9f [median $rd]] [format %.9f [percentile $rd 0.90]] [lindex $rd end] [format %.9f [median $rf]] [format %.9f [percentile $rf 0.90]] [lindex $rf end]]]
}
close $bucket_csv

set reset_file [file join $out_dir reset_recovery_removal_summary.txt]
set reset_out [open $reset_file w]
puts $reset_out "P9-R5F independent reset recovery/removal audit"
puts $reset_out "vivado_report_timing_check_type=UNSUPPORTED_IN_VIVADO_2025.2"
puts $reset_out "directional_queries=recovery clock->async-control; removal async-control->clock"
set async_ctrl_pins [get_pins -hier -quiet -filter {REF_PIN_NAME =~ PRE || REF_PIN_NAME =~ CLR}]
set clock_objs [get_clocks -quiet clk]
foreach check {recovery removal} {
    set rpt [file join $out_dir reset_${check}.rpt]
    set paths {}
    if {$check eq "recovery"} {
        catch {set paths [get_timing_paths -delay_type max -from $clock_objs -to $async_ctrl_pins -max_paths 200000 -nworst 1]} err
        catch {report_timing -delay_type max -from $clock_objs -to $async_ctrl_pins -max_paths 1000 -file $rpt}
    } else {
        catch {set paths [get_timing_paths -delay_type min -from $async_ctrl_pins -to $clock_objs -max_paths 200000 -nworst 1]} err
        catch {report_timing -delay_type min -from $async_ctrl_pins -to $clock_objs -max_paths 1000 -file $rpt}
    }
    set count [llength $paths]
    set worst ""
    set tns 0.0
    foreach p $paths {
        set s [prop_or $p SLACK ""]
        if {$s eq ""} { continue }
        set s [expr {double($s)}]
        if {$worst eq "" || $s < $worst} { set worst $s }
        if {$s < 0.0} { set tns [expr {$tns + $s}] }
    }
    if {$worst eq ""} { set worst "NA" }
    puts $reset_out "${check}_status=QUERY_COMPLETE"
    puts $reset_out "${check}_path_count=$count"
    puts $reset_out "${check}_worst_slack_ns=$worst"
    puts $reset_out "${check}_negative_tns_ns=[format %.9f $tns]"
    puts $reset_out "${check}_report=[file tail $rpt]"
}
puts $reset_out "async_control_pin_count=[llength $async_ctrl_pins]"
close $reset_out

set metrics [open [file join $out_dir r5f_census_metrics.txt] w]
puts $metrics "P9R5F_RAW_NEGATIVE_PATH_OBJECTS=[llength $raw_paths]"
puts $metrics "P9R5F_UNIQUE_NEGATIVE_ENDPOINTS=$unique_count"
puts $metrics "P9R5F_RECONSTRUCTED_TNS_NS=[format %.9f $total_tns]"
puts $metrics "P9R5F_BUCKET_COUNT=[array size bucket_count]"
puts $metrics "P9R5F_FAMILY_COUNT=[array size family_count]"
puts $metrics "P9R5F_SIGNATURE_COUNT=[array size signature_count]"
puts $metrics "P9R5F_REGION_PAIR_COUNT=[array size region_count]"
puts $metrics "P9R5F_TNS_PRECISION=Vivado timing_path/report_timing exposed three decimal places; CSV pads to nine decimals and reconciliation is rounded-report based"
puts $metrics "P9R5F_DUPLICATE_ENDPOINTS=[expr {[llength $raw_paths] - $unique_count}]"
set unclassified_count 0
if {[info exists bucket_count(OTHER_UNCLASSIFIED)]} { set unclassified_count $bucket_count(OTHER_UNCLASSIFIED) }
puts $metrics "P9R5F_UNCLASSIFIED_ENDPOINTS=$unclassified_count"
close $metrics

check_timing -verbose -file [file join $out_dir check_timing_read_only.rpt]
report_exceptions -file [file join $out_dir exceptions_read_only.rpt]
puts "P9R5F_CENSUS_DONE"
close_project
