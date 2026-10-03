set input_dcp [lindex $argv 0]
set out_dir [lindex $argv 1]
if {$input_dcp eq "" || $out_dir eq ""} {
    error "usage: prepare_common_postphysopt.tcl <postsynth.dcp> <out_dir>"
}
file mkdir $out_dir
set_param general.maxThreads 4
puts "ROUTE_AB_PREPARE_START"
puts "VIVADO_VERSION=[version -short]"
puts "MAX_THREADS=[get_param general.maxThreads]"
puts "INPUT_DCP=$input_dcp"
open_checkpoint $input_dcp
puts "DESIGN=[current_design]"
puts "PART=[get_property PART [current_design]]"

report_timing_summary -delay_type max -max_paths 100 \
    -file [file join $out_dir timing_before_opt_setup.rpt]
report_timing_summary -delay_type min -max_paths 100 \
    -file [file join $out_dir timing_before_opt_hold.rpt]
opt_design -directive Default
place_design -directive ExtraNetDelay_high
phys_opt_design -directive AggressiveExplore

report_timing_summary -delay_type max -max_paths 100 \
    -file [file join $out_dir timing_common_postphys_setup.rpt]
report_timing_summary -delay_type min -max_paths 100 \
    -file [file join $out_dir timing_common_postphys_hold.rpt]
report_utilization -file [file join $out_dir utilization_common_postphys.rpt]
report_clocks -file [file join $out_dir clocks_common_postphys.rpt]
write_checkpoint -force [file join $out_dir common_postphysopt.dcp]
puts "ROUTE_AB_COMMON_POSTPHYSOPT_DONE"
close_design
