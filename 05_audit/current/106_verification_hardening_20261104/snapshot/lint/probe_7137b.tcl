cd "C:/Users/Fine/Documents/deepseek-harness/default-workspace/closure_audit/stage"
set rtldir "C:/Users/Fine/Documents/deepseek-harness/default-workspace/its_push/02_rtl/rtl"
read_verilog -sv [list \
  "$rtldir/its_simple_ram.sv" \
  "$rtldir/its_input_cache_bank.sv" \
  "$rtldir/unified_p4_kernel.sv" \
  "$rtldir/bounded_lfnst_engine.sv" \
  "$rtldir/unified_its_wrapper.sv" \
  "$rtldir/its_unified_submission_top.sv" ]
synth_design -rtl -name rtl_lint -top its_unified_submission_top -part xcku5p-ffvb676-2-e -mode out_of_context

set one [get_cells {u_unified_wrapper/u_unified_p4_kernel/input_mem_reg[0][0][0]}]
puts "CELL_FOUND=[llength $one]"
if {[llength $one]} {
    report_property -all [lindex $one 0]
}
puts "---- cells in kernel with IS_SET or IS_RESET non-empty ----"
set n_setreset 0
set n_inmem 0
foreach c [get_cells -hier -filter {NAME =~ *unified_p4_kernel/input_mem_reg*}] {
    incr n_inmem
}
puts "INMEM_CELLS=$n_inmem"
puts "PROBE_DONE2"