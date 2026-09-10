// Quick sanity test: its_core_500 with register-based FIFO stubs (single clock)
`timescale 1ns / 1ps
module tb_core_500_direct;

    reg clk, rst_n;

    // FIFO stubs
    reg  [22:0] cmd_fifo_rdata;
    reg         cmd_fifo_empty;
    wire        cmd_fifo_rd_en;

    reg  [28:0] input_fifo_rdata;
    reg         input_fifo_empty;
    wire        input_fifo_rd_en;

    wire [39:0] output_fifo_wdata;
    wire        output_fifo_wr_en;
    reg         output_fifo_full;
    reg         output_fifo_almost_full;

    wire        core_done;

    its_core_500 u_core (
        .clk_core           (clk),
        .rst_n              (rst_n),
        .cmd_fifo_rdata     (cmd_fifo_rdata),
        .cmd_fifo_empty     (cmd_fifo_empty),
        .cmd_fifo_rd_en     (cmd_fifo_rd_en),
        .input_fifo_rdata   (input_fifo_rdata),
        .input_fifo_empty   (input_fifo_empty),
        .input_fifo_rd_en   (input_fifo_rd_en),
        .output_fifo_wdata  (output_fifo_wdata),
        .output_fifo_wr_en  (output_fifo_wr_en),
        .output_fifo_full   (output_fifo_full),
        .output_fifo_almost_full(output_fifo_almost_full),
        .core_done          (core_done),
        .core_ready         ()
    );

    initial clk = 0;
    always #2.5 clk = ~clk; // 200MHz

    integer out_count;

    initial begin
        // Init
        rst_n = 0;
        cmd_fifo_rdata = 0;
        cmd_fifo_empty = 1;
        input_fifo_rdata = 0;
        input_fifo_empty = 1;
        output_fifo_full = 0;
        output_fifo_almost_full = 0;
        out_count = 0;

        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(10) @(posedge clk);

        // Send cmd: 4x4 DCT2
        $display("Sending cmd: 4x4 DCT2");
        cmd_fifo_rdata = {1'b0, 2'd0, 2'd0, 2'd0, 2'd0, 7'd4, 7'd4};
        cmd_fifo_empty = 0;
        @(posedge clk);
        wait(cmd_fifo_rd_en);
        @(posedge clk);
        cmd_fifo_empty = 1;
        $display("Cmd consumed, state=%0d", u_core.state);

        // Send 4 input data points
        repeat(5) @(posedge clk);
        $display("Sending input data...");
        input_fifo_empty = 0;

        // Point 0: addr=0, data=100
        input_fifo_rdata = {1'b0, 12'd0, 16'd100};
        @(posedge clk);
        wait(input_fifo_rd_en);
        @(posedge clk);

        // Point 1: addr=1, data=200
        input_fifo_rdata = {1'b0, 12'd1, 16'd200};
        @(posedge clk);
        wait(input_fifo_rd_en);
        @(posedge clk);

        // Point 2: addr=2, data=300
        input_fifo_rdata = {1'b0, 12'd2, 16'd300};
        @(posedge clk);
        wait(input_fifo_rd_en);
        @(posedge clk);

        // Point 3: addr=3, data=400
        input_fifo_rdata = {1'b0, 12'd3, 16'd400};
        @(posedge clk);
        wait(input_fifo_rd_en);
        @(posedge clk);

        // Last marker
        input_fifo_rdata = {1'b1, 12'd0, 16'd0};
        @(posedge clk);
        wait(input_fifo_rd_en);
        @(posedge clk);
        input_fifo_empty = 1;
        $display("Input done, state=%0d", u_core.state);

        // Wait for output
        $display("Waiting for output...");
        repeat(5000) begin
            @(posedge clk);
            if (output_fifo_wr_en) begin
                $display("  Output[%0d]: %h", out_count, output_fifo_wdata);
                out_count = out_count + 1;
            end
            if (core_done) begin
                $display("  core_done! state=%0d", u_core.state);
            end
        end

        $display("Total outputs: %0d", out_count);
        $finish;
    end

    initial begin
        #100000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule

