# RTL-level lint for the production top and its real dependency closure.
# cd is required: the RTL uses relative $readmemh paths and vivado.bat starts
# in its own bin directory.
cd "C:/Users/Fine/Documents/deepseek-harness/default-workspace/its_push"
set outdir "C:/Users/Fine/Documents/deepseek-harness/default-workspace/closure_audit/lint"

puts "LINT_CWD=[pwd]"

set rtl_files [list \
  "02_rtl/rtl/its_simple_ram.sv" \
  "02_rtl/rtl/its_input_cache_bank.sv" \
  "02_rtl/rtl/unified_p4_kernel.sv" \
  "02_rtl/rtl/bounded_lfnst_engine.sv" \
  "02_rtl/rtl/unified_its_wrapper.sv" \
  "02_rtl/rtl/its_unified_submission_top.sv" ]

read_verilog -sv $rtl_files
synth_design -rtl -name rtl_lint -top its_unified_submission_top -part xcku5p-ffvb676-2-e -mode out_of_context
puts "LINT_RTL_DONE"