// ===================================================================
// ITS Testbench - Auto-iterate all test cases from config file
// ===================================================================

`timescale 1ns / 1ps

module its_tb;

    // Clock and reset
    reg clk;
    reg rst_n;

    // DUT signals
    reg  [21:0] it_info;
    reg         it_info_vld;
    reg  [15:0] it_data_in;
    reg  [11:0] it_data_addr;
    reg         it_data_in_vld;
    reg         it_data_end;
    wire        it_data_in_req;
    wire [39:0] it_data_out;
    wire        it_data_out_vld;
    reg         it_data_out_req;
    wire        it_done;

    // Test control
    integer test_pass;
    integer test_fail;
    integer total_tests;

    // Test vector storage
    reg [27:0] input_vec [0:4095];
    reg [9:0]  golden_vec [0:4095];

    // DUT has data_out_r pipeline register synchronized with out_vld_r.
    // No additional TB register needed - read it_data_out directly.

    // Clock generation (500MHz -> 2ns period)
    initial clk = 0;
    always #1 clk = ~clk;

    // DUT instantiation
    its_top u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .it_info       (it_info),
        .it_info_vld   (it_info_vld),
        .it_data_in    (it_data_in),
        .it_data_addr  (it_data_addr),
        .it_data_in_vld(it_data_in_vld),
        .it_data_end   (it_data_end),
        .it_data_in_req(it_data_in_req),
        .it_data_out   (it_data_out),
        .it_data_out_vld(it_data_out_vld),
        .it_data_out_req(it_data_out_req),
        .it_done       (it_done)
    );

    // Global protocol monitor: req=0 -> vld must be 0
    reg protocol_err;
    always @(posedge clk) begin
        if (rst_n && !it_data_out_req && it_data_out_vld !== 1'b0) begin
            $display("  [MONITOR] PROTOCOL VIOLATION: vld=%b when req=0 (time=%0t)",
                     it_data_out_vld, $time);
            protocol_err = 1;
        end
    end

    // Task: Send TU info
    task send_info;
        input [6:0] width;
        input [6:0] height;
        input [1:0] tr_hor;
        input [1:0] tr_ver;
        input [1:0] lfnst_tr_set_idx;
        input [1:0] lfnst_idx;
        begin
            @(posedge clk);
            it_info = {lfnst_idx, lfnst_tr_set_idx, tr_ver, tr_hor, height, width};
            it_info_vld = 1;
            @(posedge clk);
            it_info_vld = 0;
            repeat(3) @(posedge clk);
        end
    endtask

    // Task: Send one data point
    task send_data;
        input [11:0] addr;
        input [15:0] data;
        begin
            @(posedge clk);
            while (!it_data_in_req) @(posedge clk);
            it_data_in = data;
            it_data_addr = addr;
            it_data_in_vld = 1;
            @(posedge clk);
            it_data_in_vld = 0;
        end
    endtask

    // Task: Send one data point with it_data_end asserted on the same cycle
    task send_data_with_end;
        input [11:0] addr;
        input [15:0] data;
        begin
            @(posedge clk);
            while (!it_data_in_req) @(posedge clk);
            it_data_in = data;
            it_data_addr = addr;
            it_data_in_vld = 1;
            it_data_end = 1;
            @(posedge clk);
            it_data_in_vld = 0;
            it_data_end = 0;
        end
    endtask

    // Task: Wait for output with timeout
    task wait_output;
        output [39:0] data;
        output        valid;
        output        timed_out;
        integer timeout_cnt;
        begin
            timeout_cnt = 0;
            valid = 0;
            timed_out = 0;
            while (timeout_cnt < 5000000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
                if (it_data_out_vld && it_data_out_req) begin
                    data = it_data_out;  // DUT output is already registered (data_out_r)
                    valid = 1;
                    disable wait_output;
                end
            end
            if (!valid) begin
                $display("  TIMEOUT waiting for output!");
                timed_out = 1;
            end
        end
    endtask

    // Task: Wait for done with timeout
    task wait_done;
        output timed_out;
        integer timeout_cnt;
        begin
            timeout_cnt = 0;
            timed_out = 0;
            while (timeout_cnt < 1000000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
                if (it_done) disable wait_done;
            end
            $display("  TIMEOUT waiting for done!");
            timed_out = 1;
        end
    endtask

    // Task: Run one test case (reads hex files by name)
    task run_test;
        input [800*8:1] test_name;
        input [6:0] width;
        input [6:0] height;
        input [1:0] tr_hor;
        input [1:0] tr_ver;
        input [1:0] lfnst_tr_set_idx;
        input [1:0] lfnst_idx;
        input [800*8:1] input_hex;
        input [800*8:1] golden_hex;

        integer i, j;
        integer out_idx;
        reg [39:0] out_data;
        reg out_valid;
        reg out_timeout;
        reg done_timeout;
        reg signed [9:0] exp_val, got_val;
        integer local_mismatches;
        integer total_outputs;
        integer input_count;
        integer timeout_cnt;
        begin
            $display("\n=== %0s (w=%0d h=%0d tr_h=%0d tr_v=%0d sidx=%0d lfnst=%0d) ===",
                     test_name, width, height, tr_hor, tr_ver, lfnst_tr_set_idx, lfnst_idx);
            local_mismatches = 0;
            protocol_err = 0;

            // Reset DUT and clear internal memories
            rst_n = 0;
            repeat(5) @(posedge clk);
            for (i = 0; i < 4096; i = i + 1) begin
                u_dut.in_mem[i] = 16'sd0;
                u_dut.tp_buf[i] = 16'sd0;
                u_dut.out_mem[i] = 10'sd0;
            end
            rst_n = 1;
            repeat(5) @(posedge clk);

            // Clear test vector arrays
            for (i = 0; i < 4096; i = i + 1) begin
                input_vec[i] = 28'd0;
                golden_vec[i] = 10'd0;
            end

            // Load test vectors
            $readmemh(input_hex, input_vec);
            $readmemh(golden_hex, golden_vec);

            total_outputs = width * height;
            input_count = 0;
            for (i = 0; i < 4096; i = i + 1) begin
                if (input_vec[i] != 28'd0)
                    input_count = input_count + 1;
            end

            // Send info
            send_info(width, height, tr_hor, tr_ver, lfnst_tr_set_idx, lfnst_idx);

            // Send input data
            for (i = 0; i < input_count; i = i + 1) begin
                send_data(input_vec[i][27:16], input_vec[i][15:0]);
            end

            // Wait for DUT to be in S_LOAD before asserting it_data_end
            while (u_dut.state != 4'd1) @(posedge clk);  // S_LOAD = 4'd1
            @(posedge clk);

            // Assert it_data_end to signal input complete
            it_data_end = 1;
            @(posedge clk);
            it_data_end = 0;

            // Collect and compare outputs
            out_idx = 0;
            while (out_idx < total_outputs) begin
                wait_output(out_data, out_valid, out_timeout);
                if (out_valid) begin
                    for (j = 0; j < 4 && out_idx + j < total_outputs; j = j + 1) begin
                        case (j)
                            0: got_val = out_data[9:0];
                            1: got_val = out_data[19:10];
                            2: got_val = out_data[29:20];
                            3: got_val = out_data[39:30];
                        endcase
                        exp_val = golden_vec[out_idx + j];
                        if (got_val !== exp_val) begin
                            if (local_mismatches < 5)
                                $display("  MISMATCH at out[%0d]: exp=%0d got=%0d",
                                         out_idx + j, $signed(exp_val), $signed(got_val));
                            local_mismatches = local_mismatches + 1;
                        end
                    end
                    out_idx = out_idx + 4;
                end else if (out_timeout) begin
                    $display("  FAIL: output timeout at index %0d", out_idx);
                    local_mismatches = local_mismatches + 1;
                    out_idx = total_outputs;
                end else begin
                    $display("  ERROR: No valid output at index %0d", out_idx);
                    local_mismatches = local_mismatches + 1;
                    out_idx = total_outputs;
                end
            end

            wait_done(done_timeout);
            if (done_timeout) local_mismatches = local_mismatches + 1;

            if (local_mismatches == 0 && !protocol_err) begin
                $display("  PASS (%0d outputs)", total_outputs);
                test_pass = test_pass + 1;
            end else begin
                $display("  FAIL: %0d/%0d mismatches, protocol_err=%0d", local_mismatches, total_outputs, protocol_err);
                test_fail = test_fail + 1;
            end

            total_tests = total_tests + 1;
            repeat(5) @(posedge clk);
        end
    endtask

    // Task: Run one test case with it_data_end on same cycle as last input
    task run_test_end_same_cycle;
        input [800*8:1] test_name;
        input [6:0] width;
        input [6:0] height;
        input [1:0] tr_hor;
        input [1:0] tr_ver;
        input [1:0] lfnst_tr_set_idx;
        input [1:0] lfnst_idx;
        input [800*8:1] input_hex;
        input [800*8:1] golden_hex;

        integer i, j;
        integer out_idx;
        reg [39:0] out_data;
        reg out_valid;
        reg out_timeout;
        reg done_timeout;
        reg signed [9:0] exp_val, got_val;
        integer local_mismatches;
        integer total_outputs;
        integer input_count;
        begin
            $display("\n=== [END_SAME_CYCLE] %0s (w=%0d h=%0d tr_h=%0d tr_v=%0d sidx=%0d lfnst=%0d) ===",
                     test_name, width, height, tr_hor, tr_ver, lfnst_tr_set_idx, lfnst_idx);
            local_mismatches = 0;
            protocol_err = 0;

            // Reset DUT and clear internal memories
            rst_n = 0;
            repeat(5) @(posedge clk);
            for (i = 0; i < 4096; i = i + 1) begin
                u_dut.in_mem[i] = 16'sd0;
                u_dut.tp_buf[i] = 16'sd0;
                u_dut.out_mem[i] = 10'sd0;
            end
            rst_n = 1;
            repeat(5) @(posedge clk);

            // Clear test vector arrays
            for (i = 0; i < 4096; i = i + 1) begin
                input_vec[i] = 28'd0;
                golden_vec[i] = 10'd0;
            end

            // Load test vectors
            $readmemh(input_hex, input_vec);
            $readmemh(golden_hex, golden_vec);

            total_outputs = width * height;
            input_count = 0;
            for (i = 0; i < 4096; i = i + 1) begin
                if (input_vec[i] != 28'd0)
                    input_count = input_count + 1;
            end

            // Send info
            send_info(width, height, tr_hor, tr_ver, lfnst_tr_set_idx, lfnst_idx);

            // Send input data: all but last with send_data, last with send_data_with_end
            for (i = 0; i < input_count - 1; i = i + 1) begin
                send_data(input_vec[i][27:16], input_vec[i][15:0]);
            end
            // Last data point: it_data_end on same cycle
            send_data_with_end(input_vec[input_count-1][27:16], input_vec[input_count-1][15:0]);

            // Collect and compare outputs
            out_idx = 0;
            while (out_idx < total_outputs) begin
                wait_output(out_data, out_valid, out_timeout);
                if (out_valid) begin
                    for (j = 0; j < 4 && out_idx + j < total_outputs; j = j + 1) begin
                        case (j)
                            0: got_val = out_data[9:0];
                            1: got_val = out_data[19:10];
                            2: got_val = out_data[29:20];
                            3: got_val = out_data[39:30];
                        endcase
                        exp_val = golden_vec[out_idx + j];
                        if (got_val !== exp_val) begin
                            if (local_mismatches < 5)
                                $display("  MISMATCH at out[%0d]: exp=%0d got=%0d",
                                         out_idx + j, $signed(exp_val), $signed(got_val));
                            local_mismatches = local_mismatches + 1;
                        end
                    end
                    out_idx = out_idx + 4;
                end else if (out_timeout) begin
                    $display("  FAIL: output timeout at index %0d", out_idx);
                    local_mismatches = local_mismatches + 1;
                    out_idx = total_outputs;
                end else begin
                    $display("  ERROR: No valid output at index %0d", out_idx);
                    local_mismatches = local_mismatches + 1;
                    out_idx = total_outputs;
                end
            end

            wait_done(done_timeout);
            if (done_timeout) local_mismatches = local_mismatches + 1;

            if (local_mismatches == 0 && !protocol_err) begin
                $display("  PASS (%0d outputs)", total_outputs);
                test_pass = test_pass + 1;
            end else begin
                $display("  FAIL: %0d/%0d mismatches, protocol_err=%0d", local_mismatches, total_outputs, protocol_err);
                test_fail = test_fail + 1;
            end

            total_tests = total_tests + 1;
            repeat(5) @(posedge clk);
        end
    endtask

    // Task: Run one test case WITHOUT reset (for continuous TU testing)
    task run_test_continuous;
        input [800*8:1] test_name;
        input [6:0] width;
        input [6:0] height;
        input [1:0] tr_hor;
        input [1:0] tr_ver;
        input [1:0] lfnst_tr_set_idx;
        input [1:0] lfnst_idx;
        input [800*8:1] input_hex;
        input [800*8:1] golden_hex;

        integer i, j;
        integer out_idx;
        reg [39:0] out_data;
        reg out_valid;
        reg out_timeout;
        reg done_timeout;
        reg signed [9:0] exp_val, got_val;
        integer local_mismatches;
        integer total_outputs;
        integer input_count;
        begin
            $display("\n=== [CONTINUOUS] %0s (w=%0d h=%0d tr_h=%0d tr_v=%0d sidx=%0d lfnst=%0d) ===",
                     test_name, width, height, tr_hor, tr_ver, lfnst_tr_set_idx, lfnst_idx);
            local_mismatches = 0;
            protocol_err = 0;

            // Wait for DUT to be in S_IDLE (no reset)
            while (u_dut.state != 4'd0) @(posedge clk);
            repeat(2) @(posedge clk);

            // Clear test vector arrays
            for (i = 0; i < 4096; i = i + 1) begin
                input_vec[i] = 28'd0;
                golden_vec[i] = 10'd0;
            end

            // Load test vectors
            $readmemh(input_hex, input_vec);
            $readmemh(golden_hex, golden_vec);

            total_outputs = width * height;
            input_count = 0;
            for (i = 0; i < 4096; i = i + 1) begin
                if (input_vec[i] != 28'd0)
                    input_count = input_count + 1;
            end

            // Send info
            send_info(width, height, tr_hor, tr_ver, lfnst_tr_set_idx, lfnst_idx);

            // Send input data
            for (i = 0; i < input_count; i = i + 1) begin
                send_data(input_vec[i][27:16], input_vec[i][15:0]);
            end

            // Assert it_data_end
            @(posedge clk);
            it_data_end = 1;
            @(posedge clk);
            it_data_end = 0;

            // Collect and compare outputs
            out_idx = 0;
            while (out_idx < total_outputs) begin
                wait_output(out_data, out_valid, out_timeout);
                if (out_valid) begin
                    for (j = 0; j < 4 && out_idx + j < total_outputs; j = j + 1) begin
                        case (j)
                            0: got_val = out_data[9:0];
                            1: got_val = out_data[19:10];
                            2: got_val = out_data[29:20];
                            3: got_val = out_data[39:30];
                        endcase
                        exp_val = golden_vec[out_idx + j];
                        if (got_val !== exp_val) begin
                            if (local_mismatches < 5)
                                $display("  MISMATCH at out[%0d]: exp=%0d got=%0d",
                                         out_idx + j, $signed(exp_val), $signed(got_val));
                            local_mismatches = local_mismatches + 1;
                        end
                    end
                    out_idx = out_idx + 4;
                end else if (out_timeout) begin
                    $display("  FAIL: output timeout at index %0d", out_idx);
                    local_mismatches = local_mismatches + 1;
                    out_idx = total_outputs;
                end else begin
                    $display("  ERROR: No valid output at index %0d", out_idx);
                    local_mismatches = local_mismatches + 1;
                    out_idx = total_outputs;
                end
            end

            wait_done(done_timeout);
            if (done_timeout) local_mismatches = local_mismatches + 1;

            if (local_mismatches == 0 && !protocol_err) begin
                $display("  PASS (%0d outputs)", total_outputs);
                test_pass = test_pass + 1;
            end else begin
                $display("  FAIL: %0d/%0d mismatches, protocol_err=%0d", local_mismatches, total_outputs, protocol_err);
                test_fail = test_fail + 1;
            end

            total_tests = total_tests + 1;
            repeat(5) @(posedge clk);
        end
    endtask


    // Task: Run one test case with random output backpressure
    // Backpressure toggles on negedge clk to avoid race with DUT NBA sampling.
    task run_test_backpressure;
        input [800*8:1] test_name;
        input [6:0] width;
        input [6:0] height;
        input [1:0] tr_hor;
        input [1:0] tr_ver;
        input [1:0] lfnst_tr_set_idx;
        input [1:0] lfnst_idx;
        input [800*8:1] input_hex;
        input [800*8:1] golden_hex;

        integer i, j;
        integer out_idx;
        reg [39:0] out_data;
        reg out_valid;
        reg done_timeout;
        reg signed [9:0] exp_val, got_val;
        integer local_mismatches;
        integer total_outputs;
        integer input_count;
        integer bp_timer;
        integer bp_phase; // 0=high, 1=low
        integer bp_dur;
        integer done_seen;
        begin
            $display("\n=== [BACKPRESSURE] %0s (w=%0d h=%0d tr_h=%0d tr_v=%0d sidx=%0d lfnst=%0d) ===",
                     test_name, width, height, tr_hor, tr_ver, lfnst_tr_set_idx, lfnst_idx);
            local_mismatches = 0;
            protocol_err = 0;
            done_seen = 0;

            // Reset DUT and clear internal memories
            rst_n = 0;
            it_data_out_req = 1;
            repeat(5) @(posedge clk);
            for (i = 0; i < 4096; i = i + 1) begin
                u_dut.in_mem[i] = 16'sd0;
                u_dut.tp_buf[i] = 16'sd0;
                u_dut.out_mem[i] = 10'sd0;
            end
            rst_n = 1;
            repeat(5) @(posedge clk);

            // Clear and load test vectors
            for (i = 0; i < 4096; i = i + 1) begin
                input_vec[i] = 28'd0;
                golden_vec[i] = 10'd0;
            end
            $readmemh(input_hex, input_vec);
            $readmemh(golden_hex, golden_vec);

            total_outputs = width * height;
            input_count = 0;
            for (i = 0; i < 4096; i = i + 1) begin
                if (input_vec[i] != 28'd0)
                    input_count = input_count + 1;
            end

            // Send info and data (no backpressure during input)
            it_data_out_req = 1;
            send_info(width, height, tr_hor, tr_ver, lfnst_tr_set_idx, lfnst_idx);
            for (i = 0; i < input_count; i = i + 1) begin
                send_data(input_vec[i][27:16], input_vec[i][15:0]);
            end

            // Assert it_data_end
            @(posedge clk);
            it_data_end = 1;
            @(posedge clk);
            it_data_end = 0;

            // Wait for first output valid, collect it, then apply backpressure
            it_data_out_req = 1;
            while (!it_data_out_vld) @(posedge clk);
            // DUT produced first output on PREVIOUS posedge (NBA delay).
            // data_out_r has the first 4 values. Collect them.
            out_data = it_data_out;
            for (j = 0; j < 4 && j < total_outputs; j = j + 1) begin
                case (j)
                    0: got_val = out_data[9:0];
                    1: got_val = out_data[19:10];
                    2: got_val = out_data[29:20];
                    3: got_val = out_data[39:30];
                endcase
                exp_val = golden_vec[j];
                if (got_val !== exp_val) begin
                    if (local_mismatches < 5)
                        $display("  MISMATCH at out[%0d]: exp=%0d got=%0d",
                                 j, $signed(exp_val), $signed(got_val));
                    local_mismatches = local_mismatches + 1;
                end
            end
            out_idx = 4;

            // Now collect remaining outputs with backpressure
            bp_timer = 0;
            bp_phase = 0; // start with req high
            bp_dur = 3;   // hold high for 3 cycles
            while (out_idx < total_outputs) begin
                @(negedge clk);
                // Toggle backpressure on negedge so DUT samples stable value on posedge
                bp_timer = bp_timer + 1;
                if (bp_phase == 0 && bp_timer >= bp_dur) begin
                    it_data_out_req = 0;
                    bp_timer = 0;
                    bp_phase = 1;
                    bp_dur = 2; // hold low for 2 cycles
                end else if (bp_phase == 1 && bp_timer >= bp_dur) begin
                    it_data_out_req = 1;
                    bp_timer = 0;
                    bp_phase = 0;
                    bp_dur = 3; // hold high for 3 cycles
                end

                @(posedge clk);
                // Check for valid output (only when req is high)
                if (it_data_out_vld && it_data_out_req) begin
                    out_data = it_data_out;
                    for (j = 0; j < 4 && out_idx + j < total_outputs; j = j + 1) begin
                        case (j)
                            0: got_val = out_data[9:0];
                            1: got_val = out_data[19:10];
                            2: got_val = out_data[29:20];
                            3: got_val = out_data[39:30];
                        endcase
                        exp_val = golden_vec[out_idx + j];
                        if (got_val !== exp_val) begin
                            if (local_mismatches < 5)
                                $display("  MISMATCH at out[%0d]: exp=%0d got=%0d",
                                         out_idx + j, $signed(exp_val), $signed(got_val));
                            local_mismatches = local_mismatches + 1;
                        end
                    end
                    out_idx = out_idx + 4;
                end
                // Protocol: vld = data_out_valid && req.
                // data_out_valid stays high while state == S_OUT.

                // Track if DUT finished during the loop (it_done is 1-cycle pulse)
                if (it_done) done_seen = 1;
            end

            it_data_out_req = 1;
            // Tail-beat check: wait for DUT to reach S_DONE (state==4'd7),
            // then skip 1 cycle for data_out_valid hold from synchronous read pipeline,
            // then verify vld stays 0.
            begin : tail_beat_check
                integer tb_timeout;
                tb_timeout = 0;
                while (u_dut.state != 4'd7 && tb_timeout < 10000) begin
                    @(posedge clk);
                    tb_timeout = tb_timeout + 1;
                    if (it_done) done_seen = 1;
                end
                if (u_dut.state == 4'd7) done_seen = 1;
                // Skip 1 cycle for data_out_valid hold in S_DONE
                @(posedge clk);
                repeat (3) begin
                    @(posedge clk);
                    if (it_data_out_vld) begin
                        $display("  PROTOCOL ERROR: spurious vld after all data collected");
                        local_mismatches = local_mismatches + 1;
                    end
                end
            end
            if (!done_seen) begin
                wait_done(done_timeout);
                if (done_timeout) local_mismatches = local_mismatches + 1;
            end

            if (local_mismatches == 0 && !protocol_err) begin
                $display("  PASS (%0d outputs)", total_outputs);
                test_pass = test_pass + 1;
            end else begin
                $display("  FAIL: %0d/%0d mismatches, protocol_err=%0d", local_mismatches, total_outputs, protocol_err);
                test_fail = test_fail + 1;
            end

            total_tests = total_tests + 1;
            repeat(5) @(posedge clk);
        end
    endtask

    // ================================================================
    // Main test sequence
    // ================================================================
    initial begin
        test_pass = 0;
        test_fail = 0;
        total_tests = 0;
        rst_n = 0;
        it_info = 0;
        it_info_vld = 0;
        it_data_in = 0;
        it_data_addr = 0;
        it_data_in_vld = 0;
        it_data_end = 0;
        it_data_out_req = 1;

        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        // ============================
        // Exhaustive regression: 1377 test cases
        // (DCT2 25脳9 + MTS 16脳8脳9 = 225 + 1152)
        // ============================
        `include "../tb/test_vectors/regression_tests.vh"

        // ============================
        // it_data_end same-cycle protocol tests
        // ============================
        `include "../tb/test_vectors/end_same_cycle_tests.vh"

        // ============================
        // Continuous TU tests (no reset between TUs)
        // ============================
        $display("\n--- Continuous TU Tests (no reset) ---");
        `include "../tb/test_vectors/continuous_tests.vh"

        // ============================
        // Backpressure tests (3on/2off toggle)
        // ============================
        `include "../tb/test_vectors/backpressure_tests.vh"

        // ============================
        // Summary
        // ============================
        $display("\n========================================");
        $display("Test Summary: %0d passed, %0d failed (total %0d)", test_pass, test_fail, total_tests);
        $display("========================================");

        if (test_fail == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("SOME TESTS FAILED!");

        $finish;
    end

    // Global timeout watchdog (~1000s for 1444 regression tests)
    initial begin
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        $display("\nGLOBAL TIMEOUT!");
        $finish;
    end

endmodule

