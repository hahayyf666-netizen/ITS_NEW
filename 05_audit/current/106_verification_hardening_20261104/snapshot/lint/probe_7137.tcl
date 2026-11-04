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

set all [get_cells -hier -filter {NAME =~ *input_mem_reg*}]
puts "PROBE_INPUT_MEM_CELLS=[llength $all]"
if {[llength $all] > 0} {
    set one [lindex $all 0]
    puts "PROBE_NAME=[get_property NAME $one]"
    foreach prop {IS_SEQUENTIAL IS_RESET IS_SET REF_NAME PRIMITIVE_GROUP} {
        if {[catch {set v [get_property $prop $one]} err]} { set v "n/a" }
        puts "PROBE_PROP $prop=$v"
    }
}
# how many cells in the whole design carry both IS_SET and IS_RESET
set seq [get_cells -hier -filter {IS_SEQUENTIAL == 1}]
set both 0
foreach c $seq {
    set s 0; set r 0
    catch { set s [get_property IS_SET $c] }
    catch { set r [get_property IS_RESET $c] }
    if {$s == 1 && $r == 1} { incr both }
}
puts "PROBE_SEQ_TOTAL=[llength $seq]"
puts "PROBE_SET_AND_RESET=$both"
puts "PROBE_DONE"