# Step12F P9-R5G G0.5 read-only geometry/risk qualification.
#
# This script opens the fixed R5E routed DCP and collects timing/placement
# evidence only.  It must not run opt/place/phys_opt/route, create or resize
# pblocks, set design-object properties, read XDC, or write a modified DCP.

set dcp_path $::env(STEP12F_R5G_DCP)
set out_dir  $::env(STEP12F_R5G_G05_DIR)
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
    if {$cell eq ""} { return "" }
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

proc site_tile_fields {site} {
    set tile [tile_for_site $site]
    return [list \
        [prop_or $site NAME ""] \
        [prop_or $site SITE_TYPE ""] \
        [prop_or $tile NAME ""] \
        [prop_or $tile GRID_POINT_X ""] \
        [prop_or $tile GRID_POINT_Y ""] \
        [prop_or $site CLOCK_REGION [prop_or $tile CLOCK_REGION ""]]]
}

proc source_family {name} {
    if {[string match "*lfnst_grid_reg*" $name]} { return "lfnst_grid" }
    if {[string match "*kernel_vector_q_reg*" $name]} { return "kernel_vector" }
    if {[string match "*kernel_stage_q_reg*" $name]} { return "kernel_stage" }
    if {[string match "*kernel_*q_reg*" $name]} { return "kernel_control" }
    if {[string match "*input_mem_reg*" $name]} { return "input_mem" }
    if {[string match "*ingress_data_q_reg*" $name]} { return "ingress_data" }
    if {[string match "*ingress_group_q_reg*" $name]} { return "ingress_group" }
    if {[string match "*boundary*" $name]} { return "boundary" }
    return "other"
}

proc cell_from_pin {pin} {
    if {$pin eq ""} { return "" }
    set cells [get_cells -quiet -of_objects [get_pins -quiet $pin]]
    if {[llength $cells] > 0} { return [lindex $cells 0] }
    return ""
}

proc connected_net_name {cell ref_pin} {
    if {$cell eq ""} { return "" }
    set pins [get_pins -quiet -of_objects $cell -filter "REF_PIN_NAME == $ref_pin"]
    if {[llength $pins] == 0} { return "" }
    set nets [get_nets -quiet -of_objects [lindex $pins 0]]
    if {[llength $nets] == 0} { return "" }
    return [prop_or [lindex $nets 0] NAME ""]
}

proc control_set_key {cell} {
    # CONTROL_SET is not consistently materialized as a cell property in a
    # routed DCP.  Build an auditable equivalent from the connected clock,
    # enable, and reset pins for FF cells; LUTs return an empty key.
    set ref [prop_or $cell REF_NAME ""]
    if {![string match "FD*" $ref] && ![string match "LD*" $ref]} { return "" }
    set clk [connected_net_name $cell C]
    set ce  [connected_net_name $cell CE]
    set sr  [connected_net_name $cell R]
    if {$sr eq ""} { set sr [connected_net_name $cell CLR] }
    if {$sr eq ""} { set sr [connected_net_name $cell S] }
    return "$clk|$ce|$sr"
}

set_param general.maxThreads 4
puts "P9R5G_G05_START"
puts "DCP=$dcp_path"
puts "OUT_DIR=$out_dir"
puts "MAX_THREADS=4"
puts "READ_ONLY=TRUE"
open_checkpoint $dcp_path
puts "VIVADO_VERSION=[version -short]"
puts "PART=[prop_or [current_design] PART UNKNOWN]"

# Exact original producer cells.  Replica names are intentionally excluded
# here; post-phys-opt lineage is a G1 concern, not a G0.5 query.
set producer_cells {}
foreach cell [get_cells -hier -quiet *ingress_data_q_reg*] {
    set name [prop_or $cell NAME ""]
    if {[regexp {ingress_data_q_reg\[[0-9]+\]$} $name]} {
        lappend producer_cells $cell
    }
}
set producer_cells [lsort -unique $producer_cells]
set input_mem_cells [get_cells -hier -quiet *input_mem_reg*]
set input_mem_cells [lsort -unique $input_mem_cells]
puts "PRODUCER_CELLS=[llength $producer_cells]"
puts "INPUT_MEM_CELLS=[llength $input_mem_cells]"

set producer_csv [open [file join $out_dir g05_producer_inventory.csv] w]
puts $producer_csv [csv_row {cell_name bit_index ref_name loc bel site site_type tile tile_x tile_y clock_region fanout d_pin}]
foreach cell $producer_cells {
    set name [prop_or $cell NAME ""]
    set bit ""
    regexp {ingress_data_q_reg\[([0-9]+)\]$} $name -> bit
    set site [site_for_cell $cell]
    set fields [site_tile_fields $site]
    set dp [lindex [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == D}] 0]
    set outpins [get_pins -quiet -of_objects $cell -filter {DIRECTION == OUT}]
    set fo 0
    foreach op $outpins {
        foreach net [get_nets -quiet -of_objects $op] {
            set fo [expr {$fo + [llength [get_pins -quiet -of_objects $net -filter {DIRECTION == IN}]]}]
        }
    }
    puts $producer_csv [csv_row [list \
        $name $bit [prop_or $cell REF_NAME ""] [prop_or $cell LOC ""] [prop_or $cell BEL ""] \
        [lindex $fields 0] [lindex $fields 1] [lindex $fields 2] [lindex $fields 3] [lindex $fields 4] \
        [lindex $fields 5] $fo [prop_or $dp NAME ""]]]
}
close $producer_csv

# Full upstream max-delay census: one path per ingress_data D endpoint.
set upstream_csv [open [file join $out_dir g05_upstream_paths.csv] w]
puts $upstream_csv [csv_row {ingress_bit endpoint_d startpoint slack logic_levels logic_delay_ns routing_delay_ns datapath_delay_ns start_cell start_loc start_site start_tile start_tile_x start_tile_y start_clock_region end_cell end_loc end_site end_tile end_tile_x end_tile_y end_clock_region source_family}]
set upstream_count 0
set upstream_path_count 0
foreach cell $producer_cells {
    set name [prop_or $cell NAME ""]
    set bit ""
    regexp {ingress_data_q_reg\[([0-9]+)\]$} $name -> bit
    set dp [lindex [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == D}] 0]
    if {$dp eq ""} { continue }
    incr upstream_count
    set paths {}
    catch {set paths [get_timing_paths -delay_type max -to $dp -max_paths 1 -nworst 1]} err
    if {[llength $paths] == 0} { continue }
    set path [lindex $paths 0]
    incr upstream_path_count
    set sp [prop_or $path STARTPOINT_PIN ""]
    set ep [prop_or $path ENDPOINT_PIN ""]
    set sc [cell_from_pin $sp]
    set ec [cell_from_pin $ep]
    set ss [site_for_cell $sc]
    set es [site_for_cell $ec]
    set st [tile_for_site $ss]
    set et [tile_for_site $es]
    puts $upstream_csv [csv_row [list \
        $bit [prop_or $ep NAME ""] $sp [prop_or $path SLACK ""] [prop_or $path LOGIC_LEVELS ""] \
        [prop_or $path DATAPATH_LOGIC_DELAY ""] [prop_or $path DATAPATH_NET_DELAY ""] [prop_or $path DATAPATH_DELAY ""] \
        [prop_or $sc NAME ""] [prop_or $sc LOC ""] [prop_or $ss NAME ""] [prop_or $st NAME ""] \
        [prop_or $st GRID_POINT_X ""] [prop_or $st GRID_POINT_Y ""] [prop_or $ss CLOCK_REGION [prop_or $st CLOCK_REGION ""]] \
        [prop_or $ec NAME ""] [prop_or $ec LOC ""] [prop_or $es NAME ""] [prop_or $et NAME ""] \
        [prop_or $et GRID_POINT_X ""] [prop_or $et GRID_POINT_Y ""] [prop_or $es CLOCK_REGION [prop_or $et CLOCK_REGION ""]] \
        [source_family [prop_or $sc NAME ""]]]]
}
close $upstream_csv
puts "UPSTREAM_ENDPOINTS=$upstream_count"
puts "UPSTREAM_PATHS=$upstream_path_count"

# Candidate site inventory.  The observed G0 destination sites are around
# SLICE_X52..X99/Y71..Y117.  Query a deliberately wider, fixed envelope so
# G0.5 can evaluate a loose candidate without creating a pblock.
set candidate_site_csv [open [file join $out_dir g05_candidate_site_inventory.csv] w]
puts $candidate_site_csv [csv_row {site site_type tile tile_x tile_y clock_region legal_ff_bel_count legal_lut_bel_count occupied_cell_count occupied_ff_count occupied_lut_count occupied_control_sets occupied_cells}]
set site_count 0
set all_sites [get_sites -quiet -filter {SITE_TYPE == SLICEL || SITE_TYPE == SLICEM}]
foreach site $all_sites {
    set name [prop_or $site NAME ""]
    if {![regexp {^SLICE_X([0-9]+)Y([0-9]+)$} $name -> sx sy]} { continue }
    if {$sx < 40 || $sx > 115 || $sy < 55 || $sy > 135} { continue }
    set tile [tile_for_site $site]
    set cells [get_cells -quiet -of_objects $site]
    set ff 0
    set lut 0
    set control_sets {}
    foreach c $cells {
        set ref [prop_or $c REF_NAME ""]
        if {[string match "FD*" $ref] || [string match "LD*" $ref]} { incr ff }
        if {[string match "LUT*" $ref]} { incr lut }
        set cs [control_set_key $c]
        if {$cs ne "" && [lsearch -exact $control_sets $cs] < 0} { lappend control_sets $cs }
    }
    set legal_ff_bels 0
    set legal_lut_bels 0
    foreach bel [get_bels -quiet -of_objects $site] {
        set bel_name [prop_or $bel NAME ""]
        if {[regexp {([A-H]FF|[A-H]FF[0-9]+)$} $bel_name]} { incr legal_ff_bels }
        if {[regexp {[A-H][0-9]?LUT$} $bel_name]} { incr legal_lut_bels }
    }
    puts $candidate_site_csv [csv_row [list \
        $name [prop_or $site SITE_TYPE ""] [prop_or $tile NAME ""] [prop_or $tile GRID_POINT_X ""] \
        [prop_or $tile GRID_POINT_Y ""] [prop_or $site CLOCK_REGION [prop_or $tile CLOCK_REGION ""]] \
        $legal_ff_bels $legal_lut_bels [llength $cells] $ff $lut [join $control_sets {;}] \
        [join [lmap c $cells {prop_or $c NAME ""}] {;}] ]]
    incr site_count
}
close $candidate_site_csv
puts "CANDIDATE_SITES=$site_count"

set status [open [file join $out_dir g05_read_only_status.txt] w]
puts $status "status=READ_ONLY_COMPLETE"
puts $status "vivado_version=[version -short]"
puts $status "maxThreads=4"
puts $status "dcp=$dcp_path"
puts $status "producer_cells=[llength $producer_cells]"
puts $status "input_mem_cells=[llength $input_mem_cells]"
puts $status "upstream_endpoints=$upstream_count"
puts $status "upstream_paths=$upstream_path_count"
puts $status "candidate_sites=$site_count"
puts $status "rtl_changes=FORBIDDEN"
puts $status "xdc_changes=FORBIDDEN"
puts $status "implementation_commands=FORBIDDEN"
close $status

puts "P9R5G_G05_DONE"
close_project

