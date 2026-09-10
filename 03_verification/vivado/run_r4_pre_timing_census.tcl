# Read-only R4_PRE timing census. Opens the frozen R3R post-route DCP only.
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set ROOT       [file normalize [file join $SCRIPT_DIR .. ..]]
set DCP        [file join $ROOT 03_verification vivado reports_r3r_postroute p2f_b2_controlled_postroute.dcp]
set OUT        [file join $ROOT 03_verification output r4_pre_timing_census]
file mkdir $OUT

puts "R4_PRE_TIMING_CENSUS_START"
puts "DCP=$DCP"
puts "OUT=$OUT"
open_checkpoint $DCP

report_timing_summary -delay_type max -max_paths 20 \
  -file [file join $OUT timing_summary.rpt]
report_timing -delay_type max -max_paths 1000 -nworst 1 -sort_by slack \
  -file [file join $OUT top1000_setup_paths.rpt]
report_high_fanout_nets -max_nets 200 \
  -file [file join $OUT high_fanout.rpt]
report_route_status -file [file join $OUT route_status.rpt]
report_utilization -hierarchical \
  -file [file join $OUT hierarchical_utilization.rpt]
catch {report_design_analysis -congestion -file [file join $OUT congestion.rpt]} congestion_rc
if {$congestion_rc ne ""} { puts "CONGESTION_REPORT_NOTE=$congestion_rc" }

set fh [open [file join $OUT top1000_setup_paths.csv] w]
puts $fh "index,slack,datapath_delay,logic_levels,startpoint,endpoint"
set paths [get_timing_paths -delay_type max -max_paths 1000 -sort_by slack]
set idx 0
foreach p $paths {
    incr idx
    set slack ""; set delay ""; set levels ""; set sp ""; set ep ""
    catch {set slack [get_property SLACK $p]}
    catch {set delay [get_property DATAPATH_DELAY $p]}
    catch {set levels [get_property LOGIC_LEVELS $p]}
    catch {set sp [get_property STARTPOINT_PIN $p]}
    catch {set ep [get_property ENDPOINT_PIN $p]}
    set slack [string map {" " "_" "," ";"} $slack]
    set delay [string map {" " "_" "," ";"} $delay]
    set levels [string map {" " "_" "," ";"} $levels]
    set sp [string map {" " "_" "," ";"} $sp]
    set ep [string map {" " "_" "," ";"} $ep]
    puts $fh "$idx,$slack,$delay,$levels,$sp,$ep"
}
close $fh
puts "PATH_ROWS=$idx"
close_project
puts "R4_PRE_TIMING_CENSUS_DONE"
