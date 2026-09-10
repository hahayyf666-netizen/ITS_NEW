# ===================================================================
# ITS Core 500MHz OOC Timing Constraints
# Target: internal compute core only, no I/O pad paths
# ===================================================================

# Core clock 500MHz (2ns period)
create_clock -period 2.000 -name clk_core [get_ports clk_core]

# Input delay from FIFO read interface to core registers
# FIFO data is registered in FIFO output, so max delay = 0.5ns
set_input_delay -clock clk_core -max 0.500 [get_ports {cmd_fifo_rdata[*]}]
set_input_delay -clock clk_core -min 0.100 [get_ports {cmd_fifo_rdata[*]}]
set_input_delay -clock clk_core -max 0.500 [get_ports {cmd_fifo_empty}]
set_input_delay -clock clk_core -min 0.100 [get_ports {cmd_fifo_empty}]
set_input_delay -clock clk_core -max 0.500 [get_ports {input_fifo_rdata[*]}]
set_input_delay -clock clk_core -min 0.100 [get_ports {input_fifo_rdata[*]}]
set_input_delay -clock clk_core -max 0.500 [get_ports {input_fifo_empty}]
set_input_delay -clock clk_core -min 0.100 [get_ports {input_fifo_empty}]
set_input_delay -clock clk_core -max 0.500 [get_ports {output_fifo_full}]
set_input_delay -clock clk_core -min 0.100 [get_ports {output_fifo_full}]

# Output delay from core registers to FIFO write interface
set_output_delay -clock clk_core -max 0.500 [get_ports {output_fifo_wdata[*]}]
set_output_delay -clock clk_core -min 0.100 [get_ports {output_fifo_wdata[*]}]
set_output_delay -clock clk_core -max 0.500 [get_ports {output_fifo_wr_en}]
set_output_delay -clock clk_core -min 0.100 [get_ports {output_fifo_wr_en}]
set_output_delay -clock clk_core -max 0.500 [get_ports {cmd_fifo_rd_en}]
set_output_delay -clock clk_core -min 0.100 [get_ports {cmd_fifo_rd_en}]
set_output_delay -clock clk_core -max 0.500 [get_ports {input_fifo_rd_en}]
set_output_delay -clock clk_core -min 0.100 [get_ports {input_fifo_rd_en}]
set_output_delay -clock clk_core -max 0.500 [get_ports {core_done}]
set_output_delay -clock clk_core -min 0.100 [get_ports {core_done}]

# Async reset false path
set_false_path -from [get_ports rst_n]
