`timescale 1ns/1ps

// Step12B functional wrapper: one frozen R4C instance, 64x64 DCT2xDCT2,
// LFNST disabled.  This file is intentionally a functional/protocol
// prototype; it is not the V3.4 top and has not yet been through Vivado.
// The R4C source is included unchanged and result_accept is permanently 1.
module step12b_dct2_64_wrapper #(
    parameter integer VECTOR_ID_W = 16,
    parameter integer EPOCH_BITS = 8
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire [21:0]                  it_info,
    input  wire                         it_info_vld,
    input  wire signed [15:0]           it_data_in,
    input  wire [11:0]                  it_data_addr,
    input  wire                         it_data_in_vld,
    input  wire                         it_data_end,
    output reg                          it_data_in_req,
    input  wire                         it_data_out_req,
    output reg  [39:0]                  it_data_out,
    output reg                          it_data_out_vld,
    output reg                          it_done,
    output reg                          protocol_error,
    output reg                          debug_stage16_valid,
    output reg  [5:0]                   debug_stage16_row,
    output reg  [5:0]                   debug_stage16_col,
    output reg signed [15:0]            debug_stage16_data
);

    localparam [1:0] CACHE_FREE = 2'd0;
    localparam [1:0] CACHE_FILL = 2'd1;
    localparam [1:0] CACHE_READY = 2'd2;
    localparam [1:0] CACHE_BUSY = 2'd3;
    localparam [1:0] PH_IDLE = 2'd0;
    localparam [1:0] PH_VERTICAL = 2'd1;
    localparam [1:0] PH_HORIZONTAL = 2'd2;
    localparam [1:0] PH_WAIT_H = 2'd3;

    // Two physical input caches.  Epoch tags make omitted sparse addresses
    // read as zero without a 4096-cycle clear on every TU.
    // Keep every physical bank as a separate inference candidate.  The
    // staging reader below accesses one fixed bank per lane, so Vivado does
    // not have to infer a multi-dimensional RAM with a variable bank port.
    (* ram_style = "block" *) reg signed [15:0] input_cache_a0 [0:1023];
    (* ram_style = "block" *) reg signed [15:0] input_cache_a1 [0:1023];
    (* ram_style = "block" *) reg signed [15:0] input_cache_a2 [0:1023];
    (* ram_style = "block" *) reg signed [15:0] input_cache_a3 [0:1023];
    (* ram_style = "block" *) reg signed [15:0] input_cache_b0 [0:1023];
    (* ram_style = "block" *) reg signed [15:0] input_cache_b1 [0:1023];
    (* ram_style = "block" *) reg signed [15:0] input_cache_b2 [0:1023];
    (* ram_style = "block" *) reg signed [15:0] input_cache_b3 [0:1023];
    (* ram_style = "block" *) reg [EPOCH_BITS-1:0] input_tag_a0 [0:1023];
    (* ram_style = "block" *) reg [EPOCH_BITS-1:0] input_tag_a1 [0:1023];
    (* ram_style = "block" *) reg [EPOCH_BITS-1:0] input_tag_a2 [0:1023];
    (* ram_style = "block" *) reg [EPOCH_BITS-1:0] input_tag_a3 [0:1023];
    (* ram_style = "block" *) reg [EPOCH_BITS-1:0] input_tag_b0 [0:1023];
    (* ram_style = "block" *) reg [EPOCH_BITS-1:0] input_tag_b1 [0:1023];
    (* ram_style = "block" *) reg [EPOCH_BITS-1:0] input_tag_b2 [0:1023];
    (* ram_style = "block" *) reg [EPOCH_BITS-1:0] input_tag_b3 [0:1023];
    reg [EPOCH_BITS-1:0] cache_epoch [0:1];
    reg [2:0] cache_state [0:1];
    reg cache_scrubbing [0:1];
    reg [9:0] scrub_index [0:1];
    reg [15:0] cache_tu_id [0:1];
    reg [11:0] last_input_addr [0:1];
    reg last_input_valid [0:1];

    // Descriptor queue.  A descriptor is bound before its input data; the
    // one-cycle bind guard enforces the Step12B first-data-next-cycle rule.
    reg [1:0] desc_slot_q [0:1];
    reg [15:0] desc_tu_q [0:1];
    reg [21:0] desc_info_q [0:1];
    reg [1:0] desc_count;
    reg desc_bind_guard;
    reg [15:0] next_tu_serial;

    // One shared intermediate store.  Each bank has a single explicit write
    // process below; the staging reader is the synchronous read side.  This
    // fixed-port form is intentional: Step12C must not leave bank writes to
    // a variable-index loop for Vivado to reconstruct.
    (* ram_style = "block" *) reg signed [15:0] intermediate_mem0 [0:1023];
    (* ram_style = "block" *) reg signed [15:0] intermediate_mem1 [0:1023];
    (* ram_style = "block" *) reg signed [15:0] intermediate_mem2 [0:1023];
    (* ram_style = "block" *) reg signed [15:0] intermediate_mem3 [0:1023];
    // Verification shadow only.  It is not read by the functional datapath
    // and is omitted from synthesis so it cannot consume implementation RAM.
`ifndef SYNTHESIS
    reg signed [15:0] result_stage16_mem [0:4095];
`endif
    reg intermediate_owned;
    reg [1:0] active_cache;
    reg [15:0] active_tu;
    reg [1:0] phase;
    reg [15:0] phase_vector_base;

    // Ping-pong 64-point staging.  A bank is only overwritten after its
    // ready flag has been consumed by the frozen kernel.
    reg signed [15:0] stage_a [0:63];
    reg signed [15:0] stage_b [0:63];
    reg stage_ready_a, stage_ready_b;
    reg load_bank;
    reg [6:0] load_vector;
    reg [4:0] load_group;
    reg [6:0] launch_count;
    reg launch_bank;
    reg [5:0] cycles_since_launch;

    // One staging read request may be issued every edge.  M3 separates the
    // physical bank response register from the staging capture register:
    // request at C -> bank response/metadata at C+1 -> lane permutation and
    // staging capture at C+2.  The request and response metadata pipelines
    // are independent of the R4C datapath and preserve request II=1.
    reg stage_read_pending;
    reg stage_read_phase;
    reg [6:0] stage_read_vector;
    reg [4:0] stage_read_group;
    reg stage_read_cache;
    reg stage_read_bank;
    reg [EPOCH_BITS-1:0] stage_read_epoch;
    // M7 physical-local read addresses.  The four logical bank addresses are
    // copied into the selected physical memory family at the request edge.
    // Data and tag arrays have separate copies so one address net does not
    // fan out across unrelated distributed-RAM instances.  The intermediate
    // family has its own copies as well.  These are timing-localization
    // registers only; they do not add a staging cycle.
    reg [9:0] stage_addr_a_data0_q, stage_addr_a_data1_q;
    reg [9:0] stage_addr_a_data2_q, stage_addr_a_data3_q;
    reg [9:0] stage_addr_a_tag0_q, stage_addr_a_tag1_q;
    reg [9:0] stage_addr_a_tag2_q, stage_addr_a_tag3_q;
    reg [9:0] stage_addr_b_data0_q, stage_addr_b_data1_q;
    reg [9:0] stage_addr_b_data2_q, stage_addr_b_data3_q;
    reg [9:0] stage_addr_b_tag0_q, stage_addr_b_tag1_q;
    reg [9:0] stage_addr_b_tag2_q, stage_addr_b_tag3_q;
    reg [9:0] stage_addr_i_data0_q, stage_addr_i_data1_q;
    reg [9:0] stage_addr_i_data2_q, stage_addr_i_data3_q;
    reg [1:0] stage_read_perm;
    reg stage_rsp_pending_q;
    reg stage_rsp_phase_q;
    reg [6:0] stage_rsp_vector_q;
    reg [4:0] stage_rsp_group_q;
    reg stage_rsp_cache_q;
    reg stage_rsp_bank_q;
    reg [EPOCH_BITS-1:0] stage_rsp_epoch_q;
    reg [1:0] stage_rsp_perm_q;
    reg signed [15:0] stage_rsp_data0_q, stage_rsp_data1_q;
    reg signed [15:0] stage_rsp_data2_q, stage_rsp_data3_q;
    reg [EPOCH_BITS-1:0] stage_rsp_tag0_q, stage_rsp_tag1_q;
    reg [EPOCH_BITS-1:0] stage_rsp_tag2_q, stage_rsp_tag3_q;
    reg stage_rsp_valid0_q, stage_rsp_valid1_q;
    reg stage_rsp_valid2_q, stage_rsp_valid3_q;

    wire r4c_start;
    wire [VECTOR_ID_W-1:0] r4c_vector_id;
    wire [1023:0] r4c_vector_data;
    wire r4c_result_valid;
    wire [4:0] r4c_result_group;
    wire [VECTOR_ID_W-1:0] r4c_result_vector_id;
    wire r4c_result_first, r4c_result_last;
    wire [63:0] r4c_result_stage16;
    wire [39:0] r4c_result_final10;
    wire [159:0] unused_raw, unused_biased, unused_shifted;

    // The counter is the number of completed edges since the last start;
    // a value of 15 at the pre-edge combinational boundary gives an exact
    // 16-cycle start-to-start interval.
    assign r4c_start = ((phase == PH_VERTICAL) || (phase == PH_HORIZONTAL)) &&
                       ((launch_count == 0) || (cycles_since_launch >= 6'd15)) &&
                       ((launch_bank == 1'b0) ? stage_ready_a : stage_ready_b);
    assign r4c_vector_id = phase_vector_base + launch_count;

    genvar gv;
    generate
        for (gv = 0; gv < 64; gv = gv + 1) begin : GEN_STAGE_FLAT
            assign r4c_vector_data[gv*16 +: 16] =
                (launch_bank == 1'b0) ? stage_a[gv] : stage_b[gv];
        end
    endgenerate

    p2f_dct2_64_b1_step102 #(.VECTOR_ID_W(VECTOR_ID_W)) frozen_r4c (
        .clk(clk), .rst_n(rst_n), .vector_start(r4c_start),
        .vector_id_in(r4c_vector_id), .vector_data_flat(r4c_vector_data),
        .result_accept(1'b1), .result_valid(r4c_result_valid),
        .result_group(r4c_result_group), .result_vector_id(r4c_result_vector_id),
        .result_first(r4c_result_first), .result_last(r4c_result_last),
        .result_raw_flat(unused_raw), .result_biased_flat(unused_biased),
        .result_shifted_flat(unused_shifted),
        .result_stage16_flat(r4c_result_stage16),
        .result_final10_flat(r4c_result_final10)
    );

    // Result memory is a 1024-beat logical 40-bit store.  The reader below
    // has one synchronous request cycle and two elastic entries (hold/skid).
    (* ram_style = "block" *) reg [39:0] result_mem [0:1023];
    reg result_present [0:1023];
    reg [10:0] result_reserved;
    reg [10:0] result_occupied;
    reg [10:0] result_produced;
    reg [10:0] result_issued;
    reg [10:0] result_consumed;
    reg result_owner_valid;
    reg [15:0] result_owner_tu;
    reg [9:0] result_read_index;
    reg [9:0] result_issue_index;
    reg result_read_pending;
    reg [9:0] result_pending_index;
    reg result_hold_valid, result_skid_valid;
    reg [39:0] result_hold_data, result_skid_data;
    reg final_compute_seen;

    localparam [2:0] CACHE_SCRUB = 3'd4;
    localparam [1:0] DESC_UNBOUND = 2'd2;

    // M4 input boundary pipeline.  The external transaction is accepted at
    // edge C, then a bank-local command is committed to the physical data/tag
    // arrays at edge C+1.  Each cycle has at most one valid command, but the
    // command is held in the selected physical bank's own registers so that
    // it_data_addr/desc_slot_q do not directly drive all RAM write ports.
    reg input_wr_valid_a0_q, input_wr_valid_a1_q;
    reg input_wr_valid_a2_q, input_wr_valid_a3_q;
    reg input_wr_valid_b0_q, input_wr_valid_b1_q;
    reg input_wr_valid_b2_q, input_wr_valid_b3_q;
    reg [9:0] input_wr_addr_a0_q, input_wr_addr_a1_q;
    reg [9:0] input_wr_addr_a2_q, input_wr_addr_a3_q;
    reg [9:0] input_wr_addr_b0_q, input_wr_addr_b1_q;
    reg [9:0] input_wr_addr_b2_q, input_wr_addr_b3_q;
    reg signed [15:0] input_wr_data_a0_q, input_wr_data_a1_q;
    reg signed [15:0] input_wr_data_a2_q, input_wr_data_a3_q;
    reg signed [15:0] input_wr_data_b0_q, input_wr_data_b1_q;
    reg signed [15:0] input_wr_data_b2_q, input_wr_data_b3_q;
    reg [EPOCH_BITS-1:0] input_wr_epoch_a0_q, input_wr_epoch_a1_q;
    reg [EPOCH_BITS-1:0] input_wr_epoch_a2_q, input_wr_epoch_a3_q;
    reg [EPOCH_BITS-1:0] input_wr_epoch_b0_q, input_wr_epoch_b1_q;
    reg [EPOCH_BITS-1:0] input_wr_epoch_b2_q, input_wr_epoch_b3_q;
    reg input_wr_cache_q, input_wr_last_q;
    wire input_wr_pending = input_wr_valid_a0_q || input_wr_valid_a1_q ||
                            input_wr_valid_a2_q || input_wr_valid_a3_q ||
                            input_wr_valid_b0_q || input_wr_valid_b1_q ||
                            input_wr_valid_b2_q || input_wr_valid_b3_q;
    wire input_wr_last_pending = input_wr_pending && input_wr_last_q;

    // Official contest output contract: vld may rise only when req is high.
    // The internal hold/skid state remains valid and stable while req=0;
    // output_fire is the consuming edge, not the external vld indication.
    always @* begin
        it_data_in_req = 1'b0;
        if ((desc_count != 0) && (desc_slot_q[0] != DESC_UNBOUND) && !desc_bind_guard &&
            !input_wr_last_pending &&
            (cache_state[desc_slot_q[0]] == CACHE_FILL))
            it_data_in_req = 1'b1;
        it_data_out = result_hold_data;
        it_data_out_vld = result_hold_valid && it_data_out_req;
    end

    integer i;
    integer addr_tmp;
    integer bank_tmp;
    integer mem_addr_tmp;
    integer cache_row_tmp;
    integer cache_col_tmp;
    integer row_tmp;
    integer col_tmp;
    integer vec_tmp;
    integer result_idx_tmp;
    reg signed [15:0] read_value_tmp;
    reg [39:0] response_value_tmp;
    reg response_valid_tmp;
    reg output_fire_tmp;
    reg can_load_tmp;
    reg result_hold_v_tmp, result_skid_v_tmp, result_pending_v_tmp;
    reg [39:0] result_hold_d_tmp, result_skid_d_tmp;
    reg [10:0] result_reserved_tmp, result_occupied_tmp;
    reg [10:0] result_produced_tmp, result_issued_tmp, result_consumed_tmp;
    reg result_owner_v_tmp;
    reg [1:0] push_slot_calc;
    integer stage_addr0_tmp, stage_addr1_tmp, stage_addr2_tmp, stage_addr3_tmp;
    reg signed [15:0] stage_lane0_tmp, stage_lane1_tmp;
    reg signed [15:0] stage_lane2_tmp, stage_lane3_tmp;
    reg signed [15:0] stage_bank_data0_tmp, stage_bank_data1_tmp;
    reg signed [15:0] stage_bank_data2_tmp, stage_bank_data3_tmp;
    reg [EPOCH_BITS-1:0] stage_bank_tag0_tmp, stage_bank_tag1_tmp;
    reg [EPOCH_BITS-1:0] stage_bank_tag2_tmp, stage_bank_tag3_tmp;
    reg stage_bank_valid0_tmp, stage_bank_valid1_tmp;
    reg stage_bank_valid2_tmp, stage_bank_valid3_tmp;

    // Raw tag validity is evaluated only after the registered bank response.
    // Horizontal/intermediate responses are intrinsically valid; vertical
    // input-cache responses use the delayed raw tag and request epoch.
    wire stage_rsp_effective_valid0 = stage_rsp_phase_q ? stage_rsp_valid0_q :
                                      (stage_rsp_tag0_q == stage_rsp_epoch_q);
    wire stage_rsp_effective_valid1 = stage_rsp_phase_q ? stage_rsp_valid1_q :
                                      (stage_rsp_tag1_q == stage_rsp_epoch_q);
    wire stage_rsp_effective_valid2 = stage_rsp_phase_q ? stage_rsp_valid2_q :
                                      (stage_rsp_tag2_q == stage_rsp_epoch_q);
    wire stage_rsp_effective_valid3 = stage_rsp_phase_q ? stage_rsp_valid3_q :
                                      (stage_rsp_tag3_q == stage_rsp_epoch_q);

    // The sparse input stream has one write transaction per cycle.  Keeping
    // the decoded bank/address as wires makes the four bank write ports
    // statically visible to synthesis, while preserving the frozen address
    // mapping: bank=row[1:0] XOR col[1:0], addr=row*16+(col>>2).
    wire sparse_input_fire = it_data_in_vld && it_data_in_req;
    wire [1:0] sparse_input_bank = it_data_addr[7:6] ^ it_data_addr[1:0];
    wire [9:0] sparse_input_addr = {it_data_addr[11:6], it_data_addr[5:2]};

    // Select the tag write command before the RAM process.  Scrub has
    // priority over a stale input command, and each physical tag bank below
    // therefore has exactly one variable-address write expression.
    wire tag_wr_en_a0 = cache_scrubbing[0] || input_wr_valid_a0_q;
    wire tag_wr_en_a1 = cache_scrubbing[0] || input_wr_valid_a1_q;
    wire tag_wr_en_a2 = cache_scrubbing[0] || input_wr_valid_a2_q;
    wire tag_wr_en_a3 = cache_scrubbing[0] || input_wr_valid_a3_q;
    wire tag_wr_en_b0 = cache_scrubbing[1] || input_wr_valid_b0_q;
    wire tag_wr_en_b1 = cache_scrubbing[1] || input_wr_valid_b1_q;
    wire tag_wr_en_b2 = cache_scrubbing[1] || input_wr_valid_b2_q;
    wire tag_wr_en_b3 = cache_scrubbing[1] || input_wr_valid_b3_q;
    wire [9:0] tag_wr_addr_a0 = cache_scrubbing[0] ? scrub_index[0] : input_wr_addr_a0_q;
    wire [9:0] tag_wr_addr_a1 = cache_scrubbing[0] ? scrub_index[0] : input_wr_addr_a1_q;
    wire [9:0] tag_wr_addr_a2 = cache_scrubbing[0] ? scrub_index[0] : input_wr_addr_a2_q;
    wire [9:0] tag_wr_addr_a3 = cache_scrubbing[0] ? scrub_index[0] : input_wr_addr_a3_q;
    wire [9:0] tag_wr_addr_b0 = cache_scrubbing[1] ? scrub_index[1] : input_wr_addr_b0_q;
    wire [9:0] tag_wr_addr_b1 = cache_scrubbing[1] ? scrub_index[1] : input_wr_addr_b1_q;
    wire [9:0] tag_wr_addr_b2 = cache_scrubbing[1] ? scrub_index[1] : input_wr_addr_b2_q;
    wire [9:0] tag_wr_addr_b3 = cache_scrubbing[1] ? scrub_index[1] : input_wr_addr_b3_q;
    wire [EPOCH_BITS-1:0] tag_wr_data_a0 = cache_scrubbing[0] ? {EPOCH_BITS{1'b0}} : input_wr_epoch_a0_q;
    wire [EPOCH_BITS-1:0] tag_wr_data_a1 = cache_scrubbing[0] ? {EPOCH_BITS{1'b0}} : input_wr_epoch_a1_q;
    wire [EPOCH_BITS-1:0] tag_wr_data_a2 = cache_scrubbing[0] ? {EPOCH_BITS{1'b0}} : input_wr_epoch_a2_q;
    wire [EPOCH_BITS-1:0] tag_wr_data_a3 = cache_scrubbing[0] ? {EPOCH_BITS{1'b0}} : input_wr_epoch_a3_q;
    wire [EPOCH_BITS-1:0] tag_wr_data_b0 = cache_scrubbing[1] ? {EPOCH_BITS{1'b0}} : input_wr_epoch_b0_q;
    wire [EPOCH_BITS-1:0] tag_wr_data_b1 = cache_scrubbing[1] ? {EPOCH_BITS{1'b0}} : input_wr_epoch_b1_q;
    wire [EPOCH_BITS-1:0] tag_wr_data_b2 = cache_scrubbing[1] ? {EPOCH_BITS{1'b0}} : input_wr_epoch_b2_q;
    wire [EPOCH_BITS-1:0] tag_wr_data_b3 = cache_scrubbing[1] ? {EPOCH_BITS{1'b0}} : input_wr_epoch_b3_q;

    // Vertical result writes are decoded once into one write per physical
    // intermediate bank.  There is at most one lane per bank for a result
    // group, so each bank has a single write enable/address/data in a cycle.
    reg inter_wr_en0, inter_wr_en1, inter_wr_en2, inter_wr_en3;
    reg [9:0] inter_wr_addr0, inter_wr_addr1, inter_wr_addr2, inter_wr_addr3;
    reg signed [15:0] inter_wr_data0, inter_wr_data1, inter_wr_data2, inter_wr_data3;
    // One-cycle V write-command pipeline.  The command is accepted every
    // result group; the bank write processes commit the previous command.
    reg v_wr_valid_q, v_wr_last_q;
    reg [9:0] v_wr_addr0_q, v_wr_addr1_q, v_wr_addr2_q, v_wr_addr3_q;
    reg signed [15:0] v_wr_data0_q, v_wr_data1_q, v_wr_data2_q, v_wr_data3_q;
    reg vertical_commit_done;
    reg [5:0] inter_local_col;
    always @* begin
        inter_wr_en0 = 1'b0;
        inter_wr_en1 = 1'b0;
        inter_wr_en2 = 1'b0;
        inter_wr_en3 = 1'b0;
        inter_wr_addr0 = 10'd0;
        inter_wr_addr1 = 10'd0;
        inter_wr_addr2 = 10'd0;
        inter_wr_addr3 = 10'd0;
        inter_wr_data0 = 16'sd0;
        inter_wr_data1 = 16'sd0;
        inter_wr_data2 = 16'sd0;
        inter_wr_data3 = 16'sd0;
        // The V phase vector window is aligned to a 128-point TU base, so
        // result_vector_id[5:0] is the local column in the 64-vector window.
        // The full-ID window check remains in the verification-only live
        // result checker below.
        inter_local_col = r4c_result_vector_id[5:0];
        if (r4c_result_valid && phase == PH_VERTICAL) begin
            // For row lane i and local column c:
            //   bank = i XOR c[1:0]
            //   addr = {group[3:0], i[1:0], c[5:2]}
            // Each bank receives exactly one lane.  The four fixed cases
            // avoid a general subtract/multiply/variable-bank decode cone.
            inter_wr_en0 = 1'b1;
            inter_wr_en1 = 1'b1;
            inter_wr_en2 = 1'b1;
            inter_wr_en3 = 1'b1;
            case (inter_local_col[1:0])
                2'd0: begin
                    inter_wr_addr0 = {r4c_result_group[3:0], 2'd0, inter_local_col[5:2]};
                    inter_wr_addr1 = {r4c_result_group[3:0], 2'd1, inter_local_col[5:2]};
                    inter_wr_addr2 = {r4c_result_group[3:0], 2'd2, inter_local_col[5:2]};
                    inter_wr_addr3 = {r4c_result_group[3:0], 2'd3, inter_local_col[5:2]};
                    inter_wr_data0 = $signed(r4c_result_stage16[0*16 +: 16]);
                    inter_wr_data1 = $signed(r4c_result_stage16[1*16 +: 16]);
                    inter_wr_data2 = $signed(r4c_result_stage16[2*16 +: 16]);
                    inter_wr_data3 = $signed(r4c_result_stage16[3*16 +: 16]);
                end
                2'd1: begin
                    inter_wr_addr0 = {r4c_result_group[3:0], 2'd1, inter_local_col[5:2]};
                    inter_wr_addr1 = {r4c_result_group[3:0], 2'd0, inter_local_col[5:2]};
                    inter_wr_addr2 = {r4c_result_group[3:0], 2'd3, inter_local_col[5:2]};
                    inter_wr_addr3 = {r4c_result_group[3:0], 2'd2, inter_local_col[5:2]};
                    inter_wr_data0 = $signed(r4c_result_stage16[1*16 +: 16]);
                    inter_wr_data1 = $signed(r4c_result_stage16[0*16 +: 16]);
                    inter_wr_data2 = $signed(r4c_result_stage16[3*16 +: 16]);
                    inter_wr_data3 = $signed(r4c_result_stage16[2*16 +: 16]);
                end
                2'd2: begin
                    inter_wr_addr0 = {r4c_result_group[3:0], 2'd2, inter_local_col[5:2]};
                    inter_wr_addr1 = {r4c_result_group[3:0], 2'd3, inter_local_col[5:2]};
                    inter_wr_addr2 = {r4c_result_group[3:0], 2'd0, inter_local_col[5:2]};
                    inter_wr_addr3 = {r4c_result_group[3:0], 2'd1, inter_local_col[5:2]};
                    inter_wr_data0 = $signed(r4c_result_stage16[2*16 +: 16]);
                    inter_wr_data1 = $signed(r4c_result_stage16[3*16 +: 16]);
                    inter_wr_data2 = $signed(r4c_result_stage16[0*16 +: 16]);
                    inter_wr_data3 = $signed(r4c_result_stage16[1*16 +: 16]);
                end
                default: begin
                    inter_wr_addr0 = {r4c_result_group[3:0], 2'd3, inter_local_col[5:2]};
                    inter_wr_addr1 = {r4c_result_group[3:0], 2'd2, inter_local_col[5:2]};
                    inter_wr_addr2 = {r4c_result_group[3:0], 2'd1, inter_local_col[5:2]};
                    inter_wr_addr3 = {r4c_result_group[3:0], 2'd0, inter_local_col[5:2]};
                    inter_wr_data0 = $signed(r4c_result_stage16[3*16 +: 16]);
                    inter_wr_data1 = $signed(r4c_result_stage16[2*16 +: 16]);
                    inter_wr_data2 = $signed(r4c_result_stage16[1*16 +: 16]);
                    inter_wr_data3 = $signed(r4c_result_stage16[0*16 +: 16]);
                end
            endcase
        end
    end

    // Step12B functional scope is exactly 64x64 DCT2xDCT2 with LFNST off.
    // lfnst_tr_set_idx is retained losslessly but is don't-care when idx=0.
    wire descriptor_supported =
        (it_info[6:0]   == 7'd64) &&
        (it_info[13:7]  == 7'd64) &&
        (it_info[15:14] == 2'd0) &&
        (it_info[17:16] == 2'd0) &&
        (it_info[21:20] == 2'd0);
    wire desc_push_ok = it_info_vld && (desc_count < 2) && descriptor_supported;
    wire input_end_fire = (desc_count != 0) && it_data_end && it_data_in_req;

    // Explicit one-write-port bank processes.  The tag arrays are invalidated
    // by the existing per-cache scrub controller; data words do not need to
    // be cleared because a tag mismatch makes the corresponding value zero.
    // M4 commits the bank-local command captured on the previous edge.  The
    // final command is therefore visible to the cache state machine only on
    // this commit edge, never on the external acceptance edge.
    always @(posedge clk) begin
        if (!cache_scrubbing[0] && input_wr_valid_a0_q)
            input_cache_a0[input_wr_addr_a0_q] <= input_wr_data_a0_q;
        if (tag_wr_en_a0)
            input_tag_a0[tag_wr_addr_a0] <= tag_wr_data_a0;
    end
    always @(posedge clk) begin
        if (!cache_scrubbing[0] && input_wr_valid_a1_q)
            input_cache_a1[input_wr_addr_a1_q] <= input_wr_data_a1_q;
        if (tag_wr_en_a1)
            input_tag_a1[tag_wr_addr_a1] <= tag_wr_data_a1;
    end
    always @(posedge clk) begin
        if (!cache_scrubbing[0] && input_wr_valid_a2_q)
            input_cache_a2[input_wr_addr_a2_q] <= input_wr_data_a2_q;
        if (tag_wr_en_a2)
            input_tag_a2[tag_wr_addr_a2] <= tag_wr_data_a2;
    end
    always @(posedge clk) begin
        if (!cache_scrubbing[0] && input_wr_valid_a3_q)
            input_cache_a3[input_wr_addr_a3_q] <= input_wr_data_a3_q;
        if (tag_wr_en_a3)
            input_tag_a3[tag_wr_addr_a3] <= tag_wr_data_a3;
    end
    always @(posedge clk) begin
        if (!cache_scrubbing[1] && input_wr_valid_b0_q)
            input_cache_b0[input_wr_addr_b0_q] <= input_wr_data_b0_q;
        if (tag_wr_en_b0)
            input_tag_b0[tag_wr_addr_b0] <= tag_wr_data_b0;
    end
    always @(posedge clk) begin
        if (!cache_scrubbing[1] && input_wr_valid_b1_q)
            input_cache_b1[input_wr_addr_b1_q] <= input_wr_data_b1_q;
        if (tag_wr_en_b1)
            input_tag_b1[tag_wr_addr_b1] <= tag_wr_data_b1;
    end
    always @(posedge clk) begin
        if (!cache_scrubbing[1] && input_wr_valid_b2_q)
            input_cache_b2[input_wr_addr_b2_q] <= input_wr_data_b2_q;
        if (tag_wr_en_b2)
            input_tag_b2[tag_wr_addr_b2] <= tag_wr_data_b2;
    end
    always @(posedge clk) begin
        if (!cache_scrubbing[1] && input_wr_valid_b3_q)
            input_cache_b3[input_wr_addr_b3_q] <= input_wr_data_b3_q;
        if (tag_wr_en_b3)
            input_tag_b3[tag_wr_addr_b3] <= tag_wr_data_b3;
    end

    // Intermediate storage has one statically decoded write port per bank.
    // The registered command is committed one edge after the R4C result;
    // this removes the result-vector -> RAM WE timing cone while retaining
    // one command per group.
    always @(posedge clk) if (v_wr_valid_q) intermediate_mem0[v_wr_addr0_q] <= v_wr_data0_q;
    always @(posedge clk) if (v_wr_valid_q) intermediate_mem1[v_wr_addr1_q] <= v_wr_data1_q;
    always @(posedge clk) if (v_wr_valid_q) intermediate_mem2[v_wr_addr2_q] <= v_wr_data2_q;
    always @(posedge clk) if (v_wr_valid_q) intermediate_mem3[v_wr_addr3_q] <= v_wr_data3_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            desc_count <= 0;
            desc_bind_guard <= 0;
            next_tu_serial <= 0;
            cache_epoch[0] <= 0;
            cache_epoch[1] <= 0;
            // Memory arrays are not reset.  Both tag banks start in a real
            // startup scrub and remain unavailable until it completes.
            cache_scrubbing[0] <= 1'b1;
            cache_scrubbing[1] <= 1'b1;
            scrub_index[0] <= 0;
            scrub_index[1] <= 0;
            cache_state[0] <= CACHE_SCRUB;
            cache_state[1] <= CACHE_SCRUB;
            cache_tu_id[0] <= 0;
            cache_tu_id[1] <= 0;
            last_input_addr[0] <= 0;
            last_input_addr[1] <= 0;
            last_input_valid[0] <= 0;
            last_input_valid[1] <= 0;
            intermediate_owned <= 0;
            active_cache <= 0;
            active_tu <= 0;
            phase <= PH_IDLE;
            phase_vector_base <= 0;
            stage_ready_a <= 0;
            stage_ready_b <= 0;
            load_bank <= 0;
            load_vector <= 0;
            load_group <= 0;
            launch_count <= 0;
            launch_bank <= 0;
            cycles_since_launch <= 6'd16;
            stage_read_pending <= 1'b0;
            stage_read_phase <= 1'b0;
            stage_read_vector <= 0;
            stage_read_group <= 0;
            stage_read_cache <= 1'b0;
            stage_read_bank <= 1'b0;
            stage_read_epoch <= 0;
            stage_addr_a_data0_q <= 0;
            stage_addr_a_data1_q <= 0;
            stage_addr_a_data2_q <= 0;
            stage_addr_a_data3_q <= 0;
            stage_addr_a_tag0_q <= 0;
            stage_addr_a_tag1_q <= 0;
            stage_addr_a_tag2_q <= 0;
            stage_addr_a_tag3_q <= 0;
            stage_addr_b_data0_q <= 0;
            stage_addr_b_data1_q <= 0;
            stage_addr_b_data2_q <= 0;
            stage_addr_b_data3_q <= 0;
            stage_addr_b_tag0_q <= 0;
            stage_addr_b_tag1_q <= 0;
            stage_addr_b_tag2_q <= 0;
            stage_addr_b_tag3_q <= 0;
            stage_addr_i_data0_q <= 0;
            stage_addr_i_data1_q <= 0;
            stage_addr_i_data2_q <= 0;
            stage_addr_i_data3_q <= 0;
            stage_read_perm <= 0;
            stage_rsp_pending_q <= 1'b0;
            stage_rsp_phase_q <= 1'b0;
            stage_rsp_vector_q <= 0;
            stage_rsp_group_q <= 0;
            stage_rsp_cache_q <= 1'b0;
            stage_rsp_bank_q <= 1'b0;
            stage_rsp_epoch_q <= 0;
            stage_rsp_perm_q <= 0;
            stage_rsp_data0_q <= 0;
            stage_rsp_data1_q <= 0;
            stage_rsp_data2_q <= 0;
            stage_rsp_data3_q <= 0;
            stage_rsp_tag0_q <= 0;
            stage_rsp_tag1_q <= 0;
            stage_rsp_tag2_q <= 0;
            stage_rsp_tag3_q <= 0;
            stage_rsp_valid0_q <= 1'b0;
            stage_rsp_valid1_q <= 1'b0;
            stage_rsp_valid2_q <= 1'b0;
            stage_rsp_valid3_q <= 1'b0;
            v_wr_valid_q <= 1'b0;
            v_wr_last_q <= 1'b0;
            v_wr_addr0_q <= 0;
            v_wr_addr1_q <= 0;
            v_wr_addr2_q <= 0;
            v_wr_addr3_q <= 0;
            v_wr_data0_q <= 0;
            v_wr_data1_q <= 0;
            v_wr_data2_q <= 0;
            v_wr_data3_q <= 0;
            vertical_commit_done <= 1'b0;
            result_occupied <= 0;
            result_reserved <= 0;
            result_produced <= 0;
            result_issued <= 0;
            result_consumed <= 0;
            result_owner_valid <= 0;
            result_owner_tu <= 0;
            result_read_index <= 0;
            result_issue_index <= 0;
            result_read_pending <= 0;
            result_pending_index <= 0;
            result_hold_valid <= 0;
            result_skid_valid <= 0;
            result_hold_data <= 0;
            result_skid_data <= 0;
            final_compute_seen <= 0;
            it_done <= 0;
            protocol_error <= 0;
            debug_stage16_valid <= 0;
            debug_stage16_row <= 0;
            debug_stage16_col <= 0;
            debug_stage16_data <= 0;
            for (i = 0; i < 1024; i = i + 1) begin
                result_present[i] <= 0;
            end
            for (i = 0; i < 64; i = i + 1) begin
                stage_a[i] <= 0;
                stage_b[i] <= 0;
            end
            desc_info_q[0] <= 0;
            desc_info_q[1] <= 0;
            input_wr_valid_a0_q <= 1'b0;
            input_wr_valid_a1_q <= 1'b0;
            input_wr_valid_a2_q <= 1'b0;
            input_wr_valid_a3_q <= 1'b0;
            input_wr_valid_b0_q <= 1'b0;
            input_wr_valid_b1_q <= 1'b0;
            input_wr_valid_b2_q <= 1'b0;
            input_wr_valid_b3_q <= 1'b0;
            input_wr_addr_a0_q <= 0;
            input_wr_addr_a1_q <= 0;
            input_wr_addr_a2_q <= 0;
            input_wr_addr_a3_q <= 0;
            input_wr_addr_b0_q <= 0;
            input_wr_addr_b1_q <= 0;
            input_wr_addr_b2_q <= 0;
            input_wr_addr_b3_q <= 0;
            input_wr_data_a0_q <= 0;
            input_wr_data_a1_q <= 0;
            input_wr_data_a2_q <= 0;
            input_wr_data_a3_q <= 0;
            input_wr_data_b0_q <= 0;
            input_wr_data_b1_q <= 0;
            input_wr_data_b2_q <= 0;
            input_wr_data_b3_q <= 0;
            input_wr_epoch_a0_q <= 0;
            input_wr_epoch_a1_q <= 0;
            input_wr_epoch_a2_q <= 0;
            input_wr_epoch_a3_q <= 0;
            input_wr_epoch_b0_q <= 0;
            input_wr_epoch_b1_q <= 0;
            input_wr_epoch_b2_q <= 0;
            input_wr_epoch_b3_q <= 0;
            input_wr_cache_q <= 1'b0;
            input_wr_last_q <= 1'b0;
        end else begin
            debug_stage16_valid <= 1'b0;
            it_done <= 1'b0;
            // Clear the one-entry command valid bits.  A new input fire below
            // may set exactly one bank valid again on this same edge, while
            // the bank processes above commit the previous command.
            input_wr_valid_a0_q <= 1'b0;
            input_wr_valid_a1_q <= 1'b0;
            input_wr_valid_a2_q <= 1'b0;
            input_wr_valid_a3_q <= 1'b0;
            input_wr_valid_b0_q <= 1'b0;
            input_wr_valid_b1_q <= 1'b0;
            input_wr_valid_b2_q <= 1'b0;
            input_wr_valid_b3_q <= 1'b0;
            // Commit the previous V write command at this edge and capture
            // the current R4C V group for the next edge.  The explicit last
            // command marker is the only condition that releases H admission.
            v_wr_valid_q <= 1'b0;
            v_wr_last_q <= 1'b0;
            if (v_wr_valid_q && v_wr_last_q)
                vertical_commit_done <= 1'b1;
            if (r4c_result_valid && phase == PH_VERTICAL) begin
                v_wr_valid_q <= 1'b1;
                v_wr_last_q <= (r4c_result_vector_id == (phase_vector_base + 63)) && r4c_result_last;
                v_wr_addr0_q <= inter_wr_addr0;
                v_wr_addr1_q <= inter_wr_addr1;
                v_wr_addr2_q <= inter_wr_addr2;
                v_wr_addr3_q <= inter_wr_addr3;
                v_wr_data0_q <= inter_wr_data0;
                v_wr_data1_q <= inter_wr_data1;
                v_wr_data2_q <= inter_wr_data2;
                v_wr_data3_q <= inter_wr_data3;
            end
            if (desc_bind_guard)
                desc_bind_guard <= 1'b0;

            // Calculate the destination cache for a descriptor from the
            // pre-edge state.  This value is also used when a descriptor push
            // and the active TU's end_fire occur on the same edge; reading
            // q1 in that case would observe the old q1 under NBA semantics.
            push_slot_calc = DESC_UNBOUND;
            if (it_info_vld && desc_count < 2) begin
                if (cache_state[0] == CACHE_FREE && !cache_scrubbing[0] &&
                    cache_epoch[0] != {EPOCH_BITS{1'b1}})
                    push_slot_calc = 0;
                else if (cache_state[1] == CACHE_FREE && !cache_scrubbing[1] &&
                         cache_epoch[1] != {EPOCH_BITS{1'b1}})
                    push_slot_calc = 1;
            end

            // Descriptor admission.  The complete 22-bit descriptor is
            // retained even when both caches are occupied.  Only the FIFO
            // head may own the input stream; data has no TU tag.
            if (it_info_vld) begin
                if (!descriptor_supported) begin
                    protocol_error <= 1'b1;
                end else if (desc_count >= 2) begin
                    protocol_error <= 1'b1;
                end else begin
                    desc_info_q[desc_count] <= it_info;
                    desc_tu_q[desc_count] <= next_tu_serial;
                    if (cache_state[0] == CACHE_FREE && !cache_scrubbing[0] &&
                        cache_epoch[0] != {EPOCH_BITS{1'b1}}) begin
                        desc_slot_q[desc_count] <= 0;
                        cache_state[0] <= CACHE_FILL;
                        cache_tu_id[0] <= next_tu_serial;
                        cache_epoch[0] <= cache_epoch[0] + 1'b1;
                        last_input_addr[0] <= 0;
                        last_input_valid[0] <= 0;
                        if (desc_count == 0) desc_bind_guard <= 1'b1;
                    end else if (cache_state[1] == CACHE_FREE && !cache_scrubbing[1] &&
                                 cache_epoch[1] != {EPOCH_BITS{1'b1}}) begin
                        desc_slot_q[desc_count] <= 1;
                        cache_state[1] <= CACHE_FILL;
                        cache_tu_id[1] <= next_tu_serial;
                        cache_epoch[1] <= cache_epoch[1] + 1'b1;
                        last_input_addr[1] <= 0;
                        last_input_valid[1] <= 0;
                        if (desc_count == 0) desc_bind_guard <= 1'b1;
                    end else begin
                        desc_slot_q[desc_count] <= DESC_UNBOUND;
                        if (cache_state[0] == CACHE_FREE && !cache_scrubbing[0] &&
                            cache_epoch[0] == {EPOCH_BITS{1'b1}}) begin
                            cache_scrubbing[0] <= 1'b1;
                            cache_state[0] <= CACHE_SCRUB;
                            scrub_index[0] <= 0;
                        end else if (cache_state[1] == CACHE_FREE && !cache_scrubbing[1] &&
                                     cache_epoch[1] == {EPOCH_BITS{1'b1}}) begin
                            cache_scrubbing[1] <= 1'b1;
                            cache_state[1] <= CACHE_SCRUB;
                            scrub_index[1] <= 0;
                        end
                    end
                    desc_count <= desc_count + 1'b1;
                    next_tu_serial <= next_tu_serial + 1'b1;
                end
            end

            // Bind a queued descriptor once a cache becomes available.  This
            // is deliberately separate from descriptor push, so descriptor
            // storage does not depend on immediate cache availability.
            if (desc_count != 0 && desc_slot_q[0] == DESC_UNBOUND) begin
                if (cache_state[0] == CACHE_FREE && !cache_scrubbing[0] &&
                    cache_epoch[0] != {EPOCH_BITS{1'b1}}) begin
                    desc_slot_q[0] <= 0;
                    cache_state[0] <= CACHE_FILL;
                    cache_tu_id[0] <= desc_tu_q[0];
                    cache_epoch[0] <= cache_epoch[0] + 1'b1;
                    last_input_addr[0] <= 0;
                    last_input_valid[0] <= 0;
                    desc_bind_guard <= 1'b1;
                end else if (cache_state[1] == CACHE_FREE && !cache_scrubbing[1] &&
                             cache_epoch[1] != {EPOCH_BITS{1'b1}}) begin
                    desc_slot_q[0] <= 1;
                    cache_state[1] <= CACHE_FILL;
                    cache_tu_id[1] <= desc_tu_q[0];
                    cache_epoch[1] <= cache_epoch[1] + 1'b1;
                    last_input_addr[1] <= 0;
                    last_input_valid[1] <= 0;
                    desc_bind_guard <= 1'b1;
                end else if (cache_state[0] == CACHE_FREE && !cache_scrubbing[0] &&
                             cache_epoch[0] == {EPOCH_BITS{1'b1}}) begin
                    cache_scrubbing[0] <= 1'b1;
                    cache_state[0] <= CACHE_SCRUB;
                    scrub_index[0] <= 0;
                end else if (cache_state[1] == CACHE_FREE && !cache_scrubbing[1] &&
                             cache_epoch[1] == {EPOCH_BITS{1'b1}}) begin
                    cache_scrubbing[1] <= 1'b1;
                    cache_state[1] <= CACHE_SCRUB;
                    scrub_index[1] <= 0;
                end
            end

            // The four tag-bank scrub and sparse writes are in the explicit
            // bank processes above.  The cache under scrub is unavailable,
            // while the other A/B cache may continue filling.
            if (cache_scrubbing[0]) begin
                if (scrub_index[0] == 1023) begin
                    cache_scrubbing[0] <= 0;
                    cache_state[0] <= CACHE_FREE;
                    cache_epoch[0] <= {{(EPOCH_BITS-1){1'b0}},1'b1};
                    scrub_index[0] <= 0;
                end else begin
                    scrub_index[0] <= scrub_index[0] + 1'b1;
                end
            end
            if (cache_scrubbing[1]) begin
                if (scrub_index[1] == 1023) begin
                    cache_scrubbing[1] <= 0;
                    cache_state[1] <= CACHE_FREE;
                    cache_epoch[1] <= {{(EPOCH_BITS-1){1'b0}},1'b1};
                    scrub_index[1] <= 0;
                end else begin
                    scrub_index[1] <= scrub_index[1] + 1'b1;
                end
            end

            // Sparse input fire.  The stream is accepted only while the
            // bound cache is filling; data/end in the bind cycle is rejected
            // by it_data_in_req=0.  Addresses are raster-monotonic.
            if (input_wr_pending && input_wr_last_q) begin
                cache_state[input_wr_cache_q] <= CACHE_READY;
                if (desc_count == 2) begin
                    desc_slot_q[0] <= desc_slot_q[1];
                    desc_tu_q[0] <= desc_tu_q[1];
                    desc_info_q[0] <= desc_info_q[1];
                    desc_count <= 1;
                end else if (desc_push_ok) begin
                    desc_slot_q[0] <= push_slot_calc;
                    desc_tu_q[0] <= next_tu_serial;
                    desc_info_q[0] <= it_info;
                    desc_count <= 1;
                end else begin
                    desc_count <= 0;
                end
                desc_bind_guard <= 1'b0;
            end

            if (sparse_input_fire) begin
                if (last_input_valid[desc_slot_q[0]] &&
                    it_data_addr <= last_input_addr[desc_slot_q[0]]) begin
                    protocol_error <= 1'b1;
                end
                last_input_addr[desc_slot_q[0]] <= it_data_addr;
                last_input_valid[desc_slot_q[0]] <= 1'b1;
                input_wr_cache_q <= desc_slot_q[0];
                input_wr_last_q <= it_data_end;
                if (desc_slot_q[0] == 1'b0) begin
                    case (sparse_input_bank)
                        2'd0: begin
                            input_wr_valid_a0_q <= 1'b1;
                            input_wr_addr_a0_q <= sparse_input_addr;
                            input_wr_data_a0_q <= it_data_in;
                            input_wr_epoch_a0_q <= cache_epoch[0];
                        end
                        2'd1: begin
                            input_wr_valid_a1_q <= 1'b1;
                            input_wr_addr_a1_q <= sparse_input_addr;
                            input_wr_data_a1_q <= it_data_in;
                            input_wr_epoch_a1_q <= cache_epoch[0];
                        end
                        2'd2: begin
                            input_wr_valid_a2_q <= 1'b1;
                            input_wr_addr_a2_q <= sparse_input_addr;
                            input_wr_data_a2_q <= it_data_in;
                            input_wr_epoch_a2_q <= cache_epoch[0];
                        end
                        default: begin
                            input_wr_valid_a3_q <= 1'b1;
                            input_wr_addr_a3_q <= sparse_input_addr;
                            input_wr_data_a3_q <= it_data_in;
                            input_wr_epoch_a3_q <= cache_epoch[0];
                        end
                    endcase
                end else begin
                    case (sparse_input_bank)
                        2'd0: begin
                            input_wr_valid_b0_q <= 1'b1;
                            input_wr_addr_b0_q <= sparse_input_addr;
                            input_wr_data_b0_q <= it_data_in;
                            input_wr_epoch_b0_q <= cache_epoch[1];
                        end
                        2'd1: begin
                            input_wr_valid_b1_q <= 1'b1;
                            input_wr_addr_b1_q <= sparse_input_addr;
                            input_wr_data_b1_q <= it_data_in;
                            input_wr_epoch_b1_q <= cache_epoch[1];
                        end
                        2'd2: begin
                            input_wr_valid_b2_q <= 1'b1;
                            input_wr_addr_b2_q <= sparse_input_addr;
                            input_wr_data_b2_q <= it_data_in;
                            input_wr_epoch_b2_q <= cache_epoch[1];
                        end
                        default: begin
                            input_wr_valid_b3_q <= 1'b1;
                            input_wr_addr_b3_q <= sparse_input_addr;
                            input_wr_data_b3_q <= it_data_in;
                            input_wr_epoch_b3_q <= cache_epoch[1];
                        end
                    endcase
                end
            end else if (desc_count != 0 && it_data_in_req && it_data_end) begin
                // Standalone end is legal and completes an otherwise empty
                // sparse TU.
                cache_state[desc_slot_q[0]] <= CACHE_READY;
                if (desc_count == 2) begin
                    desc_slot_q[0] <= desc_slot_q[1];
                    desc_tu_q[0] <= desc_tu_q[1];
                    desc_info_q[0] <= desc_info_q[1];
                    desc_count <= 1;
                end else if (desc_push_ok) begin
                    desc_slot_q[0] <= push_slot_calc;
                    desc_tu_q[0] <= next_tu_serial;
                    desc_info_q[0] <= it_info;
                    desc_count <= 1;
                end else begin
                    desc_count <= 0;
                end
            end else if (it_data_end && !it_data_in_req) begin
                protocol_error <= 1'b1;
            end

            // Start a new vertical phase only after end_fire made a cache
            // READY.  Intermediate storage is single-owner.
            if (phase == PH_IDLE && !intermediate_owned) begin
                if (cache_state[0] == CACHE_READY) begin
                    active_cache <= 0;
                    active_tu <= cache_tu_id[0];
                    phase_vector_base <= cache_tu_id[0] * 16'd128;
                    phase <= PH_VERTICAL;
                    intermediate_owned <= 1'b1;
                    cache_state[0] <= CACHE_BUSY;
                    load_bank <= 0;
                    load_vector <= 0;
                    load_group <= 0;
                    launch_count <= 0;
                    launch_bank <= 0;
                    stage_ready_a <= 0;
                    stage_ready_b <= 0;
                    cycles_since_launch <= 6'd16;
                end else if (cache_state[1] == CACHE_READY) begin
                    active_cache <= 1;
                    active_tu <= cache_tu_id[1];
                    phase_vector_base <= cache_tu_id[1] * 16'd128;
                    phase <= PH_VERTICAL;
                    intermediate_owned <= 1'b1;
                    cache_state[1] <= CACHE_BUSY;
                    load_bank <= 0;
                    load_vector <= 0;
                    load_group <= 0;
                    launch_count <= 0;
                    launch_bank <= 0;
                    stage_ready_a <= 0;
                    stage_ready_b <= 0;
                    cycles_since_launch <= 6'd16;
                end
            end

            // H admission is separately gated by the single ResultMemory
            // owner.  A completed V phase may wait here while an earlier TU
            // is still under output backpressure.
            if (phase == PH_WAIT_H && vertical_commit_done && !v_wr_valid_q && !result_owner_valid) begin
                result_owner_valid <= 1'b1;
                result_owner_tu <= active_tu;
                result_reserved <= 11'd1024;
                result_occupied <= 0;
                result_produced <= 0;
                result_issued <= 0;
                result_consumed <= 0;
                result_read_index <= 0;
                result_issue_index <= 0;
                result_read_pending <= 0;
                result_hold_valid <= 0;
                result_skid_valid <= 0;
                final_compute_seen <= 0;
                phase_vector_base <= active_tu * 16'd128 + 16'd64;
                phase <= PH_HORIZONTAL;
                load_bank <= 0;
                load_vector <= 0;
                load_group <= 0;
                launch_count <= 0;
                launch_bank <= 0;
                stage_ready_a <= 0;
                stage_ready_b <= 0;
                cycles_since_launch <= 6'd16;
                vertical_commit_done <= 1'b0;
            end

            // Four-point-per-cycle staging.  A request is registered here;
            // the response block below consumes the saved metadata one edge
            // later.  The physical bank is selected by a case so each bank
            // has one statically visible read port.
            can_load_tmp = 1'b0;
            if ((phase == PH_VERTICAL || phase == PH_HORIZONTAL) && load_vector < 64) begin
                if ((load_bank == 0 && !stage_ready_a) ||
                    (load_bank == 1 && !stage_ready_b))
                    can_load_tmp = 1'b1;
                if (r4c_start && (load_bank == launch_bank))
                    can_load_tmp = 1'b0;
            end

            // M3 capture stage.  The bank response register above is
            // consumed one edge later, so request C -> bank response C+1
            // -> lane permutation/stage capture C+2.  The selector and all
            // ownership metadata come from the same registered response.
            if (stage_rsp_pending_q) begin
                case (stage_rsp_perm_q)
                    2'd0: begin
                        stage_lane0_tmp = stage_rsp_effective_valid0 ? stage_rsp_data0_q : 16'sd0;
                        stage_lane1_tmp = stage_rsp_effective_valid1 ? stage_rsp_data1_q : 16'sd0;
                        stage_lane2_tmp = stage_rsp_effective_valid2 ? stage_rsp_data2_q : 16'sd0;
                        stage_lane3_tmp = stage_rsp_effective_valid3 ? stage_rsp_data3_q : 16'sd0;
                    end
                    2'd1: begin
                        stage_lane0_tmp = stage_rsp_effective_valid1 ? stage_rsp_data1_q : 16'sd0;
                        stage_lane1_tmp = stage_rsp_effective_valid0 ? stage_rsp_data0_q : 16'sd0;
                        stage_lane2_tmp = stage_rsp_effective_valid3 ? stage_rsp_data3_q : 16'sd0;
                        stage_lane3_tmp = stage_rsp_effective_valid2 ? stage_rsp_data2_q : 16'sd0;
                    end
                    2'd2: begin
                        stage_lane0_tmp = stage_rsp_effective_valid2 ? stage_rsp_data2_q : 16'sd0;
                        stage_lane1_tmp = stage_rsp_effective_valid3 ? stage_rsp_data3_q : 16'sd0;
                        stage_lane2_tmp = stage_rsp_effective_valid0 ? stage_rsp_data0_q : 16'sd0;
                        stage_lane3_tmp = stage_rsp_effective_valid1 ? stage_rsp_data1_q : 16'sd0;
                    end
                    default: begin
                        stage_lane0_tmp = stage_rsp_effective_valid3 ? stage_rsp_data3_q : 16'sd0;
                        stage_lane1_tmp = stage_rsp_effective_valid2 ? stage_rsp_data2_q : 16'sd0;
                        stage_lane2_tmp = stage_rsp_effective_valid1 ? stage_rsp_data1_q : 16'sd0;
                        stage_lane3_tmp = stage_rsp_effective_valid0 ? stage_rsp_data0_q : 16'sd0;
                    end
                endcase
                if (stage_rsp_bank_q == 1'b0) begin
                    stage_a[stage_rsp_group_q*4+0] <= stage_lane0_tmp;
                    stage_a[stage_rsp_group_q*4+1] <= stage_lane1_tmp;
                    stage_a[stage_rsp_group_q*4+2] <= stage_lane2_tmp;
                    stage_a[stage_rsp_group_q*4+3] <= stage_lane3_tmp;
                end else begin
                    stage_b[stage_rsp_group_q*4+0] <= stage_lane0_tmp;
                    stage_b[stage_rsp_group_q*4+1] <= stage_lane1_tmp;
                    stage_b[stage_rsp_group_q*4+2] <= stage_lane2_tmp;
                    stage_b[stage_rsp_group_q*4+3] <= stage_lane3_tmp;
                end
                if (stage_rsp_group_q == 15) begin
                    if (stage_rsp_bank_q == 1'b0) stage_ready_a <= 1'b1;
                    else stage_ready_b <= 1'b1;
                end
            end

            // Bank response register for the previous request.  Each bank is
            // read exactly once here; no lane permutation or bank selection
            // remains in the RAM-to-register path.  The response metadata is
            // delayed with the data so the next block is fully self-routed.
            stage_rsp_pending_q <= stage_read_pending;
            if (stage_read_pending) begin
                stage_rsp_phase_q <= stage_read_phase;
                stage_rsp_vector_q <= stage_read_vector;
                stage_rsp_group_q <= stage_read_group;
                stage_rsp_cache_q <= stage_read_cache;
                stage_rsp_bank_q <= stage_read_bank;
                stage_rsp_epoch_q <= stage_read_epoch;
                stage_rsp_perm_q <= stage_read_perm;
                stage_bank_data0_tmp = 16'sd0;
                stage_bank_data1_tmp = 16'sd0;
                stage_bank_data2_tmp = 16'sd0;
                stage_bank_data3_tmp = 16'sd0;
                stage_bank_tag0_tmp = {EPOCH_BITS{1'b0}};
                stage_bank_tag1_tmp = {EPOCH_BITS{1'b0}};
                stage_bank_tag2_tmp = {EPOCH_BITS{1'b0}};
                stage_bank_tag3_tmp = {EPOCH_BITS{1'b0}};
                stage_bank_valid0_tmp = 1'b0;
                stage_bank_valid1_tmp = 1'b0;
                stage_bank_valid2_tmp = 1'b0;
                stage_bank_valid3_tmp = 1'b0;
                if (stage_read_phase == 1'b0) begin
                    if (stage_read_cache == 1'b0) begin
                        stage_bank_data0_tmp = input_cache_a0[stage_addr_a_data0_q];
                        stage_bank_data1_tmp = input_cache_a1[stage_addr_a_data1_q];
                        stage_bank_data2_tmp = input_cache_a2[stage_addr_a_data2_q];
                        stage_bank_data3_tmp = input_cache_a3[stage_addr_a_data3_q];
                        stage_bank_tag0_tmp = input_tag_a0[stage_addr_a_tag0_q];
                        stage_bank_tag1_tmp = input_tag_a1[stage_addr_a_tag1_q];
                        stage_bank_tag2_tmp = input_tag_a2[stage_addr_a_tag2_q];
                        stage_bank_tag3_tmp = input_tag_a3[stage_addr_a_tag3_q];
                        stage_bank_valid0_tmp = 1'b1;
                        stage_bank_valid1_tmp = 1'b1;
                        stage_bank_valid2_tmp = 1'b1;
                        stage_bank_valid3_tmp = 1'b1;
                    end else begin
                        stage_bank_data0_tmp = input_cache_b0[stage_addr_b_data0_q];
                        stage_bank_data1_tmp = input_cache_b1[stage_addr_b_data1_q];
                        stage_bank_data2_tmp = input_cache_b2[stage_addr_b_data2_q];
                        stage_bank_data3_tmp = input_cache_b3[stage_addr_b_data3_q];
                        stage_bank_tag0_tmp = input_tag_b0[stage_addr_b_tag0_q];
                        stage_bank_tag1_tmp = input_tag_b1[stage_addr_b_tag1_q];
                        stage_bank_tag2_tmp = input_tag_b2[stage_addr_b_tag2_q];
                        stage_bank_tag3_tmp = input_tag_b3[stage_addr_b_tag3_q];
                        stage_bank_valid0_tmp = 1'b1;
                        stage_bank_valid1_tmp = 1'b1;
                        stage_bank_valid2_tmp = 1'b1;
                        stage_bank_valid3_tmp = 1'b1;
                    end
                end else begin
                    stage_bank_data0_tmp = intermediate_mem0[stage_addr_i_data0_q];
                    stage_bank_data1_tmp = intermediate_mem1[stage_addr_i_data1_q];
                    stage_bank_data2_tmp = intermediate_mem2[stage_addr_i_data2_q];
                    stage_bank_data3_tmp = intermediate_mem3[stage_addr_i_data3_q];
                    stage_bank_tag0_tmp = {EPOCH_BITS{1'b0}};
                    stage_bank_tag1_tmp = {EPOCH_BITS{1'b0}};
                    stage_bank_tag2_tmp = {EPOCH_BITS{1'b0}};
                    stage_bank_tag3_tmp = {EPOCH_BITS{1'b0}};
                    stage_bank_valid0_tmp = 1'b1;
                    stage_bank_valid1_tmp = 1'b1;
                    stage_bank_valid2_tmp = 1'b1;
                    stage_bank_valid3_tmp = 1'b1;
                end
                stage_rsp_data0_q <= stage_bank_data0_tmp;
                stage_rsp_data1_q <= stage_bank_data1_tmp;
                stage_rsp_data2_q <= stage_bank_data2_tmp;
                stage_rsp_data3_q <= stage_bank_data3_tmp;
                stage_rsp_tag0_q <= stage_bank_tag0_tmp;
                stage_rsp_tag1_q <= stage_bank_tag1_tmp;
                stage_rsp_tag2_q <= stage_bank_tag2_tmp;
                stage_rsp_tag3_q <= stage_bank_tag3_tmp;
                stage_rsp_valid0_q <= stage_bank_valid0_tmp;
                stage_rsp_valid1_q <= stage_bank_valid1_tmp;
                stage_rsp_valid2_q <= stage_bank_valid2_tmp;
                stage_rsp_valid3_q <= stage_bank_valid3_tmp;
            end

            // Issue the next banked read.  The response will be captured on
            // the next edge, while the load counters advance at issue time.
            if (can_load_tmp) begin
                stage_read_pending <= 1'b1;
                stage_read_phase <= (phase == PH_HORIZONTAL);
                stage_read_vector <= load_vector;
                stage_read_group <= load_group;
                stage_read_cache <= active_cache;
                stage_read_bank <= load_bank;
                stage_read_epoch <= (active_cache == 1'b0) ? cache_epoch[0] : cache_epoch[1];
                stage_read_perm <= load_vector[1:0];
                if (phase == PH_VERTICAL) begin
                    // For a vertical vector, the four rows map to distinct
                    // physical banks.  Compute the address for each bank at
                    // the request edge and copy it only into the selected
                    // cache's data/tag address registers.  This keeps the
                    // address net local to the active distributed-RAM family.
                    if (active_cache == 1'b0) begin
                        stage_addr_a_data0_q <= ((load_group * 4 + load_vector[1:0]) << 4) + (load_vector >> 2);
                        stage_addr_a_data1_q <= ((load_group * 4 + (2'd1 ^ load_vector[1:0])) << 4) + (load_vector >> 2);
                        stage_addr_a_data2_q <= ((load_group * 4 + (2'd2 ^ load_vector[1:0])) << 4) + (load_vector >> 2);
                        stage_addr_a_data3_q <= ((load_group * 4 + (2'd3 ^ load_vector[1:0])) << 4) + (load_vector >> 2);
                        stage_addr_a_tag0_q <= ((load_group * 4 + load_vector[1:0]) << 4) + (load_vector >> 2);
                        stage_addr_a_tag1_q <= ((load_group * 4 + (2'd1 ^ load_vector[1:0])) << 4) + (load_vector >> 2);
                        stage_addr_a_tag2_q <= ((load_group * 4 + (2'd2 ^ load_vector[1:0])) << 4) + (load_vector >> 2);
                        stage_addr_a_tag3_q <= ((load_group * 4 + (2'd3 ^ load_vector[1:0])) << 4) + (load_vector >> 2);
                    end else begin
                        stage_addr_b_data0_q <= ((load_group * 4 + load_vector[1:0]) << 4) + (load_vector >> 2);
                        stage_addr_b_data1_q <= ((load_group * 4 + (2'd1 ^ load_vector[1:0])) << 4) + (load_vector >> 2);
                        stage_addr_b_data2_q <= ((load_group * 4 + (2'd2 ^ load_vector[1:0])) << 4) + (load_vector >> 2);
                        stage_addr_b_data3_q <= ((load_group * 4 + (2'd3 ^ load_vector[1:0])) << 4) + (load_vector >> 2);
                        stage_addr_b_tag0_q <= ((load_group * 4 + load_vector[1:0]) << 4) + (load_vector >> 2);
                        stage_addr_b_tag1_q <= ((load_group * 4 + (2'd1 ^ load_vector[1:0])) << 4) + (load_vector >> 2);
                        stage_addr_b_tag2_q <= ((load_group * 4 + (2'd2 ^ load_vector[1:0])) << 4) + (load_vector >> 2);
                        stage_addr_b_tag3_q <= ((load_group * 4 + (2'd3 ^ load_vector[1:0])) << 4) + (load_vector >> 2);
                    end
                end else begin
                    // For a horizontal vector, all four lanes share the
                    // same physical word address and differ only by bank.
                    // Keep one local address register per intermediate bank.
                    stage_addr_i_data0_q <= (load_vector << 4) + load_group;
                    stage_addr_i_data1_q <= (load_vector << 4) + load_group;
                    stage_addr_i_data2_q <= (load_vector << 4) + load_group;
                    stage_addr_i_data3_q <= (load_vector << 4) + load_group;
                end
                if (load_group == 15) begin
                    load_group <= 0;
                    load_vector <= load_vector + 1'b1;
                    load_bank <= ~load_bank;
                end else begin
                    load_group <= load_group + 1'b1;
                end
            end else begin
                stage_read_pending <= 1'b0;
            end

            if ((phase == PH_VERTICAL || phase == PH_HORIZONTAL) && cycles_since_launch < 63)
                cycles_since_launch <= cycles_since_launch + 1'b1;
            if (r4c_start) begin
                if (launch_bank == 0) stage_ready_a <= 1'b0;
                else stage_ready_b <= 1'b0;
                launch_count <= launch_count + 1'b1;
                launch_bank <= ~launch_bank;
                cycles_since_launch <= 0;
            end

            // Live R4C group writes.  V writes 16-bit stage values to the
            // single intermediate store; H writes stage16 shadow and low10
            // result beat in the same clock/event.
            if (r4c_result_valid) begin
                vec_tmp = r4c_result_vector_id - phase_vector_base;
`ifndef SYNTHESIS
                if (vec_tmp < 0 || vec_tmp >= 64) begin
                    protocol_error <= 1'b1;
                end
`endif
                for (i = 0; i < 4; i = i + 1) begin
                    row_tmp = r4c_result_group * 4 + i;
                    if (phase == PH_VERTICAL) begin
                        debug_stage16_valid <= 1'b1;
                        debug_stage16_row <= row_tmp[5:0];
                        debug_stage16_col <= vec_tmp[5:0];
                        debug_stage16_data <= $signed(r4c_result_stage16[i*16 +: 16]);
                    end else if (phase == PH_HORIZONTAL) begin
                        result_idx_tmp = vec_tmp * 16 + r4c_result_group;
`ifndef SYNTHESIS
                        result_stage16_mem[vec_tmp * 64 + row_tmp] <= $signed(r4c_result_stage16[i*16 +: 16]);
`endif
                        if (i == 0)
                            result_mem[result_idx_tmp] <= r4c_result_final10;
                        result_present[result_idx_tmp] <= 1'b1;
                    end
                end
                if (phase == PH_HORIZONTAL && r4c_result_vector_id == (phase_vector_base + 63) && r4c_result_last)
                    final_compute_seen <= 1'b1;

                // The last vertical group is the phase boundary.  The next
                // cycle starts horizontal staging; no second R4C exists.
                if (phase == PH_VERTICAL && r4c_result_vector_id == (phase_vector_base + 63) && r4c_result_last) begin
                    phase <= PH_WAIT_H;
                    load_bank <= 0;
                    load_vector <= 0;
                    load_group <= 0;
                    launch_count <= 0;
                    launch_bank <= 0;
                    stage_ready_a <= 0;
                    stage_ready_b <= 0;
                    cycles_since_launch <= 6'd16;
                end else if (phase == PH_HORIZONTAL && r4c_result_vector_id == (phase_vector_base + 63) && r4c_result_last) begin
                    phase <= PH_IDLE;
                    intermediate_owned <= 1'b0;
                    cache_state[active_cache] <= CACHE_FREE;
                end
            end

            // Result accounting and reader next-state.  A response at C+1
            // may coexist with a new request at C+1; this is what gives the
            // ready-high output path II=1 after warm-up.
            output_fire_tmp = result_hold_valid && it_data_out_req;
            response_valid_tmp = result_read_pending;
            response_value_tmp = result_mem[result_pending_index];

            if (phase == PH_WAIT_H && vertical_commit_done && !result_owner_valid) begin
                result_owner_v_tmp = 1'b1;
                result_reserved_tmp = 11'd1024;
                result_occupied_tmp = 0;
                result_produced_tmp = 0;
                result_issued_tmp = 0;
                result_consumed_tmp = 0;
                result_hold_v_tmp = 1'b0;
                result_skid_v_tmp = 1'b0;
                result_pending_v_tmp = 1'b0;
                result_hold_d_tmp = 0;
                result_skid_d_tmp = 0;
            end else begin
                result_owner_v_tmp = result_owner_valid;
                result_reserved_tmp = result_reserved;
                result_occupied_tmp = result_occupied;
                result_produced_tmp = result_produced;
                result_issued_tmp = result_issued;
                result_consumed_tmp = result_consumed;
                result_hold_v_tmp = result_hold_valid;
                result_skid_v_tmp = result_skid_valid;
                result_pending_v_tmp = result_read_pending;
                result_hold_d_tmp = result_hold_data;
                result_skid_d_tmp = result_skid_data;

                if (r4c_result_valid && phase == PH_HORIZONTAL) begin
                    if (!result_owner_valid || result_owner_tu != active_tu ||
                        result_reserved == 0) begin
                        protocol_error <= 1'b1;
                    end
                    result_reserved_tmp = result_reserved_tmp - 1'b1;
                    result_occupied_tmp = result_occupied_tmp + 1'b1;
                    result_produced_tmp = result_produced_tmp + 1'b1;
                end
                if (output_fire_tmp) begin
                    result_occupied_tmp = result_occupied_tmp - 1'b1;
                    result_consumed_tmp = result_consumed_tmp + 1'b1;
                    result_present[result_read_index] <= 1'b0;
                    result_read_index <= result_read_index + 1'b1;
                    if (result_skid_v_tmp) begin
                        result_hold_v_tmp = 1'b1;
                        result_hold_d_tmp = result_skid_d_tmp;
                        result_skid_v_tmp = 1'b0;
                    end else begin
                        result_hold_v_tmp = 1'b0;
                    end
                end

                if (response_valid_tmp) begin
                    result_pending_v_tmp = 1'b0;
                    if (!result_hold_v_tmp) begin
                        result_hold_v_tmp = 1'b1;
                        result_hold_d_tmp = response_value_tmp;
                    end else if (!result_skid_v_tmp) begin
                        result_skid_v_tmp = 1'b1;
                        result_skid_d_tmp = response_value_tmp;
                    end else begin
                        protocol_error <= 1'b1;
                    end
                end

                // Do not issue a read for a word written on this same edge;
                // this keeps the RAM read-during-write policy irrelevant.
                if (!result_pending_v_tmp && result_owner_v_tmp &&
                    result_issued_tmp < result_produced &&
                    ((result_hold_v_tmp ? 1 : 0) + (result_skid_v_tmp ? 1 : 0) < 2)) begin
                    result_pending_v_tmp = 1'b1;
                    result_pending_index <= result_issued_tmp[9:0];
                    result_issue_index <= result_issued_tmp[9:0];
                    result_issued_tmp = result_issued_tmp + 1'b1;
                end

                if (result_owner_v_tmp && output_fire_tmp &&
                    result_consumed_tmp == 11'd1024 &&
                    result_produced_tmp == 11'd1024 &&
                    result_issued_tmp == 11'd1024 &&
                    !result_pending_v_tmp && !result_hold_v_tmp && !result_skid_v_tmp) begin
                    result_owner_v_tmp = 1'b0;
                    it_done <= 1'b1;
                end
            end

`ifndef SYNTHESIS
            // Verification-only fail-closed checks.  The counters are 11-bit
            // so the terminal value 1024 is representable; result_issue_index
            // remains only a 10-bit RAM address.  Functional protocol and
            // capacity admission errors above remain synthesizable.
            if (result_owner_v_tmp) begin
                if (result_reserved_tmp > 11'd1024 ||
                    result_occupied_tmp > 11'd1024 ||
                    result_reserved_tmp > (11'd1024 - result_occupied_tmp) ||
                    result_consumed_tmp > result_issued_tmp ||
                    result_issued_tmp > result_produced_tmp ||
                    result_produced_tmp > 11'd1024 ||
                    result_produced_tmp != (11'd1024 - result_reserved_tmp) ||
                    result_occupied_tmp != (result_produced_tmp - result_consumed_tmp) ||
                    (result_issued_tmp - result_consumed_tmp) !=
                      ((result_pending_v_tmp ? 1 : 0) +
                       (result_hold_v_tmp ? 1 : 0) +
                       (result_skid_v_tmp ? 1 : 0)))
                     begin
                         protocol_error <= 1'b1;
                     end
            end else if (!((result_reserved_tmp == 0) &&
                           (result_occupied_tmp == 0) &&
                           (result_produced_tmp == 0) &&
                           (result_issued_tmp == 0) &&
                           (result_consumed_tmp == 0)) &&
                           !((result_reserved_tmp == 0) &&
                             (result_occupied_tmp == 0) &&
                             (result_produced_tmp == 11'd1024) &&
                             (result_issued_tmp == 11'd1024) &&
                             (result_consumed_tmp == 11'd1024))) begin
                 begin
                     protocol_error <= 1'b1;
                 end
            end
`endif

            result_owner_valid <= result_owner_v_tmp;
            result_reserved <= result_reserved_tmp;
            result_occupied <= result_occupied_tmp;
            result_produced <= result_produced_tmp;
            result_issued <= result_issued_tmp;
            result_consumed <= result_consumed_tmp;
            result_hold_valid <= result_hold_v_tmp;
            result_hold_data <= result_hold_d_tmp;
            result_skid_valid <= result_skid_v_tmp;
            result_skid_data <= result_skid_d_tmp;
            result_read_pending <= result_pending_v_tmp;
        end
    end
endmodule
