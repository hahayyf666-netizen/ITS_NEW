`timescale 1ns/1ps

// Step12B functional wrapper: one frozen R4C instance, 64x64 DCT2xDCT2,
// LFNST disabled.  This file is intentionally a functional/protocol
// prototype; it is not the V3.4 top and has not yet been through Vivado.
// The R4C source is included unchanged and result_accept is permanently 1.
module step12b_dct2_64_wrapper #(
    parameter integer VECTOR_ID_W = 16
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

    // Two physical input caches.  Epoch tags make omitted sparse addresses
    // read as zero without a 4096-cycle clear on every TU.
    reg signed [15:0] input_cache_a [0:4095];
    reg signed [15:0] input_cache_b [0:4095];
    reg [1:0] input_tag_a [0:4095];
    reg [1:0] input_tag_b [0:4095];
    reg [1:0] cache_epoch [0:1];
    reg [1:0] cache_state [0:1];
    reg [15:0] cache_tu_id [0:1];
    reg [11:0] last_input_addr [0:1];

    // Descriptor queue.  A descriptor is bound before its input data; the
    // one-cycle bind guard enforces the Step12B first-data-next-cycle rule.
    reg [1:0] desc_slot_q [0:1];
    reg [15:0] desc_tu_q [0:1];
    reg [1:0] desc_count;
    reg desc_bind_guard;
    reg [15:0] next_tu_serial;

    // One shared intermediate store.  The first prototype uses registers;
    // Step12C will decide BRAM/LUTRAM inference after functional closure.
    reg signed [15:0] intermediate_mem [0:4095];
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
    assign r4c_start = (phase != PH_IDLE) &&
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
    reg [10:0] result_occupied;
    reg [9:0] result_read_index;
    reg [9:0] result_issue_index;
    reg result_read_pending;
    reg [9:0] result_pending_index;
    reg result_hold_valid, result_skid_valid;
    reg [39:0] result_hold_data, result_skid_data;
    reg final_compute_seen;

    // Output contract: vld is asserted only when the caller accepts the
    // beat.  During req=0 the hold/skid contents remain unchanged.
    always @* begin
        it_data_in_req = 1'b0;
        if ((desc_count != 0) && !desc_bind_guard &&
            (cache_state[desc_slot_q[0]] == CACHE_FILL))
            it_data_in_req = 1'b1;
        it_data_out = result_hold_data;
        it_data_out_vld = result_hold_valid && it_data_out_req;
    end

    integer i;
    integer addr_tmp;
    integer row_tmp;
    integer col_tmp;
    integer vec_tmp;
    integer result_idx_tmp;
    reg signed [15:0] read_value_tmp;
    reg [39:0] response_value_tmp;
    reg response_valid_tmp;
    reg output_fire_tmp;
    reg can_load_tmp;

    always @(posedge clk) begin
        if (!rst_n) begin
            desc_count <= 0;
            desc_bind_guard <= 0;
            next_tu_serial <= 0;
            cache_epoch[0] <= 0;
            cache_epoch[1] <= 0;
            cache_state[0] <= CACHE_FREE;
            cache_state[1] <= CACHE_FREE;
            cache_tu_id[0] <= 0;
            cache_tu_id[1] <= 0;
            last_input_addr[0] <= 0;
            last_input_addr[1] <= 0;
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
                input_tag_a[i] <= 0;
                input_tag_b[i] <= 0;
                intermediate_mem[i] <= 0;
            end
            for (i = 0; i < 1024; i = i + 1) begin
                result_mem[i] <= 0;
                result_present[i] <= 0;
            end
            for (i = 0; i < 64; i = i + 1) begin
                stage_a[i] <= 0;
                stage_b[i] <= 0;
            end
        end else begin
            debug_stage16_valid <= 1'b0;
            if (desc_bind_guard)
                desc_bind_guard <= 1'b0;

            // Descriptor admission.  Only FREE caches can be bound.  A full
            // descriptor queue is an illegal environment stimulus; it never
            // overwrites an existing descriptor.
            if (it_info_vld) begin
                if (desc_count >= 2) begin
                    protocol_error <= 1'b1;
                end else if (cache_state[0] == CACHE_FREE || cache_state[1] == CACHE_FREE) begin
                    if (cache_state[0] == CACHE_FREE) begin
                        desc_slot_q[desc_count] <= 0;
                        cache_state[0] <= CACHE_FILL;
                        cache_tu_id[0] <= next_tu_serial;
                        cache_epoch[0] <= cache_epoch[0] + 1'b1;
                        last_input_addr[0] <= 0;
                    end else begin
                        desc_slot_q[desc_count] <= 1;
                        cache_state[1] <= CACHE_FILL;
                        cache_tu_id[1] <= next_tu_serial;
                        cache_epoch[1] <= cache_epoch[1] + 1'b1;
                        last_input_addr[1] <= 0;
                    end
                    desc_tu_q[desc_count] <= next_tu_serial;
                    desc_count <= desc_count + 1'b1;
                    next_tu_serial <= next_tu_serial + 1'b1;
                    desc_bind_guard <= 1'b1;
                end else begin
                    protocol_error <= 1'b1;
                end
            end

            // Sparse input fire.  The stream is accepted only while the
            // bound cache is filling; data/end in the bind cycle is rejected
            // by it_data_in_req=0.  Addresses are raster-monotonic.
            if (it_data_in_vld && it_data_in_req) begin
                if (it_data_addr < last_input_addr[desc_slot_q[0]] &&
                    last_input_addr[desc_slot_q[0]] != 0)
                    protocol_error <= 1'b1;
                last_input_addr[desc_slot_q[0]] <= it_data_addr;
                if (desc_slot_q[0] == 0) begin
                    input_cache_a[it_data_addr] <= it_data_in;
                    input_tag_a[it_data_addr] <= cache_epoch[0];
                end else begin
                    input_cache_b[it_data_addr] <= it_data_in;
                    input_tag_b[it_data_addr] <= cache_epoch[1];
                end
                if (it_data_end) begin
                    cache_state[desc_slot_q[0]] <= CACHE_READY;
                    // Pop the descriptor only after the final data has been
                    // written at this same edge.
                    if (desc_count == 2) begin
                        desc_slot_q[0] <= desc_slot_q[1];
                        desc_tu_q[0] <= desc_tu_q[1];
                    end
                    desc_count <= desc_count - 1'b1;
                    desc_bind_guard <= 1'b0;
                end
            end else if (desc_count != 0 && it_data_in_req && it_data_end) begin
                // Standalone end is legal and completes an otherwise empty
                // sparse TU.
                cache_state[desc_slot_q[0]] <= CACHE_READY;
                if (desc_count == 2) begin
                    desc_slot_q[0] <= desc_slot_q[1];
                    desc_tu_q[0] <= desc_tu_q[1];
                end
                desc_count <= desc_count - 1'b1;
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

            // Four-point-per-cycle staging.  The registered array read is the
            // prototype's explicit synchronous-read boundary.
            can_load_tmp = 1'b0;
            if (phase != PH_IDLE && load_vector < 64) begin
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
                        addr_tmp = row_tmp * 64 + col_tmp;
                        if (active_cache == 0)
                            read_value_tmp = (input_tag_a[addr_tmp] == cache_epoch[0]) ? input_cache_a[addr_tmp] : 16'sd0;
                        else
                            read_value_tmp = (input_tag_b[addr_tmp] == cache_epoch[1]) ? input_cache_b[addr_tmp] : 16'sd0;
                    end else begin
                        // Horizontal vectors read one row from intermediate.
                        addr_tmp = col_tmp * 64 + row_tmp;
                        read_value_tmp = intermediate_mem[addr_tmp];
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

            if (phase != PH_IDLE && cycles_since_launch < 63)
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
                        intermediate_mem[row_tmp * 64 + vec_tmp] <= $signed(r4c_result_stage16[i*16 +: 16]);
                        debug_stage16_valid <= 1'b1;
                        debug_stage16_row <= row_tmp[5:0];
                        debug_stage16_col <= vec_tmp[5:0];
                        debug_stage16_data <= $signed(r4c_result_stage16[i*16 +: 16]);
                    end else if (phase == PH_HORIZONTAL) begin
                        result_idx_tmp = vec_tmp * 16 + r4c_result_group;
                        result_mem[result_idx_tmp][i*10 +: 10] <= r4c_result_final10[i*10 +: 10];
                        result_present[result_idx_tmp] <= 1'b1;
                        result_occupied <= result_occupied + ((i == 0) ? 1 : 0);
                    end
                end
                if (phase == PH_HORIZONTAL && r4c_result_vector_id == (phase_vector_base + 63) && r4c_result_last)
                    final_compute_seen <= 1'b1;

                // The last vertical group is the phase boundary.  The next
                // cycle starts horizontal staging; no second R4C exists.
                if (phase == PH_VERTICAL && r4c_result_vector_id == (phase_vector_base + 63) && r4c_result_last) begin
                    phase <= PH_HORIZONTAL;
                    phase_vector_base <= active_tu * 16'd128 + 16'd64;
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

            // Result reader: request at C, response at C+1, then hold/skid.
            output_fire_tmp = result_hold_valid && it_data_out_req;
            response_valid_tmp = result_read_pending;
            response_value_tmp = result_mem[result_pending_index];
            if (result_read_pending)
                result_read_pending <= 1'b0;

            if (output_fire_tmp) begin
                result_hold_valid <= 1'b0;
                // Retire the logical beat; otherwise the issue pointer would
                // eventually wrap and replay already-consumed results.
                result_present[result_read_index] <= 1'b0;
                result_read_index <= result_read_index + 1'b1;
                if (result_occupied != 0) result_occupied <= result_occupied - 1'b1;
                if (result_skid_valid) begin
                    result_hold_valid <= 1'b1;
                    result_hold_data <= result_skid_data;
                    result_skid_valid <= 1'b0;
                end else if (response_valid_tmp) begin
                    result_hold_valid <= 1'b1;
                    result_hold_data <= response_value_tmp;
                end
            end else if (response_valid_tmp) begin
                if (!result_hold_valid) begin
                    result_hold_valid <= 1'b1;
                    result_hold_data <= response_value_tmp;
                end else if (!result_skid_valid) begin
                    result_skid_valid <= 1'b1;
                    result_skid_data <= response_value_tmp;
                end else begin
                    protocol_error <= 1'b1;
                end
            end

            if (!result_read_pending && !result_skid_valid &&
                result_issue_index < 1024 && result_present[result_issue_index]) begin
                result_pending_index <= result_issue_index;
                result_read_pending <= 1'b1;
                result_issue_index <= result_issue_index + 1'b1;
            end

            if (final_compute_seen && (result_occupied == 0) &&
                !result_hold_valid && !result_skid_valid && !result_read_pending)
                it_done <= 1'b1;
        end
    end
endmodule
