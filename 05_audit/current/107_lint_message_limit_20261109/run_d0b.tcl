# D0 part 2: decide whether Synth 8-3936 trimming is real at netlist level.
# Writes the post-synthesis netlist so s0_coeff_q connectivity can be inspected
# textually.  RTL remains read-only.
cd "C:/Users/Fine/Documents/deepseek-harness/default-workspace/closure_audit/d0"

set rtldir "C:/Users/Fine/Documents/deepseek-harness/default-workspace/its_push/02_rtl/rtl"
read_verilog -sv [list \
  "$rtldir/its_simple_ram.sv" \
  "$rtldir/its_input_cache_bank.sv" \
  "$rtldir/unified_p4_kernel.sv" \
  "$rtldir/bounded_lfnst_engine.sv" \
  "$rtldir/unified_its_wrapper.sv" \
  "$rtldir/its_unified_submission_top.sv" ]
synth_design -name d0b -top its_unified_submission_top -part xcku5p-ffvb676-2-e -mode out_of_context
puts "D0B_SYNTH_DONE"

set c [get_cells -hier -filter {NAME =~ *s0_coeff_q*}]
puts "D0B_COEFF_CELLS=[llength $c]"
foreach x [lrange $c 0 7] {
    set nets [get_nets -quiet -of_objects $x]
    puts "D0B_CELL name=[get_property NAME $x] ref=[get_property REF_NAME $x] nets=[llength $nets]"
}

write_verilog -force -mode timesim "C:/Users/Fine/Documents/deepseek-harness/default-workspace/closure_audit/d0/d0_netlist.v"
puts "D0B_NETLIST_DONE"