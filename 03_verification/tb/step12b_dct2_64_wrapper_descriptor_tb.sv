`timescale 1ns/1ps

module step12b_dct2_64_wrapper_descriptor_tb;
    reg clk = 0, rst_n = 0;
    reg [21:0] it_info = 22'h002040;
    reg it_info_vld = 0;
    reg signed [15:0] it_data_in = 0;
    reg [11:0] it_data_addr = 0;
    reg it_data_in_vld = 0, it_data_end = 0;
    wire it_data_in_req;
    reg it_data_out_req = 0;
    wire [39:0] it_data_out;
    wire it_data_out_vld, it_done, protocol_error;
    wire debug_stage16_valid;
    wire [5:0] debug_stage16_row, debug_stage16_col;
    wire signed [15:0] debug_stage16_data;

    always #1 clk = ~clk;

    step12b_dct2_64_wrapper dut (
        .clk(clk), .rst_n(rst_n), .it_info(it_info), .it_info_vld(it_info_vld),
        .it_data_in(it_data_in), .it_data_addr(it_data_addr),
        .it_data_in_vld(it_data_in_vld), .it_data_end(it_data_end),
        .it_data_in_req(it_data_in_req), .it_data_out_req(it_data_out_req),
        .it_data_out(it_data_out), .it_data_out_vld(it_data_out_vld),
        .it_done(it_done), .protocol_error(protocol_error),
        .debug_stage16_valid(debug_stage16_valid),
        .debug_stage16_row(debug_stage16_row), .debug_stage16_col(debug_stage16_col),
        .debug_stage16_data(debug_stage16_data)
    );

    initial begin
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);
        // Unsupported descriptor: this Step12B wrapper is intentionally
        // limited to 64x64 DCT2/DCT2 with LFNST disabled.  The set-index
        // field remains don't-care when lfnst_idx==0, but width/type/idx
        // violations must be rejected and must not bind a cache.
        it_info <= 22'h000000; it_info_vld <= 1'b1; @(posedge clk); it_info_vld <= 1'b0;
        #1;
        if (!protocol_error) $fatal(1, "unsupported descriptor was not rejected");
        if (dut.desc_count != 0) $fatal(1, "unsupported descriptor was enqueued");
        if (it_data_in_req) $fatal(1, "unsupported descriptor opened input request");
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        // Fill q0, then q1, then issue an illegal third descriptor while the
        // two-entry descriptor FIFO is full.  Existing descriptors must stay.
        it_info <= 22'h002040; it_info_vld <= 1'b1; @(posedge clk); it_info_vld <= 1'b0;
        it_info <= 22'h042040; it_info_vld <= 1'b1; @(posedge clk); it_info_vld <= 1'b0;
        it_info <= 22'h082040; it_info_vld <= 1'b1; @(posedge clk); it_info_vld <= 1'b0;
        #1;
        if (!protocol_error) $fatal(1, "descriptor overflow was not rejected");
        if (dut.desc_count != 2) $fatal(1, "descriptor FIFO count changed on overflow");
        if (dut.desc_info_q[0] !== 22'h002040 || dut.desc_info_q[1] !== 22'h042040)
            $fatal(1, "descriptor payload was not retained losslessly");
        $display("STEP12B_DESCRIPTOR_SEMANTICS_PASS");
        $display("STEP12B_DESCRIPTOR_OVERFLOW_PASS");
        $finish;
    end
endmodule
