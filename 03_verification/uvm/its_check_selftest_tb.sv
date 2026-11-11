// A5 reverse self-test for the checker layer.
//
// This testbench contains no DUT.  It drives the interface directly so the
// monitor and the log scanner can be shown to go red on exactly the stimuli a
// real run must never produce, and to stay quiet when nothing happens.
//
// Scenario is selected with +SCEN=<name>; a5_selftest.py asserts on the
// diagnostics that appear in the log.
//
//   clean         nothing happens; no diagnostic may appear
//   done_no_fire  done with the request low  -> ITS_DONE_NO_FIRE
//   data_x        accepted beat carrying X   -> ITS_DATA_X
//   uvm_fatal     UVM_FATAL, which exits before report_phase writes anything
//   native_error  native $error, which leaves the process exit code at 0
//   native_fatal  native $fatal, whose log also carries a $finish line
//
// The stimulus lives in run_phase and holds an objection: UVM ends the
// simulation as soon as every phase has finished, so without an objection the
// whole scenario would be skipped at time 0.

`timescale 1ps/1ps

`include "uvm_macros.svh"
import uvm_pkg::*;
import its_uvm_pkg::*;

class its_check_selftest_test extends uvm_test;
    virtual its_if vif;

    `uvm_component_utils(its_check_selftest_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual its_if)::get(this, "", "vif", vif))
            `uvm_fatal("ITS_SELFTEST", "no virtual interface in config db")
        void'(its_monitor::type_id::create("mon", this));
    endfunction

    task run_phase(uvm_phase phase);
        string scen;
        phase.raise_objection(this);
        if (!$value$plusargs("SCEN=%s", scen)) scen = "clean";

        vif.rst_n = 1'b0;
        repeat (5) @(negedge vif.clk);
        vif.rst_n = 1'b1;
        repeat (5) @(negedge vif.clk);   // the monitor warms up for 3 cycles

        case (scen)
            "done_no_fire": begin
                // done rides no handshake: the state the real DUT cannot
                // produce through legal stimulus.
                vif.it_data_out_req = 1'b0;
                vif.it_data_out_vld = 1'b1;
                vif.it_done         = 1'b1;
                @(negedge vif.clk);
                vif.it_data_out_vld = 1'b0;
                vif.it_done         = 1'b0;
            end
            "data_x": begin
                vif.it_data_out_req = 1'b1;
                vif.it_data_out     = 40'hx;
                vif.it_data_out_vld = 1'b1;
                vif.it_done         = 1'b0;
                @(negedge vif.clk);
                vif.it_data_out_vld = 1'b0;
                vif.it_data_out     = 40'h0;
            end
            default: ;
        endcase

        repeat (4) @(negedge vif.clk);

        // The uvm_fatal macro expands to a begin/end block, which cannot be a
        // case item; calling the report function keeps it a plain statement and
        // still goes through the report server.
        case (scen)
            "uvm_fatal":    uvm_report_fatal("ITS_INJECTED_FATAL",
                                             "injected for the A5 self-test");
            "native_error": $error("ITS_INJECTED_NATIVE_ERROR");
            "native_fatal": $fatal(1, "ITS_INJECTED_NATIVE_FATAL");
            default: ;
        endcase

        phase.drop_objection(this);
    endtask
endclass

module its_check_selftest_tb;
    logic clk = 1'b0;
    always #500 clk = ~clk;

    its_if dif(.clk(clk));

    initial begin
        // Every signal the DUT would drive is driven here instead.
        dif.it_data_in_req    = 1'b0;
        dif.it_data_out       = 40'h0;
        dif.it_data_out_vld   = 1'b0;
        dif.it_done           = 1'b0;
        dif.protocol_error    = 1'b0;
        dif.dbg_scrub_active  = 1'b0;
        dif.dbg_fill_active   = 1'b0;
        dif.dbg_lfnst_busy    = 1'b0;
        dif.dbg_kernel_busy   = 1'b0;
        dif.dbg_output_active = 1'b0;
        uvm_config_db #(virtual its_if)::set(null, "*", "vif", dif);
        run_test("its_check_selftest_test");
    end
endmodule