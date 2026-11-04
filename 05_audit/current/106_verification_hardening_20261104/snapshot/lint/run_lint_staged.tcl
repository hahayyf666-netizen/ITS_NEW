# Same lint scope, but run from a staging cwd that contains the ROM files at
# the relative path the RTL expects. This separates "ROM path defect" from any
# independent warning.
cd "C:/Users/Fine/Documents/deepseek-harness/default-workspace/closure_audit/stage"
set rtldir "C:/Users/Fine/Documents/deepseek-harness/default-workspace/its_push/02_rtl/rtl"
puts "LINT_CWD=[pwd]"
puts "ROM_EXISTS=[file exists 03_verification/sim/rom_coeffs.hex]"

set rtl_files [list \
  "$rtldir/its_simple_ram.sv" \
  "$rtldir/its_input_cache_bank.sv" \
  "$rtldir/unified_p4_kernel.sv" \
  "$rtldir/bounded_lfnst_engine.sv" \
  "$rtldir/unified_its_wrapper.sv" \
  "$rtldir/its_unified_submission_top.sv" ]

read_verilog -sv $rtl_files
synth_design -rtl -name rtl_lint -top its_unified_submission_top -part xcku5p-ffvb676-2-e -mode out_of_context
puts "LINT_RTL_DONE"