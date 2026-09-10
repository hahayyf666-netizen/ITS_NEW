`timescale 1ns/1ps

// P2F-B1: DCT2-64 exact factorized functional prototype.
//
// The operation and signal maps are generated from the frozen Python P2F
// schedule by generate_p2f_b1_rtl.py.  This module intentionally exposes a
// guaranteed-accept result port; the full-Core result-memory admission policy
// is not part of this prototype.
module p2f_dct2_64_b1 #(
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

    localparam integer LAST_ISSUE_CYCLE = 10;
    localparam integer RESULT_BANKS = 4;

    reg signed [15:0] vector_buf_a [0:63];
    reg signed [15:0] vector_buf_b [0:63];
    reg               active;
    reg               active_bank;
    reg [4:0]         issue_cycle;
    reg [VECTOR_ID_W-1:0] active_vector_id;

    reg signed [39:0] dot_acc [0:P2F_DOT_COUNT-1];
    reg signed [39:0] dot_acc_next [0:P2F_DOT_COUNT-1];
    reg signed [15:0] lane_x [0:127];
    reg signed [39:0] lane_product [0:127];
    integer           lane_op_id [0:127];

    reg signed [39:0] signal_value [0:P2F_SIG_COUNT-1];
    reg signed [39:0] raw_comb [0:63];

    reg               capture_pending;
    reg [1:0]         capture_bank;
    reg [VECTOR_ID_W-1:0] capture_vector_id;

    // Core-local result storage. Four banks are enough to keep a continuous
    // 16-cycle output stream while vectors are admitted every 16 cycles.
    reg signed [39:0] raw_mem [0:RESULT_BANKS-1][0:63];
    reg signed [39:0] biased_mem [0:RESULT_BANKS-1][0:63];
    reg signed [39:0] shifted_mem [0:RESULT_BANKS-1][0:63];
    reg signed [15:0] stage16_mem [0:RESULT_BANKS-1][0:63];
    reg        [9:0]  final10_mem [0:RESULT_BANKS-1][0:63];
    reg               result_ready [0:RESULT_BANKS-1];
    reg [VECTOR_ID_W-1:0] ready_vector_id [0:RESULT_BANKS-1];

    reg               output_active;
    reg [1:0]         output_bank;
    reg [4:0]         output_group;
    reg [VECTOR_ID_W-1:0] output_vector_id;
    reg [VECTOR_ID_W-1:0] next_output_vector_id;

    function automatic signed [15:0] wrap16(input signed [39:0] value);
        begin
            wrap16 = value[15:0];
        end
    endfunction

    function automatic signed [39:0] arithmetic_shift6(input signed [39:0] value);
        reg signed [39:0] biased;
        begin
            biased = value + 40'sd32;
            arithmetic_shift6 = biased >>> 6;
        end
    endfunction

    integer l;
    integer d;
    integer op_tmp;
    integer src_tmp;
    integer s;
    integer r;
    integer k;

    // One generated operation is selected for each of the 128 physical lanes
    // on each issue cycle.  Empty lanes are encoded as -1.
    always @* begin
        for (l = 0; l < 128; l = l + 1) begin
            lane_op_id[l] = -1;
            lane_x[l] = 16'sd0;
            lane_product[l] = 40'sd0;
            if (active) begin
                op_tmp = p2f_lane_op(issue_cycle * 128 + l);
                if (op_tmp >= 0) begin
                    src_tmp = p2f_op_src(op_tmp);
                    lane_op_id[l] = op_tmp;
                    if (active_bank)
                        lane_x[l] = vector_buf_b[src_tmp];
                    else
                        lane_x[l] = vector_buf_a[src_tmp];
                    lane_product[l] = $signed(p2f_op_coeff(op_tmp)) * $signed(lane_x[l]);
                end
            end
        end

        for (d = 0; d < P2F_DOT_COUNT; d = d + 1)
            dot_acc_next[d] = dot_acc[d];
        if (active) begin
            for (l = 0; l < 128; l = l + 1) begin
                if (lane_op_id[l] >= 0)
                    dot_acc_next[p2f_op_dot(lane_op_id[l])] =
                        dot_acc_next[p2f_op_dot(lane_op_id[l])] + lane_product[l];
            end
        end
    end

    // Exact E/O butterfly graph generated from the Python signal graph.
    reg signed [39:0] even_tmp;
    reg signed [39:0] odd_tmp;
    always @* begin
        // Initialize the combinational graph before consuming child signals;
        // the generated signal order is still topological, but this explicit
        // initialization keeps lint/simulator read-before-write diagnostics
        // quiet without changing the arithmetic.
        for (s = 0; s < P2F_SIG_COUNT; s = s + 1)
            signal_value[s] = 40'sd0;
        for (s = 0; s < P2F_SIG_COUNT; s = s + 1) begin
            if (p2f_sig_even_ref(s) >= 0)
                even_tmp = signal_value[p2f_sig_even_ref(s)];
            else
                even_tmp = dot_acc[p2f_sig_even_dot(s)];
            odd_tmp = dot_acc[p2f_sig_odd_dot(s)];
            if (p2f_sig_is_high(s) != 0)
                signal_value[s] = even_tmp - odd_tmp;
            else
                signal_value[s] = even_tmp + odd_tmp;
        end
        for (r = 0; r < 64; r = r + 1)
            raw_comb[r] = signal_value[p2f_root_sig(r)];
    end

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            active_bank <= 1'b0;
            issue_cycle <= 5'd0;
            active_vector_id <= {VECTOR_ID_W{1'b0}};
            capture_pending <= 1'b0;
            capture_bank <= 2'd0;
            capture_vector_id <= {VECTOR_ID_W{1'b0}};
            output_active <= 1'b0;
            output_bank <= 1'b0;
            output_group <= 5'd0;
            output_vector_id <= {VECTOR_ID_W{1'b0}};
            next_output_vector_id <= {VECTOR_ID_W{1'b0}};
            for (i = 0; i < P2F_DOT_COUNT; i = i + 1)
                dot_acc[i] <= 40'sd0;
            for (i = 0; i < RESULT_BANKS; i = i + 1) begin
                result_ready[i] <= 1'b0;
                ready_vector_id[i] <= {VECTOR_ID_W{1'b0}};
            end
        end else begin
            if (vector_start) begin
                active <= 1'b1;
                active_bank <= vector_id_in[0];
                issue_cycle <= 5'd0;
                active_vector_id <= vector_id_in;
                for (i = 0; i < P2F_DOT_COUNT; i = i + 1)
                    dot_acc[i] <= 40'sd0;
                for (i = 0; i < 64; i = i + 1) begin
                    if (vector_id_in[0])
                        vector_buf_b[i] <= $signed(vector_data_flat[i*16 +: 16]);
                    else
                        vector_buf_a[i] <= $signed(vector_data_flat[i*16 +: 16]);
                end
            end else if (active) begin
                for (i = 0; i < P2F_DOT_COUNT; i = i + 1)
                    dot_acc[i] <= dot_acc_next[i];
                if (issue_cycle == LAST_ISSUE_CYCLE) begin
                    active <= 1'b0;
                    capture_pending <= 1'b1;
                    capture_bank <= active_vector_id[1:0];
                    capture_vector_id <= active_vector_id;
                end else begin
                    issue_cycle <= issue_cycle + 5'd1;
                end
            end

            if (capture_pending) begin
                capture_pending <= 1'b0;
                for (i = 0; i < 64; i = i + 1) begin
                    raw_mem[capture_bank][i] <= raw_comb[i];
                    biased_mem[capture_bank][i] <= raw_comb[i] + 40'sd32;
                    shifted_mem[capture_bank][i] <= arithmetic_shift6(raw_comb[i]);
                    stage16_mem[capture_bank][i] <= wrap16(arithmetic_shift6(raw_comb[i]));
                    // Assignment to 10 bits intentionally keeps the low-10
                    // interface representation.
                    final10_mem[capture_bank][i] <= arithmetic_shift6(raw_comb[i]);
                end
                result_ready[capture_bank] <= 1'b1;
                ready_vector_id[capture_bank] <= capture_vector_id;
            end

            // Guaranteed-accept output sink.  An admitted invocation cannot
            // be stalled in the middle of its 16-beat burst.
            if (output_active) begin
                if (result_valid && result_accept) begin
                    if (output_group == 5'd15) begin
                        result_ready[output_bank] <= 1'b0;
                        // If the next completed vector is already available,
                        // switch banks on this same edge and keep valid high.
                        if (result_ready[next_output_vector_id[1:0] + 2'd1] &&
                            ready_vector_id[next_output_vector_id[1:0] + 2'd1] ==
                            (next_output_vector_id + 1'b1)) begin
                            output_active <= 1'b1;
                            output_bank <= next_output_vector_id[1:0] + 2'd1;
                            output_group <= 5'd0;
                            output_vector_id <= next_output_vector_id + 1'b1;
                            next_output_vector_id <= next_output_vector_id + 1'b1;
                        end else begin
                            output_active <= 1'b0;
                            next_output_vector_id <= next_output_vector_id + 1'b1;
                        end
                    end else begin
                        output_group <= output_group + 5'd1;
                    end
                end
            end else begin
                if (result_ready[next_output_vector_id[1:0]] &&
                    ready_vector_id[next_output_vector_id[1:0]] == next_output_vector_id) begin
                    output_active <= 1'b1;
                    output_bank <= next_output_vector_id[1:0];
                    output_group <= 5'd0;
                    output_vector_id <= next_output_vector_id;
                end
            end
        end
    end

    // Four-wide result port.  The values are emitted only after complete raw
    // reduction, butterfly, and fixed-point postprocessing.
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
                result_raw_flat[k*40 +: 40] = raw_mem[output_bank][output_group*4+k];
                result_biased_flat[k*40 +: 40] = biased_mem[output_bank][output_group*4+k];
                result_shifted_flat[k*40 +: 40] = shifted_mem[output_bank][output_group*4+k];
                result_stage16_flat[k*16 +: 16] = stage16_mem[output_bank][output_group*4+k];
                result_final10_flat[k*10 +: 10] = final10_mem[output_bank][output_group*4+k];
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && result_valid && !result_accept)
            $error("P2F-B1 guaranteed-accept violation at group %0d", result_group);
    end
`endif

endmodule
