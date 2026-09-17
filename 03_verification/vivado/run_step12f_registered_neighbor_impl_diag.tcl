# P9-R5E implementation-only recovery diagnostic.
# This does not resynthesize or modify RTL/XDC.  It opens the fixed R5E
# postsynthesis checkpoint and tests one alternate placement directive only to
# distinguish a Vivado placer/strategy crash from a netlist-level failure.

set script_dir [file dirname [info script]]
set root_dir   [file join $script_dir .. ..]
set default_dcp [file join $root_dir 05_audit current 59 p9_r5e_registered_neighbor_20260917_final step12f_registered_neighbor_postsynth.dcp]
set default_out [file join $root_dir 05_audit current 59 p9_r5e_registered_neighbor_20260917_diag_explore]
set dcp $default_dcp
set out_dir $default_out
if {[info exists ::env(STEP12F_R5E_DCP)] && $::env(STEP12F_R5E_DCP) ne ""} {
    set dcp $::env(STEP12F_R5E_DCP)
}
if {[info exists ::env(STEP12F_R5E_DIAG_DIR)] && $::env(STEP12F_R5E_DIAG_DIR) ne ""} {
    set out_dir $::env(STEP12F_R5E_DIAG_DIR)
}
file mkdir $out_dir
set_param general.maxThreads 4
puts "P9R5E_DIAG_START"
puts "VIVADO_VERSION=[version -short]"
puts "MAX_THREADS=4"
puts "DCP=$dcp"
puts "PLACE_DIRECTIVE=Explore"
puts "RESYNTHESIS=FORBIDDEN"

open_checkpoint $dcp
report_timing_summary -delay_type max -max_paths 100 -file [file join $out_dir report_timing_summary_open.rpt]
opt_design -directive Default
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive NoTimingRelaxation
report_route_status -file [file join $out_dir report_route_status.rpt]
report_timing_summary -delay_type max -max_paths 100 -file [file join $out_dir report_timing_summary_postroute.rpt]
report_timing_summary -delay_type min -max_paths 100 -file [file join $out_dir report_timing_hold_summary_postroute.rpt]
report_timing -delay_type max -max_paths 100 -file [file join $out_dir report_timing_worst100_postroute.rpt]
report_timing -delay_type min -max_paths 100 -file [file join $out_dir report_hold_worst100_postroute.rpt]
report_drc -file [file join $out_dir report_drc_postroute.rpt]
check_timing -verbose -file [file join $out_dir report_check_timing_postroute.rpt]
write_checkpoint -force [file join $out_dir step12f_registered_neighbor_diag_postroute.dcp]
close_project
puts "P9R5E_DIAG_DONE"

