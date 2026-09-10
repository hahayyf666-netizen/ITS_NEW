# ModelSim smoke regression for the SYNTHESIS RTL branch.
# This is intentionally small; the full 1539-test regression uses run_500_singleclk.do.

proc resolve_xpm_dir {} {
    set candidates {}

    if {[info exists ::env(VIVADO_XPM_DIR)]} {
        lappend candidates $::env(VIVADO_XPM_DIR)
    }
    if {[info exists ::env(VIVADO_HOME)]} {
        lappend candidates [file join $::env(VIVADO_HOME) data ip xpm]
        lappend candidates [file join $::env(VIVADO_HOME) Vivado data ip xpm]
    }
    if {[info exists ::env(XILINX_VIVADO)]} {
        lappend candidates [file join $::env(XILINX_VIVADO) data ip xpm]
    }

    foreach dir {
        C:/App/Xilinx/Vivado/2025.2/data/ip/xpm
        C:/App/Xilinx/Vivado/2024.1/data/ip/xpm
        C:/Xilinx/Vivado/2025.2/data/ip/xpm
        C:/Xilinx/Vivado/2024.1/data/ip/xpm
        D:/AMDDesignTools/2025.2/Vivado/data/ip/xpm
        D:/AMDDesignTools/2024.1/Vivado/data/ip/xpm
    } {
        lappend candidates $dir
    }

    foreach dir $candidates {
        set xpm_sv [file join $dir xpm_memory hdl xpm_memory.sv]
        if {[file exists $xpm_sv]} {
            return $dir
        }
    }

    puts stderr "ERROR: Vivado XPM library not found."
    puts stderr "Set VIVADO_XPM_DIR directly, or set VIVADO_HOME / XILINX_VIVADO to your Vivado install root."
    puts stderr "Example: set VIVADO_XPM_DIR D:/AMDDesignTools/2025.2/Vivado/data/ip/xpm"
    quit -code 2
}

vlib work

# Copy ROM init files into the simulation working directory for $readmemh.
file copy -force ../../02_rtl/rtl/rom_coeffs.hex .
file copy -force ../../02_rtl/rtl/lfnst_coeffs.hex .

set xpm_dir [resolve_xpm_dir]
set xpm_sv [file join $xpm_dir xpm_memory hdl xpm_memory.sv]
set incdir_arg "+incdir+$xpm_dir"
puts "Using Vivado XPM dir: $xpm_dir"
eval [list vlog -sv $incdir_arg $xpm_sv]

vlog -sv +define+SYNTHESIS ../../02_rtl/rtl/its_mac.v
vlog -sv +define+SYNTHESIS ../../02_rtl/rtl/its_rom.v
vlog -sv +define+SYNTHESIS ../../02_rtl/rtl/its_lfnst_rom.v
vlog -sv +define+SYNTHESIS ../../02_rtl/rtl/its_transform_engine.v
vlog -sv +define+SYNTHESIS ../../02_rtl/rtl/its_lfnst.v
vlog -sv +define+SYNTHESIS ../../02_rtl/rtl/its_core_500.v
vlog -sv +define+SYNTHESIS ../../02_rtl/rtl/rst_sync.v
vlog -sv +define+SYNTHESIS ../../02_rtl/rtl/async_fifo.v
vlog -sv +define+SYNTHESIS ../../02_rtl/rtl/fifo_fwft_reg_slice.v
vlog -sv +define+SYNTHESIS ../../02_rtl/rtl/its_top_500_wrapper.v
vlog -sv +define+SYNTHESIS ../../02_rtl/rtl/its_top_500_singleclk.v

vlog -sv +define+SINGLECLK_SUBMISSION +define+SYNTHESIS_SMOKE ../tb/its_tb_500.v

vsim -t 1ps work.its_tb_500

run -all
