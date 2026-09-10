# R4C functional simulation with the synthesis preprocessor define.
set root {C:/Users/Fine/Documents/Codex/2026-07-23/ni/ITS_STUDY_V35_P2F_B2_R4C_DSP_PIPE}
set sim  "$root/03_verification/sim"
set rtl  "$root/02_rtl/rtl"
set tb   "$root/03_verification/tb"
set lib  "$sim/work_r4c_dsp_pipe_synthesis_runclean"
if {[file exists $lib]} { puts "Using existing R4C synthesis library: $lib" } else { vlib $lib }
vmap work_r4c_dsp_pipe_synthesis_runclean $lib
vlog -sv -work work_r4c_dsp_pipe_synthesis_runclean +define+SYNTHESIS \
    +incdir+$rtl \
    $rtl/p2f_dct2_64_b1_step102.sv \
    $tb/p2f_dct2_64_b1_tb.sv
vsim -c -lib work_r4c_dsp_pipe_synthesis_runclean p2f_dct2_64_b1_tb \
    -do {run -all; quit -f}
