# RTL-level lint without create_project (non-project batch mode).
set outdir "C:/Users/Fine/Documents/deepseek-harness/default-workspace/closure_audit/lint"
set rtldir "C:/Users/Fine/Documents/deepseek-harness/default-workspace/its_push/02_rtl/rtl"

catch { set_param tclapp.disableAppLoading 1 }

set rtl_files [list \
  "$rtldir/its_simple_ram.sv" \
  "$rtldir/its_input_cache_bank.sv" \
  "$rtldir/unified_p4_kernel.sv" \
  "$rtldir/bounded_lfnst_engine.sv" \
  "$rtldir/unified_its_wrapper.sv" \
  "$rtldir/its_unified_submission_top.sv" ]

read_verilog -sv $rtl_files
synth_design -rtl -name rtl_lint -top its_unified_submission_top -part xcku5p-ffvb676-2-e -mode out_of_context
report_utilization -file "$outdir/util_rtl.rpt"
puts "LINT_RTL_DONE"