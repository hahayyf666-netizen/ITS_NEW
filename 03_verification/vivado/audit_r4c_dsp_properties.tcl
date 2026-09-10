# Read-only DSP property audit for the R4C routed checkpoint.
set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp
set fh [open $out w]
set cells [get_cells -hier -filter {REF_NAME == DSP48E2}]
puts $fh "count=[llength $cells]"
foreach c $cells {
    puts $fh [format "%s AREG=%s BREG=%s MREG=%s PREG=%s ADREG=%s DREG=%s" \
        $c [get_property AREG $c] [get_property BREG $c] \
        [get_property MREG $c] [get_property PREG $c] \
        [get_property ADREG $c] [get_property DREG $c]]
}
close $fh
close_project
