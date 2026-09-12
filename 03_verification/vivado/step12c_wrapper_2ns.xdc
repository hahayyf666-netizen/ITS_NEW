# Step12C OOC boundary contract for the frozen Step12B wrapper.
#
# The wrapper is evaluated as a synchronous block between registered
# neighbors.  A zero external delay is intentional and means that the
# boundary data/control is available at the launching edge and the output is
# captured by the following edge.  This is an explicit OOC contract, not a
# post-hoc timing relaxation.

create_clock -name clk -period 2.000 [get_ports clk]

set step12c_inputs [get_ports {rst_n it_info it_info_vld it_data_in it_data_addr it_data_in_vld it_data_end it_data_out_req}]
set step12c_outputs [get_ports {it_data_in_req it_data_out it_data_out_vld it_done protocol_error debug_stage16_valid debug_stage16_row debug_stage16_col debug_stage16_data}]

set_input_delay  -clock clk -max 0.000 $step12c_inputs
set_input_delay  -clock clk -min 0.000 $step12c_inputs
set_output_delay -clock clk -max 0.000 $step12c_outputs
set_output_delay -clock clk -min 0.000 $step12c_outputs

