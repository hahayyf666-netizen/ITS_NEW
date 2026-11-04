cd "C:/Users/Fine/Documents/deepseek-harness/default-workspace/closure_audit/stage"
set rtldir "C:/Users/Fine/Documents/deepseek-harness/default-workspace/its_push/02_rtl/rtl"
read_verilog -sv [list \
  "$rtldir/its_simple_ram.sv" \
  "$rtldir/its_input_cache_bank.sv" \
  "$rtldir/unified_p4_kernel.sv" \
  "$rtldir/bounded_lfnst_engine.sv" \
  "$rtldir/unified_its_wrapper.sv" \
  "$rtldir/its_unified_submission_top.sv" ]
# Full synthesis, not -rtl.
synth_design -name full_lint -top its_unified_submission_top -part xcku5p-ffvb676-2-e -mode out_of_context

puts "FULLSYNTH_CELLS=[llength [get_cells -hier]]"
set both [get_cells -hier -filter {IS_SEQUENTIAL == 1 && IS_SET == 1 && IS_RESET == 1}]
puts "FULLSYNTH_SET_AND_RESET=[llength $both]"
if {[llength $both] > 0} {
    foreach c [lrange $both 0 9] { puts "  DUAL $c" }
}
set inmem [get_cells -hier -filter {NAME =~ *input_mem*}]
puts "FULLSYNTH_INPUT_MEM=[llength $inmem]"
report_utilization -file "C:/Users/Fine/Documents/deepseek-harness/default-workspace/closure_audit/lint/util_top.ooc.rpt"
puts "FULLSYNTH_DONE"