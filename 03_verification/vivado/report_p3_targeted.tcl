set dcp [lindex $argv 0]
set outdir [lindex $argv 1]
if {$dcp eq "" || $outdir eq ""} { error "usage: vivado -mode batch -source report_p3_targeted.tcl -tclargs <dcp> <outdir>" }
open_checkpoint $dcp
file mkdir $outdir
set all_vwrite [get_cells -hier -quiet *vwrite_cmd*]
set all_kernel [get_cells -hier -quiet *unified_p4_kernel*]
set all_tmp [get_cells -hier -quiet *gen_tmp_banks*]
set vwrite_q_names {}
foreach c $all_vwrite { lappend vwrite_q_names [get_property NAME $c] }
set kernel_names {}
foreach c $all_kernel { lappend kernel_names [get_property NAME $c] }
set tmp_names {}
foreach c $all_tmp { lappend tmp_names [get_property NAME $c] }
set f [open [file join $outdir P3_TARGETED_OBJECTS.txt] w]
puts $f "VWRITE_CELLS"
foreach n $vwrite_q_names { puts $f $n }
puts $f "KERNEL_CELLS"
foreach n $kernel_names { puts $f $n }
puts $f "TMP_CELLS"
foreach n $tmp_names { puts $f $n }
close $f

set qpins [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && (NAME =~ *vwrite_cmd* || NAME =~ *kernel_group* || NAME =~ *kernel_vector*)}]
set tmp_we [get_pins -hier -quiet -filter {DIRECTION == IN && (NAME =~ *gen_tmp_banks* && (NAME =~ */WE || NAME =~ */RAMA/WE || NAME =~ */RAMB/WE))}]
set tmp_addr [get_pins -hier -quiet -filter {DIRECTION == IN && NAME =~ *gen_tmp_banks* && (NAME =~ */A* || NAME =~ */B*)}]
set kernel_qpins [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *u_unified_p4_kernel*}]
set vwrite_dpins [get_pins -hier -quiet -filter {REF_PIN_NAME == D && NAME =~ *vwrite_cmd*}]
set old_group_qpins [get_pins -hier -quiet -filter {REF_PIN_NAME == Q && NAME =~ *kernel_group_q*}]
set tmp_all_pins [get_pins -hier -quiet -filter {NAME =~ *gen_tmp_banks*}]
set tmp_ref_pin_names {}
foreach p $tmp_all_pins { lappend tmp_ref_pin_names [get_property REF_PIN_NAME $p] }
set tmp_ref_pin_names [lsort -unique $tmp_ref_pin_names]
set f [open [file join $outdir P3_TARGETED_PIN_COUNTS.txt] w]
puts $f "q_pins=[llength $qpins]"
puts $f "tmp_we_pins=[llength $tmp_we]"
puts $f "tmp_addr_pins=[llength $tmp_addr]"
puts $f "kernel_q_pins=[llength $kernel_qpins]"
puts $f "vwrite_d_pins=[llength $vwrite_dpins]"
puts $f "old_kernel_group_q_pins=[llength $old_group_qpins]"
puts $f "tmp_ref_pin_names=[join $tmp_ref_pin_names {, }]"
close $f

if {[llength $kernel_qpins] > 0 && [llength $vwrite_dpins] > 0} {
  report_timing -from $kernel_qpins -to $vwrite_dpins -delay_type max -max_paths 50 -path_type full -file [file join $outdir P3_PATH_KERNEL_TO_VWRITE_CAPTURE.rpt]
} else {
  set f [open [file join $outdir P3_PATH_KERNEL_TO_VWRITE_CAPTURE.rpt] w]
  puts $f "No matching kernel-Q to V-write-command-D pins at synthesized checkpoint."
  close $f
}

if {[llength $old_group_qpins] > 0 && [llength $tmp_we] > 0} {
  report_timing -from $old_group_qpins -to $tmp_we -delay_type max -max_paths 50 -path_type full -file [file join $outdir P3_PATH_OLD_KERNEL_GROUP_TO_TMP_WE.rpt]
} else {
  set f [open [file join $outdir P3_PATH_OLD_KERNEL_GROUP_TO_TMP_WE.rpt] w]
  puts $f "No old kernel_group_q to intermediate-RAM write path objects exist at synthesized checkpoint."
  close $f
}

if {[llength $qpins] > 0 && [llength $tmp_we] > 0} {
  report_timing -from $qpins -to $tmp_we -delay_type max -max_paths 50 -path_type full -file [file join $outdir P3_PATH_KERNEL_OR_VWRITE_TO_TMP_WE.rpt]
} else {
  set f [open [file join $outdir P3_PATH_KERNEL_OR_VWRITE_TO_TMP_WE.rpt] w]
  puts $f "No matching source/destination pins at synthesized checkpoint."
  close $f
}
if {[llength $qpins] > 0 && [llength $tmp_addr] > 0} {
  report_timing -from $qpins -to $tmp_addr -delay_type max -max_paths 50 -path_type full -file [file join $outdir P3_PATH_KERNEL_OR_VWRITE_TO_TMP_ADDR.rpt]
} else {
  set f [open [file join $outdir P3_PATH_KERNEL_OR_VWRITE_TO_TMP_ADDR.rpt] w]
  puts $f "No matching source/destination pins at synthesized checkpoint."
  close $f
}
close_design
exit
