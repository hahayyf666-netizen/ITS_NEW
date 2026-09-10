# ModelSim simulation script for ITS Core 500MHz testbench

# Create work library
vlib work

# Copy ROM init files into the simulation working directory for $readmemh. 
file copy -force ../../02_rtl/rtl/rom_coeffs.hex .
file copy -force ../../02_rtl/rtl/lfnst_coeffs.hex .

# Compile RTL (same submodules as its_top)
vlog -sv ../../02_rtl/rtl/its_mac.v
vlog -sv ../../02_rtl/rtl/its_rom.v
vlog -sv ../../02_rtl/rtl/its_lfnst_rom.v
vlog -sv ../../02_rtl/rtl/its_transform_engine.v
vlog -sv ../../02_rtl/rtl/its_lfnst.v
vlog -sv ../../02_rtl/rtl/its_core_500.v

# Compile testbench
vlog -sv ../tb/its_core_500_tb.v

# Simulate
vsim -t 1ps work.its_core_500_tb

# Run
run -all

