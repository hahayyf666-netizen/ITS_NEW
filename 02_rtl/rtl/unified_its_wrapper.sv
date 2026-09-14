// Step12E unified engineering-profile functional wrapper.
//
// This is a new functional reference implementation.  It deliberately lives
// beside, rather than inside, the frozen v3.5-18 wrapper/R4C.  The arithmetic
// is expressed directly from the hash-fixed coefficient ROM so that Gate C
// can exercise all supported rectangles, transform families, sparse raster
// input, LFNST, two-slot ownership, and output backpressure before a physical
// P4 implementation is selected.
//
// It is not a 500 MHz implementation claim.  The direct matrix loops are a
// verification baseline; synthesis/physical optimisation is a later step.

module unified_its_wrapper #(
    parameter integer DATA_W = 16,
    parameter integer OUT_W  = 10,
    parameter integer MAX_POINTS = 4096,
    parameter integer COEFF_DEPTH = 8176,
    parameter integer LFNST_DEPTH = 8192,
    parameter integer FINAL_SATURATE = 0,
    parameter string COEFF_FILE = "03_verification/sim/rom_coeffs.hex",
    parameter string LFNST_FILE = "03_verification/sim/lfnst_coeffs.hex"
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic [21:0]                  it_info,
    input  logic                         it_info_vld,
    input  logic signed [DATA_W-1:0]     it_data_in,
    input  logic [11:0]                  it_data_addr,
    input  logic                         it_data_in_vld,
    input  logic                         it_data_end,
    output logic                         it_data_in_req,
    input  logic                         it_data_out_req,
    output logic [39:0]                  it_data_out,
    output logic                         it_data_out_vld,
    output logic                         it_done,
    output logic                         protocol_error
);

    localparam logic [1:0] SLOT_FREE  = 2'd0;
    localparam logic [1:0] SLOT_FILL  = 2'd1;
    localparam logic [1:0] SLOT_READY = 2'd2;
    localparam logic [1:0] SLOT_OUT   = 2'd3;

    logic signed [15:0] coeff_mem [0:COEFF_DEPTH-1];
    logic signed [15:0] lfnst_mem [0:LFNST_DEPTH-1];
    initial begin
        $readmemh(COEFF_FILE, coeff_mem);
        $readmemh(LFNST_FILE, lfnst_mem);
    end

    // Two independent ownership slots.  Input memory is cleared when a slot
    // is bound, not by asynchronous reset; this preserves the RAM-friendly
    // reset contract and makes omitted sparse addresses deterministic zero.
    logic signed [DATA_W-1:0] input_mem [0:1][0:MAX_POINTS-1];
    logic signed [OUT_W-1:0]  result_mem[0:1][0:MAX_POINTS-1];
    logic [1:0] slot_state [0:1];
    logic [6:0] slot_width [0:1];
    logic [6:0] slot_height[0:1];
    logic [1:0] slot_hor   [0:1];
    logic [1:0] slot_ver   [0:1];
    logic [1:0] slot_set   [0:1];
    logic [1:0] slot_lfnst [0:1];

    // Descriptor FIFO.  It may queue two descriptors, while fill_slot is the
    // only active data owner because the data interface has no TU identifier.
    logic [21:0] desc_mem [0:1];
    logic [1:0]  desc_rd_ptr, desc_wr_ptr;
    logic [1:0]  desc_count;
    logic        fill_active;
    logic        fill_slot;

    logic        output_active;
    logic        output_slot;
    logic [11:0] output_index;

    logic        descriptor_shape_ok;
    logic        descriptor_legal;
    logic        desc_push;
    logic        bind_event;
    logic        bind_slot;
    logic        compute_valid;
    logic        compute_slot;
    logic        output_fire;
    logic        output_last_fire;
    wire         input_fire;
    wire         input_end_fire;

    function automatic logic shape_supported(input logic [6:0] w,
                                             input logic [6:0] h);
        begin
            shape_supported = 1'b0;
            case ({w, h})
                {7'd4,7'd4}, {7'd4,7'd8}, {7'd4,7'd16}, {7'd4,7'd32}, {7'd4,7'd64},
                {7'd8,7'd4}, {7'd16,7'd4}, {7'd32,7'd4}, {7'd64,7'd4},
                {7'd8,7'd8}, {7'd8,7'd16}, {7'd8,7'd32}, {7'd8,7'd64},
                {7'd16,7'd8}, {7'd32,7'd8}, {7'd64,7'd8}, {7'd16,7'd16},
                {7'd16,7'd32}, {7'd16,7'd64}, {7'd32,7'd16}, {7'd32,7'd32},
                {7'd32,7'd64}, {7'd64,7'd16}, {7'd64,7'd32}, {7'd64,7'd64}:
                    shape_supported = 1'b1;
                default: shape_supported = 1'b0;
            endcase
        end
    endfunction

    function automatic logic axis_supported(input logic [1:0] t,
                                             input logic [6:0] n);
        begin
            axis_supported = ((t <= 2'd2) &&
                              ((n == 7'd4) || (n == 7'd8) ||
                               (n == 7'd16) || (n == 7'd32) ||
                               ((n == 7'd64) && (t == 2'd0))));
        end
    endfunction

    function automatic logic lfnst_shape_supported(input logic [6:0] w,
                                                    input logic [6:0] h);
        begin
            lfnst_shape_supported = ((w == 7'd4) || (w == 7'd8) ||
                                     (w == 7'd16) || (w == 7'd32) || (w == 7'd64)) &&
                                    ((h == 7'd4) || (h == 7'd8) ||
                                     (h == 7'd16) || (h == 7'd32) || (h == 7'd64));
        end
    endfunction

    always_comb begin
        descriptor_shape_ok = shape_supported(it_info[6:0], it_info[13:7]);
        descriptor_legal = descriptor_shape_ok &&
                           axis_supported(it_info[15:14], it_info[6:0]) &&
                           axis_supported(it_info[17:16], it_info[13:7]) &&
                           (it_info[19:18] <= 2'd3);
        if (it_info[21:20] != 2'd0)
            descriptor_legal = descriptor_legal &&
                               (it_info[15:14] == 2'd0) &&
                               (it_info[17:16] == 2'd0) &&
                               lfnst_shape_supported(it_info[6:0], it_info[13:7]) &&
                               ((it_info[21:20] == 2'd1) ||
                                (it_info[21:20] == 2'd2));
    end

    // A full descriptor queue may accept a new item on the same edge that its
    // head binds to a free slot.  Invalid/full attempts are reported rather
    // than silently discarded.
    always_comb begin
        bind_event = 1'b0;
        bind_slot = 1'b0;
        if (!fill_active && (desc_count != 2'd0)) begin
            if (slot_state[0] == SLOT_FREE) begin
                bind_event = 1'b1;
                bind_slot = 1'b0;
            end else if (slot_state[1] == SLOT_FREE) begin
                bind_event = 1'b1;
                bind_slot = 1'b1;
            end
        end
        desc_push = it_info_vld && descriptor_legal &&
                    ((desc_count < 2'd2) || bind_event);
    end

    assign it_data_in_req = fill_active;
    assign input_fire = fill_active && it_data_in_vld && it_data_in_req;
    // The end marker is an independent input transaction: it may accompany a
    // final nonzero data word or arrive on its own after the sparse words.
    assign input_end_fire = fill_active && it_data_in_req && it_data_end;

    function automatic integer coeff_base(input logic [1:0] t,
                                          input logic [6:0] n);
        begin
            case ({t,n})
                {2'd0,7'd4}:  coeff_base = 0;
                {2'd0,7'd8}:  coeff_base = 16;
                {2'd0,7'd16}: coeff_base = 80;
                {2'd0,7'd32}: coeff_base = 336;
                {2'd0,7'd64}: coeff_base = 1360;
                {2'd1,7'd4}:  coeff_base = 5456;
                {2'd1,7'd8}:  coeff_base = 5472;
                {2'd1,7'd16}: coeff_base = 5536;
                {2'd1,7'd32}: coeff_base = 5792;
                {2'd2,7'd4}:  coeff_base = 6816;
                {2'd2,7'd8}:  coeff_base = 6832;
                {2'd2,7'd16}: coeff_base = 6896;
                {2'd2,7'd32}: coeff_base = 7152;
                default:      coeff_base = 0;
            endcase
        end
    endfunction

    function automatic integer lfnst_base(input integer ntrs,
                                           input logic [1:0] set_i,
                                           input logic [1:0] idx_i);
        integer idx_m1;
        begin
            idx_m1 = idx_i - 1;
            if (ntrs == 16)
                lfnst_base = set_i * 512 + (idx_m1 & 1) * 256;
            else
                lfnst_base = 2048 + set_i * 768 + (idx_m1 & 1) * 384;
        end
    endfunction

    function automatic integer scan_row(input integer index_i,
                                        input integer side_i);
        integer diagonal, row_i, col_i, count_i;
        begin
            scan_row = 0;
            count_i = 0;
            for (diagonal = 0; diagonal < 2*side_i-1; diagonal = diagonal + 1)
                for (row_i = 0; row_i < side_i; row_i = row_i + 1) begin
                    col_i = diagonal - row_i;
                    if ((col_i >= 0) && (col_i < side_i)) begin
                        if (count_i == index_i)
                            scan_row = ((diagonal & 1) != 0) ?
                                       (diagonal - col_i) : row_i;
                        count_i = count_i + 1;
                    end
                end
        end
    endfunction

    function automatic integer scan_col(input integer index_i,
                                        input integer side_i);
        integer diagonal, row_i, col_i, count_i;
        begin
            scan_col = 0;
            count_i = 0;
            for (diagonal = 0; diagonal < 2*side_i-1; diagonal = diagonal + 1)
                for (row_i = 0; row_i < side_i; row_i = row_i + 1) begin
                    col_i = diagonal - row_i;
                    if ((col_i >= 0) && (col_i < side_i)) begin
                        if (count_i == index_i)
                            scan_col = ((diagonal & 1) != 0) ?
                                       (diagonal - scan_row(index_i, side_i)) : col_i;
                        count_i = count_i + 1;
                    end
                end
        end
    endfunction

    function automatic signed [15:0] vtm_round_clip(
        input longint signed raw_i,
        input integer shift_i,
        input integer lo_i,
        input integer hi_i);
        longint signed value_i;
        begin
            value_i = (raw_i + (64'sd1 <<< (shift_i - 1))) >>> shift_i;
            if (value_i > hi_i)
                vtm_round_clip = 16'sh7fff;
            else if (value_i < lo_i)
                vtm_round_clip = 16'sh8000;
            else
                vtm_round_clip = value_i[15:0];
        end
    endfunction

    function automatic signed [9:0] final_adapter(input signed [15:0] wide_i);
        integer signed value_i;
        begin
            value_i = wide_i;
            if (FINAL_SATURATE != 0) begin
                if (value_i > 511)
                    final_adapter = 10'sd511;
                else if (value_i < -512)
                    final_adapter = -10'sd512;
                else
                    final_adapter = value_i[9:0];
            end else begin
                final_adapter = value_i[9:0];
            end
        end
    endfunction

    // Direct profile-compliant 2-D reference calculation.  This is purposely
    // a verification baseline; the Gate-B P4 kernel is the later replacement
    // point for a physically scheduled implementation.
    logic signed [15:0] work_calc [0:MAX_POINTS-1];
    logic signed [15:0] tmp_calc  [0:MAX_POINTS-1];
    logic signed [15:0] wide_calc [0:MAX_POINTS-1];
    logic signed [9:0]  output_calc[0:MAX_POINTS-1];
    logic signed [15:0] lfnst_calc[0:47];
    integer calc_i, calc_j, calc_k;
    integer calc_w, calc_h, calc_cut_w, calc_cut_h, calc_side, calc_ntrs;
    integer calc_skip_w, calc_skip_h, calc_base, calc_raw;
    integer calc_row, calc_col, calc_out, calc_scan_r, calc_scan_c;

    always_comb begin
        for (calc_i = 0; calc_i < MAX_POINTS; calc_i = calc_i + 1) begin
            work_calc[calc_i] = 16'sd0;
            tmp_calc[calc_i] = 16'sd0;
            wide_calc[calc_i] = 16'sd0;
            output_calc[calc_i] = 10'sd0;
        end
        for (calc_i = 0; calc_i < 48; calc_i = calc_i + 1)
            lfnst_calc[calc_i] = 16'sd0;

        calc_w = slot_width[compute_slot];
        calc_h = slot_height[compute_slot];
        for (calc_i = 0; calc_i < MAX_POINTS; calc_i = calc_i + 1)
            if (calc_i < calc_w * calc_h)
                work_calc[calc_i] = input_mem[compute_slot][calc_i];

        calc_ntrs = 0;
        calc_side = 4;
        if (slot_lfnst[compute_slot] != 2'd0) begin
            calc_ntrs = ((calc_w == 4) || (calc_h == 4)) ? 16 : 48;
            calc_side = (calc_ntrs == 16) ? 4 : 8;
            for (calc_out = 0; calc_out < calc_ntrs; calc_out = calc_out + 1) begin
                calc_raw = 0;
                for (calc_j = 0; calc_j < 16; calc_j = calc_j + 1) begin
                    calc_scan_r = scan_row(calc_j, calc_side);
                    calc_scan_c = scan_col(calc_j, calc_side);
                    if ((calc_scan_r < calc_h) && (calc_scan_c < calc_w))
                        calc_raw = calc_raw +
                                   $signed(lfnst_mem[lfnst_base(calc_ntrs,
                                                       slot_set[compute_slot],
                                                       slot_lfnst[compute_slot]) +
                                                       calc_out*16 + calc_j]) *
                                   $signed(work_calc[calc_scan_r*calc_w + calc_scan_c]);
                end
                lfnst_calc[calc_out] = vtm_round_clip(calc_raw, 7, -32768, 32767);
            end
            for (calc_out = 0; calc_out < calc_ntrs; calc_out = calc_out + 1) begin
                calc_scan_r = scan_row(calc_out, calc_side);
                calc_scan_c = scan_col(calc_out, calc_side);
                if ((calc_scan_r < calc_h) && (calc_scan_c < calc_w))
                    work_calc[calc_scan_r*calc_w + calc_scan_c] = lfnst_calc[calc_out];
            end
        end

        if (slot_hor[compute_slot] != 2'd0 && calc_w == 32)
            calc_skip_w = 16;
        else
            calc_skip_w = (calc_w > 32) ? calc_w - 32 : 0;
        if (slot_ver[compute_slot] != 2'd0 && calc_h == 32)
            calc_skip_h = 16;
        else
            calc_skip_h = (calc_h > 32) ? calc_h - 32 : 0;
        if (slot_lfnst[compute_slot] != 2'd0) begin
            if (((calc_w == 4) && (calc_h > 4)) ||
                ((calc_h == 4) && (calc_w > 4))) begin
                calc_skip_w = calc_w - 4;
                calc_skip_h = calc_h - 4;
            end else if ((calc_w >= 8) && (calc_h >= 8)) begin
                calc_skip_w = calc_w - 8;
                calc_skip_h = calc_h - 8;
            end
        end
        calc_cut_w = calc_w - calc_skip_w;
        calc_cut_h = calc_h - calc_skip_h;

        calc_base = coeff_base(slot_ver[compute_slot], calc_h);
        for (calc_col = 0; calc_col < calc_cut_w; calc_col = calc_col + 1)
            for (calc_row = 0; calc_row < calc_cut_h; calc_row = calc_row + 1) begin
                calc_raw = 0;
                for (calc_k = 0; calc_k < calc_cut_h; calc_k = calc_k + 1)
                    calc_raw = calc_raw +
                               $signed(coeff_mem[calc_base + calc_row*calc_h + calc_k]) *
                               $signed(work_calc[calc_k*calc_w + calc_col]);
                tmp_calc[calc_row*calc_w + calc_col] =
                    vtm_round_clip(calc_raw, 7, -32768, 32767);
            end

        calc_base = coeff_base(slot_hor[compute_slot], calc_w);
        for (calc_row = 0; calc_row < calc_h; calc_row = calc_row + 1)
            for (calc_col = 0; calc_col < calc_w; calc_col = calc_col + 1) begin
                calc_raw = 0;
                for (calc_k = 0; calc_k < calc_cut_w; calc_k = calc_k + 1)
                    calc_raw = calc_raw +
                               $signed(coeff_mem[calc_base + calc_col*calc_w + calc_k]) *
                               $signed(tmp_calc[calc_row*calc_w + calc_k]);
                wide_calc[calc_row*calc_w + calc_col] =
                    vtm_round_clip(calc_raw, 10, -32768, 32767);
                output_calc[calc_row*calc_w + calc_col] =
                    final_adapter(wide_calc[calc_row*calc_w + calc_col]);
            end
    end

    always_comb begin
        compute_valid = 1'b0;
        compute_slot = 1'b0;
        if (!output_active) begin
            if (slot_state[0] == SLOT_READY) begin
                compute_valid = 1'b1;
                compute_slot = 1'b0;
            end else if (slot_state[1] == SLOT_READY) begin
                compute_valid = 1'b1;
                compute_slot = 1'b1;
            end
        end
    end

    always_comb begin
        it_data_out = 40'd0;
        if (output_active) begin
            it_data_out[9:0]   = result_mem[output_slot][output_index*4 + 0];
            it_data_out[19:10] = result_mem[output_slot][output_index*4 + 1];
            it_data_out[29:20] = result_mem[output_slot][output_index*4 + 2];
            it_data_out[39:30] = result_mem[output_slot][output_index*4 + 3];
        end
        // The contest contract gates the external valid by request.  The
        // held data/index itself does not move during a request-low stall.
        it_data_out_vld = output_active && it_data_out_req;
        output_fire = output_active && it_data_out_req;
        output_last_fire = output_fire &&
                           (output_index == ((slot_width[output_slot] *
                                              slot_height[output_slot]) / 4 - 1));
        it_done = output_last_fire;
    end

    integer reset_i, clear_i, result_i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            desc_rd_ptr   <= 2'd0;
            desc_wr_ptr   <= 2'd0;
            desc_count    <= 2'd0;
            fill_active   <= 1'b0;
            fill_slot     <= 1'b0;
            output_active <= 1'b0;
            output_slot   <= 1'b0;
            output_index  <= 12'd0;
            protocol_error <= 1'b0;
            for (reset_i = 0; reset_i < 2; reset_i = reset_i + 1) begin
                slot_state[reset_i]  <= SLOT_FREE;
                slot_width[reset_i]  <= 7'd0;
                slot_height[reset_i] <= 7'd0;
                slot_hor[reset_i]    <= 2'd0;
                slot_ver[reset_i]    <= 2'd0;
                slot_set[reset_i]    <= 2'd0;
                slot_lfnst[reset_i]  <= 2'd0;
            end
        end else begin
            if (it_info_vld && !descriptor_legal)
                protocol_error <= 1'b1;
            if (it_info_vld && (desc_count == 2'd2) && !bind_event)
                protocol_error <= 1'b1;
            if (input_fire && (it_data_addr >=
                               (slot_width[fill_slot] * slot_height[fill_slot])))
                protocol_error <= 1'b1;

            if (desc_push) begin
                desc_mem[desc_wr_ptr] <= it_info;
                desc_wr_ptr <= ~desc_wr_ptr;
            end
            if (bind_event) begin
                slot_state[bind_slot]  <= SLOT_FILL;
                slot_width[bind_slot]  <= desc_mem[desc_rd_ptr][6:0];
                slot_height[bind_slot] <= desc_mem[desc_rd_ptr][13:7];
                slot_hor[bind_slot]    <= desc_mem[desc_rd_ptr][15:14];
                slot_ver[bind_slot]    <= desc_mem[desc_rd_ptr][17:16];
                slot_set[bind_slot]    <= desc_mem[desc_rd_ptr][19:18];
                slot_lfnst[bind_slot]  <= desc_mem[desc_rd_ptr][21:20];
                desc_rd_ptr <= ~desc_rd_ptr;
                fill_active <= 1'b1;
                fill_slot   <= bind_slot;
                // Startup slot clear is a simulation-safe sparse-memory
                // initialisation boundary, not an asynchronous RAM reset.
                for (clear_i = 0; clear_i < MAX_POINTS; clear_i = clear_i + 1)
                    input_mem[bind_slot][clear_i] <= '0;
            end

            case ({desc_push, bind_event})
                2'b10: desc_count <= desc_count + 2'd1;
                2'b01: desc_count <= desc_count - 2'd1;
                default: desc_count <= desc_count;
            endcase

            if (input_fire) begin
                input_mem[fill_slot][it_data_addr] <= it_data_in;
            end
            if (input_end_fire) begin
                slot_state[fill_slot] <= SLOT_READY;
                fill_active <= 1'b0;
            end

            if (compute_valid) begin
                slot_state[compute_slot] <= SLOT_OUT;
                output_active <= 1'b1;
                output_slot   <= compute_slot;
                output_index  <= 12'd0;
                for (result_i = 0; result_i < MAX_POINTS; result_i = result_i + 1)
                    if (result_i < slot_width[compute_slot] * slot_height[compute_slot])
                        result_mem[compute_slot][result_i] <= output_calc[result_i];
            end else if (output_fire) begin
                if (output_last_fire) begin
                    slot_state[output_slot] <= SLOT_FREE;
                    output_active <= 1'b0;
                    output_index <= 12'd0;
                end else begin
                    output_index <= output_index + 12'd1;
                end
            end
        end
    end

endmodule
