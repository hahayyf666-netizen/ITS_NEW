set dcp_path $::env(STEP12F_R5E_POSTROUTE_DCP)
open_checkpoint $dcp_path
set cells [get_cells -hier -quiet -filter {REF_NAME =~ RAMD64E*}]
puts "RAMD64E_CELL_COUNT=[llength $cells]"
set shown 0
foreach c $cells {
    set ref [get_property REF_NAME $c]
    puts "RAM_CELL=$c REF=$ref"
    set pins [get_pins -of_objects $c -quiet]
    foreach p $pins {
        set rp [get_property REF_PIN_NAME $p]
        if {[regexp {^(RADR|ADDR|A)[0-9]+$} $rp]} {
            puts "RAM_ADDR_PIN=$p REF_PIN=$rp"
        }
    }
    incr shown
    if {$shown >= 3} { break }
}
close_project
puts "QUERY_DONE"

