# Step12F P9-R5E registered-neighbor nominal timing contract.
#
# Data/protocol boundaries are internal source/sink FFs.  This file must not
# inherit the old unified-wrapper OOC set_input_delay/set_output_delay file.
# Package-level FPGA I/O timing is explicitly out of scope here.

create_clock -name clk -period 2.000 [get_ports clk]

# Fixed nominal contract: no additional jitter/uncertainty budget is asserted
# because no external system clock budget is supplied by the contest evidence.
set_clock_uncertainty -setup 0.000 [get_clocks clk]
set_clock_uncertainty -hold  0.000 [get_clocks clk]

# rst_n is an asynchronously asserted, synchronously released reset input.
# Recovery/removal is reported separately; no blanket false path is used.

