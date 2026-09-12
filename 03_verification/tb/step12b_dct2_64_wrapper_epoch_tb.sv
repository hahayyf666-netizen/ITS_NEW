`timescale 1ns/1ps

// Force EPOCH_BITS=2 so a short multi-TU run exercises real cache scrub and
// proves that omitted addresses never resurrect data from an older TU.
module step12b_dct2_64_wrapper_epoch_tb;
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
    integer sim_cycles = 0, fires = 0, done_count = 0, errors = 0;
    reg input_done = 1'b0;

    always #1 clk = ~clk;

    step12b_dct2_64_wrapper #(.EPOCH_BITS(2)) dut (
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

    task automatic pulse_info(input [21:0] info);
        begin
            it_info = info;
            it_info_vld = 1'b1;
            @(posedge clk);
            it_info_vld = 1'b0;
        end
    endtask

    task automatic finish_empty_tu;
        begin
            wait (it_data_in_req);
            it_data_end = 1'b1;
            @(posedge clk);
            it_data_end = 1'b0;
        end
    endtask

    // Input stream: TU0 has one nonzero point; TU1..TU9 are empty.  The
    // repeated cache reuse forces EPOCH_BITS=2 wrap and scrub.
    initial begin : drive_input
        integer t;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        pulse_info(22'h002040);
        wait (it_data_in_req);
        it_data_addr = 12'd65;
        it_data_in = 16'sd100;
        it_data_in_vld = 1'b1;
        it_data_end = 1'b1;
        @(posedge clk);
        it_data_in_vld = 1'b0;
        it_data_end = 1'b0;
        for (t = 1; t < 10; t = t + 1) begin
            pulse_info(22'h002040 + ((t % 4) << 18));
            finish_empty_tu();
        end
        input_done = 1'b1;
    end

    // A long initial stall fills the first result memory.  The monitor then
    // drains every TU and checks that only TU0 can contain the nonzero beat.
    always @(negedge clk) begin
        sim_cycles = sim_cycles + 1;
        it_data_out_req = (sim_cycles >= 5000);
        #1step;
        if (it_data_out_vld && it_data_out_req) begin
            fires = fires + 1;
            if (fires == 1 && it_data_out !== 40'h320c8320ca)
                errors = errors + 1;
            if (fires > 1024 && it_data_out !== 40'd0)
                errors = errors + 1;
        end
        if (it_done)
            done_count = done_count + 1;
        if (protocol_error)
            $fatal(1, "Step12B epoch protocol_error asserted");
        if (sim_cycles > 60000)
            $fatal(1, "Step12B epoch timeout fires=%0d done=%0d", fires, done_count);
    end

    initial begin
        wait (input_done);
        wait (done_count == 10);
        #2;
        if (fires != 10240) $fatal(1, "Step12B epoch expected 10240 beats, got %0d", fires);
        if (errors != 0) $fatal(1, "Step12B epoch stale-data errors=%0d", errors);
        $display("STEP12B_EPOCH_WRAP_PASS cycles=%0d output_beats=%0d done=%0d", sim_cycles, fires, done_count);
        $finish;
    end
endmodule
