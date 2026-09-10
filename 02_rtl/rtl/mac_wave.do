# 一键脚本：编译 + 仿真 + 波形
vlib work
vlog its_mac.v its_mac_tb.v
vsim -voptargs=+acc its_mac_tb
add wave -recursive *
run -all
