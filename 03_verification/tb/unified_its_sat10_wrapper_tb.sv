`timescale 1ns/1ps

// SAT10 wrapper qualification. All DUT inputs change on negedge; observations
// are made on posedge before the DUT's nonblocking state updates.
module unified_its_sat10_wrapper_tb;
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

    unified_its_wrapper #(.FINAL_SATURATE(1)) dut (
        .clk(clk), .rst_n(rst_n),
        .it_info(it_info), .it_info_vld(it_info_vld),
        .it_data_in(it_data_in), .it_data_addr(it_data_addr),
        .it_data_in_vld(it_data_in_vld), .it_data_end(it_data_end),
        .it_data_in_req(it_data_in_req),
        .it_data_out_req(it_data_out_req),
        .it_data_out(it_data_out), .it_data_out_vld(it_data_out_vld),
        .it_done(it_done), .protocol_error(protocol_error)
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
                    $fatal(1, "SAT10 input admission timeout case=%0d", case_id);
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

    task automatic run_single(input logic signed [15:0] value,
                              input logic signed [9:0] expected_lane,
                              input integer case_id);
        integer beat;
        integer timeout;
        integer done_count;
        logic [39:0] expected_word;
        begin
            reset_dut();
            submit_4x4(value, case_id);
            expected_word = packed_lanes(expected_lane);
            @(negedge clk);
            it_data_out_req = 1'b1;
            beat = 0;
            timeout = 0;
            done_count = 0;
            while (beat < 4) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 2000)
                    $fatal(1, "SAT10 wrapper timeout case=%0d", case_id);
                if (it_data_out_vld) begin
                    if (it_data_out !== expected_word)
                        $fatal(1, "SAT10 packed-lane mismatch case=%0d beat=%0d got=%h expected=%h",
                               case_id, beat, it_data_out, expected_word);
                    if (it_done !== (beat == 3))
                        $fatal(1, "SAT10 done timing mismatch case=%0d beat=%0d done=%b",
                               case_id, beat, it_done);
                    done_count = done_count + it_done;
                    beat = beat + 1;
                end
            end
            @(negedge clk);
            it_data_out_req = 1'b0;
            repeat (2) @(negedge clk);
            if (done_count != 1 || protocol_error)
                $fatal(1, "SAT10 single transaction completion failed case=%0d done=%0d error=%b",
                       case_id, done_count, protocol_error);
        end
    endtask

    task automatic run_two_tu_backpressure;
        integer cycle;
        integer beat;
        integer done_count;
        integer pending_stall_cycles;
        integer timeout;
        logic [39:0] held_word;
        logic [39:0] expected_word;
        bit have_held_word;
        begin
            reset_dut();
            submit_4x4(16'sd32767, 10);
            submit_4x4(-16'sd32768, 11);

            @(negedge clk);
            it_data_out_req = 1'b0;
            have_held_word = 1'b0;
            pending_stall_cycles = 0;
            for (cycle = 0; cycle < 80; cycle = cycle + 1) begin
                @(posedge clk);
                if (it_data_out_vld)
                    $fatal(1, "SAT10 out_valid asserted while out_req=0");
                if (it_done)
                    $fatal(1, "SAT10 done asserted without an output handshake");
                if (dut.output_active) begin
                    pending_stall_cycles = pending_stall_cycles + 1;
                    if (have_held_word && it_data_out !== held_word)
                        $fatal(1, "SAT10 pending output changed during stall");
                    held_word = it_data_out;
                    have_held_word = 1'b1;
                end
            end
            if (!have_held_word || pending_stall_cycles < 8)
                $fatal(1, "SAT10 test did not establish real pending-output stall cycles=%0d",
                       pending_stall_cycles);

            @(negedge clk);
            it_data_out_req = 1'b1;
            beat = 0;
            done_count = 0;
            timeout = 0;
            while (beat < 8) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 2000)
                    $fatal(1, "SAT10 two-TU drain timeout");
                if (it_data_out_vld) begin
                    expected_word = (beat < 4) ? packed_lanes(10'sh1ff) :
                                                 packed_lanes(10'sh200);
                    if (it_data_out !== expected_word)
                        $fatal(1, "SAT10 two-TU packed output mismatch beat=%0d got=%h expected=%h",
                               beat, it_data_out, expected_word);
                    if (it_done !== ((beat == 3) || (beat == 7)))
                        $fatal(1, "SAT10 done/beat mismatch beat=%0d done=%b", beat, it_done);
                    done_count = done_count + it_done;
                    beat = beat + 1;
                end
            end
            @(negedge clk);
            it_data_out_req = 1'b0;
            repeat (2) @(negedge clk);
            if (done_count != 2 || protocol_error)
                $fatal(1, "SAT10 two-TU ownership failed done=%0d error=%b",
                       done_count, protocol_error);
            $display("SAT10_REAL_PENDING_STALL_PASS cycles=%0d", pending_stall_cycles);
        end
    endtask

    initial begin
        run_single(16'sd32767, 10'sh1ff, 0);
        run_single(-16'sd32768, 10'sh200, 1);
        run_two_tu_backpressure();
        $display("SAT10_WRAPPER_BOUNDARY_PASS cases=3 beats=16");
        $finish;
    end
endmodule
