// D3 UVM top: clock, interface and the DUT.
//
// The DUT is unified_its_wrapper #(FINAL_SATURATE=1), the same configuration
// its_unified_submission_top selects, chosen here so that protocol_error stays
// observable.  Every pin is driven by the UVM driver; this module only supplies
// the clock and hands the virtual interface to the test.

`timescale 1ns/1ps

module its_uvm_tb;

    import uvm_pkg::*;
    import its_uvm_pkg::*;

    logic clk = 1'b0;
    always #1 clk = ~clk;

    its_if dif (.clk(clk));

    unified_its_wrapper #(
        .FINAL_SATURATE(1)
    ) dut (
        .clk              (dif.clk),
        .rst_n            (dif.rst_n),
        .it_info          (dif.it_info),
        .it_info_vld      (dif.it_info_vld),
        .it_data_in       (dif.it_data_in),
        .it_data_addr     (dif.it_data_addr),
        .it_data_in_vld   (dif.it_data_in_vld),
        .it_data_end      (dif.it_data_end),
        .it_data_in_req   (dif.it_data_in_req),
        .it_data_out_req  (dif.it_data_out_req),
        .it_data_out      (dif.it_data_out),
        .it_data_out_vld  (dif.it_data_out_vld),
        .it_done          (dif.it_done),
        .protocol_error   (dif.protocol_error)
    );

    initial begin
        uvm_config_db #(virtual its_if)::set(null, "*", "vif", dif);
        run_test();
    end

    // Coverage taps.  These read internal state of the wrapper instance that is
    // already declared (no RTL edit) so back-pressure can be attributed to the
    // stage that was actually busy.
    assign dif.dbg_scrub_active  = dut.scrub_active;
    assign dif.dbg_fill_active   = dut.fill_active;
    assign dif.dbg_lfnst_busy    = dut.lfnst_busy;
    assign dif.dbg_kernel_busy   = dut.kernel_busy;
    assign dif.dbg_output_active = dut.output_active;

    // Grant-profile audit.  One CSV row per rising clock edge, recording what the
    // DUT actually saw on that edge rather than what the driver believes it
    // drove.  The driver updates req with a non-blocking assignment on the
    // falling edge, so a reader on the falling edge would see the previous
    // value; the rising edge is the edge the DUT samples.
    //   off unless +GRANT_AUDIT=<path> is passed, so normal runs are unaffected
    int    audit_fd = 0;
    string audit_path;
    initial begin
        if ($value$plusargs("GRANT_AUDIT=%s", audit_path))
            audit_fd = $fopen(audit_path, "w");
    end

    always @(posedge clk) begin
        if (audit_fd != 0)
            $fdisplay(audit_fd, "%0t,%0d,%0d", $time, dif.rst_n,
                      dif.it_data_out_req);
    end

    final begin
        if (audit_fd != 0) $fclose(audit_fd);
    end

endmodule