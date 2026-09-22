`timescale 1ns/1ps

// SAT10 red-team gate: exhaustively exercise the actual wrapper function over
// the complete signed-16 intermediate domain.  This is intentionally
// independent of the sparse/full Gate-C campaigns, which historically did
// not produce out-of-range signed-10 values.
module unified_its_final_adapter_tb;
    logic clk = 1'b0;
    always #1 clk = ~clk;
    logic rst_n = 1'b0;
    logic [21:0] it_info = '0;
    logic it_info_vld = 1'b0;
    logic signed [15:0] it_data_in = '0;
    logic [11:0] it_data_addr = '0;
    logic it_data_in_vld = 1'b0;
    logic it_data_end = 1'b0;
    logic it_data_in_req;
    logic it_data_out_req = 1'b0;
    logic [39:0] it_data_out;
    logic it_data_out_vld;
    logic it_done;
    logic protocol_error;

    unified_its_wrapper #(
        .FINAL_SATURATE(1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .it_info(it_info), .it_info_vld(it_info_vld),
        .it_data_in(it_data_in), .it_data_addr(it_data_addr),
        .it_data_in_vld(it_data_in_vld), .it_data_end(it_data_end),
        .it_data_in_req(it_data_in_req),
        .it_data_out_req(it_data_out_req),
        .it_data_out(it_data_out), .it_data_out_vld(it_data_out_vld),
        .it_done(it_done), .protocol_error(protocol_error)
    );

    integer i;
    integer expected;
    logic signed [9:0] got;

    initial begin
        for (i = -32768; i <= 32767; i = i + 1) begin
            it_data_in = i;
            got = dut.final_adapter(it_data_in);
            expected = (i < -512) ? -512 : ((i > 511) ? 511 : i);
            if ($signed(got) !== expected) begin
                $fatal(1, "SAT10 mismatch x=%0d got=%0d expected=%0d", i,
                       $signed(got), expected);
            end
        end
        if ($signed(dut.final_adapter(-16'sd513)) !== -512 ||
            $signed(dut.final_adapter(16'sd512)) !== 511) begin
            $fatal(1, "SAT10 explicit boundary check failed");
        end
        $display("SAT10_ADAPTER_EXHAUSTIVE_PASS values=65536");
        $finish;
    end
endmodule

