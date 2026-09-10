# ModelSim simulation script for ITS 500MHz single-clock submission top

vlib work

# Copy ROM init files into the simulation working directory for $readmemh. 
file copy -force ../../02_rtl/rtl/rom_coeffs.hex .
file copy -force ../../02_rtl/rtl/lfnst_coeffs.hex .

vlog -sv ../../02_rtl/rtl/its_mac.v
vlog -sv ../../02_rtl/rtl/its_rom.v
vlog -sv ../../02_rtl/rtl/its_lfnst_rom.v
vlog -sv ../../02_rtl/rtl/its_transform_engine.v
vlog -sv ../../02_rtl/rtl/its_lfnst.v
vlog -sv ../../02_rtl/rtl/its_core_500.v
vlog -sv ../../02_rtl/rtl/rst_sync.v
vlog -sv ../../02_rtl/rtl/async_fifo.v
vlog -sv ../../02_rtl/rtl/fifo_fwft_reg_slice.v
vlog -sv ../../02_rtl/rtl/its_top_500_wrapper.v
vlog -sv ../../02_rtl/rtl/its_top_500_singleclk.v

vlog -sv +define+SINGLECLK_SUBMISSION ../tb/its_tb_500.v

vsim -t 1ps work.its_tb_500

run -all

