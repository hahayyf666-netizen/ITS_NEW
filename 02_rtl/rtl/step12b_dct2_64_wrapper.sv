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
    reg signed [15:0] input_cache_a [0:3][0:1023];
    reg signed [15:0] input_cache_b [0:3][0:1023];
    reg [EPOCH_BITS-1:0] input_tag_a [0:3][0:1023];
    reg [EPOCH_BITS-1:0] input_tag_b [0:3][0:1023];
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

    // One shared intermediate store.  The first prototype uses registers;
    // Step12C will decide BRAM/LUTRAM inference after functional closure.
    reg signed [15:0] intermediate_mem [0:3][0:1023];
    reg signed [15:0] result_stage16_mem [0:4095];
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
    reg [39:0] result_mem [0:1023];
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

    function integer coord_bank(input integer row, input integer col);
        coord_bank = ((row & 3) ^ (col & 3));
    endfunction
    function integer coord_addr(input integer row, input integer col);
        coord_addr = row * 16 + (col >> 2);
    endfunction

    // Official contest output contract: vld may rise only when req is high.
    // The internal hold/skid state remains valid and stable while req=0;
    // output_fire is the consuming edge, not the external vld indication.
    always @* begin
        it_data_in_req = 1'b0;
        if ((desc_count != 0) && (desc_slot_q[0] != DESC_UNBOUND) && !desc_bind_guard &&
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

    always @(posedge clk) begin
        if (!rst_n) begin
            desc_count <= 0;
            desc_bind_guard <= 0;
            next_tu_serial <= 0;
            cache_epoch[0] <= 0;
            cache_epoch[1] <= 0;
            cache_scrubbing[0] <= 0;
            cache_scrubbing[1] <= 0;
            scrub_index[0] <= 0;
            scrub_index[1] <= 0;
            cache_state[0] <= CACHE_FREE;
            cache_state[1] <= CACHE_FREE;
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
            for (i = 0; i < 4096; i = i + 1) begin
            result_stage16_mem[i] <= 0;
            end
            for (i = 0; i < 1024; i = i + 1) begin
                input_tag_a[0][i] <= 0;
                input_tag_a[1][i] <= 0;
                input_tag_a[2][i] <= 0;
                input_tag_a[3][i] <= 0;
                input_tag_b[0][i] <= 0;
                input_tag_b[1][i] <= 0;
                input_tag_b[2][i] <= 0;
                input_tag_b[3][i] <= 0;
                input_cache_a[0][i] <= 0;
                input_cache_a[1][i] <= 0;
                input_cache_a[2][i] <= 0;
                input_cache_a[3][i] <= 0;
                input_cache_b[0][i] <= 0;
                input_cache_b[1][i] <= 0;
                input_cache_b[2][i] <= 0;
                input_cache_b[3][i] <= 0;
                intermediate_mem[0][i] <= 0;
                intermediate_mem[1][i] <= 0;
                intermediate_mem[2][i] <= 0;
                intermediate_mem[3][i] <= 0;
            end
            for (i = 0; i < 1024; i = i + 1) begin
                result_mem[i] <= 0;
                result_present[i] <= 0;
            end
            for (i = 0; i < 64; i = i + 1) begin
                stage_a[i] <= 0;
                stage_b[i] <= 0;
            end
            desc_info_q[0] <= 0;
            desc_info_q[1] <= 0;
        end else begin
            debug_stage16_valid <= 1'b0;
            it_done <= 1'b0;
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

            // Four tag banks are scrubbed in parallel.  The cache under scrub
            // is unavailable, while the other A/B cache may continue filling.
            if (cache_scrubbing[0]) begin
                input_tag_a[0][scrub_index[0]] <= 0;
                input_tag_a[1][scrub_index[0]] <= 0;
                input_tag_a[2][scrub_index[0]] <= 0;
                input_tag_a[3][scrub_index[0]] <= 0;
                if (scrub_index[0] == 1023) begin
                    cache_scrubbing[0] <= 0;
                    cache_state[0] <= CACHE_FREE;
                    cache_epoch[0] <= 0;
                    scrub_index[0] <= 0;
                end else begin
                    scrub_index[0] <= scrub_index[0] + 1'b1;
                end
            end
            if (cache_scrubbing[1]) begin
                input_tag_b[0][scrub_index[1]] <= 0;
                input_tag_b[1][scrub_index[1]] <= 0;
                input_tag_b[2][scrub_index[1]] <= 0;
                input_tag_b[3][scrub_index[1]] <= 0;
                if (scrub_index[1] == 1023) begin
                    cache_scrubbing[1] <= 0;
                    cache_state[1] <= CACHE_FREE;
                    cache_epoch[1] <= 0;
                    scrub_index[1] <= 0;
                end else begin
                    scrub_index[1] <= scrub_index[1] + 1'b1;
                end
            end

            // Sparse input fire.  The stream is accepted only while the
            // bound cache is filling; data/end in the bind cycle is rejected
            // by it_data_in_req=0.  Addresses are raster-monotonic.
            if (it_data_in_vld && it_data_in_req) begin
                if (last_input_valid[desc_slot_q[0]] &&
                    it_data_addr <= last_input_addr[desc_slot_q[0]])
                    protocol_error <= 1'b1;
                last_input_addr[desc_slot_q[0]] <= it_data_addr;
                last_input_valid[desc_slot_q[0]] <= 1'b1;
                cache_row_tmp = it_data_addr / 64;
                cache_col_tmp = it_data_addr % 64;
                bank_tmp = coord_bank(cache_row_tmp, cache_col_tmp);
                mem_addr_tmp = coord_addr(cache_row_tmp, cache_col_tmp);
                if (desc_slot_q[0] == 0) begin
                    input_cache_a[bank_tmp][mem_addr_tmp] <= it_data_in;
                    input_tag_a[bank_tmp][mem_addr_tmp] <= cache_epoch[0];
                end else begin
                    input_cache_b[bank_tmp][mem_addr_tmp] <= it_data_in;
                    input_tag_b[bank_tmp][mem_addr_tmp] <= cache_epoch[1];
                end
                if (it_data_end) begin
                    cache_state[desc_slot_q[0]] <= CACHE_READY;
                    // Pop the descriptor only after the final data has been
                    // written at this same edge.
                    if (desc_count == 2) begin
                        desc_slot_q[0] <= desc_slot_q[1];
                        desc_tu_q[0] <= desc_tu_q[1];
                        desc_info_q[0] <= desc_info_q[1];
                        desc_count <= 1;
                    end else if (desc_push_ok) begin
                        // A descriptor pushed while the active descriptor
                        // ends in this same edge occupies q1 in the push
                        // block above; promote it to the new FIFO head.
                        desc_slot_q[0] <= push_slot_calc;
                        desc_tu_q[0] <= next_tu_serial;
                        desc_info_q[0] <= it_info;
                        desc_count <= 1;
                    end else begin
                        desc_count <= 0;
                    end
                    desc_bind_guard <= 1'b0;
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
            if (phase == PH_WAIT_H && !result_owner_valid) begin
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
            end

            // Four-point-per-cycle staging.  The registered array read is the
            // prototype's explicit synchronous-read boundary.
            can_load_tmp = 1'b0;
            if ((phase == PH_VERTICAL || phase == PH_HORIZONTAL) && load_vector < 64) begin
                if ((load_bank == 0 && !stage_ready_a) ||
                    (load_bank == 1 && !stage_ready_b))
                    can_load_tmp = 1'b1;
                if (r4c_start && (load_bank == launch_bank))
                    can_load_tmp = 1'b0;
            end
            if (can_load_tmp) begin
                for (i = 0; i < 4; i = i + 1) begin
                    row_tmp = load_group * 4 + i;
                    col_tmp = load_vector;
                    if (phase == PH_VERTICAL) begin
                        bank_tmp = coord_bank(row_tmp, col_tmp);
                        mem_addr_tmp = coord_addr(row_tmp, col_tmp);
                        if (active_cache == 0)
                            read_value_tmp = (input_tag_a[bank_tmp][mem_addr_tmp] == cache_epoch[0]) ? input_cache_a[bank_tmp][mem_addr_tmp] : 16'sd0;
                        else
                            read_value_tmp = (input_tag_b[bank_tmp][mem_addr_tmp] == cache_epoch[1]) ? input_cache_b[bank_tmp][mem_addr_tmp] : 16'sd0;
                    end else begin
                        // Horizontal vectors read one row from intermediate.
                        bank_tmp = coord_bank(col_tmp, row_tmp);
                        mem_addr_tmp = coord_addr(col_tmp, row_tmp);
                        read_value_tmp = intermediate_mem[bank_tmp][mem_addr_tmp];
                    end
                    if (load_bank == 0) stage_a[row_tmp] <= read_value_tmp;
                    else stage_b[row_tmp] <= read_value_tmp;
                end
                if (load_group == 15) begin
                    if (load_bank == 0) stage_ready_a <= 1'b1;
                    else stage_ready_b <= 1'b1;
                    load_group <= 0;
                    load_vector <= load_vector + 1'b1;
                    load_bank <= ~load_bank;
                end else begin
                    load_group <= load_group + 1'b1;
                end
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
                if (vec_tmp < 0 || vec_tmp >= 64)
                    protocol_error <= 1'b1;
                for (i = 0; i < 4; i = i + 1) begin
                    row_tmp = r4c_result_group * 4 + i;
                    if (phase == PH_VERTICAL) begin
                        bank_tmp = coord_bank(row_tmp, vec_tmp);
                        mem_addr_tmp = coord_addr(row_tmp, vec_tmp);
                        intermediate_mem[bank_tmp][mem_addr_tmp] <= $signed(r4c_result_stage16[i*16 +: 16]);
                        debug_stage16_valid <= 1'b1;
                        debug_stage16_row <= row_tmp[5:0];
                        debug_stage16_col <= vec_tmp[5:0];
                        debug_stage16_data <= $signed(r4c_result_stage16[i*16 +: 16]);
                    end else if (phase == PH_HORIZONTAL) begin
                        result_idx_tmp = vec_tmp * 16 + r4c_result_group;
                        result_stage16_mem[vec_tmp * 64 + row_tmp] <= $signed(r4c_result_stage16[i*16 +: 16]);
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

            if (phase == PH_WAIT_H && !result_owner_valid) begin
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
                        result_reserved == 0)
                        protocol_error <= 1'b1;
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

            // Fail closed on any reservation/accounting inconsistency.  The
            // counters are 11-bit so the terminal value 1024 is representable;
            // result_issue_index remains only a 10-bit RAM address.
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
                    protocol_error <= 1'b1;
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
                protocol_error <= 1'b1;
            end

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
