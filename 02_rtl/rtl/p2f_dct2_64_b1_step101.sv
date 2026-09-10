`timescale 1ns/1ps

// P2F-B1 Step 10.1: structurally hardened DCT2-64 P4 functional prototype.
//
// The generated operation schedule is unchanged (1368 operations, 128 lanes).
// Products are first registered, then written into per-dot term storage. Each
// dot is reduced through registered balanced levels (32 -> 16 -> 8 -> 4 -> 2
// -> 1). The exact recursive E/O graph is evaluated one registered level at a
// time. The result port is guaranteed-accept: result_accept is an assertion
// input only and never advances an already-started burst.
module p2f_dct2_64_b1_step101 #(
    parameter integer VECTOR_ID_W = 16
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         vector_start,
    input  wire [VECTOR_ID_W-1:0]       vector_id_in,
    input  wire [1023:0]                vector_data_flat,
    input  wire                         result_accept,

    output reg                          result_valid,
    output reg  [4:0]                   result_group,
    output reg  [VECTOR_ID_W-1:0]       result_vector_id,
    output reg                          result_first,
    output reg                          result_last,
    output reg  [159:0]                 result_raw_flat,
    output reg  [159:0]                 result_biased_flat,
    output reg  [159:0]                 result_shifted_flat,
    output reg  [63:0]                  result_stage16_flat,
    output reg  [39:0]                  result_final10_flat
);

`include "p2f_b1_tables.svh"

    localparam integer LANES = 128;
    localparam integer DOTS = 64;
    localparam integer SIGS = 124;
    localparam integer ISSUE_LAST = 10;
    localparam integer PIPE_BANKS = 2;
    localparam integer RESULT_BANKS = 4;

    reg signed [15:0] vector_buf_a [0:63];
    reg signed [15:0] vector_buf_b [0:63];
    reg                active;
    reg                active_bank;
    reg [4:0]          issue_cycle;
    reg [VECTOR_ID_W-1:0] active_vector_id;

    // Combinational lookup feeding the explicitly registered multiplier
    // outputs. A product is never accumulated through a combinational
    // lane-by-lane += chain.
    reg signed [15:0] lane_x_comb [0:LANES-1];
    reg signed [39:0] lane_product_comb [0:LANES-1];
    integer lane_op_id_comb [0:LANES-1];
    reg signed [39:0] lane_product_reg [0:LANES-1];
    integer lane_op_id_reg [0:LANES-1];
    reg                lane_bank_reg [0:LANES-1];

    // Registered product-term storage. The generated term index is stable
    // for each operation and preserves the exact schedule and coefficient.
    reg signed [39:0] term_mem [0:PIPE_BANKS-1][0:DOTS-1][0:31];
    reg                product_flush_pending;
    reg                product_flush_bank;
    reg                reduce_start_pending [0:PIPE_BANKS-1];

    // One balanced, registered reduction fabric per active ping-pong bank.
    // l0 is the registered multiplier-term level; l1..l5 are 32->16->8->4
    // ->2->1 reductions. Unused terms for short dots are zero-filled at
    // vector launch.
    reg signed [39:0] red_l0 [0:PIPE_BANKS-1][0:DOTS-1][0:31];
    reg signed [39:0] red_l1 [0:PIPE_BANKS-1][0:DOTS-1][0:15];
    reg signed [39:0] red_l2 [0:PIPE_BANKS-1][0:DOTS-1][0:7];
    reg signed [39:0] red_l3 [0:PIPE_BANKS-1][0:DOTS-1][0:3];
    reg signed [39:0] red_l4 [0:PIPE_BANKS-1][0:DOTS-1][0:1];
    reg signed [39:0] red_l5 [0:PIPE_BANKS-1][0:DOTS-1];
    reg                red_valid [0:PIPE_BANKS-1][0:5];
    reg signed [39:0] dot_result [0:PIPE_BANKS-1][0:DOTS-1];
    reg                dot_result_valid [0:PIPE_BANKS-1];

    // Registered butterfly levels. signal_next reads only dot_result and
    // previously registered signal values, so no 124-node combinational
    // chain is present in a single cycle.
    reg signed [39:0] signal_reg [0:PIPE_BANKS-1][0:SIGS-1];
    reg signed [39:0] signal_next [0:PIPE_BANKS-1][0:SIGS-1];
    reg [2:0]          signal_phase [0:PIPE_BANKS-1];
    reg                raw_capture_pending [0:PIPE_BANKS-1];
    reg [VECTOR_ID_W-1:0] pipe_vector_id [0:PIPE_BANKS-1];

    // Four result banks hold complete vectors for the guaranteed-accept port.
    // Raw/biased/shifted copies are verification-only and are removed from a
    // synthesis build; stage16/final10 are the implementation-facing values.
`ifndef SYNTHESIS
    reg signed [39:0] raw_mem [0:RESULT_BANKS-1][0:63];
    reg signed [39:0] biased_mem [0:RESULT_BANKS-1][0:63];
    reg signed [39:0] shifted_mem [0:RESULT_BANKS-1][0:63];
`endif
    reg signed [15:0] stage16_mem [0:RESULT_BANKS-1][0:63];
    reg        [9:0]  final10_mem [0:RESULT_BANKS-1][0:63];
    reg                result_ready [0:RESULT_BANKS-1];
    reg [VECTOR_ID_W-1:0] ready_vector_id [0:RESULT_BANKS-1];

    reg                output_active;
    reg [1:0]          output_bank;
    reg [4:0]          output_group;
    reg [VECTOR_ID_W-1:0] output_vector_id;
    reg [VECTOR_ID_W-1:0] next_output_vector_id;

    function automatic signed [15:0] wrap16(input signed [39:0] value);
        begin wrap16 = value[15:0]; end
    endfunction

    function automatic signed [39:0] shift6(input signed [39:0] value);
        reg signed [39:0] biased;
        begin
            biased = value + 40'sd32;
            shift6 = biased >>> 6;
        end
    endfunction

    wire [1:0] next_bank = next_output_vector_id[1:0];
    wire [VECTOR_ID_W-1:0] following_vector_id = next_output_vector_id + 1'b1;
    wire [1:0] following_bank = following_vector_id[1:0];
    // A capture pending on a vector's ping-pong bank is accepted as ready
    // because raw_mem is written on this same clock edge.
    wire next_vector_ready =
        (result_ready[next_bank] &&
         ready_vector_id[next_bank] == next_output_vector_id) ||
        (raw_capture_pending[next_bank[0]] &&
         pipe_vector_id[next_bank[0]] == next_output_vector_id);
    wire following_vector_ready =
        (result_ready[following_bank] &&
         ready_vector_id[following_bank] == following_vector_id) ||
        (raw_capture_pending[following_bank[0]] &&
         pipe_vector_id[following_bank[0]] == following_vector_id);

    integer l;
    integer d;
    integer t;
    integer b;
    integer s;
    integer k;
    integer op_tmp;
    integer src_tmp;
    integer dot_tmp;
    integer term_tmp;
    integer ref_tmp;
    integer odd_tmp;
    integer i;

    // Exact generated 128-lane issue lookup.
    always @* begin
        for (l = 0; l < LANES; l = l + 1) begin
            lane_op_id_comb[l] = -1;
            lane_x_comb[l] = 16'sd0;
            lane_product_comb[l] = 40'sd0;
            if (active) begin
                op_tmp = p2f_lane_op(issue_cycle * LANES + l);
                if (op_tmp >= 0) begin
                    src_tmp = p2f_op_src(op_tmp);
                    lane_op_id_comb[l] = op_tmp;
                    if (active_bank)
                        lane_x_comb[l] = vector_buf_b[src_tmp];
                    else
                        lane_x_comb[l] = vector_buf_a[src_tmp];
                    lane_product_comb[l] =
                        $signed(p2f_op_coeff(op_tmp)) * $signed(lane_x_comb[l]);
                end
            end
        end
    end

    // Each signal uses only registered predecessor values. The level function
    // generated from the Python graph identifies which subset is committed on
    // each butterfly phase.
    always @* begin
        for (b = 0; b < PIPE_BANKS; b = b + 1) begin
            for (s = 0; s < SIGS; s = s + 1) begin
                ref_tmp = p2f_sig_even_ref(s);
                if (ref_tmp >= 0)
                    signal_next[b][s] = signal_reg[b][ref_tmp];
                else
                    signal_next[b][s] = dot_result[b][p2f_sig_even_dot(s)];
                odd_tmp = p2f_sig_odd_dot(s);
                if (p2f_sig_is_high(s) != 0)
                    signal_next[b][s] = signal_next[b][s] -
                                         dot_result[b][odd_tmp];
                else
                    signal_next[b][s] = signal_next[b][s] +
                                         dot_result[b][odd_tmp];
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            active_bank <= 1'b0;
            issue_cycle <= 5'd0;
            active_vector_id <= {VECTOR_ID_W{1'b0}};
            product_flush_pending <= 1'b0;
            product_flush_bank <= 1'b0;
            output_active <= 1'b0;
            output_bank <= 2'd0;
            output_group <= 5'd0;
            output_vector_id <= {VECTOR_ID_W{1'b0}};
            next_output_vector_id <= {VECTOR_ID_W{1'b0}};
            for (l = 0; l < LANES; l = l + 1) begin
                lane_product_reg[l] <= 40'sd0;
                lane_op_id_reg[l] <= -1;
                lane_bank_reg[l] <= 1'b0;
            end
            for (b = 0; b < PIPE_BANKS; b = b + 1) begin
                reduce_start_pending[b] <= 1'b0;
                dot_result_valid[b] <= 1'b0;
                signal_phase[b] <= 3'd0;
                raw_capture_pending[b] <= 1'b0;
                pipe_vector_id[b] <= {VECTOR_ID_W{1'b0}};
                for (k = 0; k < 6; k = k + 1)
                    red_valid[b][k] <= 1'b0;
                for (d = 0; d < DOTS; d = d + 1) begin
                    dot_result[b][d] <= 40'sd0;
                    for (t = 0; t < 32; t = t + 1) begin
                        term_mem[b][d][t] <= 40'sd0;
                        red_l0[b][d][t] <= 40'sd0;
                    end
                    for (t = 0; t < 16; t = t + 1) red_l1[b][d][t] <= 40'sd0;
                    for (t = 0; t < 8; t = t + 1) red_l2[b][d][t] <= 40'sd0;
                    for (t = 0; t < 4; t = t + 1) red_l3[b][d][t] <= 40'sd0;
                    for (t = 0; t < 2; t = t + 1) red_l4[b][d][t] <= 40'sd0;
                    red_l5[b][d] <= 40'sd0;
                    for (s = 0; s < SIGS; s = s + 1)
                        signal_reg[b][s] <= 40'sd0;
                end
            end
            for (b = 0; b < RESULT_BANKS; b = b + 1) begin
                result_ready[b] <= 1'b0;
                ready_vector_id[b] <= {VECTOR_ID_W{1'b0}};
                for (i = 0; i < 64; i = i + 1) begin
`ifndef SYNTHESIS
                    raw_mem[b][i] <= 40'sd0;
                    biased_mem[b][i] <= 40'sd0;
                    shifted_mem[b][i] <= 40'sd0;
`endif
                    stage16_mem[b][i] <= 16'sd0;
                    final10_mem[b][i] <= 10'd0;
                end
            end
        end else begin
            // First commit the prior registered multiplier outputs, then
            // register this cycle's products. This is the explicit mul_reg
            // boundary required by Step 10.1.
            for (l = 0; l < LANES; l = l + 1) begin
                if (lane_op_id_reg[l] >= 0) begin
                    dot_tmp = p2f_op_dot(lane_op_id_reg[l]);
                    term_tmp = p2f_op_term(lane_op_id_reg[l]);
                    term_mem[lane_bank_reg[l]][dot_tmp][term_tmp] <=
                        lane_product_reg[l];
                end
                lane_product_reg[l] <= lane_product_comb[l];
                lane_op_id_reg[l] <= lane_op_id_comb[l];
                lane_bank_reg[l] <= active_bank;
            end

            // Launch a new vector into the inactive ping-pong input bank.
            if (vector_start) begin
                active <= 1'b1;
                active_bank <= vector_id_in[0];
                issue_cycle <= 5'd0;
                active_vector_id <= vector_id_in;
                pipe_vector_id[vector_id_in[0]] <= vector_id_in;
                for (d = 0; d < DOTS; d = d + 1)
                    for (t = 0; t < 32; t = t + 1)
                        term_mem[vector_id_in[0]][d][t] <= 40'sd0;
                for (i = 0; i < 64; i = i + 1) begin
                    if (vector_id_in[0])
                        vector_buf_b[i] <= $signed(vector_data_flat[i*16 +: 16]);
                    else
                        vector_buf_a[i] <= $signed(vector_data_flat[i*16 +: 16]);
                end
            end else if (active) begin
                if (issue_cycle == ISSUE_LAST) begin
                    active <= 1'b0;
                    product_flush_pending <= 1'b1;
                    product_flush_bank <= active_bank;
                end else begin
                    issue_cycle <= issue_cycle + 5'd1;
                end
            end

            // The product flush is intentionally applied after the reduction
            // block below so it cannot be overwritten by its valid pipeline.

            // Registered balanced reduction. Every level is committed one
            // clock after its predecessor. All 64 dots use the same fabric;
            // short dots have zero-filled terms.
            for (b = 0; b < PIPE_BANKS; b = b + 1) begin
                red_valid[b][5] <= red_valid[b][4];
                red_valid[b][4] <= red_valid[b][3];
                red_valid[b][3] <= red_valid[b][2];
                red_valid[b][2] <= red_valid[b][1];
                red_valid[b][1] <= red_valid[b][0];
                red_valid[b][0] <= reduce_start_pending[b];
                reduce_start_pending[b] <= 1'b0;

                if (reduce_start_pending[b]) begin
                    for (d = 0; d < DOTS; d = d + 1)
                        for (t = 0; t < 32; t = t + 1)
                            red_l0[b][d][t] <= term_mem[b][d][t];
                end
                if (red_valid[b][0]) begin
                    for (d = 0; d < DOTS; d = d + 1)
                        for (t = 0; t < 16; t = t + 1)
                            red_l1[b][d][t] <= red_l0[b][d][2*t] +
                                               red_l0[b][d][2*t+1];
                end
                if (red_valid[b][1]) begin
                    for (d = 0; d < DOTS; d = d + 1)
                        for (t = 0; t < 8; t = t + 1)
                            red_l2[b][d][t] <= red_l1[b][d][2*t] +
                                               red_l1[b][d][2*t+1];
                end
                if (red_valid[b][2]) begin
                    for (d = 0; d < DOTS; d = d + 1)
                        for (t = 0; t < 4; t = t + 1)
                            red_l3[b][d][t] <= red_l2[b][d][2*t] +
                                               red_l2[b][d][2*t+1];
                end
                if (red_valid[b][3]) begin
                    for (d = 0; d < DOTS; d = d + 1)
                        for (t = 0; t < 2; t = t + 1)
                            red_l4[b][d][t] <= red_l3[b][d][2*t] +
                                               red_l3[b][d][2*t+1];
                end
                if (red_valid[b][4]) begin
                    for (d = 0; d < DOTS; d = d + 1)
                        red_l5[b][d] <= red_l4[b][d][0] + red_l4[b][d][1];
                end
                dot_result_valid[b] <= red_valid[b][5];
                if (red_valid[b][5])
                    for (d = 0; d < DOTS; d = d + 1)
                        dot_result[b][d] <= red_l5[b][d];

                // Registered butterfly phases 1..5.
                if (dot_result_valid[b]) begin
                    for (s = 0; s < SIGS; s = s + 1)
                        if (p2f_sig_level(s) == 1)
                            signal_reg[b][s] <= signal_next[b][s];
                    signal_phase[b] <= 3'd2;
                end else if (signal_phase[b] != 0) begin
                    for (s = 0; s < SIGS; s = s + 1)
                        if (p2f_sig_level(s) == signal_phase[b])
                            signal_reg[b][s] <= signal_next[b][s];
                    if (signal_phase[b] == 3'd5) begin
                        signal_phase[b] <= 3'd0;
                        raw_capture_pending[b] <= 1'b1;
                    end else begin
                        signal_phase[b] <= signal_phase[b] + 3'd1;
                    end
                end

                if (raw_capture_pending[b]) begin
                    raw_capture_pending[b] <= 1'b0;
                    for (i = 0; i < 64; i = i + 1) begin
`ifndef SYNTHESIS
                        raw_mem[pipe_vector_id[b][1:0]][i] <=
                            signal_reg[b][p2f_root_sig(i)];
                        biased_mem[pipe_vector_id[b][1:0]][i] <=
                            signal_reg[b][p2f_root_sig(i)] + 40'sd32;
                        shifted_mem[pipe_vector_id[b][1:0]][i] <=
                            shift6(signal_reg[b][p2f_root_sig(i)]);
`endif
                        stage16_mem[pipe_vector_id[b][1:0]][i] <=
                            wrap16(shift6(signal_reg[b][p2f_root_sig(i)]));
                        final10_mem[pipe_vector_id[b][1:0]][i] <=
                            shift6(signal_reg[b][p2f_root_sig(i)]);
                    end
                    result_ready[pipe_vector_id[b][1:0]] <= 1'b1;
                    ready_vector_id[pipe_vector_id[b][1:0]] <= pipe_vector_id[b];
                end
            end

            // Commit the pending product flush after the reduction block. The
            // next edge then loads red_l0 from the now-complete term_mem.
            if (product_flush_pending) begin
                reduce_start_pending[product_flush_bank] <= 1'b1;
                product_flush_pending <= 1'b0;
            end

            // Guaranteed-accept result stream. result_accept is deliberately
            // absent from state transitions; it is checked below only.
            if (output_active) begin
                if (output_group == 5'd15) begin
                    result_ready[output_bank] <= 1'b0;
                    if (following_vector_ready) begin
                        output_active <= 1'b1;
                        output_bank <= following_bank;
                        output_group <= 5'd0;
                        output_vector_id <= following_vector_id;
                        next_output_vector_id <= following_vector_id;
                    end else begin
                        output_active <= 1'b0;
                        next_output_vector_id <= next_output_vector_id + 1'b1;
                    end
                end else begin
                    output_group <= output_group + 5'd1;
                end
            end else if (next_vector_ready) begin
                output_active <= 1'b1;
                output_bank <= next_bank;
                output_group <= 5'd0;
                output_vector_id <= next_output_vector_id;
            end
        end
    end

    // Four-wide output. These are complete values after the registered
    // reduction and butterfly graph, not partial sums.
    always @* begin
        result_valid = output_active;
        result_group = output_group;
        result_vector_id = output_vector_id;
        result_first = output_active && (output_group == 5'd0);
        result_last = output_active && (output_group == 5'd15);
        result_raw_flat = 160'd0;
        result_biased_flat = 160'd0;
        result_shifted_flat = 160'd0;
        result_stage16_flat = 64'd0;
        result_final10_flat = 40'd0;
        if (output_active) begin
            for (k = 0; k < 4; k = k + 1) begin
`ifndef SYNTHESIS
                result_raw_flat[k*40 +: 40] = raw_mem[output_bank][output_group*4+k];
                result_biased_flat[k*40 +: 40] = biased_mem[output_bank][output_group*4+k];
                result_shifted_flat[k*40 +: 40] = shifted_mem[output_bank][output_group*4+k];
`endif
                result_stage16_flat[k*16 +: 16] = stage16_mem[output_bank][output_group*4+k];
                result_final10_flat[k*10 +: 10] = final10_mem[output_bank][output_group*4+k];
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && result_valid && !result_accept)
            $error("P2F-B1 guaranteed-accept violation at vector %0d group %0d",
                   result_vector_id, result_group);
    end
`endif

endmodule
