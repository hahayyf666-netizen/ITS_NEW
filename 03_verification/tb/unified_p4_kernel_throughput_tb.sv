`timescale 1ns/1ps

module unified_p4_kernel_throughput_tb;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [1:0] tr_type = '0;
    logic [6:0] transform_size = '0;
    logic [6:0] active_size = '0;
    logic [6:0] output_size = '0;
    logic stage_sel = 1'b0;
    logic in_valid = 1'b0;
    logic in_req;
    logic signed [63:0] in_data = '0;
    logic out_valid;
    logic out_req = 1'b1;
    logic signed [63:0] out_data;
    logic done;
    logic busy;
    logic error;

    integer mode_i;
    integer cycle_i;
    integer group_i;
    integer vector_i;
    integer group_count;
    integer vector_count;
    integer output_count;
    integer done_count;
    integer expected_outputs;
    integer wait_i;
    integer gap;
    logic [63:0] expected_zero;

    always #1 clk = ~clk;

    unified_p4_kernel dut (
        .clk(clk), .rst_n(rst_n), .start(start), .tr_type(tr_type),
        .transform_size(transform_size), .active_size(active_size),
        .output_size(output_size),
        .stage_sel(stage_sel),
        .in_valid(in_valid), .in_req(in_req), .in_data(in_data),
        .out_valid(out_valid), .out_req(out_req), .out_data(out_data),
        .done(done), .busy(busy), .error(error)
    );

    task automatic reset_kernel;
        begin
            rst_n = 1'b0;
            repeat (2) @(posedge clk);
            #1step rst_n = 1'b1;
            @(negedge clk);
        end
    endtask

    task automatic run_mode(input integer type_arg, input integer size_arg);
        begin
            reset_kernel();
            tr_type = type_arg[1:0];
            transform_size = size_arg[6:0];
            active_size = size_arg[6:0];
            output_size = size_arg[6:0];
            stage_sel = 1'b0;
            group_count = size_arg / 4;
            vector_count = 8;
            expected_outputs = vector_count * group_count;
            output_count = 0;
            done_count = 0;

            // Each vector contributes exactly group_count input groups.  A
            // new vector starts every group_count cycles, while the preceding
            // vector is being emitted.  All-zero data makes the arithmetic
            // expectation unambiguous while exercising slot overlap.
            for (cycle_i = 0; cycle_i < (vector_count * group_count + 8);
                 cycle_i = cycle_i + 1) begin
                @(negedge clk);
                gap = cycle_i % group_count;
                if (cycle_i < vector_count * group_count) begin
                    in_valid = 1'b1;
                    in_data = '0;
                    if (gap == 0) begin
                        start = 1'b1;
                        #0;
                        if (!in_req || !dut.start_accept)
                            $fatal(1, "vector start not accepted type=%0d size=%0d cycle=%0d",
                                   type_arg, size_arg, cycle_i);
                    end else begin
                        start = 1'b0;
                    end
                end else begin
                    start = 1'b0;
                    in_valid = 1'b0;
                    in_data = '0;
                end

                @(posedge clk);
                if (out_valid && out_req) begin
                    output_count = output_count + 1;
                    if (out_data !== expected_zero)
                        $fatal(1, "nonzero output for zero vector type=%0d size=%0d cycle=%0d",
                               type_arg, size_arg, cycle_i);
                end
                #1step;
                if (done)
                    done_count = done_count + 1;
            end
            start = 1'b0;
            in_valid = 1'b0;
            in_data = '0;

            wait_i = 0;
            while ((done_count < vector_count) && (wait_i < 256)) begin
                @(posedge clk);
                if (out_valid && out_req) begin
                    output_count = output_count + 1;
                    if (out_data !== expected_zero)
                        $fatal(1, "nonzero drained output type=%0d size=%0d", type_arg, size_arg);
                end
                #1step;
                if (done)
                    done_count = done_count + 1;
                wait_i = wait_i + 1;
            end
            if (output_count != expected_outputs)
                $fatal(1, "output count mismatch type=%0d size=%0d got=%0d expected=%0d",
                       type_arg, size_arg, output_count, expected_outputs);
            if (done_count != vector_count)
                $fatal(1, "done count mismatch type=%0d size=%0d got=%0d expected=%0d",
                       type_arg, size_arg, done_count, vector_count);
            if (error)
                $fatal(1, "kernel error type=%0d size=%0d", type_arg, size_arg);
            $display("GATE_B_VECTOR_II_PASS type=%0d size=%0d ii=%0d vectors=%0d",
                     type_arg, size_arg, group_count, vector_count);
        end
    endtask

    initial begin
        expected_zero = '0;
        run_mode(0, 4);
        run_mode(0, 8);
        run_mode(0, 16);
        run_mode(0, 32);
        run_mode(0, 64);
        run_mode(1, 32);
        run_mode(2, 32);
        $display("GATE_B_VECTOR_II_TB_PASS modes=7");
        $finish;
    end
endmodule
