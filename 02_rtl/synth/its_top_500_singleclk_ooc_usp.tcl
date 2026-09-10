# ===================================================================
# ITS 500MHz Single-Clock Submission Top OOC Synthesis
# Part: Kintex UltraScale+ xcku5p-ffvb676-2-e
# Usage: vivado -mode batch -source its_top_500_singleclk_ooc_usp.tcl
# ===================================================================

create_project -in_memory -part xcku5p-ffvb676-2-e -force

set rtl_dir [file dirname [file normalize [info script]]]/../rtl

set_property include_dirs [list [file normalize $rtl_dir]] [current_fileset]
set_property verilog_define {SYNTHESIS} [current_fileset]

set sv_files [list \
    [file join $rtl_dir its_top_500_singleclk.v] \
    [file join $rtl_dir its_top_500_wrapper.v] \
    [file join $rtl_dir its_core_500.v] \
    [file join $rtl_dir its_transform_engine.v] \
    [file join $rtl_dir its_mac.v] \
    [file join $rtl_dir its_rom.v] \
    [file join $rtl_dir its_lfnst.v] \
    [file join $rtl_dir its_lfnst_rom.v] \
    [file join $rtl_dir rst_sync.v] \
    [file join $rtl_dir async_fifo.v] \
    [file join $rtl_dir fifo_fwft_reg_slice.v] \
]
add_files -fileset sources_1 $sv_files
set_property file_type {SystemVerilog} [get_files $sv_files]
set xdc_dir [file dirname [file normalize [info script]]]
read_xdc [file join $xdc_dir timing_top_500_singleclk.xdc]

puts "=========================================="
puts " OOC synthesis: its_top_500_singleclk"
puts " Part: UltraScale+ (xcku5p-2)"
puts " clk = 500MHz"
puts "=========================================="

synth_design -top its_top_500_singleclk -mode out_of_context -flatten_hierarchy rebuilt

report_timing_summary -file [file join $xdc_dir top_500_singleclk_timing_synth_usp.rpt]
report_utilization -file [file join $xdc_dir top_500_singleclk_utilization_synth_usp.rpt]

puts "Running opt_design..."
opt_design

puts "Running place_design..."
place_design -directive Explore

puts "Running phys_opt_design..."
phys_opt_design -directive AggressiveExplore

puts "Running route_design..."
route_design -directive Explore

puts "Running post-route phys_opt..."
phys_opt_design -directive AggressiveExplore
phys_opt_design -directive AlternateFlowWithRetiming

puts "Generating post-impl reports..."
report_timing_summary -file [file join $xdc_dir top_500_singleclk_timing_impl_usp.rpt]
report_timing -setup -nworst 20 -file [file join $xdc_dir top_500_singleclk_timing_setup_paths_usp.rpt]
report_timing -hold  -nworst 20 -file [file join $xdc_dir top_500_singleclk_timing_hold_paths_usp.rpt]
write_checkpoint -force [file join $xdc_dir its_top_500_singleclk_ooc_usp.dcp]
report_utilization -file [file join $xdc_dir top_500_singleclk_utilization_impl_usp.rpt]
report_power -file [file join $xdc_dir top_500_singleclk_power_impl_usp.rpt]

puts "=========================================="
puts " Checking primitive inference..."
puts "=========================================="
set dsp_count [llength [get_cells -hierarchical -filter {REF_NAME =~ DSP48E2*}]]
set bram36_count [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB36E2*}]]
set bram18_count [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB18E2*}]]
set uram_count [llength [get_cells -hierarchical -filter {REF_NAME =~ URAM289*}]]
puts "DSP48E2: $dsp_count"
puts "RAMB36E2: $bram36_count"
puts "RAMB18E2: $bram18_count"
puts "URAM289: $uram_count"

puts "=========================================="
puts " Single-clock submission top OOC synthesis complete."
puts "=========================================="
