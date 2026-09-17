# Step12F P9-R5G G0 read-only physical-locality qualification.
#
# This script opens one fixed routed registered-neighbor DCP and only queries
# placed cells, sites/tiles, fanout, and timing-path properties.  It must not
# synthesize, optimize, place, phys_opt, route, write a checkpoint, or read an
# XDC.  The launcher records the DCP SHA-256 before invoking Vivado.

set dcp_path $::env(STEP12F_R5G_DCP)
set out_dir  $::env(STEP12F_R5G_G0_DIR)
file mkdir $out_dir

proc prop_or {obj prop {fallback ""}} {
    if {$obj eq ""} { return $fallback }
    if {[catch {set value [get_property $prop $obj]}]} { return $fallback }
    if {$value eq ""} { return $fallback }
    return $value
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

proc site_for_cell {cell} {
    set sites [get_sites -quiet -of_objects $cell]
    if {[llength $sites] > 0} { return [lindex $sites 0] }
    set loc [prop_or $cell LOC ""]
    if {$loc ne ""} {
        set sites [get_sites -quiet $loc]
        if {[llength $sites] > 0} { return [lindex $sites 0] }
    }
    return ""
}

proc tile_for_site {site} {
    if {$site eq ""} { return "" }
    set tiles [get_tiles -quiet -of_objects $site]
    if {[llength $tiles] > 0} { return [lindex $tiles 0] }
    return ""
}

proc site_type_or {site} {
    if {$site eq ""} { return "" }
    set value [prop_or $site SITE_TYPE ""]
    if {$value eq ""} { set value [prop_or $site TYPE ""] }
    return $value
}

proc tile_coord {tile prop fallback} {
    if {$tile eq ""} { return $fallback }
    set value [prop_or $tile $prop ""]
    if {$value ne ""} { return $value }
    if {$prop eq "GRID_POINT_X"} { return [prop_or $tile TILE_X $fallback] }
    if {$prop eq "GRID_POINT_Y"} { return [prop_or $tile TILE_Y $fallback] }
    return $fallback
}

proc fanout_for_cell {cell} {
    set total 0
    set outpins [get_pins -quiet -of_objects $cell -filter {DIRECTION == OUT}]
    foreach pin $outpins {
        foreach net [get_nets -quiet -of_objects $pin] {
            set total [expr {$total + [llength [get_pins -quiet -of_objects $net -filter {DIRECTION == IN}]]}]
        }
    }
    return $total
}

proc family_for_name {name} {
    set value $name
    regsub -all {\[[^]]+\]} $value {} value
    regsub -all {_replica(?:_[0-9]+)?} {_replica} value
    if {[string match "*ingress_group_q_reg*" $value]} { return "ingress_group_q_reg" }
    if {[string match "*ingress_data_q_reg*" $value]} { return "ingress_data_q_reg" }
    if {[string match "*input_mem_reg*" $value]} { return "input_mem_reg" }
    if {[string match "*input_cache_bank*" $value]} { return "input_cache_bank" }
    if {[string match "*fill_wr_cmd_addr_q_reg*" $value]} { return "fill_wr_cmd_addr_q_reg" }
    if {[string match "*lfnst_grid_reg*" $value]} { return "lfnst_grid_reg" }
    if {[string match "*result_cmd_valid_q_reg*" $value]} { return "result_cmd_valid_q_reg" }
    if {[string match "*result_cmd_slot_q_reg*" $value]} { return "result_cmd_slot_q_reg" }
    if {[string match "*result_bank*" $value]} { return "result_bank" }
    if {[string match "*rd_cmd_addr_q_reg*" $value]} { return "rd_cmd_addr_q_reg" }
    if {[string match "*kernel_rd_raw_data_q_reg*" $value]} { return "kernel_rd_raw_data_q_reg" }
    if {[string match "*kernel_h_rd_addr_q_reg*" $value]} { return "kernel_h_rd_addr_q_reg" }
    if {[string match "*kernel_h_rd_data_q_reg*" $value]} { return "kernel_h_rd_data_q_reg" }
    if {[string match "*kernel_run_q_reg*" $value]} { return "kernel_run_q_reg" }
    if {[string match "*vwrite_cmd_data_q_reg*" $value]} { return "vwrite_cmd_data_q_reg" }
    return "other"
}

set_param general.maxThreads 4
puts "P9R5G_G0_START"
puts "DCP=$dcp_path"
puts "OUT_DIR=$out_dir"
puts "MAX_THREADS=4"
puts "READ_ONLY=TRUE"
open_checkpoint $dcp_path
puts "VIVADO_VERSION=[version -short]"
puts "PART=[prop_or [current_design] PART UNKNOWN]"

set inventory_path [file join $out_dir g0_cell_inventory.csv]
set inventory [open $inventory_path w]
puts $inventory [csv_row {cell_name family ref_name loc bel site site_type tile tile_x tile_y slr clock_region fanout}]

# Query only the bounded cell populations relevant to the G0 hypothesis.  A
# whole-design get_cells followed by per-cell site/tile/fanout queries is
# needlessly expensive on this DCP and can dominate a read-only audit.
set all_cells {}
foreach pattern {
    *ingress_group_q_reg*
    *ingress_data_q_reg*
    *input_mem_reg*
    *input_cache_bank*
    *fill_wr_cmd_addr_q_reg*
    *lfnst_grid_reg*
    *result_cmd_valid_q_reg*
    *result_cmd_slot_q_reg*
    *result_bank*
    *rd_cmd_addr_q_reg*
    *kernel_rd_raw_data_q_reg*
    *kernel_h_rd_addr_q_reg*
    *kernel_h_rd_data_q_reg*
    *kernel_run_q_reg*
    *vwrite_cmd_data_q_reg*
} {
    foreach cell [get_cells -hier -quiet $pattern] {
        if {[lsearch -exact $all_cells $cell] < 0} { lappend all_cells $cell }
    }
}
set selected 0
set family_counts [dict create]
foreach cell $all_cells {
    set name [prop_or $cell NAME ""]
    set family [family_for_name $name]
    if {$family eq "other"} { continue }
    set site [site_for_cell $cell]
    set tile [tile_for_site $site]
    set tx [tile_coord $tile GRID_POINT_X ""]
    set ty [tile_coord $tile GRID_POINT_Y ""]
    set slr [prop_or $tile SLR_INDEX [prop_or $site SLR_INDEX ""]]
    set cr [prop_or $site CLOCK_REGION [prop_or $cell CLOCK_REGION ""]]
    set cell_fanout ""
    # Fanout is useful for the producer/control populations, but querying it
    # for every memory bit creates a large, unnecessary object traversal.
    if {$family eq "ingress_group_q_reg" || $family eq "ingress_data_q_reg" || $family eq "kernel_run_q_reg" || $family eq "fill_wr_cmd_addr_q_reg"} {
        set cell_fanout [fanout_for_cell $cell]
    }
    puts $inventory [csv_row [list \
        $name $family [prop_or $cell REF_NAME ""] [prop_or $cell LOC ""] \
        [prop_or $cell BEL ""] [prop_or $site NAME ""] [site_type_or $site] \
        [prop_or $tile NAME ""] $tx $ty $slr $cr $cell_fanout]]
    incr selected
    dict incr family_counts $family
}
close $inventory
puts "INVENTORY_SELECTED=$selected"
puts "INVENTORY_FAMILIES=$family_counts"

# Query one best max-delay path per destination for the two largest ingress
# source populations.  This includes both positive and negative slack paths,
# enabling a failing-vs-passing spatial comparison without changing the DCP.
set src_group_cells [get_cells -hier -quiet *ingress_group_q_reg*]
set src_data_cells  [get_cells -hier -quiet *ingress_data_q_reg*]
set dst_cells       [get_cells -hier -quiet *input_mem_reg*]
set src_group_pins [get_pins -quiet -of_objects $src_group_cells -filter {DIRECTION == OUT}]
set src_data_pins  [get_pins -quiet -of_objects $src_data_cells -filter {DIRECTION == OUT}]
set dst_pins {}
foreach cell $dst_cells {
    foreach pin [get_pins -quiet -of_objects $cell -filter {DIRECTION == IN}] {
        set ref_pin [prop_or $pin REF_PIN_NAME ""]
        if {$ref_pin eq "D" || $ref_pin eq "CE"} { lappend dst_pins $pin }
    }
}
puts "INGRESS_GROUP_SOURCE_PINS=[llength $src_group_pins]"
puts "INGRESS_DATA_SOURCE_PINS=[llength $src_data_pins]"
puts "INPUT_MEM_DEST_PINS=[llength $dst_pins]"

set path_csv [open [file join $out_dir g0_ingress_inputmem_paths.csv] w]
puts $path_csv [csv_row {source_family startpoint endpoint slack logic_levels logic_delay_ns routing_delay_ns datapath_delay_ns start_cell start_loc end_cell end_loc start_tile start_tile_x start_tile_y end_tile end_tile_x end_tile_y}]

foreach source_spec [list [list ingress_group_q_reg $src_group_pins] [list ingress_data_q_reg $src_data_pins]] {
    set source_family [lindex $source_spec 0]
    set source_pins [lindex $source_spec 1]
    set paths {}
    if {[llength $source_pins] > 0 && [llength $dst_pins] > 0} {
        catch {set paths [get_timing_paths -delay_type max -from $source_pins -to $dst_pins -max_paths 200000 -nworst 1]} err
        puts "PATH_QUERY_$source_family=[llength $paths]"
    }
    foreach path $paths {
        set sp [prop_or $path STARTPOINT_PIN ""]
        set ep [prop_or $path ENDPOINT_PIN ""]
        set sp_cell [lindex [get_cells -quiet -of_objects [get_pins -quiet $sp]] 0]
        set ep_cell [lindex [get_cells -quiet -of_objects [get_pins -quiet $ep]] 0]
        set sp_site [site_for_cell $sp_cell]
        set ep_site [site_for_cell $ep_cell]
        set sp_tile [tile_for_site $sp_site]
        set ep_tile [tile_for_site $ep_site]
        puts $path_csv [csv_row [list \
            $source_family $sp $ep [prop_or $path SLACK ""] [prop_or $path LOGIC_LEVELS ""] \
            [prop_or $path DATAPATH_LOGIC_DELAY ""] [prop_or $path DATAPATH_NET_DELAY ""] [prop_or $path DATAPATH_DELAY ""] \
            [prop_or $sp_cell NAME ""] [prop_or $sp_cell LOC ""] [prop_or $ep_cell NAME ""] [prop_or $ep_cell LOC ""] \
            [prop_or $sp_tile NAME ""] [tile_coord $sp_tile GRID_POINT_X ""] [tile_coord $sp_tile GRID_POINT_Y ""] \
            [prop_or $ep_tile NAME ""] [tile_coord $ep_tile GRID_POINT_X ""] [tile_coord $ep_tile GRID_POINT_Y ""]]]
    }
}
close $path_csv

set timing_summary [open [file join $out_dir g0_timing_query_summary.txt] w]
puts $timing_summary "P9-R5G G0 timing query"
puts $timing_summary "dcp=$dcp_path"
puts $timing_summary "source_families=ingress_group_q_reg,ingress_data_q_reg"
puts $timing_summary "destination_family=input_mem_reg (D and CE pins)"
puts $timing_summary "query=one max-delay path per destination, positive and negative slack retained"
puts $timing_summary "no synthesis/implementation/constraints/write_checkpoint performed"
close $timing_summary

set status [open [file join $out_dir g0_read_only_status.txt] w]
puts $status "status=READ_ONLY_COMPLETE"
puts $status "vivado_version=[version -short]"
puts $status "maxThreads=4"
puts $status "dcp=$dcp_path"
puts $status "rtl_changes=FORBIDDEN"
puts $status "xdc_changes=FORBIDDEN"
puts $status "implementation_commands=FORBIDDEN"
close $status
puts "P9R5G_G0_DONE"
close_project
