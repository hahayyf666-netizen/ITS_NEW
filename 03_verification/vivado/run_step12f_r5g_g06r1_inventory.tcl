# Step12F P9-R5G-G0.6R1 expanded site inventory extraction.
#
# Read-only only.  This script opens the fixed routed R5E DCP and extracts the
# producer and SLICE site inventory over the frozen R1 envelope.  It must not
# invoke opt/place/phys_opt/route, create pblocks, set design-object
# properties, read/write modified XDC, or write a checkpoint.

set dcp_path $::env(STEP12F_R5G_G06R1_DCP)
set out_dir  $::env(STEP12F_R5G_G06R1_DIR)
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

proc control_set_key {cell} {
    set ref [prop_or $cell REF_NAME ""]
    if {![string match "FD*" $ref] && ![string match "LD*" $ref]} { return "" }
    set pins [get_pins -quiet -of_objects $cell]
    set values {}
    foreach pin $pins {
        set refpin [prop_or $pin REF_PIN_NAME ""]
        if {$refpin ni {C CE R CLR S}} { continue }
        set nets [get_nets -quiet -of_objects $pin]
        set net_name ""
        if {[llength $nets] > 0} { set net_name [prop_or [lindex $nets 0] NAME ""] }
        lappend values "$refpin=$net_name"
    }
    return [join $values "|"]
}

set_param general.maxThreads 4
puts "P9R5G_G06R1_INVENTORY_START"
puts "DCP=$dcp_path"
puts "OUT_DIR=$out_dir"
puts "MAX_THREADS=4"
puts "READ_ONLY=TRUE"
open_checkpoint $dcp_path
puts "VIVADO_VERSION=[version -short]"

# Exact non-replica ingress producer cells.
set producer_cells {}
foreach cell [get_cells -hier -quiet *ingress_data_q_reg*] {
    set name [prop_or $cell NAME ""]
    if {[regexp {ingress_data_q_reg\[[0-9]+\]$} $name]} { lappend producer_cells $cell }
}
set producer_cells [lsort -unique $producer_cells]
set producer_csv [open [file join $out_dir g06r1_producer_inventory.csv] w]
puts $producer_csv [csv_row {cell_name bit_index ref_name loc bel site site_type tile tile_x tile_y clock_region fanout d_pin}]
foreach cell $producer_cells {
    set name [prop_or $cell NAME ""]
    set bit ""
    regexp {ingress_data_q_reg\[([0-9]+)\]$} $name -> bit
    set site [site_for_cell $cell]
    set tile [tile_for_site $site]
    set dp [lindex [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == D}] 0]
    set fo 0
    foreach op [get_pins -quiet -of_objects $cell -filter {DIRECTION == OUT}] {
        foreach net [get_nets -quiet -of_objects $op] {
            set fo [expr {$fo + [llength [get_pins -quiet -of_objects $net -filter {DIRECTION == IN}]]}]
        }
    }
    puts $producer_csv [csv_row [list \
        $name $bit [prop_or $cell REF_NAME ""] [prop_or $cell LOC ""] [prop_or $cell BEL ""] \
        [prop_or $site NAME ""] [prop_or $site SITE_TYPE ""] [prop_or $tile NAME ""] \
        [prop_or $tile GRID_POINT_X ""] [prop_or $tile GRID_POINT_Y ""] \
        [prop_or $site CLOCK_REGION [prop_or $tile CLOCK_REGION ""]] $fo [prop_or $dp NAME ""]]]
}
close $producer_csv

# Frozen expanded R1 envelope: current producer neighbourhood, X2Y2/X2Y1
# boundary, and downstream corridor.  Bounds intentionally extend above the
# old G0.5 Y=135 inventory to cover producer site Y=148.
set site_csv [open [file join $out_dir g06r1_candidate_site_inventory.csv] w]
puts $site_csv [csv_row {site site_type tile tile_x tile_y clock_region legal_ff_bel_count legal_lut_bel_count occupied_cell_count occupied_ff_count occupied_lut_count occupied_control_sets occupied_cells}]
set site_count 0
set all_sites [get_sites -quiet -filter {SITE_TYPE == SLICEL || SITE_TYPE == SLICEM}]
foreach site $all_sites {
    set name [prop_or $site NAME ""]
    if {![regexp {^SLICE_X([0-9]+)Y([0-9]+)$} $name -> sx sy]} { continue }
    if {$sx < 40 || $sx > 112 || $sy < 55 || $sy > 180} { continue }
    set tile [tile_for_site $site]
    set cells [get_cells -quiet -of_objects $site]
    set ff 0
    set lut 0
    set control_sets {}
    foreach cell $cells {
        set ref [prop_or $cell REF_NAME ""]
        if {[string match "FD*" $ref] || [string match "LD*" $ref]} { incr ff }
        if {[string match "LUT*" $ref]} { incr lut }
        set cs [control_set_key $cell]
        if {$cs ne "" && [lsearch -exact $control_sets $cs] < 0} { lappend control_sets $cs }
    }
    set legal_ff_bels 0
    set legal_lut_bels 0
    foreach bel [get_bels -quiet -of_objects $site] {
        set bel_name [prop_or $bel NAME ""]
        if {[regexp {([A-H]FF|[A-H]FF[0-9]+)$} $bel_name]} { incr legal_ff_bels }
        if {[regexp {[A-H][0-9]?LUT$} $bel_name]} { incr legal_lut_bels }
    }
    puts $site_csv [csv_row [list \
        $name [prop_or $site SITE_TYPE ""] [prop_or $tile NAME ""] [prop_or $tile GRID_POINT_X ""] \
        [prop_or $tile GRID_POINT_Y ""] [prop_or $site CLOCK_REGION [prop_or $tile CLOCK_REGION ""]] \
        $legal_ff_bels $legal_lut_bels [llength $cells] $ff $lut [join $control_sets {;}] \
        [join [lmap c $cells {prop_or $c NAME ""}] {;}]]]
    incr site_count
}
close $site_csv

set status [open [file join $out_dir g06r1_inventory_read_only_status.txt] w]
puts $status "status=READ_ONLY_COMPLETE"
puts $status "vivado_version=[version -short]"
puts $status "maxThreads=4"
puts $status "dcp=$dcp_path"
puts $status "producer_cells=[llength $producer_cells]"
puts $status "candidate_sites=$site_count"
puts $status "site_bbox=SLICE_X40..X112/Y55..Y180"
puts $status "rtl_changes=FORBIDDEN"
puts $status "xdc_changes=FORBIDDEN"
puts $status "implementation_commands=FORBIDDEN"
close $status
puts "P9R5G_G06R1_INVENTORY_DONE"
close_project
