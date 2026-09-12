`timescale 1ns/1ps

// Permanent transaction-edge latency contract for the frozen R4C.
// The edge counter is intentionally local to this testbench; only the
// relative first-group latency is contractual.
module r4c_latency_contract_tb;
    reg clk = 0;
    reg rst_n = 0;
    reg vector_start = 0;
    reg [15:0] vector_id_in = 16'h0000;
    reg [1023:0] vector_data_flat = 1024'd0;
    reg result_accept = 1'b1;
    wire result_valid;
    wire [4:0] result_group;
    wire [15:0] result_vector_id;
    wire result_first, result_last;
    wire [159:0] result_raw_flat;
    wire [159:0] result_biased_flat;
    wire [159:0] result_shifted_flat;
    wire [63:0] result_stage16_flat;
    wire [39:0] result_final10_flat;

    integer edge_count;
    integer start_accept_edge;
    integer group0_result_fire_edge;
    integer groups;
    integer group_ii_errors;
    integer first_group_edge;
    integer last_group_edge;
    integer last_group;
    integer previous_group_edge;
    integer latency;

    always #1 clk = ~clk;

    p2f_dct2_64_b1_step102 dut (
        .clk(clk), .rst_n(rst_n), .vector_start(vector_start),
        .vector_id_in(vector_id_in), .vector_data_flat(vector_data_flat),
        .result_accept(result_accept), .result_valid(result_valid),
        .result_group(result_group), .result_vector_id(result_vector_id),
        .result_first(result_first), .result_last(result_last),
        .result_raw_flat(result_raw_flat), .result_biased_flat(result_biased_flat),
        .result_shifted_flat(result_shifted_flat),
        .result_stage16_flat(result_stage16_flat),
        .result_final10_flat(result_final10_flat)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            edge_count <= 0;
        end else begin
            edge_count <= edge_count + 1;
            if (vector_start) begin
                if (start_accept_edge >= 0)
                    $fatal(1, "unexpected second vector_start");
                start_accept_edge <= edge_count;
            end
            if (result_valid && result_accept) begin
                if (result_vector_id !== vector_id_in)
                    $fatal(1, "result vector id mismatch");
                if (result_group !== groups[4:0])
                    $fatal(1, "group sequence mismatch expected=%0d got=%0d", groups, result_group);
                if (result_first !== (groups == 0) || result_last !== (groups == 15))
                    $fatal(1, "first/last mismatch group=%0d", groups);
                if (groups == 0) begin
                    group0_result_fire_edge <= edge_count;
                    first_group_edge <= edge_count;
                end else if (edge_count - previous_group_edge != 1) begin
                    group_ii_errors <= group_ii_errors + 1;
                end
                previous_group_edge <= edge_count;
                last_group_edge <= edge_count;
                last_group <= groups;
                groups <= groups + 1;
            end
        end
    end

    initial begin
        edge_count = 0;
        start_accept_edge = -1;
        group0_result_fire_edge = -1;
        groups = 0;
        group_ii_errors = 0;
        first_group_edge = -1;
        last_group_edge = -1;
        previous_group_edge = -1;
        last_group = -1;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        vector_start = 1'b1;
        @(negedge clk);
        vector_start = 1'b0;

        fork
            begin
                repeat (5000) @(posedge clk);
                $fatal(1, "R4C latency test timeout groups=%0d edge=%0d start=%0d",
                       groups, edge_count, start_accept_edge);
            end
            begin
        wait (groups == 16);
        #1step;
        latency = group0_result_fire_edge - start_accept_edge;
        if (latency != 23)
            $fatal(1, "R4C transaction latency mismatch expected=23 got=%0d", latency);
        if (groups != 16 || last_group != 15 || group_ii_errors != 0)
            $fatal(1, "R4C group contract failed groups=%0d last=%0d ii_errors=%0d",
                   groups, last_group, group_ii_errors);
        $display("R4C_LATENCY_PASS start_accept_edge=%0d group0_result_fire_edge=%0d transaction_latency=%0d groups=16 group_ii=1",
                 start_accept_edge, group0_result_fire_edge, latency);
        $finish;
            end
        join_any
        disable fork;
    end
endmodule
