# Step12F P9-R5E: registered-neighbor integration synthesis/implementation.
# The DUT sources and all R5 arithmetic are frozen; only the enclosing
# registered-neighbor context is new in this flow.

set script_dir [file dirname [info script]]
set root_dir   [file join $script_dir .. ..]
set rtl_dir    [file join $root_dir 02_rtl rtl]
set harness    [file join $rtl_dir step12f_registered_neighbor_harness.sv]
set wrapper    [file join $rtl_dir unified_its_wrapper.sv]
set kernel     [file join $rtl_dir unified_p4_kernel.sv]
set simple_ram [file join $rtl_dir its_simple_ram.sv]
set input_bank [file join $rtl_dir its_input_cache_bank.sv]
set lfnst_engine [file join $rtl_dir bounded_lfnst_engine.sv]
set xdc        [file join $script_dir step12f_registered_neighbor_2ns.xdc]
set part       xcku5p-ffvb676-2-e

if {[info exists ::env(STEP12F_R5E_REPORT_DIR)] && $::env(STEP12F_R5E_REPORT_DIR) ne ""} {
    set report_dir $::env(STEP12F_R5E_REPORT_DIR)
} else {
    set report_dir [file join $root_dir 05_audit current 59 p9_r5e_registered_neighbor_20260917]
}
file mkdir $report_dir
set max_threads 4
if {[info exists ::env(STEP12F_MAX_THREADS)] && $::env(STEP12F_MAX_THREADS) ne ""} {
    set max_threads $::env(STEP12F_MAX_THREADS)
}
set_param general.maxThreads $max_threads
cd $root_dir

puts "P9R5E_START"
puts "VIVADO_VERSION=[version -short]"
puts "MAX_THREADS=$max_threads"
puts "PART=$part"
puts "TOP=step12f_registered_neighbor_harness"
puts "PERIOD_NS=2.000"
puts "CLOCK_UNCERTAINTY_SETUP_NS=0.000"
puts "CLOCK_UNCERTAINTY_HOLD_NS=0.000"
puts "OLD_OOC_XDC=NOT_LOADED"
puts "IMPLEMENTATION_FLOW=Default_ExtraNetDelay_high_AggressiveExplore_NoTimingRelaxation"

create_project -in_memory -part $part -force
set_property include_dirs [list $rtl_dir] [current_fileset]
add_files -norecurse -fileset sources_1 [list $simple_ram $input_bank $kernel $lfnst_engine $wrapper $harness]
foreach f [list $simple_ram $input_bank $kernel $lfnst_engine $wrapper $harness] {
    set_property file_type {SystemVerilog} [get_files $f]
}
set_property top step12f_registered_neighbor_harness [current_fileset]
add_files -norecurse -fileset constrs_1 $xdc
set_property used_in_synthesis true [get_files $xdc]
set_property used_in_implementation true [get_files $xdc]
update_compile_order -fileset sources_1
read_xdc $xdc

set synth_start [clock seconds]
synth_design -top step12f_registered_neighbor_harness \
    -part $part \
    -flatten_hierarchy none -directive Default
set synth_elapsed [expr {[clock seconds] - $synth_start}]
puts "P9R5E_SYNTH_ELAPSED_SEC=$synth_elapsed"

# Boundary anti-pruning gate.  The six source groups total 54 FF bits and the
# five sink groups total 44 FF bits; reset conditioner FFs are excluded.
set src_q [get_pins -hier -quiet -regexp {.*src_(it_info|it_info_vld|it_data_in|it_data_addr|it_data_in_vld|it_data_end|it_data_out_req)_q_reg.*/Q$}]
set sink_d [get_pins -hier -quiet -regexp {.*sink_(it_data_in_req|it_data_out|it_data_out_vld|it_done|protocol_error)_q_reg.*/D$}]
set src_cells [get_cells -quiet -of_objects $src_q]
set sink_cells [get_cells -quiet -of_objects $sink_d]
puts "SOURCE_Q_PIN_FOUND=[llength $src_q]"
puts "SINK_D_PIN_FOUND=[llength $sink_d]"
puts "SOURCE_FF_FOUND=[llength $src_cells]"
puts "SINK_FF_FOUND=[llength $sink_cells]"
if {[llength $src_cells] != 54 || [llength $sink_cells] != 44} {
    puts "BOUNDARY_ANTI_PRUNING=FAIL"
    error "Expected 54 source FF bits and 44 sink FF bits"
}
puts "BOUNDARY_ANTI_PRUNING=PASS"

write_checkpoint -force [file join $report_dir step12f_registered_neighbor_postsynth.dcp]
report_utilization -file [file join $report_dir report_utilization_postsynth.rpt]
report_utilization -hierarchical -file [file join $report_dir report_hierarchy_utilization_postsynth.rpt]
report_timing_summary -delay_type max -max_paths 100 -file [file join $report_dir report_timing_summary_postsynth.rpt]
report_timing_summary -delay_type min -max_paths 100 -file [file join $report_dir report_timing_hold_summary_postsynth.rpt]
report_timing -delay_type max -max_paths 100 -file [file join $report_dir report_timing_worst100_postsynth.rpt]
report_timing -delay_type min -max_paths 100 -file [file join $report_dir report_hold_worst100_postsynth.rpt]
check_timing -verbose -file [file join $report_dir report_check_timing_postsynth.rpt]
report_exceptions -file [file join $report_dir report_exceptions_postsynth.rpt]
report_drc -file [file join $report_dir report_drc_postsynth.rpt]
report_methodology -file [file join $report_dir report_methodology_postsynth.rpt]

set src_q [get_pins -hier -quiet -regexp {.*src_(it_info|it_info_vld|it_data_in|it_data_addr|it_data_in_vld|it_data_end|it_data_out_req)_q_reg.*/Q}]
set dut_d [get_pins -hier -quiet -regexp {.*u_dut/.*/D}]
set dut_q [get_pins -hier -quiet -regexp {.*u_dut/.*/Q}]
set sink_d [get_pins -hier -quiet -regexp {.*sink_(it_data_in_req|it_data_out|it_data_out_vld|it_done|protocol_error)_q_reg.*/D}]
if {[llength $src_q] > 0 && [llength $dut_d] > 0} {
    report_timing -from $src_q -to $dut_d -max_paths 100 -file [file join $report_dir report_paths_source_ff_to_dut.rpt]
}
if {[llength $dut_q] > 0 && [llength $dut_d] > 0} {
    report_timing -from $dut_q -to $dut_d -max_paths 100 -file [file join $report_dir report_paths_dut_internal.rpt]
}
if {[llength $dut_q] > 0 && [llength $sink_d] > 0} {
    report_timing -from $dut_q -to $sink_d -max_paths 100 -file [file join $report_dir report_paths_dut_to_sink_ff.rpt]
}

set impl_start [clock seconds]
opt_design -directive Default
place_design -directive ExtraNetDelay_high
phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation
set impl_elapsed [expr {[clock seconds] - $impl_start}]
puts "P9R5E_IMPL_ELAPSED_SEC=$impl_elapsed"

report_route_status -file [file join $report_dir report_route_status_postroute.rpt]
report_utilization -file [file join $report_dir report_utilization_postroute.rpt]
report_utilization -hierarchical -file [file join $report_dir report_hierarchy_utilization_postroute.rpt]
report_timing_summary -delay_type max -max_paths 100 -file [file join $report_dir report_timing_summary_postroute.rpt]
report_timing_summary -delay_type min -max_paths 100 -file [file join $report_dir report_timing_hold_summary_postroute.rpt]
report_timing -delay_type max -max_paths 100 -file [file join $report_dir report_timing_worst100_postroute.rpt]
report_timing -delay_type min -max_paths 100 -file [file join $report_dir report_hold_worst100_postroute.rpt]
report_high_fanout_nets -max_nets 200 -file [file join $report_dir report_high_fanout_postroute.rpt]
check_timing -verbose -file [file join $report_dir report_check_timing_postroute.rpt]
report_exceptions -file [file join $report_dir report_exceptions_postroute.rpt]
report_drc -file [file join $report_dir report_drc_postroute.rpt]
report_methodology -file [file join $report_dir report_methodology_postroute.rpt]
report_power -file [file join $report_dir report_power_postroute.rpt]

# P9 primary-V read-return diagnostics.  These are report-only queries on the
# completed route.  The same-edge kernel input fire may update FIFO retirement
# bookkeeping, but it must not feed the wide physical-read command or bank-raw
# capture D/CE cones.
set primary_fire_nets [get_nets -hier -quiet -regexp {.*kernel_input_group_fire.*}]
set primary_fire_drivers [get_pins -quiet -of_objects $primary_fire_nets \
    -filter {DIRECTION == OUT}]
set primary_cmd_addr_q [get_pins -hier -quiet -regexp {.*rd_cmd_addr_q_reg.*/Q$}]
set primary_cmd_addr_d [get_pins -hier -quiet -regexp {.*rd_cmd_addr_q_reg.*/D$}]
set primary_cmd_addr_ce [get_pins -hier -quiet -regexp {.*rd_cmd_addr_q_reg.*/CE$}]
set primary_cmd_valid_d [get_pins -hier -quiet -regexp {.*rd_cmd_valid_q_reg.*/D$}]
set primary_cmd_valid_ce [get_pins -hier -quiet -regexp {.*rd_cmd_valid_q_reg.*/CE$}]
set primary_bank_raw_q [get_pins -hier -quiet -regexp {.*kernel_rd_bank_data_q_reg.*/Q$}]
set primary_bank_raw_d [get_pins -hier -quiet -regexp {.*kernel_rd_bank_data_q_reg.*/D$}]
set primary_bank_raw_ce [get_pins -hier -quiet -regexp {.*kernel_rd_bank_data_q_reg.*/CE$}]
set primary_bank_valid_d [get_pins -hier -quiet -regexp {.*kernel_rd_bank_valid_q_reg.*/D$}]
set primary_bank_valid_ce [get_pins -hier -quiet -regexp {.*kernel_rd_bank_valid_q_reg.*/CE$}]
set primary_fifo_data_q [get_pins -hier -quiet -regexp {.*primary_return_data_q_reg.*/Q$}]
set primary_fifo_data_d [get_pins -hier -quiet -regexp {.*primary_return_data_q_reg.*/D$}]
set primary_fifo_data_ce [get_pins -hier -quiet -regexp {.*primary_return_data_q_reg.*/CE$}]
set primary_kernel_input_d [get_pins -hier -quiet -regexp {.*input_mem_reg.*/D$}]
set primary_kernel_input_ce [get_pins -hier -quiet -regexp {.*input_mem_reg.*/CE$}]

puts "P9_PRIMARY_FIRE_NETS=[llength $primary_fire_nets]"
puts "P9_PRIMARY_FIRE_DRIVER_PINS=[llength $primary_fire_drivers]"
puts "P9_PRIMARY_CMD_ADDR_Q=[llength $primary_cmd_addr_q]"
puts "P9_PRIMARY_CMD_ADDR_D=[llength $primary_cmd_addr_d]"
puts "P9_PRIMARY_CMD_ADDR_CE=[llength $primary_cmd_addr_ce]"
puts "P9_PRIMARY_CMD_VALID_D=[llength $primary_cmd_valid_d]"
puts "P9_PRIMARY_CMD_VALID_CE=[llength $primary_cmd_valid_ce]"
puts "P9_PRIMARY_BANK_RAW_Q=[llength $primary_bank_raw_q]"
puts "P9_PRIMARY_BANK_RAW_D=[llength $primary_bank_raw_d]"
puts "P9_PRIMARY_BANK_RAW_CE=[llength $primary_bank_raw_ce]"
puts "P9_PRIMARY_BANK_VALID_D=[llength $primary_bank_valid_d]"
puts "P9_PRIMARY_BANK_VALID_CE=[llength $primary_bank_valid_ce]"
puts "P9_PRIMARY_FIFO_DATA_Q=[llength $primary_fifo_data_q]"
puts "P9_PRIMARY_FIFO_DATA_D=[llength $primary_fifo_data_d]"
puts "P9_PRIMARY_FIFO_DATA_CE=[llength $primary_fifo_data_ce]"
puts "P9_PRIMARY_KERNEL_INPUT_D=[llength $primary_kernel_input_d]"
puts "P9_PRIMARY_KERNEL_INPUT_CE=[llength $primary_kernel_input_ce]"

if {[llength $primary_fire_drivers] > 0 &&
    [llength $primary_cmd_addr_d] > 0 &&
    [llength $primary_cmd_addr_ce] > 0} {
    report_timing -from $primary_fire_drivers \
        -to [concat $primary_cmd_addr_d $primary_cmd_addr_ce] \
        -delay_type max -max_paths 100 \
        -file [file join $report_dir report_p9_fire_to_command_d_ce.rpt]
} else {
    puts "P9_PRIMARY_FIRE_TO_COMMAND_QUERY=NO_SOURCE_OR_DEST_OBJECT"
}
if {[llength $primary_fire_drivers] > 0 &&
    [llength $primary_bank_raw_d] > 0 &&
    [llength $primary_bank_raw_ce] > 0} {
    report_timing -from $primary_fire_drivers \
        -to [concat $primary_bank_raw_d $primary_bank_raw_ce] \
        -delay_type max -max_paths 100 \
        -file [file join $report_dir report_p9_fire_to_bank_raw_d_ce.rpt]
} else {
    puts "P9_PRIMARY_FIRE_TO_BANK_RAW_QUERY=NO_SOURCE_OR_DEST_OBJECT"
}

set primary_ram_cells [get_cells -hier -quiet -filter {REF_NAME =~ RAMD64E*}]
set primary_ram_addr_pins {}
foreach primary_ram_cell $primary_ram_cells {
    foreach primary_ram_pin [get_pins -of_objects $primary_ram_cell -quiet] {
        if {[regexp {^RADR[0-5]$} [get_property REF_PIN_NAME $primary_ram_pin]]} {
            lappend primary_ram_addr_pins $primary_ram_pin
        }
    }
}
puts "P9_PRIMARY_RAM_CELLS=[llength $primary_ram_cells]"
puts "P9_PRIMARY_RAM_ADDR_PINS=[llength $primary_ram_addr_pins]"
if {[llength $primary_cmd_addr_q] > 0 &&
    [llength $primary_ram_addr_pins] > 0 &&
    [llength $primary_bank_raw_d] > 0} {
    report_timing -from $primary_cmd_addr_q \
        -through $primary_ram_addr_pins -to $primary_bank_raw_d \
        -delay_type max -max_paths 100 \
        -file [file join $report_dir report_p9_command_through_ram_to_bank_raw.rpt]
} else {
    puts "P9_PRIMARY_COMMAND_RAM_RAW_QUERY=NO_SOURCE_OR_DEST_OBJECT"
}
if {[llength $primary_bank_raw_q] > 0 &&
    [llength $primary_fifo_data_d] > 0} {
    report_timing -from $primary_bank_raw_q -to $primary_fifo_data_d \
        -delay_type max -max_paths 100 \
        -file [file join $report_dir report_p9_bank_raw_to_return_fifo.rpt]
} else {
    puts "P9_PRIMARY_BANK_RAW_TO_FIFO_QUERY=NO_SOURCE_OR_DEST_OBJECT"
}
if {[llength $primary_fifo_data_q] > 0 &&
    [llength $primary_kernel_input_d] > 0} {
    report_timing -from $primary_fifo_data_q -to $primary_kernel_input_d \
        -delay_type max -max_paths 100 \
        -file [file join $report_dir report_p9_return_fifo_to_p4_input.rpt]
} else {
    puts "P9_PRIMARY_FIFO_TO_P4_QUERY=NO_SOURCE_OR_DEST_OBJECT"
}
write_checkpoint -force [file join $report_dir step12f_registered_neighbor_postroute.dcp]

close_project
puts "P9R5E_DONE"

