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

    // P9 round 3: sparse-fill writes cross an atomic elastic command
    // boundary before reaching the distributed input-cache write ports.  A
    // command represents one accepted nonzero point and owns exactly one
    // physical slot/bank target; data and validity are committed together.
    logic        fill_wr_cmd_valid_q;
    logic [3:0]  fill_wr_cmd_target_q [0:1];
    logic [BANK_ADDR_W-1:0] fill_wr_cmd_addr_q;
    logic [DATA_W-1:0]      fill_wr_cmd_data_q;
    logic        fill_wr_cmd_ready;
    logic        fill_wr_cmd_commit;
    logic [3:0]  fill_wr_cmd_target_c [0:1];
    logic [BANK_ADDR_W-1:0] fill_wr_cmd_addr_c;
    logic [DATA_W-1:0]      fill_wr_cmd_data_c;
    logic        fill_end_pending_q;
    logic        fill_end_slot_q;
    integer fill_cmd_row_i, fill_cmd_col_i, fill_cmd_bank_i, fill_cmd_local_i;

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
    // Descriptor geometry is decoded once at bind time.  The live protocol
    // and result-control paths use these registered values instead of a
    // synthesized width*height multiplier.
    logic [12:0] slot_point_count [0:1];
    logic [11:0] slot_last_input_addr [0:1];
    logic [11:0] slot_output_last_index [0:1];

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
    // Latched at compute admission so output-last detection does not
    // re-evaluate the 7x7 width*height arithmetic in the output/control cone.
    // The value is stable for the complete output transaction.
    logic [11:0] output_last_index;

    // Gate-B unified P4 kernel integration.  LFNST-enabled cases first use the
    // bounded engine above and then reuse this kernel for the DCT2 passes;
    // LFNST-off primary transforms use this kernel directly.
    logic        compute_slot_q;
    logic        kernel_run_q;
    typedef enum logic [3:0] {K_IDLE, K_V_START, K_V_FEED, K_V_DRAIN,
                              K_V_WAIT_COMMIT, K_H_START, K_H_FEED,
                              K_H_DRAIN, K_H_WAIT_COMMIT} kernel_phase_t;
    kernel_phase_t kernel_phase_q;
    logic [6:0] kernel_w_q, kernel_h_q, kernel_cut_w_q, kernel_cut_h_q;
    logic [6:0] kernel_vector_q;
    // P8.1: keep feed-side input bookkeeping separate from drain-side output
    // bookkeeping.  The same-edge kernel fire may advance feed_group_q and
    // consume a response, but it must not drive the wide phase/drain mux.
    logic [4:0] kernel_feed_group_q;
    logic [4:0] kernel_drain_group_q;
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
    // P8 handshake boundary: same-edge input fire is used for response
    // consumption/group advance; the registered token drives phase changes.
    logic       kernel_input_group_fire;
    logic       kernel_input_vector_done;
    logic       kernel_busy;
    logic       kernel_error;

    // P7: phase-entry context is registered once for each V/H pass.  The
    // kernel no longer sees a live stage mux on transform/active/output size;
    // its capacity and ready logic consume these stable fields instead.
    logic       kernel_ctx_stage_q;
    logic [6:0] kernel_ctx_transform_size_q;
    logic [6:0] kernel_ctx_active_size_q;
    logic [6:0] kernel_ctx_output_size_q;
    logic [5:0] kernel_ctx_group_count_q;

    // Vertical result to intermediate-memory write boundary.  A command is
    // captured when a kernel result group is accepted and is committed by the
    // RAMs on the following edge.  The RAM write ports are driven only by
    // these registered fields, so kernel/group/address decode cannot reach a
    // distributed-RAM write endpoint in the same timing interval.
    logic                             vwrite_cmd_valid_q;
    logic [3:0]                       vwrite_cmd_bank_mask_q;
    logic [BANK_ADDR_W-1:0]           vwrite_cmd_addr_q;
    logic signed [15:0]               vwrite_cmd_data_q [0:3];
    logic                             vwrite_cmd_last_q;
    logic                             vwrite_last_commit_seen_q;
    logic                             vertical_result_fire;
    logic                             vwrite_cmd_commit;
    logic [3:0]                       vwrite_cmd_bank_mask_c;
    logic [BANK_ADDR_W-1:0]           vwrite_cmd_addr_c;
    logic signed [15:0]               vwrite_cmd_data_c [0:3];
    logic                             vwrite_cmd_last_c;

    // Horizontal result write boundary.  A result group is captured into a
    // registered bank-local command and committed by ResultMemory on the
    // following edge.  No live kernel counter reaches a RAM write port.
    logic                             result_cmd_valid_q;
    logic                             result_cmd_slot_q;
    logic [3:0]                       result_cmd_bank_mask_q;
    logic [BANK_ADDR_W-1:0]           result_cmd_addr_q;
    logic signed [OUT_W-1:0]          result_cmd_data_q [0:3];
    logic                             result_cmd_last_q;
    logic                             result_last_commit_seen_q;
    logic                             horizontal_result_fire;
    logic                             result_cmd_commit;
    logic [3:0]                       result_cmd_bank_mask_c;
    logic [BANK_ADDR_W-1:0]           result_cmd_addr_c;
    logic signed [OUT_W-1:0]          result_cmd_data_c [0:3];
    logic                             result_cmd_last_c;
    logic [BANK_ADDR_W-1:0]           result_write_beat_q;
    // Primary-transform cache reads are prefetched through a registered
    // response boundary before entering the unified kernel.  The request
    // group advances independently from the group currently being consumed,
    // so one read can be captured while the previous response is accepted.
    logic       kernel_rd_req_pending_q;
    logic [4:0] kernel_rd_req_group_q;
    logic [6:0] kernel_rd_req_vector_q;
    logic signed [63:0] kernel_rd_resp_data_q;
    logic       kernel_rd_resp_valid_q;
    // The cache bank outputs are sampled before the lane packing/validity
    // mux.  This keeps the physical RAM read path separate from the small
    // four-lane reorder and also prevents the active-height compare from
    // reaching the RAM response register.
    logic signed [63:0] kernel_rd_raw_data_q;
    logic [3:0]         kernel_rd_raw_valid_q;
    logic               kernel_rd_raw_pending_q;
    logic [4:0]         kernel_rd_raw_group_q;
    logic [6:0]         kernel_rd_raw_vector_q;
    logic       kernel_start_sent_q;
    logic       kernel_group_accept;
    logic signed [63:0] kernel_rd_data_comb;
    logic               kernel_rd_valid_comb;
    logic               kernel_rd_resp_slot_ready;
    logic               kernel_rd_raw_to_resp;
    logic               kernel_rd_raw_capture;

    // P9 second round: one atomic elastic physical-read command is shared by
    // primary-V and LFNST logical requests.  The command owns all physical
    // slot/bank addresses and the metadata needed by response capture.
    // Address registers are held even when valid is low; validity and owner
    // metadata, not an address mux, determine whether a RAM output is useful.
    localparam logic RD_OWNER_PRIMARY_V = 1'b0;
    localparam logic RD_OWNER_LFNST     = 1'b1;
    logic                         rd_cmd_valid_q;
    logic                         rd_cmd_owner_q;
    logic                         rd_cmd_slot_q;
    logic [3:0]                   rd_cmd_bank_mask_q;
    logic [BANK_ADDR_W-1:0]       rd_cmd_addr_q [0:1][0:3];
    logic [4:0]                   rd_cmd_group_q;
    logic [6:0]                   rd_cmd_vector_q;
    logic                         rd_cmd_lfnst_is_tail_q;
    logic [4:0]                   rd_cmd_lfnst_index_q;
    logic [5:0]                   rd_cmd_lfnst_grid_addr_q;
    logic                         rd_cmd_lfnst_valid_q;
    logic                         rd_cmd_lfnst_last_q;
    logic [1:0]                   rd_cmd_lfnst_bank_q;

    logic                         rd_cmd_candidate_valid;
    logic                         rd_cmd_candidate_owner;
    logic                         rd_cmd_candidate_slot;
    logic [3:0]                   rd_cmd_candidate_bank_mask;
    logic [BANK_ADDR_W-1:0]       rd_cmd_candidate_addr_c [0:1][0:3];
    logic [4:0]                   rd_cmd_candidate_group;
    logic [6:0]                   rd_cmd_candidate_vector;
    logic                         rd_cmd_candidate_lfnst_is_tail;
    logic [4:0]                   rd_cmd_candidate_lfnst_index;
    logic [5:0]                   rd_cmd_candidate_lfnst_grid_addr;
    logic                         rd_cmd_candidate_lfnst_valid;
    logic                         rd_cmd_candidate_lfnst_last;
    logic [1:0]                   rd_cmd_candidate_lfnst_bank;
    logic                         rd_cmd_owner_response_ready;
    logic                         rd_cmd_response_fire;
    logic                         rd_cmd_ready;
    logic                         rd_cmd_accept;
    logic                         primary_logical_req_fire;
    logic                         lfnst_mem_req_accept;

    // Horizontal intermediate reads use a bank-local address register and a
    // response register as well.  The request address is generated from the
    // current row/group metadata and held for one cycle before the RAM output
    // is sampled, keeping kernel_w_q and the dynamic bank mux out of the RAM
    // to kernel input timing path.
    logic [BANK_ADDR_W-1:0] kernel_h_rd_addr_q [0:3];
    logic [BANK_ADDR_W-1:0] kernel_h_rd_addr_advance_c [0:3];
    logic [BANK_ADDR_W-1:0] kernel_h_row_base_q [0:3];
    logic [BANK_ADDR_W-1:0] kernel_h_row_base_next_c [0:3];
    logic [6:0]             kernel_h_width_q;
    logic [4:0]             kernel_h_groups_per_row_q;
    logic [4:0]             kernel_h_groups_left_q;
    logic [6:0]             kernel_h_rows_left_q;
    logic [1:0]             kernel_h_row_phase_q;
    logic                   kernel_h_rd_pending_q;
    logic [4:0]             kernel_h_rd_group_q;
    logic [6:0]             kernel_h_rd_vector_q;
    logic signed [63:0]     kernel_h_rd_data_q;
    logic                   kernel_h_rd_raw_pending_q;
    logic [4:0]             kernel_h_rd_raw_group_q;
    logic [6:0]             kernel_h_rd_raw_vector_q;
    // A second response entry decouples the address sequencer from a one-cycle
    // kernel consume stall.  The head entry is still presented to the kernel;
    // the tail entry is only an elastic skid buffer and carries the same
    // group/vector metadata as its data.
    logic signed [63:0]     kernel_h_rd_data_tail_q;
    logic                   kernel_h_rd_raw_tail_pending_q;
    logic [4:0]             kernel_h_rd_raw_tail_group_q;
    logic [6:0]             kernel_h_rd_raw_tail_vector_q;
    logic                   kernel_h_rd_capture;
    logic                   kernel_h_rd_consume;
    logic [4:0]             kernel_h_rd_next_group;
    logic                   kernel_h_input_last_fire_c;
    // P9 ingress adds one cycle between the final input fire and the
    // commit-qualified input_vector_done token.  During that interval the
    // horizontal read sequencer must not pre-issue the next row: doing so
    // would advance row metadata while the kernel is still waiting for the
    // final input commit, and the response would then be discarded when the
    // wrapper enters H_DRAIN.  This bit freezes H-read advancement for that
    // bounded handoff window without changing steady-state request II.
    logic                   kernel_h_input_commit_wait_q;
    integer                 kernel_h_addr_i;
    integer                 kernel_h_capture_bank_i;
    integer                 kernel_h_seq_addr_i;
    integer                 kernel_h_seq_capture_bank_i;

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
    // LFNST input reads use an explicit request/response boundary.  The
    // request registers hold the bank-local physical address and its source
    // metadata; the response registers then isolate the cache read from the
    // term/grid write.  This keeps the gather path bounded without changing
    // the external transaction contract.
    logic       lfnst_mem_req_q;
    logic       lfnst_mem_req_is_tail_q;
    logic [4:0] lfnst_mem_req_index_q;
    logic [5:0] lfnst_mem_req_grid_addr_q;
    logic [BANK_ADDR_W-1:0] lfnst_mem_req_addr_q;
    logic       lfnst_mem_req_valid_q;
    logic       lfnst_mem_req_last_q;
    logic       lfnst_mem_req_slot_q;
    logic [1:0] lfnst_mem_req_bank_q;
    logic       lfnst_mem_resp_pending_q;
    logic       lfnst_mem_resp_is_tail_q;
    logic [4:0] lfnst_mem_resp_index_q;
    logic [5:0] lfnst_mem_resp_grid_addr_q;
    logic signed [15:0] lfnst_mem_resp_data_q;
    logic       lfnst_mem_resp_valid_q;
    logic       lfnst_mem_resp_last_q;
    logic signed [255:0] lfnst_input_terms_q;
    logic signed [15:0] lfnst_grid [0:63];
    logic               lfnst_grid_valid [0:63];

    unified_p4_kernel #(
        .DATA_W(16), .COEFF_W(16), .ACC_W(40), .MAX_N(64),
        .COEFF_DEPTH(COEFF_DEPTH), .COEFF_FILE(COEFF_FILE)
    ) u_unified_p4_kernel (
        .clk(clk), .rst_n(rst_n), .start(kernel_start),
        .tr_type(kernel_type_q),
        .transform_size(kernel_ctx_transform_size_q),
        .active_size(kernel_ctx_active_size_q),
        .output_size(kernel_ctx_output_size_q),
        .output_group_count(kernel_ctx_group_count_q),
        .stage_sel(kernel_ctx_stage_q), .in_valid(kernel_in_valid),
        .in_req(kernel_in_req), .in_data(kernel_in_data),
        .out_valid(kernel_out_valid), .out_req(kernel_out_req),
        .out_data(kernel_out_data), .done(kernel_done),
        .input_group_fire(kernel_input_group_fire),
        .input_vector_done(kernel_input_vector_done),
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
    logic [12:0] bind_point_count_c;

    // desc_rd_ptr selects only the descriptor being bound.  The expression is
    // a table decode, not a multiply, and is registered into the slot below.
    assign bind_point_count_c =
        static_tu_point_count(desc_mem[desc_rd_ptr][6:0],
                              desc_mem[desc_rd_ptr][13:7]);

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

    // All supported dimensions are powers of two.  Keep the geometry as a
    // constant decode table rather than a generic multiplier.  The 13-bit
    // count is intentional: 64x64 is 4096, which does not fit in 12 bits.
    function automatic logic [12:0] static_tu_point_count(input logic [6:0] w,
                                                           input logic [6:0] h);
        begin
            static_tu_point_count = 13'd0;
            case ({w, h})
                {7'd4,7'd4}:   static_tu_point_count = 13'd16;
                {7'd4,7'd8}, {7'd8,7'd4}: static_tu_point_count = 13'd32;
                {7'd4,7'd16}, {7'd8,7'd8}, {7'd16,7'd4}: static_tu_point_count = 13'd64;
                {7'd4,7'd32}, {7'd8,7'd16}, {7'd16,7'd8}, {7'd32,7'd4}: static_tu_point_count = 13'd128;
                {7'd4,7'd64}, {7'd8,7'd32}, {7'd16,7'd16}, {7'd32,7'd8}, {7'd64,7'd4}: static_tu_point_count = 13'd256;
                {7'd8,7'd64}, {7'd16,7'd32}, {7'd32,7'd16}, {7'd64,7'd8}: static_tu_point_count = 13'd512;
                {7'd16,7'd64}, {7'd32,7'd32}, {7'd64,7'd16}: static_tu_point_count = 13'd1024;
                {7'd32,7'd64}, {7'd64,7'd32}: static_tu_point_count = 13'd2048;
                {7'd64,7'd64}: static_tu_point_count = 13'd4096;
                default: static_tu_point_count = 13'd0;
            endcase
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

    // Static-width form used by the vertical write-command boundary.  The
    // intermediate mapping is local = group * width + column; spelling out
    // the five supported powers of two prevents a runtime multiplier from
    // being inferred in the command-generation path.
    function automatic logic [BANK_ADDR_W-1:0] tmp_local_for_vwrite(
        input logic [4:0] group_i,
        input logic [6:0] width_i,
        input logic [6:0] col_i);
        logic [BANK_ADDR_W-1:0] group_ext;
        logic [BANK_ADDR_W-1:0] col_ext;
        begin
            group_ext = '0;
            group_ext[4:0] = group_i;
            col_ext = '0;
            col_ext[6:0] = col_i;
            case (width_i)
                7'd4:  tmp_local_for_vwrite = (group_ext << 2) + col_ext;
                7'd8:  tmp_local_for_vwrite = (group_ext << 3) + col_ext;
                7'd16: tmp_local_for_vwrite = (group_ext << 4) + col_ext;
                7'd32: tmp_local_for_vwrite = (group_ext << 5) + col_ext;
                7'd64: tmp_local_for_vwrite = (group_ext << 6) + col_ext;
                default: tmp_local_for_vwrite = '0;
            endcase
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

    // P9 round 3: acceptance is defined at the command boundary.  The
    // current write stage is guaranteed to make progress, but retaining the
    // explicit ready/commit equations prevents a future write-side stall from
    // creating a fire-without-storage condition.
    assign fill_wr_cmd_commit = fill_wr_cmd_valid_q;
    assign fill_wr_cmd_ready  = !fill_wr_cmd_valid_q || fill_wr_cmd_commit;
    assign it_data_in_req = fill_active && fill_wr_cmd_ready;
    assign input_fire = it_data_in_vld && it_data_in_req;
    // The end marker is an independent input transaction: it may accompany a
    // final nonzero data word or arrive on its own after the sparse words.
    assign input_end_fire = it_data_end && it_data_in_req;

    // Decode one accepted sparse point into a registered physical write
    // command.  The decode is intentionally before the command register;
    // RAM write enables/addresses/data below are driven only from *_q.
    always_comb begin : fill_write_command_generate
        fill_wr_cmd_addr_c = '0;
        fill_wr_cmd_data_c = '0;
        fill_wr_cmd_target_c[0] = 4'b0000;
        fill_wr_cmd_target_c[1] = 4'b0000;
        fill_cmd_row_i = 0;
        fill_cmd_col_i = 0;
        fill_cmd_bank_i = 0;
        fill_cmd_local_i = 0;
        if (input_fire) begin
            fill_cmd_row_i = raster_row_for(it_data_addr, slot_width[fill_slot]);
            fill_cmd_col_i = raster_col_for(it_data_addr, slot_width[fill_slot]);
            fill_cmd_bank_i = cache_bank_for(fill_cmd_row_i, fill_cmd_col_i);
            fill_cmd_local_i = cache_local_for(fill_cmd_row_i, fill_cmd_col_i);
            fill_wr_cmd_addr_c = fill_cmd_local_i[BANK_ADDR_W-1:0];
            fill_wr_cmd_data_c = it_data_in;
            fill_wr_cmd_target_c[fill_slot][fill_cmd_bank_i] = 1'b1;
        end
    end

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

    // Static LFNST scan lookup used by synthesis.  Keeping the reference
    // arithmetic helpers above preserves an independent readable model, while
    // this bounded coordinate table removes runtime diagonal iteration from
    // the physical datapath.
    function automatic integer scan_coord_lut(input integer index_i,
                                               input integer side_i);
        begin
            scan_coord_lut = 0;
            if (side_i == 4) begin
                case (index_i)
                    0: scan_coord_lut = 0;
                    1: scan_coord_lut = 8;
                    2: scan_coord_lut = 1;
                    3: scan_coord_lut = 2;
                    4: scan_coord_lut = 9;
                    5: scan_coord_lut = 16;
                    6: scan_coord_lut = 24;
                    7: scan_coord_lut = 17;
                    8: scan_coord_lut = 10;
                    9: scan_coord_lut = 3;
                    10: scan_coord_lut = 11;
                    11: scan_coord_lut = 18;
                    12: scan_coord_lut = 25;
                    13: scan_coord_lut = 26;
                    14: scan_coord_lut = 19;
                    15: scan_coord_lut = 27;
                    default: scan_coord_lut = 0;
                endcase
            end else begin
                case (index_i)
                    0: scan_coord_lut = 0;
                    1: scan_coord_lut = 8;
                    2: scan_coord_lut = 1;
                    3: scan_coord_lut = 2;
                    4: scan_coord_lut = 9;
                    5: scan_coord_lut = 16;
                    6: scan_coord_lut = 24;
                    7: scan_coord_lut = 17;
                    8: scan_coord_lut = 10;
                    9: scan_coord_lut = 3;
                    10: scan_coord_lut = 4;
                    11: scan_coord_lut = 11;
                    12: scan_coord_lut = 18;
                    13: scan_coord_lut = 25;
                    14: scan_coord_lut = 32;
                    15: scan_coord_lut = 40;
                    16: scan_coord_lut = 33;
                    17: scan_coord_lut = 26;
                    18: scan_coord_lut = 19;
                    19: scan_coord_lut = 12;
                    20: scan_coord_lut = 5;
                    21: scan_coord_lut = 6;
                    22: scan_coord_lut = 13;
                    23: scan_coord_lut = 20;
                    24: scan_coord_lut = 27;
                    25: scan_coord_lut = 34;
                    26: scan_coord_lut = 41;
                    27: scan_coord_lut = 48;
                    28: scan_coord_lut = 56;
                    29: scan_coord_lut = 49;
                    30: scan_coord_lut = 42;
                    31: scan_coord_lut = 35;
                    32: scan_coord_lut = 28;
                    33: scan_coord_lut = 21;
                    34: scan_coord_lut = 14;
                    35: scan_coord_lut = 7;
                    36: scan_coord_lut = 15;
                    37: scan_coord_lut = 22;
                    38: scan_coord_lut = 29;
                    39: scan_coord_lut = 36;
                    40: scan_coord_lut = 43;
                    41: scan_coord_lut = 50;
                    42: scan_coord_lut = 57;
                    43: scan_coord_lut = 58;
                    44: scan_coord_lut = 51;
                    45: scan_coord_lut = 44;
                    46: scan_coord_lut = 37;
                    47: scan_coord_lut = 30;
                    48: scan_coord_lut = 23;
                    49: scan_coord_lut = 31;
                    50: scan_coord_lut = 38;
                    51: scan_coord_lut = 45;
                    52: scan_coord_lut = 52;
                    53: scan_coord_lut = 59;
                    54: scan_coord_lut = 60;
                    55: scan_coord_lut = 53;
                    56: scan_coord_lut = 46;
                    57: scan_coord_lut = 39;
                    58: scan_coord_lut = 47;
                    59: scan_coord_lut = 54;
                    60: scan_coord_lut = 61;
                    61: scan_coord_lut = 62;
                    62: scan_coord_lut = 55;
                    63: scan_coord_lut = 63;
                    default: scan_coord_lut = 0;
                endcase
            end
        end
    endfunction

    function automatic integer scan_row_lut(input integer index_i,
                                             input integer side_i);
        begin
            scan_row_lut = scan_coord_lut(index_i, side_i) >> 3;
        end
    endfunction

    function automatic integer scan_col_lut(input integer index_i,
                                             input integer side_i);
        begin
            scan_col_lut = scan_coord_lut(index_i, side_i) & 7;
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

    // Build one logical request candidate at a time.  The candidate is
    // captured only when the atomic command bundle is ready; all physical
    // addresses are then held in rd_cmd_addr_q until the matching response is
    // consumed.  LFNST retains priority during its gather/tail phase, while
    // primary-V owns the cache in the normal transform phase.
    integer rd_candidate_slot_i, rd_candidate_bank_i;
    integer rd_candidate_row_i, rd_candidate_col_i;
    integer rd_candidate_bank_map_i, rd_candidate_local_i;
    always_comb begin : rd_command_candidate_comb
        rd_cmd_candidate_valid = 1'b0;
        rd_cmd_candidate_owner = RD_OWNER_PRIMARY_V;
        rd_cmd_candidate_slot = 1'b0;
        rd_cmd_candidate_bank_mask = 4'b0000;
        rd_cmd_candidate_group = 5'd0;
        rd_cmd_candidate_vector = 7'd0;
        rd_cmd_candidate_lfnst_is_tail = 1'b0;
        rd_cmd_candidate_lfnst_index = 5'd0;
        rd_cmd_candidate_lfnst_grid_addr = 6'd0;
        rd_cmd_candidate_lfnst_valid = 1'b0;
        rd_cmd_candidate_lfnst_last = 1'b0;
        rd_cmd_candidate_lfnst_bank = 2'd0;
        for (rd_candidate_slot_i = 0;
             rd_candidate_slot_i < 2;
             rd_candidate_slot_i = rd_candidate_slot_i + 1)
            for (rd_candidate_bank_i = 0;
                 rd_candidate_bank_i < 4;
                 rd_candidate_bank_i = rd_candidate_bank_i + 1)
                rd_cmd_candidate_addr_c[rd_candidate_slot_i][rd_candidate_bank_i] = '0;

        if (lfnst_mem_req_q) begin
            rd_cmd_candidate_valid = 1'b1;
            rd_cmd_candidate_owner = RD_OWNER_LFNST;
            rd_cmd_candidate_slot = lfnst_mem_req_slot_q;
            rd_cmd_candidate_bank_mask =
                (4'b0001 << lfnst_mem_req_bank_q);
            rd_cmd_candidate_lfnst_is_tail = lfnst_mem_req_is_tail_q;
            rd_cmd_candidate_lfnst_index = lfnst_mem_req_index_q;
            rd_cmd_candidate_lfnst_grid_addr = lfnst_mem_req_grid_addr_q;
            rd_cmd_candidate_lfnst_valid = lfnst_mem_req_valid_q;
            rd_cmd_candidate_lfnst_last = lfnst_mem_req_last_q;
            rd_cmd_candidate_lfnst_bank = lfnst_mem_req_bank_q;
            rd_cmd_candidate_addr_c[lfnst_mem_req_slot_q][lfnst_mem_req_bank_q] =
                lfnst_mem_req_addr_q;
        end else if (kernel_run_q && !kernel_stage_q &&
                     !lfnst_case_q && kernel_rd_req_pending_q) begin
            rd_cmd_candidate_valid = 1'b1;
            rd_cmd_candidate_owner = RD_OWNER_PRIMARY_V;
            rd_cmd_candidate_slot = compute_slot_q;
            rd_cmd_candidate_bank_mask = 4'b1111;
            rd_cmd_candidate_group = kernel_rd_req_group_q;
            rd_cmd_candidate_vector = kernel_rd_req_vector_q;
            for (rd_candidate_bank_i = 0;
                 rd_candidate_bank_i < 4;
                 rd_candidate_bank_i = rd_candidate_bank_i + 1) begin
                rd_candidate_row_i = kernel_rd_req_group_q * 4 +
                                     rd_candidate_bank_i;
                rd_candidate_col_i = kernel_rd_req_vector_q;
                rd_candidate_bank_map_i =
                    cache_bank_for(rd_candidate_row_i, rd_candidate_col_i);
                rd_candidate_local_i =
                    cache_local_for(rd_candidate_row_i, rd_candidate_col_i);
                rd_cmd_candidate_addr_c[compute_slot_q][rd_candidate_bank_map_i] =
                    rd_candidate_local_i[BANK_ADDR_W-1:0];
            end
        end
    end

    // A command is an atomic bundle even though it drives four physical bank
    // ports for primary-V.  The owner-specific response slot controls whether
    // the bundle may be retired and replaced on the same edge.
    always_comb begin : rd_command_flow_comb
        if (rd_cmd_owner_q == RD_OWNER_LFNST)
            rd_cmd_owner_response_ready = 1'b1;
        else
            rd_cmd_owner_response_ready =
                !kernel_rd_raw_pending_q || kernel_rd_resp_slot_ready;
        rd_cmd_response_fire = rd_cmd_valid_q && rd_cmd_owner_response_ready;
        rd_cmd_ready = !rd_cmd_valid_q || rd_cmd_response_fire;
        rd_cmd_accept = rd_cmd_candidate_valid && rd_cmd_ready;
        primary_logical_req_fire = rd_cmd_accept &&
                                    (rd_cmd_candidate_owner == RD_OWNER_PRIMARY_V);
        lfnst_mem_req_accept = rd_cmd_accept &&
                               (rd_cmd_candidate_owner == RD_OWNER_LFNST);
    end

`ifndef SYNTHESIS
    // The physical command is one transaction bundle: primary-V must carry
    // all four bank lanes, while LFNST carries exactly one bank lane.  These
    // checks also guard the owner mutual-exclusion assumption used by the
    // shared command register.
    always @(posedge clk) begin
        if (rst_n && rd_cmd_accept) begin
            if (rd_cmd_candidate_owner == RD_OWNER_PRIMARY_V)
                assert (rd_cmd_candidate_bank_mask == 4'b1111)
                    else $error("P9 primary-V read command is not four-bank atomic");
            else
                assert ($onehot(rd_cmd_candidate_bank_mask))
                    else $error("P9 LFNST read command is not one-bank atomic");
        end
        if (rst_n)
            assert (!(rd_cmd_candidate_valid &&
                      (rd_cmd_candidate_owner == RD_OWNER_PRIMARY_V) &&
                      lfnst_mem_req_q))
                else $error("P9 primary-V and LFNST logical read owners overlap");
    end
`endif

    // Physical RAM addresses are unconditional connections from the command
    // registers.  Invalid commands retain their previous address; valid and
    // owner metadata give the address meaning to the response stage.  No
    // valid/owner mux is allowed in front of the RAMD64E ADDR pins.
    always_comb begin : input_read_addr_comb
        integer read_slot_i, read_bank_i;
        for (read_slot_i = 0; read_slot_i < 2; read_slot_i = read_slot_i + 1)
            for (read_bank_i = 0; read_bank_i < 4; read_bank_i = read_bank_i + 1)
                input_rd_addr[read_slot_i][read_bank_i] =
                    rd_cmd_addr_q[read_slot_i][read_bank_i];
    end

    // The primary vertical transform consumes a two-stage cache response.
    // First, all four physical bank outputs are sampled without a dynamic
    // lane mux.  The following stage performs only the bounded 4x4 lane
    // reorder and active-height masking.  Thus the cache RAM output is not
    // combined with the row-range/arithmetic cone in one timing interval.
    integer kernel_rd_lane_i;
    integer kernel_rd_row_i;
    integer kernel_rd_bank_i;
    always_comb begin : kernel_rd_data_comb_block
        kernel_rd_data_comb = '0;
        kernel_rd_valid_comb = kernel_rd_raw_pending_q;
        for (kernel_rd_lane_i = 0; kernel_rd_lane_i < 4;
             kernel_rd_lane_i = kernel_rd_lane_i + 1) begin
            kernel_rd_row_i = kernel_rd_raw_group_q * 4 + kernel_rd_lane_i;
            if (kernel_rd_raw_pending_q && (kernel_rd_row_i < kernel_cut_h_q)) begin
                kernel_rd_bank_i = cache_bank_for(kernel_rd_row_i,
                                                  kernel_rd_raw_vector_q);
                if (kernel_rd_raw_valid_q[kernel_rd_bank_i])
                    kernel_rd_data_comb[kernel_rd_lane_i*16 +: 16] =
                        kernel_rd_raw_data_q[kernel_rd_bank_i*16 +: 16];
            end
        end
    end

    // Horizontal addresses use a bank-local recurrence.  The row-zero base is
    // [0,1,2,3]; moving across a group adds four to every bank-local address.
    // At a row boundary the physical bank ownership rotates, and the local
    // base advances by width only after every fourth row.  Keeping this
    // recurrence in registered state removes the runtime row*width/column
    // arithmetic and dynamic bank case from the RAM-address timing cone.
    always_comb begin : kernel_h_rd_addr_comb
        for (kernel_h_addr_i = 0; kernel_h_addr_i < 4;
             kernel_h_addr_i = kernel_h_addr_i + 1)
            kernel_h_rd_addr_advance_c[kernel_h_addr_i] =
                kernel_h_rd_addr_q[kernel_h_addr_i] + BANK_ADDR_W'(4);
        for (kernel_h_addr_i = 0; kernel_h_addr_i < 4;
             kernel_h_addr_i = kernel_h_addr_i + 1) begin
            if (kernel_h_row_phase_q == 2'd3)
                kernel_h_row_base_next_c[kernel_h_addr_i] =
                    kernel_h_row_base_q[(kernel_h_addr_i + 3) & 3] +
                    kernel_h_width_q;
            else
                kernel_h_row_base_next_c[kernel_h_addr_i] =
                    kernel_h_row_base_q[(kernel_h_addr_i + 3) & 3];
        end
    end

    // The horizontal response slot is filled only while the elastic tail is
    // available.  A consume that frees the tail is handled on the following
    // edge rather than feeding the current kernel-ready signal back into the
    // address/group enables.  Ready-high steady state still has one request
    // and one response per cycle; a request-low stall may cost one refill edge.
    always_comb begin
        kernel_h_rd_consume = kernel_h_rd_raw_pending_q &&
                              kernel_stage_q &&
                              ((kernel_phase_q == K_H_START) ||
                               (kernel_phase_q == K_H_FEED)) &&
                              !kernel_h_input_commit_wait_q &&
                              kernel_input_group_fire;
        kernel_h_rd_capture = kernel_h_rd_pending_q &&
                              !kernel_h_rd_raw_tail_pending_q;
        kernel_h_rd_next_group = kernel_h_rd_group_q + 1'b1;
        // The P4 kernel's final-input condition is based on active_size (the
        // transform-support input cut), not necessarily the output group
        // count.  This distinction matters for LFNST and DST7/DCT8 support
        // cuts, where the H pass emits a wider result than it consumes.
        kernel_h_input_last_fire_c = kernel_input_group_fire &&
                                     (kernel_ctx_active_size_q != 7'd0) &&
                                     ((kernel_feed_group_q + 1'b1) >=
                                      (kernel_ctx_active_size_q >> 2));
    end

    // A response entry can be replaced on the same edge on which the kernel
    // accepts it.  The raw bank-response stage follows the same elastic rule,
    // allowing one request and one response to advance every cycle after the
    // initial two-edge fill.
    always_comb begin
        kernel_rd_resp_slot_ready = !kernel_rd_resp_valid_q || kernel_group_accept;
        kernel_rd_raw_to_resp = kernel_rd_raw_pending_q && kernel_rd_resp_slot_ready;
        // A primary raw response is captured only when the atomic physical
        // command retires.  The command itself, rather than the live request
        // counters, supplies the slot/group/vector metadata below.
        kernel_rd_raw_capture = rd_cmd_response_fire &&
                                (rd_cmd_owner_q == RD_OWNER_PRIMARY_V);
    end

    always_comb begin : lfnst_gather_data_comb
        lfnst_gather_rd_data = '0;
        lfnst_gather_rd_valid = 1'b0;
        if (rd_cmd_valid_q &&
            (rd_cmd_owner_q == RD_OWNER_LFNST) &&
            rd_cmd_lfnst_valid_q) begin
            lfnst_gather_rd_data =
                input_rd_data[rd_cmd_slot_q][rd_cmd_lfnst_bank_q];
            lfnst_gather_rd_valid =
                input_rd_valid[rd_cmd_slot_q][rd_cmd_lfnst_bank_q];
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
        kernel_start     = ((kernel_phase_q == K_V_START) &&
                            !kernel_start_sent_q) ||
                           ((kernel_phase_q == K_H_START) &&
                            !kernel_start_sent_q &&
                            kernel_h_rd_raw_pending_q &&
                            !kernel_h_input_commit_wait_q);
        if (!kernel_stage_q && !lfnst_case_q)
            kernel_in_valid = ((kernel_phase_q == K_V_START) ||
                               (kernel_phase_q == K_V_FEED)) &&
                              kernel_rd_resp_valid_q &&
                              !kernel_input_vector_done;
        else if (kernel_stage_q)
            kernel_in_valid = ((kernel_phase_q == K_H_START) ||
                               (kernel_phase_q == K_H_FEED)) &&
                              kernel_h_rd_raw_pending_q &&
                              !kernel_h_input_commit_wait_q &&
                              !kernel_input_vector_done;
        else
            kernel_in_valid = (kernel_start ||
                              (kernel_phase_q == K_V_FEED)) &&
                              !kernel_input_vector_done;
        kernel_in_data = '0;
        for (kernel_lane_i = 0; kernel_lane_i < 4;
             kernel_lane_i = kernel_lane_i + 1) begin
            if (kernel_stage_q)
                kernel_sample_index_i = kernel_h_rd_raw_group_q * 4 +
                                        kernel_lane_i;
            else
                kernel_sample_index_i = kernel_feed_group_q * 4 + kernel_lane_i;
            if (kernel_in_valid && !kernel_stage_q) begin
                if (kernel_sample_index_i < kernel_cut_h_q) begin
                    if (lfnst_case_q) begin
                        if ((kernel_sample_index_i < kernel_cut_h_q) &&
                            (kernel_vector_q < kernel_cut_w_q) &&
                            lfnst_grid_valid[kernel_sample_index_i * 8 + kernel_vector_q])
                            kernel_in_data[kernel_lane_i*16 +: 16] =
                                lfnst_grid[kernel_sample_index_i * 8 + kernel_vector_q];
                    end else if (kernel_rd_resp_valid_q)
                        kernel_in_data[kernel_lane_i*16 +: 16] =
                            kernel_rd_resp_data_q[kernel_lane_i*16 +: 16];
                end
            end else if (kernel_in_valid && kernel_stage_q) begin
                // The vertical transform writes only its transform-support
                // cut.  Horizontal reads outside that cut must be treated as
                // zero rather than exposing stale words left in the
                // generation-tagged intermediate RAM.  This is especially
                // important for DST7/DCT8-32, whose support is 16.
                if ((kernel_sample_index_i < kernel_cut_w_q) &&
                    (kernel_h_rd_raw_vector_q < kernel_cut_h_q))
                    kernel_in_data[kernel_lane_i*16 +: 16] =
                        kernel_h_rd_data_q[
                            tmp_bank_for(kernel_h_rd_raw_vector_q,
                                         kernel_sample_index_i)*16 +: 16];
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

    // A vertical output group is a real write transaction only when the
    // kernel output is being accepted by the wrapper.  The command fields are
    // generated from the current group metadata and then captured into the
    // registered boundary below.  The intermediate RAMs never see these live
    // kernel signals directly.
    integer vwrite_gen_bank_i;
    integer vwrite_gen_lane_i;
    always_comb begin : vwrite_command_generate
        vertical_result_fire = kernel_run_q &&
                               (kernel_phase_q == K_V_DRAIN) &&
                               kernel_out_valid && kernel_out_req;
        vwrite_cmd_bank_mask_c = 4'b0000;
        vwrite_cmd_addr_c = '0;
        vwrite_cmd_last_c = 1'b0;
        for (vwrite_gen_bank_i = 0; vwrite_gen_bank_i < 4;
             vwrite_gen_bank_i = vwrite_gen_bank_i + 1)
            vwrite_cmd_data_c[vwrite_gen_bank_i] = '0;

        if (vertical_result_fire) begin
            vwrite_cmd_addr_c = tmp_local_for_vwrite(
                kernel_drain_group_q, kernel_w_q, kernel_vector_q);
            vwrite_cmd_last_c =
                (kernel_vector_q == (kernel_cut_w_q - 1'b1)) &&
                (kernel_drain_group_q == ((kernel_cut_h_q >> 2) - 1'b1));
            for (vwrite_gen_bank_i = 0; vwrite_gen_bank_i < 4;
                 vwrite_gen_bank_i = vwrite_gen_bank_i + 1) begin
                // Inverse of bank=(row+column)&3 for row=4*group+lane.
                // The subtraction is only two-bit modulo-4 permutation.
                vwrite_gen_lane_i =
                    (vwrite_gen_bank_i - (kernel_vector_q & 3)) & 3;
                if ((kernel_drain_group_q * 4 + vwrite_gen_lane_i) <
                    kernel_cut_h_q) begin
                    vwrite_cmd_bank_mask_c[vwrite_gen_bank_i] = 1'b1;
                    vwrite_cmd_data_c[vwrite_gen_bank_i] =
                        $signed(kernel_out_data[vwrite_gen_lane_i*16 +: 16]);
                end
            end
        end
    end

    // A valid registered command is committed by the simple RAMs on this
    // edge.  Capture and commit may occur on the same edge for consecutive
    // groups, preserving write-command II=1.
    assign vwrite_cmd_commit = vwrite_cmd_valid_q;

`ifndef SYNTHESIS
    // The simplified V-write map is checked against the original generic
    // coordinate formula in simulation.  Since a supported vertical group
    // has four valid lanes, the explicit permutation must cover every bank
    // exactly once and all bank commands must share one local address.
    integer vwrite_assert_lane_i;
    integer vwrite_assert_lane_j;
    always @(posedge clk) begin
        if (vertical_result_fire) begin
            assert (vwrite_cmd_bank_mask_c == 4'b1111)
                else $error("P3 V-write bank collision/missing bank: mask=%b",
                            vwrite_cmd_bank_mask_c);
            assert (vwrite_cmd_addr_c ==
                    tmp_local_for(kernel_drain_group_q * 4,
                                  kernel_vector_q,
                                  kernel_w_q))
                else $error("P3 V-write local address mismatch");
            for (vwrite_assert_lane_i = 0;
                 vwrite_assert_lane_i < 4;
                 vwrite_assert_lane_i = vwrite_assert_lane_i + 1)
                for (vwrite_assert_lane_j = vwrite_assert_lane_i + 1;
                     vwrite_assert_lane_j < 4;
                     vwrite_assert_lane_j = vwrite_assert_lane_j + 1)
                    assert ((((vwrite_assert_lane_i +
                               (kernel_vector_q & 3)) & 3) !=
                              ((vwrite_assert_lane_j +
                               (kernel_vector_q & 3)) & 3)))
                        else $error("P3 V-write lane bank collision");
        end
        if (vwrite_cmd_commit)
            assert (vwrite_cmd_bank_mask_q != 4'b0000)
                else $error("P3 empty V-write command committed");
        if (horizontal_result_fire) begin
            assert (result_cmd_bank_mask_c == 4'b1111)
                else $error("P6 result write missing bank: mask=%b",
                            result_cmd_bank_mask_c);
            // Equivalence-only check: the old two-dimensional expression is
            // retained here under simulation, but never drives a RAM port.
            assert (result_cmd_addr_c ==
                    (kernel_vector_q * (kernel_w_q >> 2) + kernel_drain_group_q))
                else $error("P6 result beat address mismatch");
        end
        if (result_cmd_commit)
            assert (result_cmd_bank_mask_q != 4'b0000)
                else $error("P6 empty result write command committed");

        // P9 round 3 sparse-fill command invariants.  The target is one
        // physical slot/bank for every valid command, and data/valid writes
        // must be paired on that same commit edge.
        if (fill_wr_cmd_valid_q) begin
            assert ($onehot({fill_wr_cmd_target_q[1],
                             fill_wr_cmd_target_q[0]}))
                else $error("P9 fill command target is not onehot");
            for (vwrite_assert_lane_i = 0;
                 vwrite_assert_lane_i < 2;
                 vwrite_assert_lane_i = vwrite_assert_lane_i + 1)
                for (vwrite_assert_lane_j = 0;
                     vwrite_assert_lane_j < 4;
                     vwrite_assert_lane_j = vwrite_assert_lane_j + 1)
                    if (fill_wr_cmd_target_q[vwrite_assert_lane_i]
                                                        [vwrite_assert_lane_j]) begin
                        assert (input_data_wr_en[vwrite_assert_lane_i]
                                                        [vwrite_assert_lane_j] &&
                                input_valid_wr_en[vwrite_assert_lane_i]
                                                        [vwrite_assert_lane_j])
                            else $error("P9 fill data/valid commit mismatch");
                        assert (input_data_wr_addr[vwrite_assert_lane_i]
                                                         [vwrite_assert_lane_j] ==
                                fill_wr_cmd_addr_q)
                            else $error("P9 fill data address mismatch");
                        assert (input_valid_wr_addr[vwrite_assert_lane_i]
                                                          [vwrite_assert_lane_j] ==
                                fill_wr_cmd_addr_q)
                            else $error("P9 fill valid address mismatch");
                    end
            if (scrub_active)
                assert (!fill_wr_cmd_target_q[scrub_slot])
                    else $error("P9 fill commit conflicts with scrub slot");
        end
        if (fill_end_pending_q)
            assert (slot_state[fill_end_slot_q] != SLOT_READY)
                else $error("P9 slot became READY with fill write pending");
        if (input_end_fire && !input_fire)
            assert ((fill_wr_cmd_target_c[0] == 4'b0000) &&
                    (fill_wr_cmd_target_c[1] == 4'b0000))
                else $error("P9 end-only marker generated a data command");
    end
`endif

    // A kernel request is only a real group transaction when the kernel's own
    // ownership/admission condition is true.  In particular, the vertical
    // START phase may last one cycle while the first cache read is in flight;
    // using the wrapper-visible ready signal alone would advance the phase
    // before any data was actually accepted.
    always_comb begin
        kernel_group_accept = kernel_input_group_fire;
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
                           (output_index == output_last_index);
        it_done = output_last_fire;
    end

    // All memory writes are reduced to one fixed command per physical bank.
    // The wrapper may have several logical producers (sparse input, scrub,
    // vertical kernel results, and horizontal output), but ownership/state
    // makes these producers mutually exclusive for a given memory.
    always_comb begin : memory_command_comb
        integer cmd_slot_i, cmd_bank_i;
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
            // Intermediate writes are driven exclusively by the registered
            // V-write command.  This is the physical timing cut: no live
            // kernel_group/vector/address decode reaches the RAM port.
            tmp_wr_en[cmd_bank_i] = vwrite_cmd_valid_q &&
                                    vwrite_cmd_bank_mask_q[cmd_bank_i];
            tmp_wr_addr[cmd_bank_i] = vwrite_cmd_addr_q;
            tmp_wr_data[cmd_bank_i] = vwrite_cmd_data_q[cmd_bank_i];
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

        // P9 round 3: the sparse-fill command is the only live source allowed
        // to drive the input-cache write ports.  Address and data are held
        // from command Q even when valid is low; command validity selects the
        // single target bank, while the matching valid-memory write is issued
        // on the same commit edge as the data write.
        for (cmd_slot_i = 0; cmd_slot_i < 2; cmd_slot_i = cmd_slot_i + 1) begin
            for (cmd_bank_i = 0; cmd_bank_i < 4; cmd_bank_i = cmd_bank_i + 1) begin
                input_data_wr_en[cmd_slot_i][cmd_bank_i] =
                    fill_wr_cmd_valid_q && fill_wr_cmd_target_q[cmd_slot_i][cmd_bank_i];
                input_data_wr_addr[cmd_slot_i][cmd_bank_i] = fill_wr_cmd_addr_q;
                input_data_wr_data[cmd_slot_i][cmd_bank_i] = fill_wr_cmd_data_q;
                // Preserve a scrub valid-clear command when no fill command
                // targets this bank.  The previous unconditional assignments
                // overwrote scrub's write-enable/address/data with zeros on
                // every scrub cycle, leaving stale valid tags when a slot was
                // reused by a later TU.  If a fill command is present it owns
                // the same data/valid commit edge (and wins only for its
                // one-hot target); a scrub on a different slot remains active.
                if (fill_wr_cmd_valid_q &&
                    fill_wr_cmd_target_q[cmd_slot_i][cmd_bank_i]) begin
                    input_valid_wr_en[cmd_slot_i][cmd_bank_i] = 1'b1;
                    input_valid_wr_addr[cmd_slot_i][cmd_bank_i] = fill_wr_cmd_addr_q;
                    input_valid_wr_data[cmd_slot_i][cmd_bank_i] = 1'b1;
                end
            end
        end

        // P9 round 5: the temporary-bank read address is a registered value.
        // Keep it driving the asynchronous RAM unconditionally; pending/run/
        // stage are transaction-valid metadata and must not form an address
        // mux in front of the RAMD64E address pins.  When no request is
        // pending, the address simply retains its last value and the response
        // path ignores the RAM data.
        for (cmd_bank_i = 0; cmd_bank_i < 4; cmd_bank_i = cmd_bank_i + 1)
            tmp_rd_addr[cmd_bank_i] = kernel_h_rd_addr_q[cmd_bank_i];

        // ResultMemory writes are driven only by the registered command below.
        // The live horizontal counters therefore cannot reach a distributed
        // RAM write-enable/address endpoint in this timing interval.
        if (result_cmd_valid_q) begin
            result_wr_en[result_cmd_slot_q][0] = result_cmd_bank_mask_q[0];
            result_wr_en[result_cmd_slot_q][1] = result_cmd_bank_mask_q[1];
            result_wr_en[result_cmd_slot_q][2] = result_cmd_bank_mask_q[2];
            result_wr_en[result_cmd_slot_q][3] = result_cmd_bank_mask_q[3];
            for (cmd_bank_i = 0; cmd_bank_i < 4; cmd_bank_i = cmd_bank_i + 1) begin
                result_wr_addr[result_cmd_slot_q][cmd_bank_i] = result_cmd_addr_q;
                result_wr_data[result_cmd_slot_q][cmd_bank_i] = result_cmd_data_q[cmd_bank_i];
            end
        end
    end

    // Capture one horizontal result group per cycle.  Legal widths are
    // multiples of four, so each accepted group writes exactly one word in
    // every physical bank.  The monotonically increasing beat counter is the
    // raster-order local address; it replaces the live vector*groups+group
    // expression on the physical RAM path.
    integer result_gen_bank_i;
    always_comb begin : result_command_generate
        horizontal_result_fire = kernel_run_q &&
                                 (kernel_phase_q == K_H_DRAIN) &&
                                 kernel_out_valid && kernel_out_req;
        result_cmd_bank_mask_c = 4'b0000;
        result_cmd_addr_c = result_write_beat_q;
        result_cmd_last_c = horizontal_result_fire &&
                            (result_write_beat_q ==
                             slot_output_last_index[compute_slot_q]);
        for (result_gen_bank_i = 0; result_gen_bank_i < 4;
             result_gen_bank_i = result_gen_bank_i + 1)
            result_cmd_data_c[result_gen_bank_i] = '0;
        if (horizontal_result_fire) begin
            result_cmd_bank_mask_c = 4'b1111;
            for (result_gen_bank_i = 0; result_gen_bank_i < 4;
                 result_gen_bank_i = result_gen_bank_i + 1)
                result_cmd_data_c[result_gen_bank_i] =
                    final_adapter($signed(kernel_out_data[result_gen_bank_i*16 +: 16]));
        end
    end

    assign result_cmd_commit = result_cmd_valid_q;

    integer reset_i, lfnst_grid_i;
    integer rd_cmd_reset_slot_i, rd_cmd_reset_bank_i;
    integer rd_cmd_load_slot_i, rd_cmd_load_bank_i;
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
            output_last_index <= 12'd0;
            compute_slot_q <= 1'b0;
            kernel_run_q <= 1'b0;
            kernel_phase_q <= K_IDLE;
            kernel_w_q <= 7'd0;
            kernel_h_q <= 7'd0;
            kernel_cut_w_q <= 7'd0;
            kernel_cut_h_q <= 7'd0;
            kernel_vector_q <= 7'd0;
            kernel_feed_group_q <= 5'd0;
            kernel_drain_group_q <= 5'd0;
            kernel_type_q <= 2'd0;
            kernel_stage_q <= 1'b0;
            kernel_ctx_stage_q <= 1'b0;
            kernel_ctx_transform_size_q <= 7'd0;
            kernel_ctx_active_size_q <= 7'd0;
            kernel_ctx_output_size_q <= 7'd0;
            kernel_ctx_group_count_q <= 6'd0;
            vwrite_cmd_valid_q <= 1'b0;
            vwrite_cmd_bank_mask_q <= 4'b0000;
            vwrite_cmd_addr_q <= '0;
            vwrite_cmd_last_q <= 1'b0;
            vwrite_last_commit_seen_q <= 1'b0;
            for (kernel_capture_lane_i = 0; kernel_capture_lane_i < 4;
                 kernel_capture_lane_i = kernel_capture_lane_i + 1)
                vwrite_cmd_data_q[kernel_capture_lane_i] <= '0;
            result_cmd_valid_q <= 1'b0;
            result_cmd_slot_q <= 1'b0;
            result_cmd_bank_mask_q <= 4'b0000;
            result_cmd_addr_q <= '0;
            result_cmd_last_q <= 1'b0;
            result_last_commit_seen_q <= 1'b0;
            result_write_beat_q <= '0;
            for (kernel_capture_lane_i = 0; kernel_capture_lane_i < 4;
                 kernel_capture_lane_i = kernel_capture_lane_i + 1)
                result_cmd_data_q[kernel_capture_lane_i] <= '0;
            fill_wr_cmd_valid_q <= 1'b0;
            fill_wr_cmd_addr_q <= '0;
            fill_wr_cmd_data_q <= '0;
            fill_end_pending_q <= 1'b0;
            fill_end_slot_q <= 1'b0;
            for (reset_i = 0; reset_i < 2; reset_i = reset_i + 1)
                fill_wr_cmd_target_q[reset_i] <= 4'b0000;
            kernel_rd_req_pending_q <= 1'b0;
            kernel_rd_req_group_q <= 5'd0;
            kernel_rd_req_vector_q <= 7'd0;
            kernel_rd_resp_data_q <= '0;
            kernel_rd_resp_valid_q <= 1'b0;
            kernel_rd_raw_data_q <= '0;
            kernel_rd_raw_valid_q <= '0;
            kernel_rd_raw_pending_q <= 1'b0;
            kernel_rd_raw_group_q <= 5'd0;
            kernel_rd_raw_vector_q <= 7'd0;
            rd_cmd_valid_q <= 1'b0;
            rd_cmd_owner_q <= RD_OWNER_PRIMARY_V;
            rd_cmd_slot_q <= 1'b0;
            rd_cmd_bank_mask_q <= 4'b0000;
            rd_cmd_group_q <= 5'd0;
            rd_cmd_vector_q <= 7'd0;
            rd_cmd_lfnst_is_tail_q <= 1'b0;
            rd_cmd_lfnst_index_q <= 5'd0;
            rd_cmd_lfnst_grid_addr_q <= 6'd0;
            rd_cmd_lfnst_valid_q <= 1'b0;
            rd_cmd_lfnst_last_q <= 1'b0;
            rd_cmd_lfnst_bank_q <= 2'd0;
            for (rd_cmd_reset_slot_i = 0;
                 rd_cmd_reset_slot_i < 2;
                 rd_cmd_reset_slot_i = rd_cmd_reset_slot_i + 1)
                for (rd_cmd_reset_bank_i = 0;
                     rd_cmd_reset_bank_i < 4;
                     rd_cmd_reset_bank_i = rd_cmd_reset_bank_i + 1)
                    rd_cmd_addr_q[rd_cmd_reset_slot_i][rd_cmd_reset_bank_i] <= '0;
            kernel_h_rd_pending_q <= 1'b0;
            kernel_h_rd_group_q <= 5'd0;
            kernel_h_rd_vector_q <= 7'd0;
            kernel_h_width_q <= 7'd0;
            kernel_h_groups_per_row_q <= 5'd0;
            kernel_h_groups_left_q <= 5'd0;
            kernel_h_rows_left_q <= 7'd0;
            kernel_h_row_phase_q <= 2'd0;
            kernel_h_rd_data_q <= '0;
            kernel_h_rd_raw_pending_q <= 1'b0;
            kernel_h_rd_raw_group_q <= 5'd0;
            kernel_h_rd_raw_vector_q <= 7'd0;
            kernel_h_rd_data_tail_q <= '0;
            kernel_h_rd_raw_tail_pending_q <= 1'b0;
            kernel_h_rd_raw_tail_group_q <= 5'd0;
            kernel_h_rd_raw_tail_vector_q <= 7'd0;
            kernel_h_input_commit_wait_q <= 1'b0;
            for (kernel_h_seq_addr_i = 0; kernel_h_seq_addr_i < 4;
                 kernel_h_seq_addr_i = kernel_h_seq_addr_i + 1) begin
                kernel_h_rd_addr_q[kernel_h_seq_addr_i] <= '0;
                kernel_h_row_base_q[kernel_h_seq_addr_i] <=
                    BANK_ADDR_W'(kernel_h_seq_addr_i);
            end
            kernel_start_sent_q <= 1'b0;
            lfnst_run_q <= 1'b0;
            lfnst_case_q <= 1'b0;
            lfnst_gather_q <= 1'b0;
            lfnst_gather_index_q <= 5'd0;
            lfnst_tail_q <= 1'b0;
            lfnst_tail_index_q <= 5'd0;
            lfnst_mem_req_q <= 1'b0;
            lfnst_mem_req_is_tail_q <= 1'b0;
            lfnst_mem_req_index_q <= 5'd0;
            lfnst_mem_req_grid_addr_q <= 6'd0;
            lfnst_mem_req_addr_q <= '0;
            lfnst_mem_req_valid_q <= 1'b0;
            lfnst_mem_req_last_q <= 1'b0;
            lfnst_mem_req_slot_q <= 1'b0;
            lfnst_mem_req_bank_q <= 2'd0;
            lfnst_mem_resp_pending_q <= 1'b0;
            lfnst_mem_resp_is_tail_q <= 1'b0;
            lfnst_mem_resp_index_q <= 5'd0;
            lfnst_mem_resp_grid_addr_q <= 6'd0;
            lfnst_mem_resp_data_q <= '0;
            lfnst_mem_resp_valid_q <= 1'b0;
            lfnst_mem_resp_last_q <= 1'b0;
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
                slot_point_count[reset_i] <= 13'd0;
                slot_last_input_addr[reset_i] <= 12'd0;
                slot_output_last_index[reset_i] <= 12'd0;
            end
            for (lfnst_grid_i = 0; lfnst_grid_i < 64; lfnst_grid_i = lfnst_grid_i + 1) begin
                lfnst_grid[lfnst_grid_i] <= '0;
                lfnst_grid_valid[lfnst_grid_i] <= 1'b0;
            end
        end else begin
            // A one-cycle pulse starts the bounded LFNST engine on the next
            // edge, after compute_slot_q and its descriptor metadata settle.
            lfnst_start_q <= 1'b0;

            // P9 round 3 sparse-fill write command.  The old command commits
            // on this edge; a newly accepted point may refill the same entry
            // without a bubble.  The command Q fields, rather than the live
            // fill slot/address decode, drive the cache write ports.
            if (fill_wr_cmd_commit) begin
                fill_wr_cmd_valid_q <= 1'b0;
                fill_wr_cmd_target_q[0] <= 4'b0000;
                fill_wr_cmd_target_q[1] <= 4'b0000;
            end
            if (input_fire) begin
                fill_wr_cmd_valid_q <= 1'b1;
                fill_wr_cmd_addr_q <= fill_wr_cmd_addr_c;
                fill_wr_cmd_data_q <= fill_wr_cmd_data_c;
                fill_wr_cmd_target_q[0] <= fill_wr_cmd_target_c[0];
                fill_wr_cmd_target_q[1] <= fill_wr_cmd_target_c[1];
            end

            // P9 second round physical-read command boundary.  A command is
            // retired only when its owner response slot can capture the
            // asynchronous RAM result.  If that retirement and a new logical
            // request coincide, the bundle is atomically refilled in the same
            // edge; otherwise the command remains held without advancing any
            // request counters.
            if (rd_cmd_ready) begin
                if (rd_cmd_accept) begin
                    rd_cmd_valid_q <= 1'b1;
                    rd_cmd_owner_q <= rd_cmd_candidate_owner;
                    rd_cmd_slot_q <= rd_cmd_candidate_slot;
                    rd_cmd_bank_mask_q <= rd_cmd_candidate_bank_mask;
                    rd_cmd_group_q <= rd_cmd_candidate_group;
                    rd_cmd_vector_q <= rd_cmd_candidate_vector;
                    rd_cmd_lfnst_is_tail_q <=
                        rd_cmd_candidate_lfnst_is_tail;
                    rd_cmd_lfnst_index_q <=
                        rd_cmd_candidate_lfnst_index;
                    rd_cmd_lfnst_grid_addr_q <=
                        rd_cmd_candidate_lfnst_grid_addr;
                    rd_cmd_lfnst_valid_q <=
                        rd_cmd_candidate_lfnst_valid;
                    rd_cmd_lfnst_last_q <=
                        rd_cmd_candidate_lfnst_last;
                    rd_cmd_lfnst_bank_q <=
                        rd_cmd_candidate_lfnst_bank;
                    for (rd_cmd_load_slot_i = 0;
                         rd_cmd_load_slot_i < 2;
                         rd_cmd_load_slot_i = rd_cmd_load_slot_i + 1)
                        for (rd_cmd_load_bank_i = 0;
                             rd_cmd_load_bank_i < 4;
                             rd_cmd_load_bank_i = rd_cmd_load_bank_i + 1)
                            rd_cmd_addr_q[rd_cmd_load_slot_i][rd_cmd_load_bank_i] <=
                                rd_cmd_candidate_addr_c[rd_cmd_load_slot_i]
                                                                   [rd_cmd_load_bank_i];
                end else begin
                    rd_cmd_valid_q <= 1'b0;
                    rd_cmd_bank_mask_q <= 4'b0000;
                end
            end

            // P3 vertical write-command pipeline.  The old command is
            // committed by the intermediate RAMs on this edge; a new result
            // group may replace it at the same edge, preserving II=1.
            if (vwrite_cmd_commit && vwrite_cmd_last_q)
                vwrite_last_commit_seen_q <= 1'b1;
            if (vertical_result_fire) begin
                vwrite_cmd_valid_q <= 1'b1;
                vwrite_cmd_bank_mask_q <= vwrite_cmd_bank_mask_c;
                vwrite_cmd_addr_q <= vwrite_cmd_addr_c;
                vwrite_cmd_last_q <= vwrite_cmd_last_c;
                for (kernel_capture_lane_i = 0;
                     kernel_capture_lane_i < 4;
                     kernel_capture_lane_i = kernel_capture_lane_i + 1)
                    vwrite_cmd_data_q[kernel_capture_lane_i] <=
                        vwrite_cmd_data_c[kernel_capture_lane_i];
            end else begin
                vwrite_cmd_valid_q <= 1'b0;
                vwrite_cmd_bank_mask_q <= 4'b0000;
                vwrite_cmd_addr_q <= '0;
                vwrite_cmd_last_q <= 1'b0;
            end
            if (compute_valid)
                vwrite_last_commit_seen_q <= 1'b0;

            // P6 horizontal result-write command pipeline.  The registered
            // command is committed by ResultMemory on this edge while a new
            // horizontal result may be captured for the next edge, preserving
            // one accepted result group per cycle.
            if (result_cmd_commit && result_cmd_last_q)
                result_last_commit_seen_q <= 1'b1;
            if (horizontal_result_fire) begin
                result_cmd_valid_q <= 1'b1;
                result_cmd_slot_q <= compute_slot_q;
                result_cmd_bank_mask_q <= result_cmd_bank_mask_c;
                result_cmd_addr_q <= result_cmd_addr_c;
                result_cmd_last_q <= result_cmd_last_c;
                for (kernel_capture_lane_i = 0;
                     kernel_capture_lane_i < 4;
                     kernel_capture_lane_i = kernel_capture_lane_i + 1)
                    result_cmd_data_q[kernel_capture_lane_i] <=
                        result_cmd_data_c[kernel_capture_lane_i];
                result_write_beat_q <= result_write_beat_q + 1'b1;
            end else begin
                result_cmd_valid_q <= 1'b0;
                result_cmd_bank_mask_q <= 4'b0000;
                result_cmd_addr_q <= '0;
                result_cmd_last_q <= 1'b0;
            end
            if (compute_valid) begin
                result_last_commit_seen_q <= 1'b0;
                result_write_beat_q <= '0;
            end

            // Primary vertical reads use a raw-bank register followed by a
            // packed response register.  The response is held until the
            // kernel accepts it; both stages can advance on the same edge, so
            // the steady-state group cadence remains one group per cycle.
            if (kernel_start)
                kernel_start_sent_q <= 1'b1;
            if (!kernel_run_q || kernel_stage_q || lfnst_case_q) begin
                kernel_rd_req_pending_q <= 1'b0;
                kernel_rd_resp_valid_q <= 1'b0;
                kernel_rd_raw_pending_q <= 1'b0;
            end else begin
                if (kernel_rd_raw_to_resp) begin
                    kernel_rd_resp_data_q <= kernel_rd_data_comb;
                    kernel_rd_resp_valid_q <= kernel_rd_valid_comb;
                end else if (kernel_group_accept) begin
                    kernel_rd_resp_valid_q <= 1'b0;
                end

                if (kernel_rd_raw_capture) begin
                    for (kernel_capture_lane_i = 0;
                         kernel_capture_lane_i < 4;
                         kernel_capture_lane_i = kernel_capture_lane_i + 1) begin
                        kernel_rd_raw_data_q[kernel_capture_lane_i*16 +: 16] <=
                            input_rd_data[rd_cmd_slot_q][kernel_capture_lane_i];
                        kernel_rd_raw_valid_q[kernel_capture_lane_i] <=
                            rd_cmd_bank_mask_q[kernel_capture_lane_i] &&
                            input_rd_valid[rd_cmd_slot_q][kernel_capture_lane_i];
                    end
                    kernel_rd_raw_pending_q <= 1'b1;
                    kernel_rd_raw_group_q <= rd_cmd_group_q;
                    kernel_rd_raw_vector_q <= rd_cmd_vector_q;
                end else if (kernel_rd_raw_to_resp) begin
                    kernel_rd_raw_pending_q <= 1'b0;
                end

                // The request counter advances when the logical request is
                // accepted into the atomic command bundle, not when the
                // asynchronous RAM response later retires.
                if (primary_logical_req_fire) begin
                    if (kernel_rd_req_group_q ==
                        ((kernel_cut_h_q >> 2) - 1'b1)) begin
                        kernel_rd_req_pending_q <= 1'b0;
                    end else begin
                        kernel_rd_req_group_q <= kernel_rd_req_group_q + 1'b1;
                    end
                end
            end

            // Horizontal intermediate reads have a registered request
            // address followed by a bank-response register.  A response can
            // be replaced on the same edge on which the kernel accepts the
            // previous group, so the steady-state group cadence remains one.
            if (!kernel_run_q || !kernel_stage_q ||
                ((kernel_phase_q != K_H_START) &&
                 (kernel_phase_q != K_H_FEED))) begin
                kernel_h_rd_pending_q <= 1'b0;
                kernel_h_rd_raw_pending_q <= 1'b0;
                kernel_h_rd_raw_tail_pending_q <= 1'b0;
            end else if (kernel_h_input_commit_wait_q &&
                         !kernel_input_vector_done) begin
                // The last H input group has fired into the kernel ingress,
                // but input_mem is not complete until the next commit edge.
                // Hold all read/request state during this one-cycle handoff;
                // otherwise K_H_START can prefetch the next row, and that
                // response would be dropped when the phase changes to drain.
            end else begin
                // Start a new horizontal row by issuing group zero.  The
                // address is captured here; tmp RAM is read during the next
                // cycle and sampled into the response register afterwards.
                if ((kernel_phase_q == K_H_START) &&
                    !kernel_h_rd_pending_q &&
                    !kernel_h_rd_raw_pending_q) begin
                    kernel_h_rd_group_q <= 5'd0;
                    kernel_h_rd_vector_q <= kernel_vector_q;
                    kernel_h_groups_left_q <= kernel_h_groups_per_row_q;
                    for (kernel_h_seq_addr_i = 0; kernel_h_seq_addr_i < 4;
                         kernel_h_seq_addr_i = kernel_h_seq_addr_i + 1)
                        kernel_h_rd_addr_q[kernel_h_seq_addr_i] <=
                            kernel_h_row_base_q[kernel_h_seq_addr_i];
                    kernel_h_rd_pending_q <= 1'b1;
                end

                if (kernel_h_rd_capture) begin
                    // If the head is free, fill it.  If the head is being
                    // consumed, replace it directly; otherwise fill the
                    // elastic tail entry.  All response metadata advances
                    // with the associated four-bank data bundle.
                    if (!kernel_h_rd_raw_pending_q) begin
                        for (kernel_h_seq_capture_bank_i = 0;
                             kernel_h_seq_capture_bank_i < 4;
                             kernel_h_seq_capture_bank_i =
                                 kernel_h_seq_capture_bank_i + 1)
                            kernel_h_rd_data_q[kernel_h_seq_capture_bank_i*16 +: 16] <=
                                tmp_rd_data[kernel_h_seq_capture_bank_i];
                        kernel_h_rd_raw_group_q <= kernel_h_rd_group_q;
                        kernel_h_rd_raw_vector_q <= kernel_h_rd_vector_q;
                        kernel_h_rd_raw_pending_q <= 1'b1;
                    end else if (kernel_h_rd_consume) begin
                        if (kernel_h_rd_raw_tail_pending_q) begin
                            kernel_h_rd_data_q <= kernel_h_rd_data_tail_q;
                            kernel_h_rd_raw_group_q <= kernel_h_rd_raw_tail_group_q;
                            kernel_h_rd_raw_vector_q <= kernel_h_rd_raw_tail_vector_q;
                            for (kernel_h_seq_capture_bank_i = 0;
                                 kernel_h_seq_capture_bank_i < 4;
                                 kernel_h_seq_capture_bank_i =
                                     kernel_h_seq_capture_bank_i + 1)
                                kernel_h_rd_data_tail_q[kernel_h_seq_capture_bank_i*16 +: 16] <=
                                    tmp_rd_data[kernel_h_seq_capture_bank_i];
                            kernel_h_rd_raw_tail_group_q <= kernel_h_rd_group_q;
                            kernel_h_rd_raw_tail_vector_q <= kernel_h_rd_vector_q;
                            kernel_h_rd_raw_tail_pending_q <= 1'b1;
                        end else begin
                            for (kernel_h_seq_capture_bank_i = 0;
                                 kernel_h_seq_capture_bank_i < 4;
                                 kernel_h_seq_capture_bank_i =
                                     kernel_h_seq_capture_bank_i + 1)
                                kernel_h_rd_data_q[kernel_h_seq_capture_bank_i*16 +: 16] <=
                                    tmp_rd_data[kernel_h_seq_capture_bank_i];
                            kernel_h_rd_raw_group_q <= kernel_h_rd_group_q;
                            kernel_h_rd_raw_vector_q <= kernel_h_rd_vector_q;
                            kernel_h_rd_raw_tail_pending_q <= 1'b0;
                        end
                    end else begin
                        for (kernel_h_seq_capture_bank_i = 0;
                             kernel_h_seq_capture_bank_i < 4;
                             kernel_h_seq_capture_bank_i =
                                 kernel_h_seq_capture_bank_i + 1)
                            kernel_h_rd_data_tail_q[kernel_h_seq_capture_bank_i*16 +: 16] <=
                                tmp_rd_data[kernel_h_seq_capture_bank_i];
                        kernel_h_rd_raw_tail_group_q <= kernel_h_rd_group_q;
                        kernel_h_rd_raw_tail_vector_q <= kernel_h_rd_vector_q;
                        kernel_h_rd_raw_tail_pending_q <= 1'b1;
                    end

                    if (kernel_h_groups_left_q > 5'd1) begin
                        // The next group in the same row is a fixed local
                        // increment.  No width/row decode is on this path.
                        kernel_h_groups_left_q <=
                            kernel_h_groups_left_q - 1'b1;
                        kernel_h_rd_group_q <= kernel_h_rd_next_group;
                        for (kernel_h_seq_addr_i = 0; kernel_h_seq_addr_i < 4;
                             kernel_h_seq_addr_i = kernel_h_seq_addr_i + 1)
                            kernel_h_rd_addr_q[kernel_h_seq_addr_i] <=
                                kernel_h_rd_addr_advance_c[kernel_h_seq_addr_i];
                        kernel_h_rd_pending_q <= 1'b1;
                    end else if (kernel_h_rows_left_q > 7'd1) begin
                        // The final group of a row is complete.  Prepare the
                        // next row base using only registered row state; the
                        // next request itself is issued at K_H_START after
                        // the kernel drains this row.
                        kernel_h_rows_left_q <=
                            kernel_h_rows_left_q - 1'b1;
                        kernel_h_groups_left_q <= kernel_h_groups_per_row_q;
                        kernel_h_row_phase_q <= kernel_h_row_phase_q + 1'b1;
                        for (kernel_h_seq_addr_i = 0;
                             kernel_h_seq_addr_i < 4;
                             kernel_h_seq_addr_i = kernel_h_seq_addr_i + 1)
                            kernel_h_row_base_q[kernel_h_seq_addr_i] <=
                                kernel_h_row_base_next_c[kernel_h_seq_addr_i];
                        kernel_h_rd_group_q <= 5'd0;
                        kernel_h_rd_pending_q <= 1'b0;
                    end else begin
                        kernel_h_groups_left_q <= 5'd0;
                        kernel_h_rows_left_q <= 7'd0;
                        kernel_h_rd_pending_q <= 1'b0;
                    end
                end else if (kernel_h_rd_consume) begin
                    if (kernel_h_rd_raw_tail_pending_q) begin
                        kernel_h_rd_data_q <= kernel_h_rd_data_tail_q;
                        kernel_h_rd_raw_group_q <= kernel_h_rd_raw_tail_group_q;
                        kernel_h_rd_raw_vector_q <= kernel_h_rd_raw_tail_vector_q;
                        kernel_h_rd_raw_pending_q <= 1'b1;
                        kernel_h_rd_raw_tail_pending_q <= 1'b0;
                    end else begin
                        kernel_h_rd_raw_pending_q <= 1'b0;
                    end
                end
            end

            // A logical LFNST request remains held until the atomic physical
            // command accepts it.  When it is accepted, the next gather/tail
            // request may refill this logical-request register on the same
            // edge, preserving one request per cycle in steady state.
            lfnst_mem_resp_pending_q <= 1'b0;
            if (lfnst_mem_req_q && lfnst_mem_req_accept)
                lfnst_mem_req_q <= 1'b0;

            // Commit the registered cache response.  This is deliberately a
            // separate edge from both address generation and cache read, so
            // the source-index/address network cannot reach the term/grid
            // write endpoint in one long combinational path.
            if (lfnst_mem_resp_pending_q) begin
                if (lfnst_mem_resp_is_tail_q) begin
                    lfnst_grid[lfnst_mem_resp_grid_addr_q] <=
                        lfnst_mem_resp_valid_q ? lfnst_mem_resp_data_q : '0;
                    lfnst_grid_valid[lfnst_mem_resp_grid_addr_q] <=
                        lfnst_mem_resp_valid_q;
                end else begin
                    lfnst_input_terms_q[lfnst_mem_resp_index_q*16 +: 16] <=
                        lfnst_mem_resp_valid_q ? lfnst_mem_resp_data_q : '0;
                end

                if (lfnst_mem_resp_last_q) begin
                    if (lfnst_mem_resp_is_tail_q) begin
                        lfnst_tail_q <= 1'b0;
                        lfnst_start_q <= 1'b1;
                    end else if (lfnst_ntrs48_q) begin
                        // The 48-term LFNST replaces only the first 48
                        // diagonal coefficients.  Preserve the remaining 16
                        // low-frequency-grid coefficients from the input TU.
                        lfnst_tail_q <= 1'b1;
                        lfnst_tail_index_q <= 5'd0;
                    end else begin
                        lfnst_start_q <= 1'b1;
                    end
                end
            end

            // Issue one bank-local request per cycle.  The address and all
            // source metadata are registered here; the response is captured
            // on the following edge and committed one edge after that.
            if ((lfnst_gather_q || lfnst_tail_q) &&
                (!lfnst_mem_req_q || lfnst_mem_req_accept)) begin
                integer issue_index_i, issue_row_i, issue_col_i;
                integer issue_bank_i, issue_local_i, issue_grid_addr_i;
                issue_index_i = lfnst_gather_q ? lfnst_gather_index_q :
                                (48 + lfnst_tail_index_q);
                issue_row_i = scan_row_lut(issue_index_i,
                                           lfnst_ntrs48_q ? 8 : 4);
                issue_col_i = scan_col_lut(issue_index_i,
                                           lfnst_ntrs48_q ? 8 : 4);
                issue_bank_i = cache_bank_for(issue_row_i, issue_col_i);
                issue_local_i = cache_local_for(issue_row_i, issue_col_i);
                issue_grid_addr_i = issue_row_i * 8 + issue_col_i;

                lfnst_mem_req_q <= 1'b1;
                lfnst_mem_req_is_tail_q <= lfnst_tail_q;
                lfnst_mem_req_index_q <= lfnst_gather_q ?
                                         lfnst_gather_index_q : 5'd0;
                lfnst_mem_req_grid_addr_q <= issue_grid_addr_i[5:0];
                lfnst_mem_req_addr_q <= issue_local_i[BANK_ADDR_W-1:0];
                lfnst_mem_req_valid_q <=
                    (issue_row_i < slot_height[lfnst_slot_q]) &&
                    (issue_col_i < slot_width[lfnst_slot_q]);
                lfnst_mem_req_last_q <= lfnst_gather_q ?
                                        (lfnst_gather_index_q == 5'd15) :
                                        (lfnst_tail_index_q == 5'd15);
                lfnst_mem_req_slot_q <= lfnst_slot_q;
                lfnst_mem_req_bank_q <= issue_bank_i[1:0];

                if (lfnst_gather_q) begin
                    if (lfnst_gather_index_q == 5'd15)
                        lfnst_gather_q <= 1'b0;
                    else
                        lfnst_gather_index_q <= lfnst_gather_index_q + 1'b1;
                end else begin
                    if (lfnst_tail_index_q == 5'd15)
                        lfnst_tail_q <= 1'b0;
                    else
                        lfnst_tail_index_q <= lfnst_tail_index_q + 1'b1;
                end
            end

            // Capture the asynchronous cache read addressed by the physical
            // command.  Metadata is copied from that same command so a tail
            // write can never be associated with a different gather index.
            if (rd_cmd_response_fire &&
                (rd_cmd_owner_q == RD_OWNER_LFNST)) begin
                lfnst_mem_resp_pending_q <= 1'b1;
                lfnst_mem_resp_is_tail_q <= rd_cmd_lfnst_is_tail_q;
                lfnst_mem_resp_index_q <= rd_cmd_lfnst_index_q;
                lfnst_mem_resp_grid_addr_q <= rd_cmd_lfnst_grid_addr_q;
                lfnst_mem_resp_data_q <=
                    input_rd_data[rd_cmd_slot_q][rd_cmd_lfnst_bank_q];
                lfnst_mem_resp_valid_q <= rd_cmd_lfnst_valid_q &&
                    input_rd_valid[rd_cmd_slot_q][rd_cmd_lfnst_bank_q];
                lfnst_mem_resp_last_q <= rd_cmd_lfnst_last_q;
            end

            if (it_info_vld && !descriptor_legal)
                protocol_error <= 1'b1;
            if (it_info_vld && (desc_count == 2'd2) && !bind_event)
                protocol_error <= 1'b1;
            if (input_fire &&
                (it_data_addr > slot_last_input_addr[fill_slot]))
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
                slot_point_count[bind_slot] <= bind_point_count_c;
                slot_last_input_addr[bind_slot] <= bind_point_count_c[11:0] - 1'b1;
                slot_output_last_index[bind_slot] <=
                    (bind_point_count_c >> 2) - 1'b1;
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

            // P9 round 3 completion barrier.  End is an independent protocol
            // event and may accompany the final sparse word.  In that case
            // the word has only been captured into the command Q on this
            // edge, so the slot must remain owned by the fill until the next
            // edge commits it to both data_mem and valid_mem.
            if (fill_end_pending_q && fill_wr_cmd_commit) begin
                slot_state[fill_end_slot_q] <= SLOT_READY;
                fill_end_pending_q <= 1'b0;
            end
            if (input_end_fire) begin
                fill_active <= 1'b0;
                fill_end_slot_q <= fill_slot;
                if (input_fire) begin
                    // The accepted point is the command that still needs a
                    // commit edge; defer SLOT_READY until that commit.
                    fill_end_pending_q <= 1'b1;
                end else begin
                    // An end-only marker has no new data command.  Any older
                    // command is committed on this same edge, so the slot is
                    // complete now; no phantom data write is generated.
                    slot_state[fill_slot] <= SLOT_READY;
                    fill_end_pending_q <= 1'b0;
                end
            end

            if (compute_valid) begin
                slot_state[compute_slot] <= SLOT_OUT;
                compute_slot_q <= compute_slot;
                kernel_h_input_commit_wait_q <= 1'b0;
                output_index  <= 12'd0;
                output_last_index <= slot_output_last_index[compute_slot];
                // Seed the horizontal bank-local address sequencer once per
                // admitted TU.  Row zero maps columns 0..3 to banks 0..3;
                // subsequent rows are generated by the registered rotation
                // recurrence, so kernel_w_q never reaches a RAM-address D
                // endpoint during steady-state H reads.
                kernel_h_width_q <= slot_width[compute_slot];
                // Horizontal reads cover the transform-support input cut,
                // not the full output width.  For DST7/DCT8 (for example a
                // 32-point transform with a 16-point support cut), the
                // kernel accepts only cut_w/4 input groups while it still
                // emits width/4 output groups.  Keeping these two counts
                // distinct is required by the P8 real-fire contract.
                kernel_h_groups_per_row_q <=
                    kernel_cut_dim(slot_hor[compute_slot],
                                   slot_width[compute_slot]) >> 2;
                kernel_h_groups_left_q <=
                    kernel_cut_dim(slot_hor[compute_slot],
                                   slot_width[compute_slot]) >> 2;
                kernel_h_rows_left_q <= slot_height[compute_slot];
                kernel_h_row_phase_q <= 2'd0;
                for (kernel_h_seq_addr_i = 0;
                     kernel_h_seq_addr_i < 4;
                     kernel_h_seq_addr_i = kernel_h_seq_addr_i + 1)
                    kernel_h_row_base_q[kernel_h_seq_addr_i] <=
                        BANK_ADDR_W'(kernel_h_seq_addr_i);
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
                    // Freeze the complete vertical kernel context at TU
                    // admission.  The P4 ready/capacity path consumes the
                    // predecoded group count rather than a live stage mux.
                    kernel_ctx_stage_q <= 1'b0;
                    kernel_ctx_transform_size_q <= slot_height[compute_slot];
                    kernel_ctx_active_size_q <=
                        kernel_cut_dim(slot_ver[compute_slot],
                                       slot_height[compute_slot]);
                    kernel_ctx_output_size_q <=
                        kernel_cut_dim(slot_ver[compute_slot],
                                       slot_height[compute_slot]);
                    kernel_ctx_group_count_q <=
                        kernel_cut_dim(slot_ver[compute_slot],
                                       slot_height[compute_slot]) >> 2;
                    kernel_vector_q <= 7'd0;
                    kernel_feed_group_q <= 5'd0;
                    kernel_drain_group_q <= 5'd0;
                    kernel_type_q <= slot_ver[compute_slot];
                    kernel_stage_q <= 1'b0;
                    kernel_rd_req_pending_q <= 1'b1;
                    kernel_rd_req_group_q <= 5'd0;
                    kernel_rd_req_vector_q <= 7'd0;
                    kernel_rd_resp_valid_q <= 1'b0;
                    kernel_rd_raw_pending_q <= 1'b0;
                    kernel_start_sent_q <= 1'b0;
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
                    kernel_feed_group_q <= 5'd0;
                    kernel_drain_group_q <= 5'd0;
                    kernel_rd_req_pending_q <= 1'b0;
                    kernel_rd_resp_valid_q <= 1'b0;
                    kernel_rd_raw_pending_q <= 1'b0;
                    kernel_start_sent_q <= 1'b0;
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
                                scan_row_lut(lfnst_out_group * 4 + kernel_capture_lane_i,
                                         lfnst_ntrs48_q ? 8 : 4) *
                                8 +
                                scan_col_lut(lfnst_out_group * 4 + kernel_capture_lane_i,
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
                    // LFNST writeback is followed by the same DCT2
                    // vertical pass as an LFNST-off transaction.  The
                    // phase-entry context must be populated here as well;
                    // otherwise the P7 context registers retain reset values
                    // and the kernel sees an invalid zero-size configuration.
                    kernel_ctx_stage_q <= 1'b0;
                    kernel_ctx_transform_size_q <= kernel_h_q;
                    kernel_ctx_active_size_q <= kernel_cut_h_q;
                    kernel_ctx_output_size_q <= kernel_cut_h_q;
                    kernel_ctx_group_count_q <= kernel_cut_h_q >> 2;
                    // After LFNST, the horizontal input domain is the
                    // LFNST support cut (4 or 8 columns), even when the
                    // output transform width is larger.  Re-seed the
                    // bank-local H-read group count from that cut; the
                    // kernel still emits the full output-width group count.
                    kernel_h_groups_per_row_q <= kernel_cut_w_q >> 2;
                    kernel_h_groups_left_q <= kernel_cut_w_q >> 2;
                    kernel_vector_q <= 7'd0;
                    kernel_feed_group_q <= 5'd0;
                    kernel_drain_group_q <= 5'd0;
                    kernel_rd_req_pending_q <= 1'b0;
                    kernel_rd_resp_valid_q <= 1'b0;
                    kernel_rd_raw_pending_q <= 1'b0;
                    kernel_start_sent_q <= 1'b0;
                    kernel_h_input_commit_wait_q <= 1'b0;
                end
            end

            if (kernel_run_q) begin
                case (kernel_phase_q)
                    K_V_START: begin
                        // The same-edge fire is retained as a local feed
                        // transaction event, but it no longer drives the wide
                        // phase mux.  START->FEED is driven by the registered
                        // wrapper-local start-issued state; FEED->DRAIN is
                        // driven only by the registered input_vector_done
                        // token.
                        if (kernel_input_vector_done) begin
                            kernel_feed_group_q <= 5'd0;
                            kernel_drain_group_q <= 5'd0;
                            kernel_phase_q <= K_V_DRAIN;
                        end else begin
                            if (kernel_input_group_fire) begin
                                if (kernel_feed_group_q + 1'b1 <
                                    kernel_ctx_group_count_q)
                                    kernel_feed_group_q <=
                                        kernel_feed_group_q + 1'b1;
                                else
                                    kernel_feed_group_q <= 5'd0;
                            end
                            if (kernel_start_sent_q)
                                kernel_phase_q <= K_V_FEED;
                        end
                    end
                    K_V_FEED: begin
                        if (kernel_input_vector_done) begin
                            kernel_feed_group_q <= 5'd0;
                            kernel_drain_group_q <= 5'd0;
                            kernel_phase_q <= K_V_DRAIN;
                        end else if (kernel_input_group_fire) begin
                            if (kernel_feed_group_q + 1'b1 <
                                kernel_ctx_group_count_q)
                                kernel_feed_group_q <=
                                    kernel_feed_group_q + 1'b1;
                            else
                                kernel_feed_group_q <= 5'd0;
                        end
                    end
                    K_V_DRAIN: begin
                        if (kernel_out_valid)
                            kernel_drain_group_q <=
                                kernel_drain_group_q + 1'b1;
                        if (kernel_done) begin
                            kernel_feed_group_q <= 5'd0;
                            kernel_drain_group_q <= 5'd0;
                            if (kernel_vector_q + 1'b1 < kernel_cut_w_q) begin
                                kernel_vector_q <= kernel_vector_q + 1'b1;
                                kernel_rd_req_pending_q <= 1'b1;
                                kernel_rd_req_group_q <= 5'd0;
                                kernel_rd_req_vector_q <= kernel_vector_q + 1'b1;
                                kernel_rd_resp_valid_q <= 1'b0;
                                kernel_rd_raw_pending_q <= 1'b0;
                                kernel_start_sent_q <= 1'b0;
                                kernel_phase_q <= K_V_START;
                            end else begin
                                kernel_vector_q <= 7'd0;
                                kernel_rd_req_pending_q <= 1'b0;
                                kernel_rd_resp_valid_q <= 1'b0;
                                kernel_rd_raw_pending_q <= 1'b0;
                                kernel_start_sent_q <= 1'b0;
                                // The final V result may have just filled the
                                // registered write command.  Wait until that
                                // command is committed before admitting H.
                                kernel_phase_q <= K_V_WAIT_COMMIT;
                            end
                        end
                    end
                    K_V_WAIT_COMMIT: begin
                        // vwrite_last_commit_seen_q is set on the edge that
                        // writes the old registered command into intermediate
                        // RAM.  This state therefore cannot observe a stale
                        // pre-NBA "empty" pending bit and start H early.
                        if (vwrite_last_commit_seen_q &&
                            !vwrite_cmd_valid_q) begin
                            kernel_type_q <= slot_hor[compute_slot_q];
                            kernel_stage_q <= 1'b1;
                            // Switch the kernel through a registered
                            // phase-entry context.  H dimensions and group
                            // count are stable for the entire H pass; no
                            // kernel_stage ? V : H mux remains in the
                            // ready/accept feedback cone.
                            kernel_ctx_stage_q <= 1'b1;
                            kernel_ctx_transform_size_q <=
                                kernel_w_q;
                            kernel_ctx_active_size_q <=
                                kernel_cut_w_q;
                            kernel_ctx_output_size_q <=
                                kernel_w_q;
                            kernel_ctx_group_count_q <= kernel_w_q >> 2;
                            kernel_rd_req_pending_q <= 1'b0;
                            kernel_rd_resp_valid_q <= 1'b0;
                            kernel_rd_raw_pending_q <= 1'b0;
                            kernel_start_sent_q <= 1'b0;
                            vwrite_last_commit_seen_q <= 1'b0;
                            kernel_h_input_commit_wait_q <= 1'b0;
                            kernel_phase_q <= K_H_START;
                        end
                    end
                    K_H_START: begin
                        if (kernel_input_vector_done) begin
                            kernel_feed_group_q <= 5'd0;
                            kernel_drain_group_q <= 5'd0;
                            kernel_h_input_commit_wait_q <= 1'b0;
                            kernel_phase_q <= K_H_DRAIN;
                        end else begin
                            if (kernel_input_group_fire) begin
                                if (kernel_feed_group_q + 1'b1 <
                                    kernel_ctx_group_count_q)
                                    kernel_feed_group_q <=
                                        kernel_feed_group_q + 1'b1;
                                if (kernel_h_input_last_fire_c) begin
                                    kernel_feed_group_q <= 5'd0;
                                    // The final H input group has been
                                    // accepted into the kernel ingress, but
                                    // its payload is not in input_mem until
                                    // the following commit edge.  Freeze the
                                    // H-read sequencer until the registered
                                    // completion token arrives.
                                    kernel_h_input_commit_wait_q <= 1'b1;
                                end
                            end
                            if (kernel_start_sent_q)
                                kernel_phase_q <= K_H_FEED;
                        end
                    end
                    K_H_FEED: begin
                        if (kernel_input_vector_done) begin
                            kernel_feed_group_q <= 5'd0;
                            kernel_drain_group_q <= 5'd0;
                            kernel_h_input_commit_wait_q <= 1'b0;
                            kernel_phase_q <= K_H_DRAIN;
                        end else if (kernel_input_group_fire) begin
                            if (kernel_feed_group_q + 1'b1 <
                                kernel_ctx_group_count_q)
                                kernel_feed_group_q <=
                                    kernel_feed_group_q + 1'b1;
                            if (kernel_h_input_last_fire_c) begin
                                kernel_feed_group_q <= 5'd0;
                                kernel_h_input_commit_wait_q <= 1'b1;
                            end
                        end
                    end
                    K_H_DRAIN: begin
                        if (kernel_out_valid)
                            kernel_drain_group_q <=
                                kernel_drain_group_q + 1'b1;
                        if (kernel_done) begin
                            kernel_feed_group_q <= 5'd0;
                            kernel_drain_group_q <= 5'd0;
                            // Horizontal transform is run once for every
                            // vertical output row.  Keep the same P4 group
                            // cadence while advancing to the next row; only
                            // the final row hands ownership to the output
                            // protocol.
                            if (kernel_vector_q + 1'b1 < kernel_h_q) begin
                                kernel_vector_q <= kernel_vector_q + 1'b1;
                                kernel_start_sent_q <= 1'b0;
                                kernel_h_input_commit_wait_q <= 1'b0;
                                kernel_phase_q <= K_H_START;
                            end else begin
                                // The final horizontal group may have just
                                // filled result_cmd_q.  Keep the kernel
                                // context alive until that command has really
                                // committed to ResultMemory; output_active
                                // must never expose a partially written TU.
                                kernel_phase_q <= K_H_WAIT_COMMIT;
                                kernel_rd_req_pending_q <= 1'b0;
                                kernel_rd_resp_valid_q <= 1'b0;
                                kernel_rd_raw_pending_q <= 1'b0;
                                kernel_start_sent_q <= 1'b0;
                            end
                        end
                    end
                    K_H_WAIT_COMMIT: begin
                        if (result_last_commit_seen_q &&
                            !result_cmd_valid_q) begin
                            kernel_run_q <= 1'b0;
                            kernel_phase_q <= K_IDLE;
                            kernel_h_input_commit_wait_q <= 1'b0;
                            result_last_commit_seen_q <= 1'b0;
                            output_active <= 1'b1;
                            output_slot <= compute_slot_q;
                            output_index <= 12'd0;
                        end
                    end
                    default: kernel_phase_q <= K_IDLE;
                endcase
            end
        end
    end

endmodule
