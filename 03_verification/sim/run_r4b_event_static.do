# Reproducible R4B event-static P2F functional simulation.
if {[file exists work_r4b_event_static]} { vdel -lib work_r4b_event_static -all }
vlib work_r4b_event_static
vmap work_r4b_event_static [file normalize work_r4b_event_static]
vlog -sv -work work_r4b_event_static \
    +incdir+[file normalize ../../02_rtl/rtl] \
    [file normalize ../../02_rtl/rtl/p2f_dct2_64_b1_step102.sv] \
    [file normalize ../tb/p2f_dct2_64_b1_tb.sv]
vsim -c -lib work_r4b_event_static p2f_dct2_64_b1_tb \
    -do {run -all; quit -f}
