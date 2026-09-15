# Diagnostic module OOC ports differ from the wrapper. Same 2 ns period and
# zero input/output budgets; no timing exceptions. Not physical signoff.
create_clock -name clk -period 2.000 [get_ports clk]
set probe_inputs [get_ports -filter {DIRECTION == IN && NAME != clk}]
set probe_outputs [get_ports -filter {DIRECTION == OUT}]
set_input_delay -clock clk -min 0.000 $probe_inputs
set_input_delay -clock clk -max 0.000 $probe_inputs
set_output_delay -clock clk -min 0.000 $probe_outputs
set_output_delay -clock clk -max 0.000 $probe_outputs
