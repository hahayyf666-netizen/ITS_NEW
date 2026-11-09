# D0: determine the true warning counts that the default 100-print limit hides.
# Read-only against the repo: RTL is only read, never written.
cd "C:/Users/Fine/Documents/deepseek-harness/default-workspace/closure_audit/d0"

# Raise the per-message-id print limit from the default 100.
set_msg_config -id {Synth 8-7137} -limit 20000
set_msg_config -id {Synth 8-6014} -limit 20000
set_msg_config -id {Synth 8-7129} -limit 20000
set_msg_config -id {Synth 8-3917} -limit 20000
set_msg_config -id {Synth 8-3936} -limit 20000
set_msg_config -id {Synth 8-4767} -limit 20000
set_msg_config -id {Synth 8-3333} -limit 20000
set_msg_config -id {Synth 8-6904} -limit 20000
set_msg_config -id {Synth 8-7052} -limit 20000
set_msg_config -id {Synth 8-6155} -limit 20000
set_msg_config -id {Synth 8-6157} -limit 20000
puts "D0_LIMITS_SET"

set rtldir "C:/Users/Fine/Documents/deepseek-harness/default-workspace/its_push/02_rtl/rtl"
read_verilog -sv [list \
  "$rtldir/its_simple_ram.sv" \
  "$rtldir/its_input_cache_bank.sv" \
  "$rtldir/unified_p4_kernel.sv" \
  "$rtldir/bounded_lfnst_engine.sv" \
  "$rtldir/unified_its_wrapper.sv" \
  "$rtldir/its_unified_submission_top.sv" ]
puts "D0_READ_OK"

synth_design -name d0_full -top its_unified_submission_top -part xcku5p-ffvb676-2-e -mode out_of_context
puts "D0_SYNTH_DONE"

puts "D0_CELLS=[llength [get_cells -hier]]"
set im [get_cells -hier -filter {NAME =~ *input_mem_reg*}]
puts "D0_INPUTMEM_REG_CELLS=[llength $im]"
set imany [get_cells -hier -filter {NAME =~ *input_mem*}]
puts "D0_INPUTMEM_ANY_CELLS=[llength $imany]"

report_utilization -file "C:/Users/Fine/Documents/deepseek-harness/default-workspace/closure_audit/d0/util_d0.rpt"
puts "D0_UTIL_DONE"
puts "D0_ALL_DONE"