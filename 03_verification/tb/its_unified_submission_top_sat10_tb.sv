`timescale 1ns/1ps

// Exercise the actual competition-facing module, not only its wrapper.
module its_unified_submission_top_sat10_tb;
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
    logic [39:0] it_data_out;
    logic it_data_out_vld;
    logic it_data_out_req = 1'b0;
    logic it_done;

    its_unified_submission_top dut (
        .clk(clk), .rst_n(rst_n),
        .it_info(it_info), .it_info_vld(it_info_vld),
        .it_data_in(it_data_in), .it_data_addr(it_data_addr),
        .it_data_in_vld(it_data_in_vld), .it_data_end(it_data_end),
        .it_data_in_req(it_data_in_req),
        .it_data_out(it_data_out), .it_data_out_vld(it_data_out_vld),
        .it_data_out_req(it_data_out_req), .it_done(it_done)
    );

    function automatic [21:0] desc4x4;
        desc4x4 = 22'd4 | (22'd4 << 7);
    endfunction

    function automatic [39:0] packed_lanes(input logic signed [9:0] lane);
        packed_lanes = {lane, lane, lane, lane};
    endfunction

    task automatic reset_dut;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            it_info_vld = 1'b0;
            it_data_in_vld = 1'b0;
            it_data_end = 1'b0;
            it_data_out_req = 1'b0;
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic submit_4x4(input logic signed [15:0] value,
                              input integer case_id);
        integer timeout;
        begin
            @(negedge clk);
            it_info = desc4x4();
            it_info_vld = 1'b1;
            @(negedge clk);
            it_info_vld = 1'b0;
            timeout = 0;
            while (!it_data_in_req) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 2000)
                    $fatal(1, "submission-top input admission timeout case=%0d", case_id);
            end
            it_data_addr = 12'd0;
            it_data_in = value;
            it_data_in_vld = 1'b1;
            it_data_end = 1'b1;
            @(negedge clk);
            it_data_in_vld = 1'b0;
            it_data_end = 1'b0;
        end
    endtask

    integer cycle;
    integer stall_cycles;
    integer beat;
    integer done_count;
    integer timeout;
    logic [39:0] held_word;
    logic [39:0] expected_word;
    bit have_held_word;

    initial begin
        reset_dut();
        submit_4x4(16'sd32767, 0);
        submit_4x4(-16'sd32768, 1);

        @(negedge clk);
        it_data_out_req = 1'b0;
        stall_cycles = 0;
        have_held_word = 1'b0;
        for (cycle = 0; cycle < 80; cycle = cycle + 1) begin
            @(posedge clk);
            if (it_data_out_vld)
                $fatal(1, "submission-top out_valid asserted while stalled");
            if (it_done)
                $fatal(1, "submission-top done asserted without output handshake");
            if (dut.u_unified_wrapper.output_active) begin
                stall_cycles = stall_cycles + 1;
                if (have_held_word && it_data_out !== held_word)
                    $fatal(1, "submission-top 40-bit output changed while stalled");
                held_word = it_data_out;
                have_held_word = 1'b1;
            end
        end
        if (!have_held_word || stall_cycles < 8)
            $fatal(1, "submission-top did not demonstrate pending-output stall cycles=%0d",
                   stall_cycles);

        @(negedge clk);
        it_data_out_req = 1'b1;
        beat = 0;
        done_count = 0;
        timeout = 0;
        while (beat < 8) begin
            @(posedge clk);
            timeout = timeout + 1;
            if (timeout > 2000)
                $fatal(1, "submission-top output drain timeout");
            if (it_data_out_vld) begin
                expected_word = (beat < 4) ? packed_lanes(10'sh1ff) :
                                             packed_lanes(10'sh200);
                if (it_data_out !== expected_word)
                    $fatal(1, "submission-top packed-lane mismatch beat=%0d got=%h expected=%h",
                           beat, it_data_out, expected_word);
                if (it_done !== ((beat == 3) || (beat == 7)))
                    $fatal(1, "submission-top done mismatch beat=%0d done=%b", beat, it_done);
                done_count = done_count + it_done;
                beat = beat + 1;
            end
        end
        @(negedge clk);
        it_data_out_req = 1'b0;
        repeat (2) @(negedge clk);
        if (done_count != 2)
            $fatal(1, "submission-top expected two done pulses, got %0d", done_count);
        $display("SAT10_SUBMISSION_TOP_PASS tus=2 beats=8 done=2 observed_stall_cycles=%0d", stall_cycles);
        $finish;
    end
endmodule
