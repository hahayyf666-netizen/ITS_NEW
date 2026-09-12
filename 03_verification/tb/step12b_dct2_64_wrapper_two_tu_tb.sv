`timescale 1ns/1ps

// Step12B protocol/ownership stress: descriptor push+pop on the same edge,
// one active input stream, an empty second TU, long output backpressure, and
// two independent it_done pulses.  Numeric coverage of the full transform is
// retained by the single-TU oracle TB; this TB focuses on ownership/capacity.
module step12b_dct2_64_wrapper_two_tu_tb;
    reg clk = 0;
    reg rst_n = 0;
    reg [21:0] it_info = 0;
    reg it_info_vld = 0;
    reg signed [15:0] it_data_in = 0;
    reg [11:0] it_data_addr = 0;
    reg it_data_in_vld = 0;
    reg it_data_end = 0;
    wire it_data_in_req;
    reg it_data_out_req = 0;
    wire [39:0] it_data_out;
    wire it_data_out_vld;
    wire it_done;
    wire protocol_error;
    wire debug_stage16_valid;
    wire [5:0] debug_stage16_row, debug_stage16_col;
    wire signed [15:0] debug_stage16_data;
    integer cycles, fires, done_count, errors;
    reg hold_seen;
    reg [39:0] hold_data;

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
        cycles = 0;
        fires = 0;
        done_count = 0;
        errors = 0;
        hold_seen = 1'b0;
        hold_data = 0;

        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        // TU0 descriptor.
        it_info <= 22'h155001;
        it_info_vld <= 1'b1;
        @(posedge clk);
        it_info_vld <= 1'b0;
        wait (it_data_in_req);

        // TU0 final data and TU1 descriptor are deliberately accepted on the
        // same edge.  This exercises descriptor FIFO push/pop next-state.
        it_data_addr <= 12'd65;
        it_data_in <= 16'sd100;
        it_data_in_vld <= 1'b1;
        it_data_end <= 1'b1;
        it_info <= 22'h2AA155;
        it_info_vld <= 1'b1;
        @(posedge clk);
        it_data_in_vld <= 1'b0;
        it_data_end <= 1'b0;
        it_info_vld <= 1'b0;

        // TU1 is empty: standalone end is legal once its descriptor has been
        // bound and req is asserted.  Its output must be all zero, proving no
        // stale TU0 cache data leaked through the epoch/tag path.
        wait (it_data_in_req);
        it_data_end <= 1'b1;
        @(posedge clk);
        it_data_end <= 1'b0;

        // Keep output stalled through the first result production and into
        // the second TU's vertical work.  Then drain with ready high.
        while (cycles < 20000 && done_count < 2) begin
            @(negedge clk);
            cycles = cycles + 1;
            if (cycles < 5000)
                it_data_out_req = 1'b0;
            else
                it_data_out_req = 1'b1;

            if (!it_data_out_req) begin
                if (it_data_out_vld) begin
                    if (hold_seen && it_data_out !== hold_data)
                        errors = errors + 1;
                    hold_seen = 1'b1;
                    hold_data = it_data_out;
                end
            end else begin
                hold_seen = 1'b0;
            end

            // A fire is sampled for the accepting edge that follows this
            // negedge.  The first sparse TU has a deterministic first beat;
            // every beat of the empty TU must be zero.
            if (it_data_out_vld && it_data_out_req) begin
                fires = fires + 1;
                if (fires == 1 && it_data_out !== 40'h320c8320ca)
                    errors = errors + 1;
                if (fires > 1024 && it_data_out !== 40'd0)
                    errors = errors + 1;
            end
            if (it_done)
                done_count = done_count + 1;
        end

        if (protocol_error) $fatal(1, "Step12B two-TU protocol_error asserted");
        if (cycles >= 20000) $fatal(1, "Step12B two-TU timeout");
        if (done_count != 2) $fatal(1, "Step12B expected two it_done pulses, got %0d", done_count);
        if (fires != 2048) $fatal(1, "Step12B expected 2048 output beats, got %0d", fires);
        if (errors != 0) $fatal(1, "Step12B two-TU errors=%0d", errors);
        $display("STEP12B_TWO_TU_PASS cycles=%0d output_beats=%0d done=%0d", cycles, fires, done_count);
        $finish;
    end
endmodule
