# Read-only structural/timing inspection of the completed post-route DCP.
# This file intentionally contains no design-changing implementation command.
if {![info exists ::env(STEP12F_DCP)] || $::env(STEP12F_DCP) eq ""} {
    error "STEP12F_DCP must name the frozen post-route checkpoint"
}
if {![info exists ::env(STEP12F_AUDIT_DIR)] || $::env(STEP12F_AUDIT_DIR) eq ""} {
    error "STEP12F_AUDIT_DIR must name the evidence directory"
}

set_param general.maxThreads 4
open_checkpoint $::env(STEP12F_DCP)

set init_cells [get_cells -hier -quiet -filter {NAME =~ *lfnst_grid_init_q_reg*}]
set grid_cells [get_cells -hier -quiet -filter {NAME =~ *lfnst_grid_reg*}]
set valid_cells [get_cells -hier -quiet -filter {NAME =~ *lfnst_grid_valid_reg*}]
set init_q_pins [get_pins -quiet -of_objects $init_cells -filter {REF_PIN_NAME == Q}]
set grid_d_pins [get_pins -quiet -of_objects $grid_cells -filter {REF_PIN_NAME == D}]
set grid_ce_pins [get_pins -quiet -of_objects $grid_cells -filter {REF_PIN_NAME == CE}]

puts "READ_ONLY_DCP_AUDIT_START"
puts "INIT_REGISTER_CELL_COUNT=[llength $init_cells]"
puts "INIT_REGISTER_CELLS=[join [get_property NAME $init_cells] ,]"
puts "GRID_REGISTER_CELL_COUNT=[llength $grid_cells]"
puts "GRID_VALID_REGISTER_CELL_COUNT=[llength $valid_cells]"
puts "INIT_Q_PIN_COUNT=[llength $init_q_pins]"
puts "GRID_D_PIN_COUNT=[llength $grid_d_pins]"
puts "GRID_CE_PIN_COUNT=[llength $grid_ce_pins]"

if {[llength $init_q_pins] > 0} {
    report_timing -from $init_q_pins -delay_type max -max_paths 32 -nworst 1 \
        -file [file join $::env(STEP12F_AUDIT_DIR) lfnst_init_q_fanout_paths_postroute.rpt]
} else {
    puts "INIT_REGISTER_Q_STATUS=NO_SOURCE_OBJECT"
}
puts "READ_ONLY_DCP_AUDIT_DONE"
close_design
