// Bounded, synthesizable LFNST engine for the engineering-profile wrapper.
//
// One issue contains four complete output rows and sixteen coefficient/input
// terms per row.  Coefficients are packed by (nTrs,set,index,output_group),
// so the implementation has one bounded 1024-bit ROM read per issue rather
// than 64 arbitrary reads from the canonical flat ROM.

module bounded_lfnst_engine #(
    parameter integer DATA_W = 16,
    parameter integer COEFF_W = 16,
    parameter integer ACC_W = 40,
    parameter string COEFF_FILE = "03_verification/sim/lfnst_packed_coeffs.hex"
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start,
    input  logic [1:0]                   set_idx,
    input  logic [1:0]                   lfnst_idx,
    input  logic                         ntrs48,
    input  logic                         nonzero8,
    input  logic signed [(16*DATA_W)-1:0] input_terms,
    output logic                         busy,
    output logic                         out_valid,
    output logic signed [(4*DATA_W)-1:0] out_data,
    output logic [3:0]                   out_group,
    output logic                         out_last,
    output logic                         done,
    output logic                         error
);

    localparam integer BUNDLE_COUNT = 128;
    localparam logic [1:0] ST_IDLE = 2'd0;
    localparam logic [1:0] ST_RUN  = 2'd1;

    logic [1023:0] coeff_bundle_mem [0:BUNDLE_COUNT-1];
    logic [1:0] state_q;
    logic [1:0] set_q;
    logic [1:0] idx_q;
    logic       ntrs48_q;
    logic       nonzero8_q;
    logic signed [(16*DATA_W)-1:0] input_terms_q;
    logic [3:0] issue_group_q;
    logic [3:0] product_group_q;
    logic       product_valid_q;
    logic       product_last_q;
    logic signed [ACC_W-1:0] products_q [0:63];

    logic [6:0] bundle_addr;
    logic signed [DATA_W+COEFF_W-1:0] products_c [0:63];
    logic signed [ACC_W-1:0] reduce_l1_c [0:31];
    logic signed [ACC_W-1:0] reduce_l2_c [0:15];
    logic signed [ACC_W-1:0] reduce_l3_c [0:7];
    logic signed [ACC_W-1:0] reduce_l4_c [0:3];
    logic signed [ACC_W-1:0] sum_c [0:3];
    logic signed [DATA_W-1:0] scaled_c [0:3];
    integer bundle_i;
    integer product_i;
    integer reduce_i;
    integer sum_lane;
    integer scale_lane;
    integer seq_i;
    integer seq_lane;

    initial $readmemh(COEFF_FILE, coeff_bundle_mem);

    always_comb begin
        if (!ntrs48_q)
            bundle_addr = (set_q * 7'd8) + ((idx_q - 1'b1) * 7'd4) + issue_group_q;
        else
            bundle_addr = 7'd32 + (set_q * 7'd24) +
                          ((idx_q - 1'b1) * 7'd12) + issue_group_q;
        for (product_i = 0; product_i < 64; product_i = product_i + 1) begin
            if (!ntrs48_q && nonzero8_q && ((product_i % 16) >= 8))
                products_c[product_i] = '0;
            else
                products_c[product_i] =
                    $signed(coeff_bundle_mem[bundle_addr][product_i*16 +: 16]) *
                    $signed(input_terms_q[(product_i % 16)*DATA_W +: DATA_W]);
        end
    end

    always_comb begin
        for (reduce_i = 0; reduce_i < 32; reduce_i = reduce_i + 1)
            reduce_l1_c[reduce_i] = '0;
        for (reduce_i = 0; reduce_i < 64; reduce_i = reduce_i + 1)
            reduce_l1_c[reduce_i/2] = reduce_l1_c[reduce_i/2] +
                {{(ACC_W-(DATA_W+COEFF_W)){products_q[reduce_i][DATA_W+COEFF_W-1]}},
                 products_q[reduce_i][DATA_W+COEFF_W-1:0]};
        for (reduce_i = 0; reduce_i < 16; reduce_i = reduce_i + 1)
            reduce_l2_c[reduce_i] = reduce_l1_c[reduce_i*2] +
                                    reduce_l1_c[reduce_i*2+1];
        for (reduce_i = 0; reduce_i < 8; reduce_i = reduce_i + 1)
            reduce_l3_c[reduce_i] = reduce_l2_c[reduce_i*2] +
                                    reduce_l2_c[reduce_i*2+1];
        for (reduce_i = 0; reduce_i < 4; reduce_i = reduce_i + 1)
            reduce_l4_c[reduce_i] = reduce_l3_c[reduce_i*2] +
                                    reduce_l3_c[reduce_i*2+1];
        for (sum_lane = 0; sum_lane < 4; sum_lane = sum_lane + 1)
            sum_c[sum_lane] = reduce_l4_c[sum_lane];
    end

    function automatic logic signed [DATA_W-1:0] round_clip(
        input logic signed [ACC_W-1:0] raw_i);
        logic signed [ACC_W-1:0] value_i;
        begin
            value_i = (raw_i + (1 <<< 6)) >>> 7;
            if (value_i > 32767)
                round_clip = 16'sh7fff;
            else if (value_i < -32768)
                round_clip = 16'sh8000;
            else
                round_clip = value_i[DATA_W-1:0];
        end
    endfunction

    always_comb begin
        for (scale_lane = 0; scale_lane < 4; scale_lane = scale_lane + 1)
            scaled_c[scale_lane] = round_clip(sum_c[scale_lane]);
    end

    always_comb begin
        busy = (state_q != ST_IDLE) || product_valid_q;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= ST_IDLE;
            set_q <= 2'd0;
            idx_q <= 2'd0;
            ntrs48_q <= 1'b0;
            nonzero8_q <= 1'b0;
            input_terms_q <= '0;
            issue_group_q <= 4'd0;
            product_group_q <= 4'd0;
            product_valid_q <= 1'b0;
            product_last_q <= 1'b0;
            out_valid <= 1'b0;
            out_data <= '0;
            out_group <= 4'd0;
            out_last <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            for (seq_i = 0; seq_i < 64; seq_i = seq_i + 1)
                products_q[seq_i] <= '0;
        end else begin
            out_valid <= 1'b0;
            out_last <= 1'b0;
            done <= 1'b0;

            if (start) begin
                if ((state_q != ST_IDLE) || (lfnst_idx == 2'd0) ||
                    (lfnst_idx > 2'd2)) begin
                    error <= 1'b1;
                end else begin
                    state_q <= ST_RUN;
                    set_q <= set_idx;
                    idx_q <= lfnst_idx;
                    ntrs48_q <= ntrs48;
                    nonzero8_q <= nonzero8;
                    input_terms_q <= input_terms;
                    issue_group_q <= 4'd0;
                    product_valid_q <= 1'b0;
                end
            end

            if (state_q == ST_RUN) begin
                if (issue_group_q < (ntrs48_q ? 4'd12 : 4'd4)) begin
                    for (seq_i = 0; seq_i < 64; seq_i = seq_i + 1)
                        products_q[seq_i] <= products_c[seq_i];
                    product_group_q <= issue_group_q;
                    product_last_q <= (issue_group_q == (ntrs48_q ? 4'd11 : 4'd3));
                    product_valid_q <= 1'b1;
                    issue_group_q <= issue_group_q + 1'b1;
                end else begin
                    product_valid_q <= 1'b0;
                    state_q <= ST_IDLE;
                end
            end

            if (product_valid_q) begin
                out_valid <= 1'b1;
                out_group <= product_group_q;
                out_last <= product_last_q;
                for (seq_lane = 0; seq_lane < 4; seq_lane = seq_lane + 1)
                    out_data[seq_lane*DATA_W +: DATA_W] <= scaled_c[seq_lane];
                if (product_last_q) begin
                    done <= 1'b1;
                    product_valid_q <= 1'b0;
                    state_q <= ST_IDLE;
                end
            end
        end
    end
endmodule
