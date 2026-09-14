// Step12E unified engineering-profile functional wrapper.
//
// This is a new functional engineering implementation.  It deliberately
// lives beside, rather than inside, the frozen v3.5-18 wrapper/R4C.  LFNST
// cases use the bounded LFNST engine followed by the integrated four-slot P4
// kernel, while LFNST-off primary cases use the P4 kernel directly.  The
// wrapper still exposes the descriptor, sparse-raster, ownership and output
// protocol contracts needed by Gate C before physical implementation.
//
// It is not a 500 MHz implementation claim.  Synthesis/physical optimisation
// is a later step for this new unified path.

module unified_its_wrapper #(
    parameter integer DATA_W = 16,
    parameter integer OUT_W  = 10,
    parameter integer MAX_POINTS = 4096,
    parameter integer COEFF_DEPTH = 8176,
    parameter integer LFNST_DEPTH = 8192,
    parameter integer FINAL_SATURATE = 0,
    parameter string COEFF_FILE = "03_verification/sim/rom_coeffs.hex",
    parameter string LFNST_FILE = "03_verification/sim/lfnst_coeffs.hex",
    parameter string LFNST_PACKED_FILE = "03_verification/sim/lfnst_packed_coeffs.hex"
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

    localparam logic [2:0] SLOT_FREE  = 3'd0;
    localparam logic [2:0] SLOT_FILL  = 3'd1;
    localparam logic [2:0] SLOT_READY = 3'd2;
    localparam logic [2:0] SLOT_OUT   = 3'd3;
    localparam logic [2:0] SLOT_SCRUB = 3'd4;
    localparam integer INPUT_VALID_WORDS = MAX_POINTS / 4;
    localparam integer BANK_DEPTH = (MAX_POINTS + 3) / 4;
    localparam integer BANK_ADDR_W = (BANK_DEPTH <= 1) ? 1 : $clog2(BANK_DEPTH);

    // Two independent ownership slots.  Logical raster addresses are mapped
    // to four fixed physical banks.  Each bank has one explicit write port;
    // validity is scrubbed independently of stale data, so no 4096-entry
    // reset or multi-address memory assignment remains in the wrapper.
    logic [BANK_ADDR_W-1:0] input_rd_addr [0:1][0:3];
    logic signed [DATA_W-1:0] input_rd_data [0:1][0:3];
    logic input_rd_valid [0:1][0:3];
    logic input_data_wr_en [0:1][0:3];
    logic [BANK_ADDR_W-1:0] input_data_wr_addr [0:1][0:3];
    logic [DATA_W-1:0] input_data_wr_data [0:1][0:3];
    logic input_valid_wr_en [0:1][0:3];
    logic [BANK_ADDR_W-1:0] input_valid_wr_addr [0:1][0:3];
    logic input_valid_wr_data [0:1][0:3];

    logic [BANK_ADDR_W-1:0] result_rd_addr [0:1][0:3];
    logic signed [OUT_W-1:0] result_rd_data [0:1][0:3];
    logic result_wr_en [0:1][0:3];
    logic [BANK_ADDR_W-1:0] result_wr_addr [0:1][0:3];
    logic [OUT_W-1:0] result_wr_data [0:1][0:3];

    logic [BANK_ADDR_W-1:0] tmp_rd_addr [0:3];
    logic signed [15:0] tmp_rd_data [0:3];
    logic tmp_wr_en [0:3];
    logic [BANK_ADDR_W-1:0] tmp_wr_addr [0:3];
    logic signed [15:0] tmp_wr_data [0:3];

    genvar mem_slot_g, mem_bank_g;
    generate
        for (mem_slot_g = 0; mem_slot_g < 2; mem_slot_g = mem_slot_g + 1) begin : gen_input_slots
            for (mem_bank_g = 0; mem_bank_g < 4; mem_bank_g = mem_bank_g + 1) begin : gen_input_banks
                its_input_cache_bank #(
                    .DATA_W(DATA_W), .DEPTH(BANK_DEPTH), .ADDR_W(BANK_ADDR_W)
                ) u_input_cache_bank (
                    .clk(clk),
                    .data_wr_en(input_data_wr_en[mem_slot_g][mem_bank_g]),
                    .data_wr_addr(input_data_wr_addr[mem_slot_g][mem_bank_g]),
                    .data_wr_data(input_data_wr_data[mem_slot_g][mem_bank_g]),
                    .valid_wr_en(input_valid_wr_en[mem_slot_g][mem_bank_g]),
                    .valid_wr_addr(input_valid_wr_addr[mem_slot_g][mem_bank_g]),
                    .valid_wr_data(input_valid_wr_data[mem_slot_g][mem_bank_g]),
                    .rd_addr(input_rd_addr[mem_slot_g][mem_bank_g]),
                    .rd_data(input_rd_data[mem_slot_g][mem_bank_g]),
                    .rd_valid(input_rd_valid[mem_slot_g][mem_bank_g])
                );
            end
        end
    endgenerate

    generate
        for (mem_slot_g = 0; mem_slot_g < 2; mem_slot_g = mem_slot_g + 1) begin : gen_result_slots
            for (mem_bank_g = 0; mem_bank_g < 4; mem_bank_g = mem_bank_g + 1) begin : gen_result_banks
                its_simple_ram #(
                    .DATA_W(OUT_W), .DEPTH(BANK_DEPTH), .ADDR_W(BANK_ADDR_W)
                ) u_result_bank (
                    .clk(clk),
                    .wr_en(result_wr_en[mem_slot_g][mem_bank_g]),
                    .wr_addr(result_wr_addr[mem_slot_g][mem_bank_g]),
                    .wr_data(result_wr_data[mem_slot_g][mem_bank_g]),
                    .rd_addr(result_rd_addr[mem_slot_g][mem_bank_g]),
                    .rd_data(result_rd_data[mem_slot_g][mem_bank_g])
                );
            end
        end
    endgenerate

    genvar tmp_bank_g;
    generate
        for (tmp_bank_g = 0; tmp_bank_g < 4; tmp_bank_g = tmp_bank_g + 1) begin : gen_tmp_banks
            its_simple_ram #(
                .DATA_W(16), .DEPTH(BANK_DEPTH), .ADDR_W(BANK_ADDR_W)
            ) u_kernel_tmp_bank (
                .clk(clk),
                .wr_en(tmp_wr_en[tmp_bank_g]),
                .wr_addr(tmp_wr_addr[tmp_bank_g]),
                .wr_data(tmp_wr_data[tmp_bank_g]),
                .rd_addr(tmp_rd_addr[tmp_bank_g]),
                .rd_data(tmp_rd_data[tmp_bank_g])
            );
        end
    endgenerate
    logic [2:0] slot_state [0:1];
    logic [6:0] slot_width [0:1];
    logic [6:0] slot_height[0:1];
    logic [1:0] slot_hor   [0:1];
    logic [1:0] slot_ver   [0:1];
    logic [1:0] slot_set   [0:1];
    logic [1:0] slot_lfnst [0:1];

    // Descriptor FIFO.  It may queue two descriptors, while fill_slot is the
    // only active data owner because the data interface has no TU identifier.
    logic [21:0] desc_mem [0:1];
    logic        desc_rd_ptr, desc_wr_ptr;
    logic [1:0]  desc_count;
    logic        fill_active;
    logic        fill_slot;
    logic        scrub_active;
    logic        scrub_slot;
    logic [11:0] scrub_index;

    logic        output_active;
    logic        output_slot;
    logic [11:0] output_index;

    // Gate-B unified P4 kernel integration.  LFNST-enabled cases first use the
    // bounded engine above and then reuse this kernel for the DCT2 passes;
    // LFNST-off primary transforms use this kernel directly.
    logic        compute_slot_q;
    logic        kernel_run_q;
    typedef enum logic [2:0] {K_IDLE, K_V_START, K_V_FEED, K_V_DRAIN,
                              K_H_START, K_H_FEED, K_H_DRAIN} kernel_phase_t;
    kernel_phase_t kernel_phase_q;
    logic [6:0] kernel_w_q, kernel_h_q, kernel_cut_w_q, kernel_cut_h_q;
    logic [6:0] kernel_vector_q;
    logic [4:0] kernel_group_q;
    logic [1:0] kernel_type_q;
    logic       kernel_stage_q;
    logic       kernel_start;
    logic       kernel_in_valid;
    logic       kernel_in_req;
    logic signed [63:0] kernel_in_data;
    logic       kernel_out_valid;
    logic       kernel_out_req;
    logic signed [63:0] kernel_out_data;
    logic       kernel_done;
    logic       kernel_busy;
    logic       kernel_error;

    logic       lfnst_run_q;
    logic       lfnst_start_q;
    logic       lfnst_slot_q;
    logic       lfnst_ntrs48_q;
    logic       lfnst_nonzero8_q;
    logic [1:0] lfnst_set_q;
    logic [1:0] lfnst_idx_q;
    logic       lfnst_busy;
    logic       lfnst_out_valid;
    logic signed [63:0] lfnst_out_data;
    logic [3:0] lfnst_out_group;
    logic       lfnst_out_last;
    logic       lfnst_done;
    logic       lfnst_error;
    logic       lfnst_case_q;
    logic       lfnst_gather_q;
    logic [4:0] lfnst_gather_index_q;
    logic       lfnst_tail_q;
    logic [4:0] lfnst_tail_index_q;
    logic signed [255:0] lfnst_input_terms_q;
    logic signed [15:0] lfnst_grid [0:63];
    logic               lfnst_grid_valid [0:63];

    unified_p4_kernel #(
        .DATA_W(16), .COEFF_W(16), .ACC_W(40), .MAX_N(64),
        .COEFF_DEPTH(COEFF_DEPTH), .COEFF_FILE(COEFF_FILE)
    ) u_unified_p4_kernel (
        .clk(clk), .rst_n(rst_n), .start(kernel_start),
        .tr_type(kernel_type_q),
        .transform_size(kernel_stage_q ? kernel_w_q : kernel_h_q),
        .active_size(kernel_stage_q ? kernel_cut_w_q : kernel_cut_h_q),
        .output_size(kernel_stage_q ? kernel_w_q : kernel_cut_h_q),
        .stage_sel(kernel_stage_q), .in_valid(kernel_in_valid),
        .in_req(kernel_in_req), .in_data(kernel_in_data),
        .out_valid(kernel_out_valid), .out_req(kernel_out_req),
        .out_data(kernel_out_data), .done(kernel_done),
        .busy(kernel_busy), .error(kernel_error)
    );

    bounded_lfnst_engine #(
        .DATA_W(16), .COEFF_W(16), .ACC_W(40),
        .COEFF_FILE(LFNST_PACKED_FILE)
    ) u_bounded_lfnst_engine (
        .clk(clk), .rst_n(rst_n), .start(lfnst_start_q),
        .set_idx(lfnst_set_q), .lfnst_idx(lfnst_idx_q),
        .ntrs48(lfnst_ntrs48_q), .nonzero8(lfnst_nonzero8_q),
        .input_terms(lfnst_input_terms_q), .busy(lfnst_busy),
        .out_valid(lfnst_out_valid), .out_data(lfnst_out_data),
        .out_group(lfnst_out_group), .out_last(lfnst_out_last),
        .done(lfnst_done), .error(lfnst_error)
    );

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

    function automatic logic [6:0] kernel_cut_dim(input logic [1:0] t,
                                                  input logic [6:0] n);
        begin
            if ((t != 2'd0) && (n == 7'd32))
                kernel_cut_dim = 7'd16;
            else if (n > 7'd32)
                kernel_cut_dim = 7'd32;
            else
                kernel_cut_dim = n;
        end
    endfunction

    function automatic logic [6:0] lfnst_cut_dim(input logic [6:0] n,
                                                  input logic [6:0] other_n);
        begin
            // LFNST operates on a 4x4 or 8x8 low-frequency support region.
            // The shape contract guarantees both dimensions are powers of two
            // in the supported 4..64 range.
            if ((n == 7'd4) || (other_n == 7'd4))
                lfnst_cut_dim = 7'd4;
            else
                lfnst_cut_dim = 7'd8;
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

    function automatic logic [13:0] tu_points(input logic [6:0] w,
                                              input logic [6:0] h);
        logic [13:0] w_ext;
        logic [13:0] h_ext;
        begin
            w_ext = {7'd0, w};
            h_ext = {7'd0, h};
            tu_points = w_ext * h_ext;
        end
    endfunction

    // The bank map is fixed-stride so it is independent of the active TU
    // width.  Four consecutive rows at a given column therefore select four
    // different banks, while the local address remains at most 1023.
    function automatic integer cache_bank_for(input integer row_i,
                                               input integer col_i);
        begin
            cache_bank_for = (row_i & 3) ^ (col_i & 3);
        end
    endfunction

    function automatic integer cache_local_for(input integer row_i,
                                                input integer col_i);
        begin
            cache_local_for = row_i * 16 + (col_i >> 2);
        end
    endfunction

    function automatic integer tmp_bank_for(input integer row_i,
                                             input integer col_i);
        begin
            // Cyclic diagonal banking is conflict-free for both access
            // patterns: V writes four consecutive rows at one column, while H
            // reads four consecutive columns at one row.
            tmp_bank_for = (row_i + col_i) & 3;
        end
    endfunction

    function automatic integer tmp_local_for(input integer row_i,
                                              input integer col_i,
                                              input integer width_i);
        begin
            tmp_local_for = (row_i >> 2) * width_i + col_i;
        end
    endfunction

    function automatic integer raster_row_for(input integer address_i,
                                               input integer width_i);
        begin
            case (width_i)
                7'd4:  raster_row_for = address_i >> 2;
                7'd8:  raster_row_for = address_i >> 3;
                7'd16: raster_row_for = address_i >> 4;
                7'd32: raster_row_for = address_i >> 5;
                7'd64: raster_row_for = address_i >> 6;
                default: raster_row_for = 0;
            endcase
        end
    endfunction

    function automatic integer raster_col_for(input integer address_i,
                                               input integer width_i);
        begin
            case (width_i)
                7'd4:  raster_col_for = address_i & 3;
                7'd8:  raster_col_for = address_i & 7;
                7'd16: raster_col_for = address_i & 15;
                7'd32: raster_col_for = address_i & 31;
                7'd64: raster_col_for = address_i & 63;
                default: raster_col_for = 0;
            endcase
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
        if (!fill_active && !scrub_active && (desc_count != 2'd0)) begin
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

    function automatic integer scan_row(input integer index_i,
                                        input integer side_i);
        integer diagonal, row_lo, row_hi, diagonal_count;
        integer offset_i, count_i;
        begin
            scan_row = 0;
            count_i = 0;
            // side_i is restricted to 4 or 8 by the LFNST contract.  Keep
            // the loop statically bounded for synthesis; the runtime guard
            // preserves the original 2*side_i-1 diagonal traversal.
            for (diagonal = 0; diagonal < 15;
                 diagonal = diagonal + 1) begin
                if (diagonal < 2*side_i-1) begin
                    row_lo = (diagonal < side_i) ? 0 : diagonal - side_i + 1;
                    row_hi = (diagonal < side_i) ? diagonal : side_i - 1;
                    diagonal_count = row_hi - row_lo + 1;
                    if ((index_i >= count_i) &&
                        (index_i < count_i + diagonal_count)) begin
                        offset_i = index_i - count_i;
                        scan_row = ((diagonal & 1) != 0) ?
                                   (row_hi - offset_i) : (row_lo + offset_i);
                    end
                    count_i = count_i + diagonal_count;
                end
            end
        end
    endfunction

    function automatic integer scan_col(input integer index_i,
                                        input integer side_i);
        integer diagonal, row_lo, row_hi, diagonal_count;
        integer offset_i, selected_row, count_i;
        begin
            scan_col = 0;
            count_i = 0;
            // See scan_row above: a static 15-iteration bound avoids a
            // variable loop termination condition in Vivado while retaining
            // the exact diagonal scan for side_i=4 or 8.
            for (diagonal = 0; diagonal < 15;
                 diagonal = diagonal + 1) begin
                if (diagonal < 2*side_i-1) begin
                    row_lo = (diagonal < side_i) ? 0 : diagonal - side_i + 1;
                    row_hi = (diagonal < side_i) ? diagonal : side_i - 1;
                    diagonal_count = row_hi - row_lo + 1;
                    if ((index_i >= count_i) &&
                        (index_i < count_i + diagonal_count)) begin
                        offset_i = index_i - count_i;
                        selected_row = ((diagonal & 1) != 0) ?
                                       (row_hi - offset_i) : (row_lo + offset_i);
                        scan_col = diagonal - selected_row;
                    end
                    count_i = count_i + diagonal_count;
                end
            end
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

    // The unified kernel's vertical results are banked by output lane.  A
    // vertical group writes one word to each bank, and the horizontal group
    // reads the corresponding four bank-local words.
    integer gather_i;
    logic signed [15:0] lfnst_gather_rd_data;
    logic               lfnst_gather_rd_valid;

    // All large-memory reads are issued through fixed bank ports.  LFNST
    // gather deliberately uses one address at a time; the four physical ports
    // are still available, but no 16-way dynamic read mux is inferred.
    always_comb begin : input_read_addr_comb
        integer read_slot_i, read_bank_i, read_row_i, read_col_i, read_local_i;
        for (read_slot_i = 0; read_slot_i < 2; read_slot_i = read_slot_i + 1)
            for (read_bank_i = 0; read_bank_i < 4; read_bank_i = read_bank_i + 1)
                input_rd_addr[read_slot_i][read_bank_i] = '0;

        if (lfnst_gather_q || lfnst_tail_q) begin
            read_row_i = scan_row(lfnst_gather_q ? lfnst_gather_index_q :
                                  (6'd48 + lfnst_tail_index_q),
                                  lfnst_ntrs48_q ? 8 : 4);
            read_col_i = scan_col(lfnst_gather_q ? lfnst_gather_index_q :
                                  (6'd48 + lfnst_tail_index_q),
                                  lfnst_ntrs48_q ? 8 : 4);
            read_local_i = cache_local_for(read_row_i, read_col_i);
            read_bank_i = cache_bank_for(read_row_i, read_col_i);
            if ((read_row_i < slot_height[compute_slot_q]) &&
                (read_col_i < slot_width[compute_slot_q]))
                input_rd_addr[compute_slot_q][read_bank_i] = read_local_i;
        end else if (kernel_run_q && !kernel_stage_q &&
                     !lfnst_case_q && kernel_in_valid) begin
            for (read_bank_i = 0; read_bank_i < 4; read_bank_i = read_bank_i + 1) begin
                read_row_i = kernel_group_q * 4 + read_bank_i;
                read_col_i = kernel_vector_q;
                if (read_row_i < kernel_cut_h_q)
                    input_rd_addr[compute_slot_q][cache_bank_for(read_row_i, read_col_i)] =
                        cache_local_for(read_row_i, read_col_i);
            end
        end
    end

    always_comb begin : lfnst_gather_data_comb
        integer gather_data_row_i, gather_data_col_i, gather_data_bank_i;
        lfnst_gather_rd_data = '0;
        lfnst_gather_rd_valid = 1'b0;
        if (lfnst_gather_q || lfnst_tail_q) begin
            gather_data_row_i = scan_row(lfnst_gather_q ? lfnst_gather_index_q :
                                         (6'd48 + lfnst_tail_index_q),
                                         lfnst_ntrs48_q ? 8 : 4);
            gather_data_col_i = scan_col(lfnst_gather_q ? lfnst_gather_index_q :
                                         (6'd48 + lfnst_tail_index_q),
                                         lfnst_ntrs48_q ? 8 : 4);
            gather_data_bank_i = cache_bank_for(gather_data_row_i,
                                                gather_data_col_i);
            if ((gather_data_row_i < slot_height[compute_slot_q]) &&
                (gather_data_col_i < slot_width[compute_slot_q])) begin
                lfnst_gather_rd_data = input_rd_data[compute_slot_q][gather_data_bank_i];
                lfnst_gather_rd_valid = input_rd_valid[compute_slot_q][gather_data_bank_i];
            end
        end
    end

    always_comb begin
        compute_valid = 1'b0;
        compute_slot = 1'b0;
        // A kernel run owns compute_slot_q and its phase metadata until the
        // horizontal pass has completed.  Do not admit another ready slot
        // while that run is active; otherwise a queued TU would overwrite the
        // in-flight kernel's owner and dimensions.
        if (!output_active && !kernel_run_q && !lfnst_run_q && !scrub_active) begin
            if (slot_state[0] == SLOT_READY) begin
                compute_valid = 1'b1;
                compute_slot = 1'b0;
            end else if (slot_state[1] == SLOT_READY) begin
                compute_valid = 1'b1;
                compute_slot = 1'b1;
            end
        end
    end

    // The wrapper presents one vector as four packed samples per kernel input
    // group.  Metadata and group counters are registered by the kernel; this
    // combinational adapter only selects the current column/row from the
    // already-owned intermediate arrays.
    integer kernel_lane_i;
    integer kernel_sample_index_i;
    always_comb begin
        kernel_start     = (kernel_phase_q == K_V_START) ||
                           (kernel_phase_q == K_H_START);
        kernel_in_valid  = kernel_start ||
                           (kernel_phase_q == K_V_FEED) ||
                           (kernel_phase_q == K_H_FEED);
        kernel_in_data = '0;
        for (kernel_lane_i = 0; kernel_lane_i < 4;
             kernel_lane_i = kernel_lane_i + 1) begin
            kernel_sample_index_i = kernel_group_q * 4 + kernel_lane_i;
            if (kernel_in_valid && !kernel_stage_q) begin
                if (kernel_sample_index_i < kernel_cut_h_q) begin
                    if (lfnst_case_q) begin
                        if ((kernel_sample_index_i < kernel_cut_h_q) &&
                            (kernel_vector_q < kernel_cut_w_q) &&
                            lfnst_grid_valid[kernel_sample_index_i * 8 + kernel_vector_q])
                            kernel_in_data[kernel_lane_i*16 +: 16] =
                                lfnst_grid[kernel_sample_index_i * 8 + kernel_vector_q];
                    end else if (input_rd_valid[compute_slot_q][
                                      cache_bank_for(kernel_sample_index_i,
                                                     kernel_vector_q)])
                        kernel_in_data[kernel_lane_i*16 +: 16] =
                            input_rd_data[compute_slot_q][
                                cache_bank_for(kernel_sample_index_i,
                                               kernel_vector_q)];
                end
            end else if (kernel_in_valid) begin
                if ((kernel_sample_index_i < kernel_cut_w_q) &&
                    (kernel_vector_q < kernel_cut_h_q))
                    kernel_in_data[kernel_lane_i*16 +: 16] =
                        tmp_rd_data[tmp_bank_for(kernel_vector_q,
                                                 kernel_sample_index_i)];
            end
        end
    end

    // The overlapping kernel can become output-active on the same edge that
    // accepts its final input group.  Keep its output held while the wrapper
    // is still in a feed phase; otherwise group 0 would be consumed before
    // the wrapper enters its drain state.  The kernel output remains stable
    // until this drain-qualified request is asserted.
    always_comb begin
        kernel_out_req = kernel_run_q &&
                         ((kernel_phase_q == K_V_DRAIN) ||
                          (kernel_phase_q == K_H_DRAIN));
    end

    always_comb begin
        it_data_out = 40'd0;
        if (output_active) begin
            it_data_out[9:0]   = result_rd_data[output_slot][0];
            it_data_out[19:10] = result_rd_data[output_slot][1];
            it_data_out[29:20] = result_rd_data[output_slot][2];
            it_data_out[39:30] = result_rd_data[output_slot][3];
        end
        // The contest contract gates the external valid by request.  The
        // held data/index itself does not move during a request-low stall.
        it_data_out_vld = output_active && it_data_out_req;
        output_fire = output_active && it_data_out_req;
        output_last_fire = output_fire &&
                           (output_index ==
                            ((tu_points(slot_width[output_slot],
                                        slot_height[output_slot]) >> 2) - 1));
        it_done = output_last_fire;
    end

    // All memory writes are reduced to one fixed command per physical bank.
    // The wrapper may have several logical producers (sparse input, scrub,
    // vertical kernel results, and horizontal output), but ownership/state
    // makes these producers mutually exclusive for a given memory.
    always_comb begin : memory_command_comb
        integer cmd_slot_i, cmd_bank_i;
        integer input_cmd_row_i, input_cmd_col_i, input_cmd_bank_i, input_cmd_local_i;
        for (cmd_slot_i = 0; cmd_slot_i < 2; cmd_slot_i = cmd_slot_i + 1) begin
            for (cmd_bank_i = 0; cmd_bank_i < 4; cmd_bank_i = cmd_bank_i + 1) begin
                input_data_wr_en[cmd_slot_i][cmd_bank_i] = 1'b0;
                input_data_wr_addr[cmd_slot_i][cmd_bank_i] = '0;
                input_data_wr_data[cmd_slot_i][cmd_bank_i] = '0;
                input_valid_wr_en[cmd_slot_i][cmd_bank_i] = 1'b0;
                input_valid_wr_addr[cmd_slot_i][cmd_bank_i] = '0;
                input_valid_wr_data[cmd_slot_i][cmd_bank_i] = 1'b0;
                result_wr_en[cmd_slot_i][cmd_bank_i] = 1'b0;
                result_wr_addr[cmd_slot_i][cmd_bank_i] = '0;
                result_wr_data[cmd_slot_i][cmd_bank_i] = '0;
                result_rd_addr[cmd_slot_i][cmd_bank_i] = output_index;
            end
        end
        for (cmd_bank_i = 0; cmd_bank_i < 4; cmd_bank_i = cmd_bank_i + 1) begin
            tmp_wr_en[cmd_bank_i] = 1'b0;
            tmp_wr_addr[cmd_bank_i] = '0;
            tmp_wr_data[cmd_bank_i] = '0;
            tmp_rd_addr[cmd_bank_i] = '0;
        end

        // Scrubbing clears one local address in all four valid memories per
        // cycle.  It never writes the corresponding data memories.
        if (scrub_active) begin
            for (cmd_bank_i = 0; cmd_bank_i < 4; cmd_bank_i = cmd_bank_i + 1) begin
                input_valid_wr_en[scrub_slot][cmd_bank_i] = 1'b1;
                input_valid_wr_addr[scrub_slot][cmd_bank_i] = scrub_index;
                input_valid_wr_data[scrub_slot][cmd_bank_i] = 1'b0;
            end
        end

        // A sparse input word is mapped once, before it reaches the physical
        // bank.  The command is mutually exclusive with scrub and LFNST.
        if (input_fire) begin
            input_cmd_row_i = raster_row_for(it_data_addr, slot_width[fill_slot]);
            input_cmd_col_i = raster_col_for(it_data_addr, slot_width[fill_slot]);
            input_cmd_bank_i = cache_bank_for(input_cmd_row_i, input_cmd_col_i);
            input_cmd_local_i = cache_local_for(input_cmd_row_i, input_cmd_col_i);
            input_data_wr_en[fill_slot][input_cmd_bank_i] = 1'b1;
            input_data_wr_addr[fill_slot][input_cmd_bank_i] = input_cmd_local_i;
            input_data_wr_data[fill_slot][input_cmd_bank_i] = it_data_in;
            input_valid_wr_en[fill_slot][input_cmd_bank_i] = 1'b1;
            input_valid_wr_addr[fill_slot][input_cmd_bank_i] = input_cmd_local_i;
            input_valid_wr_data[fill_slot][input_cmd_bank_i] = 1'b1;
        end

        // Vertical results are lane-bank-local: one write per bank and cycle.
        if (kernel_run_q && (kernel_phase_q == K_V_DRAIN)) begin
            for (cmd_bank_i = 0; cmd_bank_i < 4; cmd_bank_i = cmd_bank_i + 1) begin
                if (kernel_out_valid &&
                    (kernel_group_q * 4 + cmd_bank_i < kernel_cut_h_q)) begin
                    input_cmd_row_i = kernel_group_q * 4 + cmd_bank_i;
                    input_cmd_col_i = kernel_vector_q;
                    input_cmd_bank_i = tmp_bank_for(input_cmd_row_i, input_cmd_col_i);
                    input_cmd_local_i = tmp_local_for(input_cmd_row_i,
                                                      input_cmd_col_i,
                                                      kernel_w_q);
                    tmp_wr_en[input_cmd_bank_i] = 1'b1;
                    tmp_wr_addr[input_cmd_bank_i] = input_cmd_local_i;
                    tmp_wr_data[input_cmd_bank_i] =
                        $signed(kernel_out_data[cmd_bank_i*16 +: 16]);
                end
            end
        end else if (kernel_run_q && kernel_stage_q && kernel_in_valid) begin
            // Horizontal input group reads the four words written by the
            // corresponding vertical group.
            for (cmd_bank_i = 0; cmd_bank_i < 4; cmd_bank_i = cmd_bank_i + 1) begin
                input_cmd_row_i = kernel_vector_q;
                input_cmd_col_i = kernel_group_q * 4 + cmd_bank_i;
                tmp_rd_addr[tmp_bank_for(input_cmd_row_i, input_cmd_col_i)] =
                    tmp_local_for(input_cmd_row_i, input_cmd_col_i, kernel_w_q);
            end
        end

        if (kernel_run_q && (kernel_phase_q == K_H_DRAIN) && kernel_out_valid) begin
            for (cmd_bank_i = 0; cmd_bank_i < 4; cmd_bank_i = cmd_bank_i + 1) begin
                if (kernel_group_q * 4 + cmd_bank_i < kernel_w_q) begin
                    result_wr_en[compute_slot_q][cmd_bank_i] = 1'b1;
                    result_wr_addr[compute_slot_q][cmd_bank_i] =
                        kernel_vector_q * (kernel_w_q >> 2) + kernel_group_q;
                    result_wr_data[compute_slot_q][cmd_bank_i] =
                        final_adapter($signed(kernel_out_data[cmd_bank_i*16 +: 16]));
                end
            end
        end
    end

    integer reset_i, lfnst_grid_i;
    integer kernel_capture_lane_i;
    integer lfnst_write_addr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            desc_rd_ptr   <= 1'b0;
            desc_wr_ptr   <= 1'b0;
            desc_count    <= 2'd0;
            fill_active   <= 1'b0;
            fill_slot     <= 1'b0;
            scrub_active  <= 1'b0;
            scrub_slot    <= 1'b0;
            scrub_index   <= 12'd0;
            output_active <= 1'b0;
            output_slot   <= 1'b0;
            output_index  <= 12'd0;
            compute_slot_q <= 1'b0;
            kernel_run_q <= 1'b0;
            kernel_phase_q <= K_IDLE;
            kernel_w_q <= 7'd0;
            kernel_h_q <= 7'd0;
            kernel_cut_w_q <= 7'd0;
            kernel_cut_h_q <= 7'd0;
            kernel_vector_q <= 7'd0;
            kernel_group_q <= 5'd0;
            kernel_type_q <= 2'd0;
            kernel_stage_q <= 1'b0;
            lfnst_run_q <= 1'b0;
            lfnst_case_q <= 1'b0;
            lfnst_gather_q <= 1'b0;
            lfnst_gather_index_q <= 5'd0;
            lfnst_tail_q <= 1'b0;
            lfnst_tail_index_q <= 5'd0;
            lfnst_input_terms_q <= '0;
            lfnst_start_q <= 1'b0;
            lfnst_slot_q <= 1'b0;
            lfnst_ntrs48_q <= 1'b0;
            lfnst_nonzero8_q <= 1'b0;
            lfnst_set_q <= 2'd0;
            lfnst_idx_q <= 2'd0;
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
            for (lfnst_grid_i = 0; lfnst_grid_i < 64; lfnst_grid_i = lfnst_grid_i + 1) begin
                lfnst_grid[lfnst_grid_i] <= '0;
                lfnst_grid_valid[lfnst_grid_i] <= 1'b0;
            end
        end else begin
            // A one-cycle pulse starts the bounded LFNST engine on the next
            // edge, after compute_slot_q and its descriptor metadata settle.
            lfnst_start_q <= 1'b0;

            // One bounded cache read is captured per cycle.  After the
            // sixteenth term has been captured, the engine starts on the
            // following edge with a complete, stable term vector.
            if (lfnst_gather_q) begin
                if (lfnst_gather_rd_valid)
                    lfnst_input_terms_q[lfnst_gather_index_q*16 +: 16] <=
                        lfnst_gather_rd_data;
                else
                    lfnst_input_terms_q[lfnst_gather_index_q*16 +: 16] <= '0;
                if (lfnst_gather_index_q == 5'd15) begin
                    lfnst_gather_q <= 1'b0;
                    if (lfnst_ntrs48_q) begin
                        // The 48-term LFNST replaces only the first 48
                        // diagonal coefficients.  Preserve the remaining
                        // 16 low-frequency-grid coefficients from the input
                        // TU so a sparse value outside the LFNST output
                        // domain is not lost.
                        lfnst_tail_q <= 1'b1;
                        lfnst_tail_index_q <= 5'd0;
                    end else begin
                        lfnst_start_q <= 1'b1;
                    end
                end else begin
                    lfnst_gather_index_q <= lfnst_gather_index_q + 1'b1;
                end
            end else if (lfnst_tail_q) begin
                lfnst_write_addr =
                    scan_row(6'd48 + lfnst_tail_index_q, 8) * 8 +
                    scan_col(6'd48 + lfnst_tail_index_q, 8);
                if (lfnst_write_addr < 64) begin
                    lfnst_grid[lfnst_write_addr] <=
                        lfnst_gather_rd_valid ? lfnst_gather_rd_data : '0;
                    lfnst_grid_valid[lfnst_write_addr] <= lfnst_gather_rd_valid;
                end
                if (lfnst_tail_index_q == 5'd15) begin
                    lfnst_tail_q <= 1'b0;
                    lfnst_start_q <= 1'b1;
                end else begin
                    lfnst_tail_index_q <= lfnst_tail_index_q + 1'b1;
                end
            end

            if (it_info_vld && !descriptor_legal)
                protocol_error <= 1'b1;
            if (it_info_vld && (desc_count == 2'd2) && !bind_event)
                protocol_error <= 1'b1;
            if (input_fire &&
                ({2'd0, it_data_addr} >=
                 tu_points(slot_width[fill_slot], slot_height[fill_slot])))
                protocol_error <= 1'b1;

            if (desc_push) begin
                desc_mem[desc_wr_ptr] <= it_info;
                desc_wr_ptr <= ~desc_wr_ptr;
            end
            if (bind_event) begin
                slot_state[bind_slot]  <= SLOT_SCRUB;
                slot_width[bind_slot]  <= desc_mem[desc_rd_ptr][6:0];
                slot_height[bind_slot] <= desc_mem[desc_rd_ptr][13:7];
                slot_hor[bind_slot]    <= desc_mem[desc_rd_ptr][15:14];
                slot_ver[bind_slot]    <= desc_mem[desc_rd_ptr][17:16];
                slot_set[bind_slot]    <= desc_mem[desc_rd_ptr][19:18];
                slot_lfnst[bind_slot]  <= desc_mem[desc_rd_ptr][21:20];
                desc_rd_ptr <= ~desc_rd_ptr;
                // Four valid tags per bank are scrubbed per cycle before the
                // slot is exposed through it_data_in_req.  Data memories are
                // never bulk-cleared.
                scrub_active <= 1'b1;
                scrub_slot   <= bind_slot;
                scrub_index  <= 12'd0;
            end

            if (scrub_active) begin
                if (scrub_index == (INPUT_VALID_WORDS - 1)) begin
                    scrub_active <= 1'b0;
                    slot_state[scrub_slot] <= SLOT_FILL;
                    fill_active <= 1'b1;
                    fill_slot <= scrub_slot;
                    scrub_index <= 12'd0;
                end else begin
                    scrub_index <= scrub_index + 1'b1;
                end
            end

            case ({desc_push, bind_event})
                2'b10: desc_count <= desc_count + 2'd1;
                2'b01: desc_count <= desc_count - 2'd1;
                default: desc_count <= desc_count;
            endcase

            if (input_end_fire) begin
                slot_state[fill_slot] <= SLOT_READY;
                fill_active <= 1'b0;
            end

            if (compute_valid) begin
                slot_state[compute_slot] <= SLOT_OUT;
                compute_slot_q <= compute_slot;
                output_index  <= 12'd0;
                if (slot_lfnst[compute_slot] == 2'd0) begin
                    // Primary-transform cases run through the real Gate-B
                    // P4 kernel.  The kernel works on the transform-support
                    // cut; coefficients outside the cut are explicitly zero.
                    kernel_run_q <= 1'b1;
                    kernel_phase_q <= K_V_START;
                    kernel_w_q <= slot_width[compute_slot];
                    kernel_h_q <= slot_height[compute_slot];
                    kernel_cut_w_q <= kernel_cut_dim(slot_hor[compute_slot],
                                                     slot_width[compute_slot]);
                    kernel_cut_h_q <= kernel_cut_dim(slot_ver[compute_slot],
                                                     slot_height[compute_slot]);
                    kernel_vector_q <= 7'd0;
                    kernel_group_q <= 5'd0;
                    kernel_type_q <= slot_ver[compute_slot];
                    kernel_stage_q <= 1'b0;
                    lfnst_case_q <= 1'b0;
                    output_active <= 1'b0;
                end else begin
                    // Active LFNST first gathers its bounded input vector and
                    // writes results to a small local grid, then reuses the
                    // DCT2 P4 vertical/horizontal path below.
                    kernel_run_q <= 1'b0;
                    kernel_phase_q <= K_IDLE;
                    output_active <= 1'b0;
                    lfnst_run_q <= 1'b1;
                    lfnst_start_q <= 1'b0;
                    lfnst_gather_q <= 1'b1;
                    lfnst_gather_index_q <= 5'd0;
                    lfnst_tail_q <= 1'b0;
                    lfnst_tail_index_q <= 5'd0;
                    lfnst_input_terms_q <= '0;
                    lfnst_case_q <= 1'b1;
                    lfnst_slot_q <= compute_slot;
                    lfnst_set_q <= slot_set[compute_slot];
                    lfnst_idx_q <= slot_lfnst[compute_slot];
                    lfnst_ntrs48_q <= !((slot_width[compute_slot] == 7'd4) ||
                                        (slot_height[compute_slot] == 7'd4));
                    lfnst_nonzero8_q <= ((slot_width[compute_slot] == 7'd4) &&
                                         (slot_height[compute_slot] == 7'd4)) ||
                                        ((slot_width[compute_slot] == 7'd8) &&
                                         (slot_height[compute_slot] == 7'd8));
                    kernel_w_q <= slot_width[compute_slot];
                    kernel_h_q <= slot_height[compute_slot];
                    kernel_cut_w_q <= lfnst_cut_dim(slot_width[compute_slot],
                                                    slot_height[compute_slot]);
                    kernel_cut_h_q <= lfnst_cut_dim(slot_height[compute_slot],
                                                    slot_width[compute_slot]);
                    kernel_vector_q <= 7'd0;
                    kernel_group_q <= 5'd0;
                    for (lfnst_grid_i = 0; lfnst_grid_i < 64;
                         lfnst_grid_i = lfnst_grid_i + 1) begin
                        lfnst_grid[lfnst_grid_i] <= '0;
                        lfnst_grid_valid[lfnst_grid_i] <= 1'b0;
                    end
                end
            end else if (output_fire) begin
                if (output_last_fire) begin
                    slot_state[output_slot] <= SLOT_FREE;
                    output_active <= 1'b0;
                    output_index <= 12'd0;
                end else begin
                    output_index <= output_index + 12'd1;
                end
            end

            if (kernel_error)
                protocol_error <= 1'b1;
            if (lfnst_error)
                protocol_error <= 1'b1;

            if (lfnst_run_q) begin
                if (lfnst_out_valid) begin
                    for (kernel_capture_lane_i = 0;
                         kernel_capture_lane_i < 4;
                         kernel_capture_lane_i = kernel_capture_lane_i + 1) begin
                        if ((lfnst_out_group * 4 + kernel_capture_lane_i) <
                            (lfnst_ntrs48_q ? 48 : 16)) begin
                            lfnst_write_addr =
                                scan_row(lfnst_out_group * 4 + kernel_capture_lane_i,
                                         lfnst_ntrs48_q ? 8 : 4) *
                                8 +
                                scan_col(lfnst_out_group * 4 + kernel_capture_lane_i,
                                         lfnst_ntrs48_q ? 8 : 4);
                            if (lfnst_write_addr < 64) begin
                                lfnst_grid[lfnst_write_addr] <=
                                    $signed(lfnst_out_data[kernel_capture_lane_i*16 +: 16]);
                                lfnst_grid_valid[lfnst_write_addr] <= 1'b1;
                            end
                        end
                    end
                end
                if (lfnst_done) begin
                    lfnst_run_q <= 1'b0;
                    kernel_run_q <= 1'b1;
                    kernel_phase_q <= K_V_START;
                    kernel_type_q <= 2'd0;
                    kernel_stage_q <= 1'b0;
                    kernel_vector_q <= 7'd0;
                    kernel_group_q <= 5'd0;
                end
            end

            if (kernel_run_q) begin
                case (kernel_phase_q)
                    K_V_START: begin
                        if (kernel_in_req) begin
                            if (kernel_cut_h_q <= 7'd4) begin
                                kernel_group_q <= 5'd0;
                                kernel_phase_q <= K_V_DRAIN;
                            end else begin
                                kernel_group_q <= 5'd1;
                                kernel_phase_q <= K_V_FEED;
                            end
                        end
                    end
                    K_V_FEED: begin
                        if (kernel_in_req) begin
                            if (kernel_group_q == ((kernel_cut_h_q >> 2) - 1'b1)) begin
                                kernel_group_q <= 5'd0;
                                kernel_phase_q <= K_V_DRAIN;
                            end else begin
                                kernel_group_q <= kernel_group_q + 1'b1;
                            end
                        end
                    end
                    K_V_DRAIN: begin
                        if (kernel_out_valid) begin
                            kernel_group_q <= kernel_group_q + 1'b1;
                        end
                        if (kernel_done) begin
                            kernel_group_q <= 5'd0;
                            if (kernel_vector_q + 1'b1 < kernel_cut_w_q) begin
                                kernel_vector_q <= kernel_vector_q + 1'b1;
                                kernel_phase_q <= K_V_START;
                            end else begin
                                kernel_vector_q <= 7'd0;
                                kernel_group_q <= 5'd0;
                                kernel_type_q <= slot_hor[compute_slot_q];
                                kernel_stage_q <= 1'b1;
                                kernel_phase_q <= K_H_START;
                            end
                        end
                    end
                    K_H_START: begin
                        if (kernel_in_req) begin
                            if (kernel_w_q <= 7'd4) begin
                                kernel_group_q <= 5'd0;
                                kernel_phase_q <= K_H_DRAIN;
                            end else begin
                                kernel_group_q <= 5'd1;
                                kernel_phase_q <= K_H_FEED;
                            end
                        end
                    end
                    K_H_FEED: begin
                        if (kernel_in_req) begin
                            if (kernel_group_q == ((kernel_w_q >> 2) - 1'b1)) begin
                                kernel_group_q <= 5'd0;
                                kernel_phase_q <= K_H_DRAIN;
                            end else begin
                                kernel_group_q <= kernel_group_q + 1'b1;
                            end
                        end
                    end
                    K_H_DRAIN: begin
                        if (kernel_out_valid) begin
                            kernel_group_q <= kernel_group_q + 1'b1;
                        end
                        if (kernel_done) begin
                            // Horizontal transform is run once for every
                            // vertical output row.  Keep the same P4 group
                            // cadence while advancing to the next row; only
                            // the final row hands ownership to the output
                            // protocol.
                            if (kernel_vector_q + 1'b1 < kernel_h_q) begin
                                kernel_vector_q <= kernel_vector_q + 1'b1;
                                kernel_group_q <= 5'd0;
                                kernel_phase_q <= K_H_START;
                            end else begin
                                kernel_run_q <= 1'b0;
                                kernel_phase_q <= K_IDLE;
                                output_active <= 1'b1;
                                output_slot <= compute_slot_q;
                                output_index <= 12'd0;
                            end
                        end
                    end
                    default: kernel_phase_q <= K_IDLE;
                endcase
            end
        end
    end

endmodule
