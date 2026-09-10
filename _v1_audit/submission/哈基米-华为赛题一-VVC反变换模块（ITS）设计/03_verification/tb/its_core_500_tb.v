// ===================================================================
// ITS Core 500MHz Testbench
// Verifies its_core_500 FIFO interface output is bit-exact
// with its_top golden vectors (94 test cases: 89 + 5 backpressure).
//
// FIFO protocol:
//   cmd_fifo:   FWFT, 23-bit. Push {1'b0, it_info[21:0]}. 1 entry per TU.
//   input_fifo: FWFT, 29-bit. Push {addr[11:0], data[15:0]} for each coeff,
//               then push {last=1, 0} as pure end-of-TU marker (no data).
//   output_fifo: Standard write, 40-bit. Read when !empty.
// ===================================================================

`timescale 1ns / 1ps

module its_core_500_tb;

    // ================================================================
    // Clock and reset
    // ================================================================
    reg clk_core;
    reg rst_n;

    initial clk_core = 0;
    always #1 clk_core = ~clk_core; // 500MHz

    // ================================================================
    // DUT interface wires
    // ================================================================
    wire [22:0] cmd_fifo_rdata;
    wire        cmd_fifo_empty;
    wire        cmd_fifo_rd_en;

    wire [28:0] input_fifo_rdata;
    wire        input_fifo_empty;
    wire        input_fifo_rd_en;

    wire [39:0] output_fifo_wdata;
    wire        output_fifo_wr_en;
    wire        output_fifo_full;
    wire        output_fifo_almost_full;
    wire        core_done;

    // ================================================================
    // DUT
    // ================================================================
    its_core_500 u_dut (
        .clk_core              (clk_core),
        .rst_n                 (rst_n),
        .cmd_fifo_rdata        (cmd_fifo_rdata),
        .cmd_fifo_empty        (cmd_fifo_empty),
        .cmd_fifo_rd_en        (cmd_fifo_rd_en),
        .input_fifo_rdata      (input_fifo_rdata),
        .input_fifo_empty      (input_fifo_empty),
        .input_fifo_rd_en      (input_fifo_rd_en),
        .output_fifo_wdata     (output_fifo_wdata),
        .output_fifo_wr_en     (output_fifo_wr_en),
        .output_fifo_full      (output_fifo_full),
        .output_fifo_almost_full(output_fifo_almost_full),
        .core_done             (core_done),
        .core_ready            ()
    );

    // ================================================================
    // FIFO overflow error flag (P1 #58)
    // ================================================================
    reg fifo_overflow_error;
    initial fifo_overflow_error = 0;

    // ================================================================
    // CMD FIFO (FWFT, 23-bit, depth 4)
    // ================================================================
    reg  [22:0] cmd_fifo_mem [0:3];
    reg  [2:0]  cmd_fifo_wr_ptr;
    reg  [2:0]  cmd_fifo_rd_ptr;
    wire [2:0]  cmd_fifo_count = cmd_fifo_wr_ptr - cmd_fifo_rd_ptr;
    assign      cmd_fifo_empty = (cmd_fifo_count == 0);
    wire        cmd_fifo_full  = (cmd_fifo_count == 4);
    assign      cmd_fifo_rdata = cmd_fifo_mem[cmd_fifo_rd_ptr[1:0]];

    task cmd_fifo_reset;
        integer i;
        begin
            cmd_fifo_wr_ptr = 0;
            cmd_fifo_rd_ptr = 0;
            for (i = 0; i < 4; i = i + 1)
                cmd_fifo_mem[i] = 0;
        end
    endtask

    task cmd_fifo_push;
        input [22:0] data;
        begin
            if (!cmd_fifo_full) begin
                cmd_fifo_mem[cmd_fifo_wr_ptr[1:0]] = data;
                cmd_fifo_wr_ptr = cmd_fifo_wr_ptr + 1;
            end else begin
                $display("  [CMD_FIFO] ERROR: push to full FIFO!");
                fifo_overflow_error = 1;
            end
        end
    endtask

    always @(posedge clk_core) begin
        if (cmd_fifo_rd_en && !cmd_fifo_empty)
            cmd_fifo_rd_ptr <= cmd_fifo_rd_ptr + 1;
    end

    // ================================================================
    // INPUT FIFO (FWFT, 29-bit, depth 16)
    // [28]=last, [27:16]=addr, [15:0]=data
    // ================================================================
    reg  [28:0] input_fifo_mem [0:15];
    reg  [4:0]  input_fifo_wr_ptr;
    reg  [4:0]  input_fifo_rd_ptr;
    wire [4:0]  input_fifo_count = input_fifo_wr_ptr - input_fifo_rd_ptr;
    assign      input_fifo_empty = (input_fifo_count == 0);
    wire        input_fifo_full  = (input_fifo_count == 16);
    assign      input_fifo_rdata = input_fifo_mem[input_fifo_rd_ptr[3:0]];

    task input_fifo_reset;
        integer i;
        begin
            input_fifo_wr_ptr = 0;
            input_fifo_rd_ptr = 0;
            for (i = 0; i < 16; i = i + 1)
                input_fifo_mem[i] = 0;
        end
    endtask

    task input_fifo_push;
        input [28:0] data;
        begin
            if (!input_fifo_full) begin
                input_fifo_mem[input_fifo_wr_ptr[3:0]] = data;
                input_fifo_wr_ptr = input_fifo_wr_ptr + 1;
            end else begin
                $display("  [INPUT_FIFO] ERROR: push to full FIFO!");
                fifo_overflow_error = 1;
            end
        end
    endtask

    always @(posedge clk_core) begin
        if (input_fifo_rd_en && !input_fifo_empty)
            input_fifo_rd_ptr <= input_fifo_rd_ptr + 1;
    end

    // ================================================================
    // OUTPUT FIFO (standard write, 40-bit, depth 16)
    // ================================================================
    reg  [39:0] output_fifo_mem [0:15];
    reg  [4:0]  output_fifo_wr_ptr;
    reg  [4:0]  output_fifo_rd_ptr;
    wire [4:0]  output_fifo_count = output_fifo_wr_ptr - output_fifo_rd_ptr;
    wire        output_fifo_empty = (output_fifo_count == 0);
    assign      output_fifo_full  = (output_fifo_count == 16);
    assign      output_fifo_almost_full = (output_fifo_count >= 14);
    wire [39:0] output_fifo_rdata = output_fifo_mem[output_fifo_rd_ptr[3:0]];

    task output_fifo_reset;
        integer i;
        begin
            output_fifo_wr_ptr = 0;
            output_fifo_rd_ptr = 0;
            for (i = 0; i < 16; i = i + 1)
                output_fifo_mem[i] = 0;
        end
    endtask

    // Write side: registered
    integer output_fifo_full_cycles;
    initial output_fifo_full_cycles = 0;
    always @(posedge clk_core) begin
        if (output_fifo_wr_en && !output_fifo_full) begin
            output_fifo_mem[output_fifo_wr_ptr[3:0]] <= output_fifo_wdata;
            output_fifo_wr_ptr <= output_fifo_wr_ptr + 1;
        end else if (output_fifo_wr_en && output_fifo_full) begin
            $display("  [OUTPUT_FIFO] ERROR: write to full FIFO!");
            fifo_overflow_error = 1;
        end
        if (output_fifo_full)
            output_fifo_full_cycles = output_fifo_full_cycles + 1;
    end

    // Read side: combinational rdata, pop via task (blocking)
    // No always block - pop is done directly in collect_and_compare task

    // ================================================================
    // Test control
    // ================================================================
    integer test_pass;
    integer test_fail;
    integer total_tests;

    reg [27:0] input_vec [0:4095];
    reg [9:0]  golden_vec [0:4095];

    // ================================================================
    // Tasks
    // ================================================================

    task push_cmd;
        input [6:0] width;
        input [6:0] height;
        input [1:0] tr_hor;
        input [1:0] tr_ver;
        input [1:0] lfnst_tr_set_idx;
        input [1:0] lfnst_idx;
        begin
            cmd_fifo_push({1'b0, lfnst_idx, lfnst_tr_set_idx, tr_ver, tr_hor, height, width});
        end
    endtask

    task push_inputs;
        input integer count;
        integer i;
        begin
            for (i = 0; i < count; i = i + 1)
                input_fifo_push(input_vec[i]);
            // Append last=1 marker (pure control signal, addr/data ignored by RTL)
            input_fifo_push({1'b1, 12'd0, 16'd0});
        end
    endtask

    // Collect outputs continuously while DUT runs, compare with golden.
    // slow_div: 0 = normal (pop every cycle), N>0 = pop 1 in every (N+1) cycles
    reg [3:0] slow_div;
    initial slow_div = 0;

    task collect_and_compare;
        input integer total_outputs;
        output integer mismatches;
        integer out_idx;
        integer j;
        reg signed [9:0] exp_val, got_val;
        reg [39:0] out_data;
        integer timeout_cnt;
        integer done_seen;
        integer slow_cnt;
        reg pop_this_cycle;
        begin
            mismatches = 0;
            out_idx = 0;
            done_seen = 0;
            slow_cnt = 0;
            while (out_idx < total_outputs) begin
                @(posedge clk_core);

                if (core_done) done_seen = 1;

                // Slow consumption: only pop 1 in every (slow_div+1) cycles
                if (slow_div == 0)
                    pop_this_cycle = 1;
                else begin
                    slow_cnt = slow_cnt + 1;
                    pop_this_cycle = (slow_cnt > slow_div);
                    if (pop_this_cycle) slow_cnt = 0;
                end

                if (!output_fifo_empty && pop_this_cycle) begin
                    out_data = output_fifo_rdata;
                    // Pop: blocking assignment, immediate
                    output_fifo_rd_ptr = output_fifo_rd_ptr + 1;

                    for (j = 0; j < 4 && out_idx + j < total_outputs; j = j + 1) begin
                        case (j)
                            0: got_val = out_data[9:0];
                            1: got_val = out_data[19:10];
                            2: got_val = out_data[29:20];
                            3: got_val = out_data[39:30];
                        endcase
                        exp_val = golden_vec[out_idx + j];
                        if (got_val !== exp_val) begin
                            if (mismatches < 5)
                                $display("  MISMATCH at out[%0d]: exp=%0d got=%0d",
                                         out_idx + j, $signed(exp_val), $signed(got_val));
                            mismatches = mismatches + 1;
                        end
                    end
                    out_idx = out_idx + 4;
                end
            end

            // Phase 2: Wait for core_done, drain any extra outputs
            begin : extra_drain
                integer extra_outputs;
                extra_outputs = 0;
                if (!done_seen) begin
                    timeout_cnt = 0;
                    while (!core_done && timeout_cnt < 1000000) begin
                        @(posedge clk_core);
                        timeout_cnt = timeout_cnt + 1;
                        if (!output_fifo_empty) begin
                            output_fifo_rd_ptr = output_fifo_rd_ptr + 1;
                            extra_outputs = extra_outputs + 1;
                        end
                    end
                    if (!core_done) begin
                        $display("  TIMEOUT waiting for core_done after collecting outputs");
                        mismatches = mismatches + 1;
                    end
                end

                // Phase 3: After core_done, wait a few cycles then drain remaining
                repeat(10) @(posedge clk_core);
                while (!output_fifo_empty) begin
                    output_fifo_rd_ptr = output_fifo_rd_ptr + 1;
                    extra_outputs = extra_outputs + 1;
                end

                if (extra_outputs > 0) begin
                    $display("  EXTRA OUTPUTS: %0d unexpected entries after expected %0d outputs",
                             extra_outputs, total_outputs);
                    mismatches = mismatches + 1;
                end
            end
        end
    endtask

    // Run one test case
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

        integer i;
        integer input_count;
        integer total_outputs;
        integer mismatches;
        begin
            $display("\n=== %0s (w=%0d h=%0d tr_h=%0d tr_v=%0d sidx=%0d lfnst=%0d) ===",
                     test_name, width, height, tr_hor, tr_ver, lfnst_tr_set_idx, lfnst_idx);

            // Reset
            fifo_overflow_error = 0;
            rst_n = 0;
            cmd_fifo_reset;
            input_fifo_reset;
            output_fifo_reset;
            repeat(10) @(posedge clk_core);
            rst_n = 1;
            repeat(5) @(posedge clk_core);

            // Load test vectors
            for (i = 0; i < 4096; i = i + 1) begin
                input_vec[i] = 28'd0;
                golden_vec[i] = 10'd0;
            end
            $readmemh(input_hex, input_vec);
            $readmemh(golden_hex, golden_vec);

            // Count inputs
            input_count = 0;
            for (i = 0; i < 4096; i = i + 1) begin
                if (input_vec[i] != 28'd0)
                    input_count = input_count + 1;
            end
            total_outputs = width * height;

            // Push: cmd (it_info), then inputs with last=1 marker
            push_cmd(width, height, tr_hor, tr_ver, lfnst_tr_set_idx, lfnst_idx);
            push_inputs(input_count);

            // Collect outputs while DUT processes
            collect_and_compare(total_outputs, mismatches);

            // Check FIFO overflow (P1 #58)
            if (fifo_overflow_error) begin
                $display("  FIFO OVERFLOW detected during this test");
                mismatches = mismatches + 1;
            end

            if (mismatches == 0) begin
                $display("  PASS (%0d outputs)", total_outputs);
                test_pass = test_pass + 1;
            end else begin
                $display("  FAIL: %0d/%0d mismatches", mismatches, total_outputs);
                test_fail = test_fail + 1;
            end

            total_tests = total_tests + 1;
            repeat(5) @(posedge clk_core);
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
        repeat(10) @(posedge clk_core);
        rst_n = 1;
        repeat(5) @(posedge clk_core);

        // ============================
        // DCT2 (25 block sizes)
        // ============================
        run_test("dct2_4x4",    7'd4,  7'd4,  2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_4x4_input.hex",
                 "../tb/test_vectors/dct2_4x4_golden.hex");
        run_test("dct2_4x8",    7'd4,  7'd8,  2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_4x8_input.hex",
                 "../tb/test_vectors/dct2_4x8_golden.hex");
        run_test("dct2_4x16",   7'd4,  7'd16, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_4x16_input.hex",
                 "../tb/test_vectors/dct2_4x16_golden.hex");
        run_test("dct2_4x32",   7'd4,  7'd32, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_4x32_input.hex",
                 "../tb/test_vectors/dct2_4x32_golden.hex");
        run_test("dct2_4x64",   7'd4,  7'd64, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_4x64_input.hex",
                 "../tb/test_vectors/dct2_4x64_golden.hex");
        run_test("dct2_8x4",    7'd8,  7'd4,  2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_8x4_input.hex",
                 "../tb/test_vectors/dct2_8x4_golden.hex");
        run_test("dct2_16x4",   7'd16, 7'd4,  2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_16x4_input.hex",
                 "../tb/test_vectors/dct2_16x4_golden.hex");
        run_test("dct2_32x4",   7'd32, 7'd4,  2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_32x4_input.hex",
                 "../tb/test_vectors/dct2_32x4_golden.hex");
        run_test("dct2_64x4",   7'd64, 7'd4,  2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_64x4_input.hex",
                 "../tb/test_vectors/dct2_64x4_golden.hex");
        run_test("dct2_8x8",    7'd8,  7'd8,  2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_8x8_input.hex",
                 "../tb/test_vectors/dct2_8x8_golden.hex");
        run_test("dct2_8x16",   7'd8,  7'd16, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_8x16_input.hex",
                 "../tb/test_vectors/dct2_8x16_golden.hex");
        run_test("dct2_8x32",   7'd8,  7'd32, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_8x32_input.hex",
                 "../tb/test_vectors/dct2_8x32_golden.hex");
        run_test("dct2_8x64",   7'd8,  7'd64, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_8x64_input.hex",
                 "../tb/test_vectors/dct2_8x64_golden.hex");
        run_test("dct2_16x8",   7'd16, 7'd8,  2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_16x8_input.hex",
                 "../tb/test_vectors/dct2_16x8_golden.hex");
        run_test("dct2_32x8",   7'd32, 7'd8,  2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_32x8_input.hex",
                 "../tb/test_vectors/dct2_32x8_golden.hex");
        run_test("dct2_64x8",   7'd64, 7'd8,  2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_64x8_input.hex",
                 "../tb/test_vectors/dct2_64x8_golden.hex");
        run_test("dct2_16x16",  7'd16, 7'd16, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_16x16_input.hex",
                 "../tb/test_vectors/dct2_16x16_golden.hex");
        run_test("dct2_16x32",  7'd16, 7'd32, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_16x32_input.hex",
                 "../tb/test_vectors/dct2_16x32_golden.hex");
        run_test("dct2_16x64",  7'd16, 7'd64, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_16x64_input.hex",
                 "../tb/test_vectors/dct2_16x64_golden.hex");
        run_test("dct2_32x16",  7'd32, 7'd16, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_32x16_input.hex",
                 "../tb/test_vectors/dct2_32x16_golden.hex");
        run_test("dct2_32x32",  7'd32, 7'd32, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_32x32_input.hex",
                 "../tb/test_vectors/dct2_32x32_golden.hex");
        run_test("dct2_32x64",  7'd32, 7'd64, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_32x64_input.hex",
                 "../tb/test_vectors/dct2_32x64_golden.hex");
        run_test("dct2_64x16",  7'd64, 7'd16, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_64x16_input.hex",
                 "../tb/test_vectors/dct2_64x16_golden.hex");
        run_test("dct2_64x32",  7'd64, 7'd32, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_64x32_input.hex",
                 "../tb/test_vectors/dct2_64x32_golden.hex");
        run_test("dct2_64x64",  7'd64, 7'd64, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_64x64_input.hex",
                 "../tb/test_vectors/dct2_64x64_golden.hex");

        // ============================
        // DCT8 (16 block sizes)
        // ============================
        run_test("dct8_4x4",    7'd4,  7'd4,  2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_4x4_input.hex",
                 "../tb/test_vectors/dct8_4x4_golden.hex");
        run_test("dct8_4x8",    7'd4,  7'd8,  2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_4x8_input.hex",
                 "../tb/test_vectors/dct8_4x8_golden.hex");
        run_test("dct8_4x16",   7'd4,  7'd16, 2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_4x16_input.hex",
                 "../tb/test_vectors/dct8_4x16_golden.hex");
        run_test("dct8_4x32",   7'd4,  7'd32, 2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_4x32_input.hex",
                 "../tb/test_vectors/dct8_4x32_golden.hex");
        run_test("dct8_8x4",    7'd8,  7'd4,  2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_8x4_input.hex",
                 "../tb/test_vectors/dct8_8x4_golden.hex");
        run_test("dct8_16x4",   7'd16, 7'd4,  2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_16x4_input.hex",
                 "../tb/test_vectors/dct8_16x4_golden.hex");
        run_test("dct8_32x4",   7'd32, 7'd4,  2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_32x4_input.hex",
                 "../tb/test_vectors/dct8_32x4_golden.hex");
        run_test("dct8_8x8",    7'd8,  7'd8,  2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_8x8_input.hex",
                 "../tb/test_vectors/dct8_8x8_golden.hex");
        run_test("dct8_8x16",   7'd8,  7'd16, 2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_8x16_input.hex",
                 "../tb/test_vectors/dct8_8x16_golden.hex");
        run_test("dct8_8x32",   7'd8,  7'd32, 2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_8x32_input.hex",
                 "../tb/test_vectors/dct8_8x32_golden.hex");
        run_test("dct8_16x8",   7'd16, 7'd8,  2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_16x8_input.hex",
                 "../tb/test_vectors/dct8_16x8_golden.hex");
        run_test("dct8_32x8",   7'd32, 7'd8,  2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_32x8_input.hex",
                 "../tb/test_vectors/dct8_32x8_golden.hex");
        run_test("dct8_16x16",  7'd16, 7'd16, 2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_16x16_input.hex",
                 "../tb/test_vectors/dct8_16x16_golden.hex");
        run_test("dct8_16x32",  7'd16, 7'd32, 2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_16x32_input.hex",
                 "../tb/test_vectors/dct8_16x32_golden.hex");
        run_test("dct8_32x16",  7'd32, 7'd16, 2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_32x16_input.hex",
                 "../tb/test_vectors/dct8_32x16_golden.hex");
        run_test("dct8_32x32",  7'd32, 7'd32, 2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_32x32_input.hex",
                 "../tb/test_vectors/dct8_32x32_golden.hex");

        // ============================
        // DST7 (16 block sizes)
        // ============================
        run_test("dst7_4x4",    7'd4,  7'd4,  2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_4x4_input.hex",
                 "../tb/test_vectors/dst7_4x4_golden.hex");
        run_test("dst7_4x8",    7'd4,  7'd8,  2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_4x8_input.hex",
                 "../tb/test_vectors/dst7_4x8_golden.hex");
        run_test("dst7_4x16",   7'd4,  7'd16, 2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_4x16_input.hex",
                 "../tb/test_vectors/dst7_4x16_golden.hex");
        run_test("dst7_4x32",   7'd4,  7'd32, 2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_4x32_input.hex",
                 "../tb/test_vectors/dst7_4x32_golden.hex");
        run_test("dst7_8x4",    7'd8,  7'd4,  2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_8x4_input.hex",
                 "../tb/test_vectors/dst7_8x4_golden.hex");
        run_test("dst7_16x4",   7'd16, 7'd4,  2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_16x4_input.hex",
                 "../tb/test_vectors/dst7_16x4_golden.hex");
        run_test("dst7_32x4",   7'd32, 7'd4,  2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_32x4_input.hex",
                 "../tb/test_vectors/dst7_32x4_golden.hex");
        run_test("dst7_8x8",    7'd8,  7'd8,  2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_8x8_input.hex",
                 "../tb/test_vectors/dst7_8x8_golden.hex");
        run_test("dst7_8x16",   7'd8,  7'd16, 2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_8x16_input.hex",
                 "../tb/test_vectors/dst7_8x16_golden.hex");
        run_test("dst7_8x32",   7'd8,  7'd32, 2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_8x32_input.hex",
                 "../tb/test_vectors/dst7_8x32_golden.hex");
        run_test("dst7_16x8",   7'd16, 7'd8,  2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_16x8_input.hex",
                 "../tb/test_vectors/dst7_16x8_golden.hex");
        run_test("dst7_32x8",   7'd32, 7'd8,  2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_32x8_input.hex",
                 "../tb/test_vectors/dst7_32x8_golden.hex");
        run_test("dst7_16x16",  7'd16, 7'd16, 2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_16x16_input.hex",
                 "../tb/test_vectors/dst7_16x16_golden.hex");
        run_test("dst7_16x32",  7'd16, 7'd32, 2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_16x32_input.hex",
                 "../tb/test_vectors/dst7_16x32_golden.hex");
        run_test("dst7_32x16",  7'd32, 7'd16, 2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_32x16_input.hex",
                 "../tb/test_vectors/dst7_32x16_golden.hex");
        run_test("dst7_32x32",  7'd32, 7'd32, 2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_32x32_input.hex",
                 "../tb/test_vectors/dst7_32x32_golden.hex");

        // ============================
        // LFNST nTrs=16
        // ============================
        run_test("lfnst16_s0_i1", 7'd4, 7'd4, 2'd0, 2'd0, 2'd0, 2'd1,
                 "../tb/test_vectors/lfnst16_s0_i1_input.hex",
                 "../tb/test_vectors/lfnst16_s0_i1_golden.hex");
        run_test("lfnst16_s0_i2", 7'd4, 7'd4, 2'd0, 2'd0, 2'd0, 2'd2,
                 "../tb/test_vectors/lfnst16_s0_i2_input.hex",
                 "../tb/test_vectors/lfnst16_s0_i2_golden.hex");
        run_test("lfnst16_s1_i1", 7'd4, 7'd4, 2'd0, 2'd0, 2'd1, 2'd1,
                 "../tb/test_vectors/lfnst16_s1_i1_input.hex",
                 "../tb/test_vectors/lfnst16_s1_i1_golden.hex");
        run_test("lfnst16_s1_i2", 7'd4, 7'd4, 2'd0, 2'd0, 2'd1, 2'd2,
                 "../tb/test_vectors/lfnst16_s1_i2_input.hex",
                 "../tb/test_vectors/lfnst16_s1_i2_golden.hex");
        run_test("lfnst16_s2_i1", 7'd4, 7'd4, 2'd0, 2'd0, 2'd2, 2'd1,
                 "../tb/test_vectors/lfnst16_s2_i1_input.hex",
                 "../tb/test_vectors/lfnst16_s2_i1_golden.hex");
        run_test("lfnst16_s2_i2", 7'd4, 7'd4, 2'd0, 2'd0, 2'd2, 2'd2,
                 "../tb/test_vectors/lfnst16_s2_i2_input.hex",
                 "../tb/test_vectors/lfnst16_s2_i2_golden.hex");
        run_test("lfnst16_s3_i1", 7'd4, 7'd4, 2'd0, 2'd0, 2'd3, 2'd1,
                 "../tb/test_vectors/lfnst16_s3_i1_input.hex",
                 "../tb/test_vectors/lfnst16_s3_i1_golden.hex");
        run_test("lfnst16_s3_i2", 7'd4, 7'd4, 2'd0, 2'd0, 2'd3, 2'd2,
                 "../tb/test_vectors/lfnst16_s3_i2_input.hex",
                 "../tb/test_vectors/lfnst16_s3_i2_golden.hex");

        // ============================
        // LFNST nTrs=48
        // ============================
        run_test("lfnst48_s0_i1", 7'd8, 7'd8, 2'd0, 2'd0, 2'd0, 2'd1,
                 "../tb/test_vectors/lfnst48_s0_i1_input.hex",
                 "../tb/test_vectors/lfnst48_s0_i1_golden.hex");
        run_test("lfnst48_s0_i2", 7'd8, 7'd8, 2'd0, 2'd0, 2'd0, 2'd2,
                 "../tb/test_vectors/lfnst48_s0_i2_input.hex",
                 "../tb/test_vectors/lfnst48_s0_i2_golden.hex");
        run_test("lfnst48_s1_i1", 7'd8, 7'd8, 2'd0, 2'd0, 2'd1, 2'd1,
                 "../tb/test_vectors/lfnst48_s1_i1_input.hex",
                 "../tb/test_vectors/lfnst48_s1_i1_golden.hex");
        run_test("lfnst48_s1_i2", 7'd8, 7'd8, 2'd0, 2'd0, 2'd1, 2'd2,
                 "../tb/test_vectors/lfnst48_s1_i2_input.hex",
                 "../tb/test_vectors/lfnst48_s1_i2_golden.hex");
        run_test("lfnst48_s2_i1", 7'd8, 7'd8, 2'd0, 2'd0, 2'd2, 2'd1,
                 "../tb/test_vectors/lfnst48_s2_i1_input.hex",
                 "../tb/test_vectors/lfnst48_s2_i1_golden.hex");
        run_test("lfnst48_s2_i2", 7'd8, 7'd8, 2'd0, 2'd0, 2'd2, 2'd2,
                 "../tb/test_vectors/lfnst48_s2_i2_input.hex",
                 "../tb/test_vectors/lfnst48_s2_i2_golden.hex");
        run_test("lfnst48_s3_i1", 7'd8, 7'd8, 2'd0, 2'd0, 2'd3, 2'd1,
                 "../tb/test_vectors/lfnst48_s3_i1_input.hex",
                 "../tb/test_vectors/lfnst48_s3_i1_golden.hex");
        run_test("lfnst48_s3_i2", 7'd8, 7'd8, 2'd0, 2'd0, 2'd3, 2'd2,
                 "../tb/test_vectors/lfnst48_s3_i2_input.hex",
                 "../tb/test_vectors/lfnst48_s3_i2_golden.hex");

        // ============================
        // LFNST + non-DCT2
        // ============================
        run_test("lfnst16_dct8_force", 7'd4, 7'd4, 2'd1, 2'd1, 2'd0, 2'd1,
                 "../tb/test_vectors/lfnst16_s0_i1_input.hex",
                 "../tb/test_vectors/lfnst16_s0_i1_golden.hex");

        // ============================
        // LFNST nTrs=48 with different block sizes
        // ============================
        run_test("dct2_8x16_lfnst1",  7'd8,  7'd16, 2'd0, 2'd0, 2'd0, 2'd1,
                 "../tb/test_vectors/dct2_8x16_lfnst1_input.hex",
                 "../tb/test_vectors/dct2_8x16_lfnst1_golden.hex");
        run_test("dct2_16x8_lfnst1",  7'd16, 7'd8,  2'd0, 2'd0, 2'd0, 2'd1,
                 "../tb/test_vectors/dct2_16x8_lfnst1_input.hex",
                 "../tb/test_vectors/dct2_16x8_lfnst1_golden.hex");
        run_test("dct2_16x16_lfnst1", 7'd16, 7'd16, 2'd0, 2'd0, 2'd0, 2'd1,
                 "../tb/test_vectors/dct2_16x16_lfnst1_input.hex",
                 "../tb/test_vectors/dct2_16x16_lfnst1_golden.hex");
        run_test("dct2_16x32_lfnst1", 7'd16, 7'd32, 2'd0, 2'd0, 2'd0, 2'd1,
                 "../tb/test_vectors/dct2_16x32_lfnst1_input.hex",
                 "../tb/test_vectors/dct2_16x32_lfnst1_golden.hex");
        run_test("dct2_32x16_lfnst1", 7'd32, 7'd16, 2'd0, 2'd0, 2'd0, 2'd1,
                 "../tb/test_vectors/dct2_32x16_lfnst1_input.hex",
                 "../tb/test_vectors/dct2_32x16_lfnst1_golden.hex");
        run_test("dct2_32x32_lfnst1", 7'd32, 7'd32, 2'd0, 2'd0, 2'd0, 2'd1,
                 "../tb/test_vectors/dct2_32x32_lfnst1_input.hex",
                 "../tb/test_vectors/dct2_32x32_lfnst1_golden.hex");

        // ============================
        // Non-square LFNST combinations
        // ============================
        run_test("dct2_4x64_lfnst1", 7'd4, 7'd64, 2'd0, 2'd0, 2'd0, 2'd1,
                 "../tb/test_vectors/dct2_4x64_lfnst1_input.hex",
                 "../tb/test_vectors/dct2_4x64_lfnst1_golden.hex");
        run_test("dct2_64x4_lfnst1", 7'd64, 7'd4, 2'd0, 2'd0, 2'd0, 2'd1,
                 "../tb/test_vectors/dct2_64x4_lfnst1_input.hex",
                 "../tb/test_vectors/dct2_64x4_lfnst1_golden.hex");
        run_test("dct2_8x64_lfnst1", 7'd8, 7'd64, 2'd0, 2'd0, 2'd0, 2'd1,
                 "../tb/test_vectors/dct2_8x64_lfnst1_input.hex",
                 "../tb/test_vectors/dct2_8x64_lfnst1_golden.hex");
        run_test("dct2_64x8_lfnst1", 7'd64, 7'd8, 2'd0, 2'd0, 2'd0, 2'd1,
                 "../tb/test_vectors/dct2_64x8_lfnst1_input.hex",
                 "../tb/test_vectors/dct2_64x8_lfnst1_golden.hex");

        // ============================
        // Boundary input tests
        // ============================
        run_test("boundary_zero_4x4", 7'd4, 7'd4, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/boundary_zero_4x4_input.hex",
                 "../tb/test_vectors/boundary_zero_4x4_golden.hex");
        run_test("boundary_dc_4x4", 7'd4, 7'd4, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/boundary_dc_4x4_input.hex",
                 "../tb/test_vectors/boundary_dc_4x4_golden.hex");
        run_test("boundary_maxval_4x4", 7'd4, 7'd4, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/boundary_maxval_4x4_input.hex",
                 "../tb/test_vectors/boundary_maxval_4x4_golden.hex");
        run_test("boundary_minval_4x4", 7'd4, 7'd4, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/boundary_minval_4x4_input.hex",
                 "../tb/test_vectors/boundary_minval_4x4_golden.hex");
        run_test("boundary_sparse_8x8", 7'd8, 7'd8, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/boundary_sparse_8x8_input.hex",
                 "../tb/test_vectors/boundary_sparse_8x8_golden.hex");

        // ============================
        // Output backpressure tests
        // slow_div=7: pop 1 in every 8 cycles, filling output FIFO to full
        // ============================
        $display("\n--- Output Backpressure Tests (slow_div=7) ---");
        output_fifo_full_cycles = 0;
        slow_div = 4'd7;
        run_test("bp_dct2_32x32", 7'd32, 7'd32, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_32x32_input.hex",
                 "../tb/test_vectors/dct2_32x32_golden.hex");
        run_test("bp_dct2_64x64", 7'd64, 7'd64, 2'd0, 2'd0, 2'd0, 2'd0,
                 "../tb/test_vectors/dct2_64x64_input.hex",
                 "../tb/test_vectors/dct2_64x64_golden.hex");
        run_test("bp_dct8_32x32", 7'd32, 7'd32, 2'd1, 2'd1, 2'd0, 2'd0,
                 "../tb/test_vectors/dct8_32x32_input.hex",
                 "../tb/test_vectors/dct8_32x32_golden.hex");
        run_test("bp_dst7_32x32", 7'd32, 7'd32, 2'd2, 2'd2, 2'd0, 2'd0,
                 "../tb/test_vectors/dst7_32x32_input.hex",
                 "../tb/test_vectors/dst7_32x32_golden.hex");
        run_test("bp_lfnst48", 7'd8, 7'd8, 2'd0, 2'd0, 2'd0, 2'd1,
                 "../tb/test_vectors/lfnst48_s0_i1_input.hex",
                 "../tb/test_vectors/lfnst48_s0_i1_golden.hex");
        $display("  [BP] output_fifo_full_cycles during backpressure tests: %0d", output_fifo_full_cycles);
        slow_div = 0;  // restore

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

    // Global timeout watchdog
    initial begin
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        #2000000000;
        $display("\nGLOBAL TIMEOUT!");
        $finish;
    end

endmodule

