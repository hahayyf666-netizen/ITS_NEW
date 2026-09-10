# V3.3 implementation (orientation-fixed RTL+ROM)
# Best strategy: ExtraNetDelay_low. top=its_top_500_singleclk, xcku5p-2, 500MHz
create_project -in_memory -part xcku5p-ffvb676-2-e -force

set proj_root [file normalize [file join [file dirname [info script]] ../..]]
set rtl_dir  [file join $proj_root 02_rtl/rtl]
set xdc_dir  [file join $proj_root 02_rtl/synth]
set out_dir  [file dirname [info script]]

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
read_xdc [file join $xdc_dir timing_top_500_singleclk.xdc]

synth_design -top its_top_500_singleclk -mode out_of_context -flatten_hierarchy rebuilt
opt_design
place_design -directive ExtraNetDelay_low
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
phys_opt_design -directive AggressiveExplore
phys_opt_design -directive AlternateFlowWithRetiming

report_timing_summary -file [file join $out_dir v33_timing_summary.rpt]
report_timing -setup -nworst 10 -file [file join $out_dir v33_setup.rpt]
report_timing -hold  -nworst 10 -file [file join $out_dir v33_hold.rpt]
report_utilization -file [file join $out_dir v33_utilization.rpt]
report_power -file [file join $out_dir v33_power.rpt]
write_checkpoint -force [file join $out_dir v33.dcp]

puts "V3.3 implementation complete"
