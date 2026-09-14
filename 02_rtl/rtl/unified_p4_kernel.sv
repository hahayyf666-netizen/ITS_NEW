// Step12E Gate-B engineering-profile unified P4 1-D transform kernel.
//
// This is a new module.  The v3.5-18 wrapper and frozen R4C are intentionally
// not edited.  Gate B uses this direct matrix implementation to establish
// functional, lane, and handshake contracts before any physical optimisation.
// A later implementation may replace the arithmetic with a factorised or
// family-specific reduction fabric without changing this interface contract.
//
// Contract:
//   * N = 4/8/16/32 for DCT2, DST7, DCT8; N = 64 for DCT2.
//   * input accepts one complete signed 16-bit sample per cycle.
//   * output presents four consecutive transform outputs per group.
//   * group order is raster/output-index order and group II is one when
//     out_req remains asserted.
//   * stage_sel=0 uses the VTM-profile first-stage shift 7 (+64), while
//     stage_sel=1 uses the second-stage shift 10 (+512).
//   * output-valid is intentionally gated by out_req to match the contest
//     interface; out_data remains stable while out_req is low.
//   * reset is asynchronous active-low.

module unified_p4_kernel #(
    parameter int DATA_W     = 16,
    parameter int COEFF_W    = 16,
    parameter int ACC_W      = 40,
    parameter int MAX_N      = 64,
    parameter int COEFF_DEPTH = 8176,
    parameter string COEFF_FILE = "03_verification/sim/rom_coeffs.hex"
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start,
    input  logic [1:0]                   tr_type,
    input  logic [6:0]                   transform_size,
    input  logic                         stage_sel,
    input  logic                         in_valid,
    output logic                         in_req,
    input  logic signed [DATA_W-1:0]     in_data,
    output logic                         out_valid,
    input  logic                         out_req,
    output logic signed [(4*DATA_W)-1:0] out_data,
    output logic                         done,
    output logic                         busy,
    output logic                         error
);

    typedef enum logic [1:0] {S_IDLE, S_LOAD, S_OUTPUT} state_t;
    state_t state_q;

    logic [1:0] tr_type_q;
    logic [6:0] size_q;
    logic       stage_sel_q;
    logic [6:0] load_index_q;
    logic [4:0] group_q;

    logic signed [DATA_W-1:0]  input_q [0:MAX_N-1];
    logic signed [COEFF_W-1:0] coeff_mem [0:COEFF_DEPTH-1];

    integer lane_i;
    integer input_i;
    integer coeff_index_i;
    logic signed [ACC_W-1:0] accum_c [0:3];
    logic signed [DATA_W-1:0] scaled_c [0:3];

    initial begin
        $readmemh(COEFF_FILE, coeff_mem);
    end

    function automatic integer rom_base(input logic [1:0] type_i,
                                         input logic [6:0] n_i);
        begin
            rom_base = -1;
            case ({type_i, n_i})
                {2'd0, 7'd4}:  rom_base = 0;
                {2'd0, 7'd8}:  rom_base = 16;
                {2'd0, 7'd16}: rom_base = 80;
                {2'd0, 7'd32}: rom_base = 336;
                {2'd0, 7'd64}: rom_base = 1360;
                {2'd1, 7'd4}:  rom_base = 5456;
                {2'd1, 7'd8}:  rom_base = 5472;
                {2'd1, 7'd16}: rom_base = 5536;
                {2'd1, 7'd32}: rom_base = 5792;
                {2'd2, 7'd4}:  rom_base = 6816;
                {2'd2, 7'd8}:  rom_base = 6832;
                {2'd2, 7'd16}: rom_base = 6896;
                {2'd2, 7'd32}: rom_base = 7152;
                default:       rom_base = -1;
            endcase
        end
    endfunction

    function automatic logic valid_config(input logic [1:0] type_i,
                                           input logic [6:0] n_i);
        begin
            valid_config = 1'b0;
            if ((n_i == 7'd4) || (n_i == 7'd8) ||
                (n_i == 7'd16) || (n_i == 7'd32)) begin
                valid_config = (type_i <= 2'd2);
            end else if (n_i == 7'd64) begin
                valid_config = (type_i == 2'd0);
            end
        end
    endfunction

    function automatic logic signed [DATA_W-1:0] post_process(
        input logic signed [ACC_W-1:0] raw_i,
        input logic [3:0]              shift_i
    );
        logic signed [ACC_W-1:0] biased;
        logic signed [ACC_W-1:0] shifted;
        begin
            biased  = raw_i + (1 <<< (shift_i - 1));
            shifted = biased >>> shift_i;
            if (shifted > 32767)
                post_process = 16'sh7fff;
            else if (shifted < -32768)
                post_process = 16'sh8000;
            else
                post_process = shifted[DATA_W-1:0];
        end
    endfunction

    // Direct P4 arithmetic reference.  This intentionally exposes the full
    // coefficient/lane mapping for Gate B; reduction sharing is a later
    // physical implementation decision.
    always_comb begin
        for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
            accum_c[lane_i] = '0;
            if (valid_config(tr_type_q, size_q) &&
                ((group_q * 4 + lane_i) < size_q)) begin
                for (input_i = 0; input_i < MAX_N; input_i = input_i + 1) begin
                    if (input_i < size_q) begin
                        coeff_index_i = rom_base(tr_type_q, size_q) +
                                        ((group_q * 4 + lane_i) * size_q) + input_i;
                        accum_c[lane_i] = accum_c[lane_i] +
                            ($signed(coeff_mem[coeff_index_i]) * $signed(input_q[input_i]));
                    end
                end
            end
            scaled_c[lane_i] = post_process(accum_c[lane_i], stage_sel_q ? 4'd10 : 4'd7);
        end
    end

    always_comb begin
        in_req  = (state_q == S_LOAD);
        busy    = (state_q != S_IDLE);
        // Contest protocol: external valid is not asserted unless request is
        // high.  The held output data itself is independent of out_req.
        out_valid = (state_q == S_OUTPUT) && out_req;
        out_data  = '0;
        for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1)
            out_data[lane_i*DATA_W +: DATA_W] = scaled_c[lane_i];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q      <= S_IDLE;
            tr_type_q    <= '0;
            size_q       <= '0;
            stage_sel_q  <= 1'b0;
            load_index_q <= '0;
            group_q      <= '0;
            done         <= 1'b0;
            error        <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state_q)
                S_IDLE: begin
                    if (start) begin
                        if (valid_config(tr_type, transform_size)) begin
                            tr_type_q    <= tr_type;
                            size_q       <= transform_size;
                            stage_sel_q  <= stage_sel;
                            load_index_q <= '0;
                            group_q      <= '0;
                            state_q      <= S_LOAD;
                        end else begin
                            error <= 1'b1;
                        end
                    end
                end

                S_LOAD: begin
                    if (in_valid && in_req) begin
                        input_q[load_index_q] <= in_data;
                        if (load_index_q == (size_q - 1'b1)) begin
                            load_index_q <= '0;
                            group_q      <= '0;
                            state_q      <= S_OUTPUT;
                        end else begin
                            load_index_q <= load_index_q + 1'b1;
                        end
                    end
                end

                S_OUTPUT: begin
                    if (out_valid && out_req) begin
                        if (group_q == ((size_q >> 2) - 1'b1)) begin
                            state_q <= S_IDLE;
                            done    <= 1'b1;
                        end else begin
                            group_q <= group_q + 1'b1;
                        end
                    end
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule
