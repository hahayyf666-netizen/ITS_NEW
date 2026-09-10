# ===================================================================
# ITS 500MHz Single-Clock Submission Top Timing Constraints
# Top: its_top_500_singleclk
# Part target: Kintex UltraScale+ xcku5p-ffvb676-2-e
# ===================================================================

create_clock -period 2.000 -name clk [get_ports clk]

# Async reset assertion; deassertion is synchronized inside the wrapper.
set_false_path -from [get_ports rst_n]

# OOC interface assumptions. The competition interface is driven by the
# same 500MHz clock in this submission top, so use modest I/O delays.
set_input_delay -clock clk -max 0.200 [get_ports {it_info[*]}]
set_input_delay -clock clk -min 0.200 [get_ports {it_info[*]}]
set_input_delay -clock clk -max 0.200 [get_ports {it_info_vld}]
set_input_delay -clock clk -min 0.200 [get_ports {it_info_vld}]
set_input_delay -clock clk -max 0.200 [get_ports {it_data_in[*]}]
set_input_delay -clock clk -min 0.200 [get_ports {it_data_in[*]}]
set_input_delay -clock clk -max 0.200 [get_ports {it_data_addr[*]}]
set_input_delay -clock clk -min 0.200 [get_ports {it_data_addr[*]}]
set_input_delay -clock clk -max 0.200 [get_ports {it_data_in_vld}]
set_input_delay -clock clk -min 0.200 [get_ports {it_data_in_vld}]
set_input_delay -clock clk -max 0.200 [get_ports {it_data_end}]
set_input_delay -clock clk -min 0.200 [get_ports {it_data_end}]
set_input_delay -clock clk -max 0.200 [get_ports {it_data_out_req}]
set_input_delay -clock clk -min 0.200 [get_ports {it_data_out_req}]

set_output_delay -clock clk -max 0.200 [get_ports {it_data_in_req}]
set_output_delay -clock clk -min 0.200 [get_ports {it_data_in_req}]
set_output_delay -clock clk -max 0.200 [get_ports {it_data_out[*]}]
set_output_delay -clock clk -min 0.200 [get_ports {it_data_out[*]}]
set_output_delay -clock clk -max 0.200 [get_ports {it_data_out_vld}]
set_output_delay -clock clk -min 0.200 [get_ports {it_data_out_vld}]
set_output_delay -clock clk -max 0.200 [get_ports {it_done}]
set_output_delay -clock clk -min 0.200 [get_ports {it_done}]
