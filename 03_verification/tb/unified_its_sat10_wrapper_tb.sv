`timescale 1ns/1ps

// End-to-end SAT10 gate.  A 4x4 DCT2 DC coefficient of +/-32768 produces a
// signed-16 intermediate outside the signed-10 interval, so this test checks
// the actual wrapper path and output packing rather than only calling the
// adapter function.
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

    function automatic [21:0] desc4x4();
        desc4x4 = 22'd4 | (22'd4 << 7);
    endfunction

    task automatic reset_dut;
        begin
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic run_case(input integer value, input logic signed [9:0] expected_lane,
                            input integer case_id);
        integer beat;
        integer timeout;
        logic [39:0] expected_word;
        begin
            expected_word = {4{expected_lane}};
            it_info = desc4x4();
            it_info_vld = 1'b1;
            @(posedge clk);
            it_info_vld = 1'b0;
            while (!it_data_in_req) @(posedge clk);
            it_data_addr = 12'd0;
            it_data_in = value;
            it_data_in_vld = 1'b1;
            it_data_end = 1'b1;
            @(posedge clk);
            it_data_in_vld = 1'b0;
            it_data_end = 1'b0;
            it_data_out_req = 1'b1;
            beat = 0;
            timeout = 0;
            while (beat < 4) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 2000) $fatal(1, "SAT10 wrapper timeout case=%0d", case_id);
                if (it_data_out_vld) begin
                    if (it_data_out !== expected_word)
                        $fatal(1, "SAT10 wrapper mismatch case=%0d beat=%0d got=%h expected=%h",
                               case_id, beat, it_data_out, expected_word);
                    beat = beat + 1;
                end
            end
            it_data_out_req = 1'b0;
            repeat (3) @(posedge clk);
            if (protocol_error) $fatal(1, "protocol_error case=%0d", case_id);
        end
    endtask

    task automatic run_two_tu_backpressure;
        integer cycle;
        integer beat;
        integer done_count;
        integer first_beats;
        logic [39:0] held_data;
        logic [39:0] expected_word;
        bit holding;
        begin
            reset_dut();

            // TU0 is deliberately out of signed-10 range and is submitted
            // before TU1.  TU1 is accepted while TU0 is held at output.
            it_info = desc4x4();
            it_info_vld = 1'b1;
            @(posedge clk);
            it_info_vld = 1'b0;
            while (!it_data_in_req) @(posedge clk);
            it_data_addr = 12'd0;
            it_data_in = 16'sd32767;
            it_data_in_vld = 1'b1;
            it_data_end = 1'b1;
            @(posedge clk);
            it_data_in_vld = 1'b0;
            it_data_end = 1'b0;

            it_info = desc4x4();
            it_info_vld = 1'b1;
            @(posedge clk);
            it_info_vld = 1'b0;
            while (!it_data_in_req) @(posedge clk);
            it_data_addr = 12'd0;
            it_data_in = -16'sd32768;
            it_data_in_vld = 1'b1;
            it_data_end = 1'b1;
            @(posedge clk);
            it_data_in_vld = 1'b0;
            it_data_end = 1'b0;

            // Hold the first result for a bounded interval.  The second TU
            // must be accepted and retained without changing the held word.
            it_data_out_req = 1'b0;
            holding = 1'b0;
            for (cycle = 0; cycle < 80; cycle = cycle + 1) begin
                @(negedge clk);
                #0;
                if (it_data_out_vld)
                    $fatal(1, "SAT10 output valid asserted under stall");
                if (dut.output_active) begin
                    if (holding && it_data_out !== held_data)
                        $fatal(1, "SAT10 held output changed under stall");
                    held_data = it_data_out;
                    holding = 1'b1;
                end
            end

            it_data_out_req = 1'b1;
            first_beats = 0;
            beat = 0;
            done_count = 0;
            while (beat < 8) begin
                @(posedge clk);
                if (it_data_out_vld && it_data_out_req) begin
                    expected_word = (beat < 4) ? {4{10'sh1ff}} : {4{10'sh200}};
                    if (it_data_out !== expected_word)
                        $fatal(1, "SAT10 two-TU mismatch beat=%0d got=%h expected=%h",
                               beat, it_data_out, expected_word);
                    if (beat < 4)
                        first_beats = first_beats + 1;
                    beat = beat + 1;
                end
                if (it_done)
                    done_count = done_count + 1;
                if (cycle > 2000)
                    $fatal(1, "SAT10 two-TU timeout");
                cycle = cycle + 1;
            end
            it_data_out_req = 1'b0;
            repeat (3) @(posedge clk);
            if (first_beats != 4 || done_count != 2)
                $fatal(1, "SAT10 two-TU ownership failed beats=%0d done=%0d",
                       first_beats, done_count);
            if (protocol_error)
                $fatal(1, "SAT10 two-TU protocol_error");
        end
    endtask

    initial begin
        reset_dut();
        // +32767 yields +1024 in the current 4x4 DCT2 profile.
        run_case(32767, 10'sh1ff, 0);
        reset_dut();
        // -32768 yields -1024 and must saturate to -512 (10'h200).
        run_case(-32768, 10'sh200, 1);
        run_two_tu_backpressure();
        $display("SAT10_WRAPPER_BOUNDARY_PASS cases=3 beats=16");
        $finish;
    end
endmodule

