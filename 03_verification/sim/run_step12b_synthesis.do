transcript file 03_verification/logs/step12b_wrapper_synthesis.log
if {![file exists work]} {vlib work}
vlog -sv -work work +define+SYNTHESIS +incdir+02_rtl/rtl 02_rtl/rtl/p2f_dct2_64_b1_step102.sv 02_rtl/rtl/step12b_dct2_64_wrapper.sv 03_verification/tb/step12b_dct2_64_wrapper_tb.sv
vsim -c work.step12b_dct2_64_wrapper_tb
run -all
quit -f
