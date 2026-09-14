# Step12F fresh unified-wrapper OOC boundary contract.
# This file intentionally targets only unified_its_wrapper and its actual
# interface.  It is not inherited from the frozen Step12B/v3.5-18 wrapper.

create_clock -name clk -period 2.000 [get_ports clk]

set step12f_inputs [get_ports {
    rst_n
    it_info
    it_info_vld
    it_data_in
    it_data_addr
    it_data_in_vld
    it_data_end
    it_data_out_req
}]
set step12f_outputs [get_ports {
    it_data_in_req
    it_data_out
    it_data_out_vld
    it_done
    protocol_error
}]

# Registered-neighbor OOC contract.  These are explicit timing assumptions;
# they do not waive paths or add implementation delay.
set_input_delay  -clock clk -max 0.000 $step12f_inputs
set_input_delay  -clock clk -min 0.000 $step12f_inputs
set_output_delay -clock clk -max 0.000 $step12f_outputs
set_output_delay -clock clk -min 0.000 $step12f_outputs
