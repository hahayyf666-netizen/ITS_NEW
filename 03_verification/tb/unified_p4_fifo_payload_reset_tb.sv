`timescale 1ns/1ps

module unified_p4_fifo_payload_reset_tb;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [1:0] tr_type = 2'd0;
    logic [6:0] transform_size = 7'd4;
    logic [6:0] active_size = 7'd4;
    logic [6:0] output_size = 7'd4;
    logic [5:0] output_group_count;
    logic stage_sel = 1'b0;
    logic in_valid = 1'b0;
    logic in_req;
    logic signed [63:0] in_data = '0;
    logic out_valid;
    logic out_req = 1'b0;
    logic signed [63:0] out_data;
    logic done;
    logic busy;
    logic error;
    logic input_group_fire;
    logic input_vector_done;
    integer wait_i;
    integer beat_count;
    integer done_count;
    integer lane_i;

    always #1 clk = ~clk;
    assign output_group_count = output_size[6:2];

    unified_p4_kernel dut (
        .clk(clk), .rst_n(rst_n), .start(start), .tr_type(tr_type),
        .transform_size(transform_size), .active_size(active_size),
        .output_size(output_size), .output_group_count(output_group_count),
        .stage_sel(stage_sel), .in_valid(in_valid), .in_req(in_req),
        .in_data(in_data), .out_valid(out_valid), .out_req(out_req),
        .out_data(out_data), .done(done),
        .input_group_fire(input_group_fire),
        .input_vector_done(input_vector_done), .busy(busy), .error(error)
    );

    task automatic reset_kernel;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            start = 1'b0;
            in_valid = 1'b0;
            in_data = '0;
            out_req = 1'b0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            #1step rst_n = 1'b1;
        end
    endtask

    task automatic send_vector(input integer sample_value);
        begin
            @(negedge clk);
            start = 1'b1;
            in_valid = 1'b1;
            for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1)
                in_data[lane_i*16 +: 16] = sample_value;
            #1step;
            if (!in_req)
                $fatal(1, "FIFO reset test vector was not accepted");
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;
            in_valid = 1'b0;
            in_data = '0;
        end
    endtask

    task automatic wait_for_fifo_payload;
        begin
            wait_i = 0;
            while (dut.fifo_count_q == 0 && wait_i < 128) begin
                @(negedge clk);
                wait_i = wait_i + 1;
            end
            if (dut.fifo_count_q == 0)
                $fatal(1, "FIFO payload did not become pending");
        end
    endtask

    task automatic verify_one_zero_output;
        begin
            beat_count = 0;
            done_count = 0;
            out_req = 1'b1;
            wait_i = 0;
            while ((beat_count == 0 || done_count == 0) && wait_i < 32) begin
                @(posedge clk);
                if (out_valid && out_req) begin
                    if (out_data !== 64'd0)
                        $fatal(1, "stale pre-reset FIFO payload escaped: %h", out_data);
                    beat_count = beat_count + 1;
                end
                #1step;
                if (done)
                    done_count = done_count + 1;
                @(negedge clk);
                wait_i = wait_i + 1;
            end
            out_req = 1'b0;
            if (beat_count != 1 || done_count != 1)
                $fatal(1, "post-reset output count mismatch beats=%0d done=%0d",
                       beat_count, done_count);
            repeat (4) begin
                @(posedge clk);
                #1step;
                if (out_valid || done || dut.fifo_count_q != 0)
                    $fatal(1, "stale FIFO ownership remained after reset");
            end
        end
    endtask

    initial begin
        // Reset while the arithmetic pipeline owns a vector but before its
        // result reaches the output FIFO.
        reset_kernel();
        send_vector(2048);
        wait_i = 0;
        while (!(dut.issue_desc_valid_q || dut.s0_valid_q || dut.s1_valid_q ||
                 dut.s2_valid_q || dut.s3_valid_q || dut.s4_valid_q ||
                 dut.s5_valid_q || dut.s6_valid_q || dut.shifted_valid_q ||
                 dut.pipe_out_valid_q) && wait_i < 32) begin
            @(negedge clk);
            wait_i = wait_i + 1;
        end
        if (wait_i == 32)
            $fatal(1, "did not observe in-flight arithmetic before reset");
        if (dut.fifo_count_q != 0)
            $fatal(1, "in-flight reset scenario unexpectedly already queued output");
        reset_kernel();
        if (dut.fifo_count_q != 0 || dut.output_active_q || out_data !== 64'd0)
            $fatal(1, "reset did not clear FIFO ownership/output view");
        send_vector(0);
        wait_for_fifo_payload();
        verify_one_zero_output();

        // Reset again with a real, nonzero payload waiting under backpressure.
        reset_kernel();
        send_vector(2048);
        wait_for_fifo_payload();
        if (dut.fifo_count_q == 0 || out_data === 64'd0)
            $fatal(1, "queued payload test did not establish nonzero pending data");
        reset_kernel();
        if (dut.fifo_count_q != 0 || dut.output_active_q || out_data !== 64'd0)
            $fatal(1, "reset exposed stale FIFO payload/ownership");

        send_vector(0);
        wait_for_fifo_payload();
        verify_one_zero_output();
        if (error)
            $fatal(1, "kernel error in FIFO payload reset test");

        $display("P4_FIFO_PAYLOAD_RESET_PASS inflight_reset=1 queued_nonzero_reset=1 stale_outputs=0");
        $finish;
    end
endmodule
