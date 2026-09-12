`timescale 1ns/1ps

module step12b_dct2_64_wrapper_random_tb #(
    parameter string INPUT_FILE = "03_verification/generated/step12b_random_input.mem",
    parameter string EXPECTED_FILE = "03_verification/generated/step12b_random_expected.mem"
);
    reg clk = 0, rst_n = 0;
    reg [21:0] it_info = 22'h002040;
    reg it_info_vld = 0;
    reg signed [15:0] it_data_in = 0;
    reg [11:0] it_data_addr = 0;
    reg it_data_in_vld = 0, it_data_end = 0;
    wire it_data_in_req;
    reg it_data_out_req = 1;
    wire [39:0] it_data_out;
    wire it_data_out_vld, it_done, protocol_error;
    wire debug_stage16_valid;
    wire [5:0] debug_stage16_row, debug_stage16_col;
    wire signed [15:0] debug_stage16_data;
    reg [15:0] input_mem [0:4095];
    reg [39:0] expected_mem [0:1023];
    integer cycles = 0, fires = 0, data_errors = 0;

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
        $readmemh(INPUT_FILE, input_mem);
        $readmemh(EXPECTED_FILE, expected_mem);
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        it_info = 22'h002040;
        it_info_vld = 1'b1;
        @(posedge clk);
        it_info_vld = 1'b0;
        wait (it_data_in_req);

        // Dense full-range signed16 stream; the final point and end are the
        // same accepted edge.
        for (integer a = 0; a < 4096; a = a + 1) begin
            while (!it_data_in_req) @(posedge clk);
            it_data_addr = a[11:0];
            it_data_in = input_mem[a];
            it_data_in_vld = 1'b1;
            it_data_end = (a == 4095);
            @(posedge clk);
            it_data_in_vld = 1'b0;
            it_data_end = 1'b0;
        end

        while (cycles < 20000 && !it_done) begin
            @(negedge clk);
            cycles = cycles + 1;
            if (it_data_out_vld && it_data_out_req) begin
                if (fires >= 1024 || it_data_out !== expected_mem[fires]) begin
                    data_errors = data_errors + 1;
                    if (data_errors < 4)
                        $display("RANDOM_DATA_MISMATCH beat=%0d got=%h exp=%h",
                                 fires, it_data_out, expected_mem[fires]);
                end
                fires = fires + 1;
            end
        end
        if (protocol_error) $fatal(1, "Step12B random protocol_error asserted");
        if (!it_done) $fatal(1, "Step12B random timeout");
        if (fires != 1024) $fatal(1, "Step12B random expected 1024 beats, got %0d", fires);
        if (data_errors != 0) $fatal(1, "Step12B random data errors=%0d", data_errors);
        $display("STEP12B_RANDOM_PASS cycles=%0d output_beats=%0d", cycles, fires);
        $finish;
    end
endmodule
