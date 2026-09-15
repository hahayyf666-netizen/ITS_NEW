// Step12F unified P4 1-D transform kernel.
//
// Four samples are accepted per input group and four complete transform
// outputs are emitted per output group.  The arithmetic path is explicitly
// registered: input/coefficient capture, product generation, four balanced
// reduction levels, final reduction and round/clip.  A result FIFO separates
// the fixed-progress arithmetic pipeline from the output-side request.
//
// The v3.5-18 R4C and historical wrapper are not modified or imported.

module unified_p4_kernel #(
    parameter integer DATA_W       = 16,
    parameter integer COEFF_W      = 16,
    parameter integer ACC_W        = 40,
    parameter integer MAX_N        = 64,
    parameter integer COEFF_DEPTH  = 8176,
    parameter string  COEFF_FILE   = "03_verification/sim/rom_coeffs.hex"
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start,
    input  logic [1:0]                   tr_type,
    input  logic [6:0]                   transform_size,
    input  logic [6:0]                   active_size,
    input  logic [6:0]                   output_size,
    input  logic                         stage_sel,
    input  logic                         in_valid,
    output logic                         in_req,
    input  logic signed [(4*DATA_W)-1:0] in_data,
    output logic                         out_valid,
    input  logic                         out_req,
    output logic signed [(4*DATA_W)-1:0] out_data,
    output logic                         done,
    output logic                         busy,
    output logic                         error
);

    localparam integer SLOT_COUNT = 4;
    localparam integer PROD_W = DATA_W + COEFF_W;
    // Reserve enough result groups for the arithmetic pipeline to drain while
    // a new vector is admitted at the required N/4 interval.  The previous
    // depth of 32 could reject the third overlapping N=64 vector before the
    // first vector's pipeline tail had reached the FIFO.
    localparam integer FIFO_DEPTH = 64;
    localparam integer FIFO_PTR_W = $clog2(FIFO_DEPTH);
    localparam logic [1:0] SLOT_FREE  = 2'd0;
    localparam logic [1:0] SLOT_LOAD  = 2'd1;
    localparam logic [1:0] SLOT_READY = 2'd2;
    localparam logic [1:0] SLOT_OUT   = 2'd3;

    // Compile-time transpose only. Runtime selection is one complete P4
    // bundle. The canonical coefficient values and orientation are unchanged.
    localparam integer BUNDLE_COUNT = 61;
    localparam integer BUNDLE_W = 4 * MAX_N * COEFF_W;
    logic signed [COEFF_W-1:0] coeff_init [0:COEFF_DEPTH-1];
    logic [BUNDLE_W-1:0] coeff_bundle_mem [0:BUNDLE_COUNT-1];
    // Stage-0 issue descriptor.  Scheduler state is deliberately separated
    // from the wide coefficient/operand capture boundary below.
    logic                         issue_desc_valid_q;
    logic [1:0]                   issue_desc_slot_q;
    logic [4:0]                   issue_desc_group_q;
    logic [5:0]                   issue_desc_bundle_addr_q;
    logic [6:0]                   issue_desc_active_size_q;
    logic [3:0]                   issue_desc_shift_q;
    logic                         issue_desc_last_q;
    logic [5:0]                   issue_desc_bundle_addr_c;
    logic [6:0]                   issue_desc_active_size_c;
    logic [3:0]                   issue_desc_shift_c;
    logic                         issue_desc_last_c;

    logic signed [DATA_W-1:0] input_mem [0:SLOT_COUNT-1][0:MAX_N-1];
    logic [1:0] slot_state_q [0:SLOT_COUNT-1];
    logic [1:0] slot_type_q  [0:SLOT_COUNT-1];
    logic [6:0] slot_size_q  [0:SLOT_COUNT-1];
    logic [6:0] slot_matrix_size_q [0:SLOT_COUNT-1];
    logic [6:0] slot_output_size_q [0:SLOT_COUNT-1];
    logic       slot_stage_q [0:SLOT_COUNT-1];

    logic       load_active_q;
    logic [1:0] load_slot_q;
    logic [4:0] load_group_q;

    // One ready slot is issued completely before the next ready slot.  The
    // slot is released once all operands have been captured into the pipeline;
    // output ordering is preserved by the result FIFO.
    logic       issue_active_q;
    logic [1:0] issue_slot_q;
    logic [4:0] issue_group_q;
    logic       issue_emit_c;
    logic [1:0] issue_emit_slot_c;
    logic [4:0] issue_emit_group_c;

    logic       free_found_c;
    logic [1:0] free_slot_c;
    logic       ready_found_c;
    logic [1:0] ready_slot_c;
    logic       capacity_ok_c;
    logic       issue_last_c;
    logic       start_accept;
    logic       input_group_accept;
    logic       pending_load_last;
    logic       out_fire;
    logic       out_last_fire;
    // Compatibility-visible status used by existing standalone benches.
    logic       output_active_q;
    logic [5:0] new_group_count_c;
    logic [8:0] reserved_groups_q;

    integer free_scan_i;
    integer ready_scan_i;
    integer busy_scan_i;
    integer lane_i;
    integer input_i;
    integer reset_i;
    integer write_lane_i;

    function automatic integer bundle_base(input logic [1:0] type_i,
                                            input logic [6:0] n_i);
        begin
            case ({type_i, n_i})
                {2'd0, 7'd4}:  bundle_base = 0;
                {2'd0, 7'd8}:  bundle_base = 1;
                {2'd0, 7'd16}: bundle_base = 3;
                {2'd0, 7'd32}: bundle_base = 7;
                {2'd0, 7'd64}: bundle_base = 15;
                {2'd1, 7'd4}:  bundle_base = 31;
                {2'd1, 7'd8}:  bundle_base = 32;
                {2'd1, 7'd16}: bundle_base = 34;
                {2'd1, 7'd32}: bundle_base = 38;
                {2'd2, 7'd4}:  bundle_base = 46;
                {2'd2, 7'd8}:  bundle_base = 47;
                {2'd2, 7'd16}: bundle_base = 49;
                {2'd2, 7'd32}: bundle_base = 53;
                default: bundle_base = 0;
            endcase
        end
    endfunction

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
                (n_i == 7'd16) || (n_i == 7'd32))
                valid_config = (type_i <= 2'd2);
            else if (n_i == 7'd64)
                valid_config = (type_i == 2'd0);
        end
    endfunction

    function automatic logic [5:0] group_count_for(input logic [6:0] size_i);
        begin
            group_count_for = (size_i + 7'd3) >> 2;
        end
    endfunction

    function automatic logic signed [DATA_W-1:0] post_process(
        input logic signed [ACC_W-1:0] raw_i,
        input logic [3:0]              shift_i
    );
        logic signed [ACC_W-1:0] biased;
        logic signed [ACC_W-1:0] shifted;
        begin
            biased = raw_i + (1 <<< (shift_i - 1));
            shifted = biased >>> shift_i;
            if (shifted > 32767)
                post_process = 16'sh7fff;
            else if (shifted < -32768)
                post_process = 16'sh8000;
            else
                post_process = shifted[DATA_W-1:0];
        end
    endfunction

    function automatic logic signed [ACC_W-1:0] extend_product(
        input logic signed [PROD_W-1:0] product_i);
        begin
            extend_product = {{(ACC_W-PROD_W){product_i[PROD_W-1]}}, product_i};
        end
    endfunction

    integer init_b, init_t, init_logn, init_g, init_lane, init_term;
    initial begin
        $readmemh(COEFF_FILE, coeff_init);
        for (init_b = 0; init_b < BUNDLE_COUNT; init_b = init_b + 1)
            coeff_bundle_mem[init_b] = '0;
        for (init_t = 0; init_t < 3; init_t = init_t + 1)
            for (init_logn = 2; init_logn <= 6; init_logn = init_logn + 1)
                if ((init_t == 0) || (init_logn < 6))
                    for (init_g = 0; init_g < (1 << (init_logn - 2)); init_g = init_g + 1)
                        for (init_lane = 0; init_lane < 4; init_lane = init_lane + 1)
                            for (init_term = 0; init_term < MAX_N; init_term = init_term + 1)
                                if (init_term < (1 << init_logn))
                                    coeff_bundle_mem[bundle_base(init_t, 1 << init_logn) + init_g]
                                        [(init_lane*MAX_N + init_term)*COEFF_W +: COEFF_W] =
                                            coeff_init[rom_base(init_t, 1 << init_logn) +
                                                (init_g*4 + init_lane)*(1 << init_logn) + init_term];
    end

    // Admission and storage reservation. A vector reserves all of its result
    // groups before its first input group is accepted. This prevents output
    // backpressure from overwriting an admitted arithmetic transaction.
    always_comb begin
        free_found_c = 1'b0;
        free_slot_c  = 2'd0;
        for (free_scan_i = 0; free_scan_i < SLOT_COUNT;
             free_scan_i = free_scan_i + 1) begin
            if (!free_found_c && (slot_state_q[free_scan_i] == SLOT_FREE)) begin
                free_found_c = 1'b1;
                free_slot_c = free_scan_i[1:0];
            end
        end
        // A slot is not reusable merely because its final descriptor is being
        // issued. Stage 0 consumes the descriptor and reads the slot's
        // operands on the following edge, so the slot remains occupied until
        // that capture has completed. This intentionally removes the old
        // same-edge reuse shortcut.
        issue_last_c = issue_active_q &&
                       (issue_group_q ==
                        (group_count_for(slot_output_size_q[issue_slot_q]) - 1'b1));
        new_group_count_c = group_count_for(output_size);
        capacity_ok_c = ((reserved_groups_q + new_group_count_c) <= FIFO_DEPTH);
        in_req = load_active_q || (free_found_c && capacity_ok_c);
        start_accept = start && !load_active_q && free_found_c && capacity_ok_c;
    end

    always_comb begin
        input_group_accept = in_valid && in_req &&
                             (load_active_q || start_accept);
        pending_load_last = 1'b0;
        if (input_group_accept) begin
            if (start_accept)
                pending_load_last = (active_size <= 7'd4);
            else
                pending_load_last =
                    (load_group_q == ((slot_size_q[load_slot_q] >> 2) - 1'b1));
        end
    end

    always_comb begin
        ready_found_c = 1'b0;
        ready_slot_c  = 2'd0;
        for (ready_scan_i = 0; ready_scan_i < SLOT_COUNT;
             ready_scan_i = ready_scan_i + 1) begin
            if (!ready_found_c && (slot_state_q[ready_scan_i] == SLOT_READY)) begin
                ready_found_c = 1'b1;
                ready_slot_c = ready_scan_i[1:0];
            end
        end
    end

    // When the issue engine is idle, a ready slot can enter stage 0 on this
    // edge.  This removes the otherwise unnecessary idle edge between the
    // ready state and the first group, which is required for vector II=1 in
    // the N=4 mode.  For an active issue, the current group remains selected.
    always_comb begin
        issue_emit_c = issue_active_q || ((!issue_active_q) && ready_found_c);
        issue_emit_slot_c = issue_slot_q;
        issue_emit_group_c = issue_group_q;
        if (!issue_active_q && ready_found_c) begin
            issue_emit_slot_c = ready_slot_c;
            issue_emit_group_c = 5'd0;
        end
    end

    // The scheduler emits one compact descriptor per group.  All fields that
    // can be derived from slot metadata are frozen here; the following cycle
    // must not consult ready arbitration or live slot metadata for Stage 0.
    always_comb begin
        issue_desc_bundle_addr_c = 6'd0;
        issue_desc_active_size_c = 7'd0;
        issue_desc_shift_c       = 4'd7;
        issue_desc_last_c        = 1'b0;
        if (issue_emit_c) begin
            issue_desc_bundle_addr_c =
                bundle_base(slot_type_q[issue_emit_slot_c],
                            slot_matrix_size_q[issue_emit_slot_c]) + issue_emit_group_c;
            issue_desc_active_size_c = slot_size_q[issue_emit_slot_c];
            issue_desc_shift_c = slot_stage_q[issue_emit_slot_c] ? 4'd10 : 4'd7;
            issue_desc_last_c = (issue_emit_group_c ==
                                 (group_count_for(slot_output_size_q[issue_emit_slot_c]) - 1'b1));
        end
    end

    // Stage 0 captures the complete vector operands and coefficient bundle.
    logic                         s0_valid_q;
    logic                         s0_last_q;
    logic [4:0]                   s0_group_q;
    logic [3:0]                   s0_shift_q;
    logic [6:0]                   s0_active_size_q;
    logic signed [DATA_W-1:0]     s0_input_q [0:MAX_N-1];
    logic [BUNDLE_W-1:0]          s0_coeff_q;

    // Product stage and balanced reduction tree.
    logic                         s1_valid_q, s2_valid_q, s3_valid_q;
    logic                         s4_valid_q, s5_valid_q, s6_valid_q;
    logic                         s1_last_q, s2_last_q, s3_last_q;
    logic                         s4_last_q, s5_last_q, s6_last_q;
    logic [4:0]                   s1_group_q, s2_group_q, s3_group_q;
    logic [4:0]                   s4_group_q, s5_group_q, s6_group_q;
    logic signed [PROD_W-1:0]     product_q [0:3][0:MAX_N-1];
    logic signed [ACC_W-1:0]      reduce_l1_q [0:3][0:31];
    logic signed [ACC_W-1:0]      reduce_l2_q [0:3][0:15];
    logic signed [ACC_W-1:0]      reduce_l3_q [0:3][0:7];
    logic signed [ACC_W-1:0]      reduce_l4_q [0:3][0:3];
    logic signed [ACC_W-1:0]      reduce_l5_q [0:3];

    logic signed [PROD_W-1:0]     product_c [0:3][0:MAX_N-1];
    logic signed [ACC_W-1:0]      reduce_l1_c [0:3][0:31];
    logic signed [ACC_W-1:0]      reduce_l2_c [0:3][0:15];
    logic signed [ACC_W-1:0]      reduce_l3_c [0:3][0:7];
    logic signed [ACC_W-1:0]      reduce_l4_c [0:3][0:3];
    logic signed [ACC_W-1:0]      reduce_l5_c [0:3];
    logic signed [DATA_W-1:0]     rounded_c [0:3];

    logic [3:0] s1_shift_q, s2_shift_q, s3_shift_q;
    logic [3:0] s4_shift_q, s5_shift_q, s6_shift_q;
    logic                         pipe_out_valid_q;
    logic                         pipe_out_last_q;
    logic [4:0]                   pipe_out_group_q;
    logic signed [(4*DATA_W)-1:0] pipe_out_data_q;

    integer comb_lane_i;
    integer comb_term_i;
    integer comb_reduce_i;
    always_comb begin
        for (comb_lane_i = 0; comb_lane_i < 4; comb_lane_i = comb_lane_i + 1) begin
            for (comb_term_i = 0; comb_term_i < MAX_N; comb_term_i = comb_term_i + 1) begin
                if ((comb_term_i < s0_active_size_q) && s0_valid_q)
                    product_c[comb_lane_i][comb_term_i] =
                        $signed(s0_coeff_q[(comb_lane_i*MAX_N + comb_term_i)*COEFF_W +: COEFF_W]) *
                        $signed(s0_input_q[comb_term_i]);
                else
                    product_c[comb_lane_i][comb_term_i] = '0;
            end
            for (comb_reduce_i = 0; comb_reduce_i < 32; comb_reduce_i = comb_reduce_i + 1)
                reduce_l1_c[comb_lane_i][comb_reduce_i] =
                    extend_product(product_q[comb_lane_i][comb_reduce_i*2]) +
                    extend_product(product_q[comb_lane_i][comb_reduce_i*2+1]);
            for (comb_reduce_i = 0; comb_reduce_i < 16; comb_reduce_i = comb_reduce_i + 1)
                reduce_l2_c[comb_lane_i][comb_reduce_i] =
                    reduce_l1_q[comb_lane_i][comb_reduce_i*2] +
                    reduce_l1_q[comb_lane_i][comb_reduce_i*2+1];
            for (comb_reduce_i = 0; comb_reduce_i < 8; comb_reduce_i = comb_reduce_i + 1)
                reduce_l3_c[comb_lane_i][comb_reduce_i] =
                    reduce_l2_q[comb_lane_i][comb_reduce_i*2] +
                    reduce_l2_q[comb_lane_i][comb_reduce_i*2+1];
            for (comb_reduce_i = 0; comb_reduce_i < 4; comb_reduce_i = comb_reduce_i + 1)
                reduce_l4_c[comb_lane_i][comb_reduce_i] =
                    reduce_l3_q[comb_lane_i][comb_reduce_i*2] +
                    reduce_l3_q[comb_lane_i][comb_reduce_i*2+1];
            reduce_l5_c[comb_lane_i] =
                reduce_l4_q[comb_lane_i][0] + reduce_l4_q[comb_lane_i][1] +
                reduce_l4_q[comb_lane_i][2] + reduce_l4_q[comb_lane_i][3];
            rounded_c[comb_lane_i] = post_process(
                reduce_l5_q[comb_lane_i], s6_shift_q);
        end
    end

    integer pipe_lane_i;
    integer pipe_term_i;
    integer pipe_reduce_i;
    // The arithmetic pipeline has no ready input: its result capacity is
    // reserved at admission and the FIFO is deeper than one complete vector.
    // External output backpressure therefore cannot overwrite an in-flight
    // group; it only delays FIFO pops and future admissions.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_desc_valid_q <= 1'b0;
            issue_desc_slot_q <= '0;
            issue_desc_group_q <= '0;
            issue_desc_bundle_addr_q <= '0;
            issue_desc_active_size_q <= '0;
            issue_desc_shift_q <= 4'd7;
            issue_desc_last_q <= 1'b0;
            s0_valid_q <= 1'b0;
            s0_last_q <= 1'b0;
            s0_group_q <= '0;
            s0_shift_q <= 4'd7;
            s0_active_size_q <= '0;
            s0_coeff_q <= '0;
            s1_valid_q <= 1'b0; s2_valid_q <= 1'b0; s3_valid_q <= 1'b0;
            s4_valid_q <= 1'b0; s5_valid_q <= 1'b0; s6_valid_q <= 1'b0;
            s1_last_q <= 1'b0; s2_last_q <= 1'b0; s3_last_q <= 1'b0;
            s4_last_q <= 1'b0; s5_last_q <= 1'b0; s6_last_q <= 1'b0;
            s1_group_q <= '0; s2_group_q <= '0; s3_group_q <= '0;
            s4_group_q <= '0; s5_group_q <= '0; s6_group_q <= '0;
            s1_shift_q <= 4'd7; s2_shift_q <= 4'd7; s3_shift_q <= 4'd7;
            s4_shift_q <= 4'd7; s5_shift_q <= 4'd7; s6_shift_q <= 4'd7;
            pipe_out_valid_q <= 1'b0;
            pipe_out_last_q <= 1'b0;
            pipe_out_group_q <= '0;
            pipe_out_data_q <= '0;
            for (pipe_lane_i = 0; pipe_lane_i < 4; pipe_lane_i = pipe_lane_i + 1)
                for (pipe_term_i = 0; pipe_term_i < MAX_N;
                     pipe_term_i = pipe_term_i + 1)
                    product_q[pipe_lane_i][pipe_term_i] <= '0;
            for (pipe_lane_i = 0; pipe_lane_i < 4; pipe_lane_i = pipe_lane_i + 1) begin
                for (pipe_reduce_i = 0; pipe_reduce_i < 32; pipe_reduce_i = pipe_reduce_i + 1)
                    reduce_l1_q[pipe_lane_i][pipe_reduce_i] <= '0;
                for (pipe_reduce_i = 0; pipe_reduce_i < 16; pipe_reduce_i = pipe_reduce_i + 1)
                    reduce_l2_q[pipe_lane_i][pipe_reduce_i] <= '0;
                for (pipe_reduce_i = 0; pipe_reduce_i < 8; pipe_reduce_i = pipe_reduce_i + 1)
                    reduce_l3_q[pipe_lane_i][pipe_reduce_i] <= '0;
                for (pipe_reduce_i = 0; pipe_reduce_i < 4; pipe_reduce_i = pipe_reduce_i + 1)
                    reduce_l4_q[pipe_lane_i][pipe_reduce_i] <= '0;
                reduce_l5_q[pipe_lane_i] <= '0;
            end
        end else begin
            // Descriptor register: issue remains one group per cycle.
            issue_desc_valid_q <= issue_emit_c;
            if (issue_emit_c) begin
                issue_desc_slot_q <= issue_emit_slot_c;
                issue_desc_group_q <= issue_emit_group_c;
                issue_desc_bundle_addr_q <= issue_desc_bundle_addr_c;
                issue_desc_active_size_q <= issue_desc_active_size_c;
                issue_desc_shift_q <= issue_desc_shift_c;
                issue_desc_last_q <= issue_desc_last_c;
            end

            // Stage 0: capture from the registered descriptor only.  This is
            // the timing boundary between scheduler control and the wide
            // coefficient/operand capture network.
            s0_valid_q <= issue_desc_valid_q;
            if (issue_desc_valid_q) begin
                s0_group_q <= issue_desc_group_q;
                s0_last_q <= issue_desc_last_q;
                s0_shift_q <= issue_desc_shift_q;
                s0_active_size_q <= issue_desc_active_size_q;
                s0_coeff_q <= coeff_bundle_mem[issue_desc_bundle_addr_q];
                for (pipe_term_i = 0; pipe_term_i < MAX_N;
                     pipe_term_i = pipe_term_i + 1)
                    s0_input_q[pipe_term_i] <= input_mem[issue_desc_slot_q][pipe_term_i];
            end

            // Stage 1: products.
            s1_valid_q <= s0_valid_q;
            s1_last_q <= s0_last_q;
            s1_group_q <= s0_group_q;
            s1_shift_q <= s0_shift_q;
            if (s0_valid_q)
                for (pipe_lane_i = 0; pipe_lane_i < 4; pipe_lane_i = pipe_lane_i + 1)
                    for (pipe_term_i = 0; pipe_term_i < MAX_N;
                         pipe_term_i = pipe_term_i + 1)
                        product_q[pipe_lane_i][pipe_term_i] <=
                            product_c[pipe_lane_i][pipe_term_i];

            // Reduction level 1.
            s2_valid_q <= s1_valid_q;
            s2_last_q <= s1_last_q;
            s2_group_q <= s1_group_q;
            s2_shift_q <= s1_shift_q;
            if (s1_valid_q)
                for (pipe_lane_i = 0; pipe_lane_i < 4; pipe_lane_i = pipe_lane_i + 1)
                    for (pipe_reduce_i = 0; pipe_reduce_i < 32;
                         pipe_reduce_i = pipe_reduce_i + 1)
                        reduce_l1_q[pipe_lane_i][pipe_reduce_i] <=
                            reduce_l1_c[pipe_lane_i][pipe_reduce_i];

            // Reduction level 2.
            s3_valid_q <= s2_valid_q;
            s3_last_q <= s2_last_q;
            s3_group_q <= s2_group_q;
            s3_shift_q <= s2_shift_q;
            if (s2_valid_q)
                for (pipe_lane_i = 0; pipe_lane_i < 4; pipe_lane_i = pipe_lane_i + 1)
                    for (pipe_reduce_i = 0; pipe_reduce_i < 16;
                         pipe_reduce_i = pipe_reduce_i + 1)
                        reduce_l2_q[pipe_lane_i][pipe_reduce_i] <=
                            reduce_l2_c[pipe_lane_i][pipe_reduce_i];

            // Reduction level 3.
            s4_valid_q <= s3_valid_q;
            s4_last_q <= s3_last_q;
            s4_group_q <= s3_group_q;
            s4_shift_q <= s3_shift_q;
            if (s3_valid_q)
                for (pipe_lane_i = 0; pipe_lane_i < 4; pipe_lane_i = pipe_lane_i + 1)
                    for (pipe_reduce_i = 0; pipe_reduce_i < 8;
                         pipe_reduce_i = pipe_reduce_i + 1)
                        reduce_l3_q[pipe_lane_i][pipe_reduce_i] <=
                            reduce_l3_c[pipe_lane_i][pipe_reduce_i];

            // Reduction level 4.
            s5_valid_q <= s4_valid_q;
            s5_last_q <= s4_last_q;
            s5_group_q <= s4_group_q;
            s5_shift_q <= s4_shift_q;
            if (s4_valid_q)
                for (pipe_lane_i = 0; pipe_lane_i < 4; pipe_lane_i = pipe_lane_i + 1)
                    for (pipe_reduce_i = 0; pipe_reduce_i < 4;
                         pipe_reduce_i = pipe_reduce_i + 1)
                        reduce_l4_q[pipe_lane_i][pipe_reduce_i] <=
                            reduce_l4_c[pipe_lane_i][pipe_reduce_i];

            // Final reduction.
            s6_valid_q <= s5_valid_q;
            s6_last_q <= s5_last_q;
            s6_group_q <= s5_group_q;
            s6_shift_q <= s5_shift_q;
            if (s5_valid_q)
                for (pipe_lane_i = 0; pipe_lane_i < 4; pipe_lane_i = pipe_lane_i + 1)
                    reduce_l5_q[pipe_lane_i] <= reduce_l5_c[pipe_lane_i];

            // Final round/clip register.
            pipe_out_valid_q <= s6_valid_q;
            pipe_out_last_q <= s6_last_q;
            pipe_out_group_q <= s6_group_q;
            if (s6_valid_q)
                for (pipe_lane_i = 0; pipe_lane_i < 4; pipe_lane_i = pipe_lane_i + 1)
                    pipe_out_data_q[pipe_lane_i*DATA_W +: DATA_W] <= rounded_c[pipe_lane_i];
        end
    end

    // Result FIFO. The FIFO is sized for multiple complete 64-point vectors
    // plus the arithmetic pipeline, while admission reserves actual groups.
    logic signed [(4*DATA_W)-1:0] fifo_data_q [0:FIFO_DEPTH-1];
    logic                         fifo_last_q [0:FIFO_DEPTH-1];
    logic [FIFO_PTR_W-1:0]        fifo_rd_ptr_q;
    logic [FIFO_PTR_W-1:0]        fifo_wr_ptr_q;
    logic [FIFO_PTR_W:0]          fifo_count_q;
    logic                         fifo_push_c;
    logic                         fifo_pop_c;
    logic                         fifo_full_c;

    always_comb begin
        fifo_push_c = pipe_out_valid_q;
        fifo_full_c = (fifo_count_q == FIFO_DEPTH);
        fifo_pop_c = (fifo_count_q != 0) && out_req;
        out_valid = (fifo_count_q != 0) && out_req;
        out_data = '0;
        if (fifo_count_q != 0)
            out_data = fifo_data_q[fifo_rd_ptr_q];
        out_fire = fifo_pop_c;
        out_last_fire = fifo_pop_c && fifo_last_q[fifo_rd_ptr_q];
        // Compatibility-visible status used by existing standalone benches.
        output_active_q = (fifo_count_q != 0);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_rd_ptr_q <= '0;
            fifo_wr_ptr_q <= '0;
            fifo_count_q <= '0;
            for (reset_i = 0; reset_i < FIFO_DEPTH; reset_i = reset_i + 1) begin
                fifo_data_q[reset_i] <= '0;
                fifo_last_q[reset_i] <= 1'b0;
            end
        end else begin
            if (fifo_push_c && !fifo_full_c) begin
                fifo_data_q[fifo_wr_ptr_q] <= pipe_out_data_q;
                fifo_last_q[fifo_wr_ptr_q] <= pipe_out_last_q;
                fifo_wr_ptr_q <= fifo_wr_ptr_q + 1'b1;
            end
            if (fifo_pop_c)
                fifo_rd_ptr_q <= fifo_rd_ptr_q + 1'b1;
            case ({fifo_push_c && !fifo_full_c, fifo_pop_c})
                2'b10: fifo_count_q <= fifo_count_q + 1'b1;
                2'b01: fifo_count_q <= fifo_count_q - 1'b1;
                default: fifo_count_q <= fifo_count_q;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_active_q <= 1'b0;
            load_slot_q <= '0;
            load_group_q <= '0;
            issue_active_q <= 1'b0;
            issue_slot_q <= '0;
            issue_group_q <= '0;
            reserved_groups_q <= '0;
            error <= 1'b0;
            done <= 1'b0;
            for (reset_i = 0; reset_i < SLOT_COUNT; reset_i = reset_i + 1) begin
                slot_state_q[reset_i] <= SLOT_FREE;
                slot_type_q[reset_i] <= '0;
                slot_size_q[reset_i] <= '0;
                slot_matrix_size_q[reset_i] <= '0;
                slot_output_size_q[reset_i] <= '0;
                slot_stage_q[reset_i] <= 1'b0;
            end
        end else begin
            done <= 1'b0;

            if (start && !start_accept)
                error <= 1'b1;
            if (start_accept && !valid_config(tr_type, transform_size))
                error <= 1'b1;

            if (start_accept) begin
                slot_type_q[free_slot_c] <= tr_type;
                slot_size_q[free_slot_c] <= active_size;
                slot_matrix_size_q[free_slot_c] <= transform_size;
                slot_output_size_q[free_slot_c] <= output_size;
                slot_stage_q[free_slot_c] <= stage_sel;
                load_slot_q <= free_slot_c;
                load_group_q <= 5'd0;
                load_active_q <= 1'b1;
                slot_state_q[free_slot_c] <= SLOT_LOAD;
                if (input_group_accept) begin
                    for (write_lane_i = 0; write_lane_i < 4;
                         write_lane_i = write_lane_i + 1)
                        input_mem[free_slot_c][write_lane_i] <=
                            $signed(in_data[write_lane_i*DATA_W +: DATA_W]);
                    if (active_size <= 7'd4) begin
                        slot_state_q[free_slot_c] <= SLOT_READY;
                        load_active_q <= 1'b0;
                    end else begin
                        load_group_q <= 5'd1;
                    end
                end
            end else if (load_active_q && input_group_accept) begin
                for (write_lane_i = 0; write_lane_i < 4;
                     write_lane_i = write_lane_i + 1)
                    input_mem[load_slot_q][load_group_q*4 + write_lane_i] <=
                        $signed(in_data[write_lane_i*DATA_W +: DATA_W]);
                if (pending_load_last) begin
                    slot_state_q[load_slot_q] <= SLOT_READY;
                    load_active_q <= 1'b0;
                    load_group_q <= '0;
                end else begin
                    load_group_q <= load_group_q + 1'b1;
                end
            end

            if (!issue_active_q && ready_found_c) begin
                if (group_count_for(slot_output_size_q[ready_slot_c]) <= 6'd1) begin
                    // The descriptor is emitted directly, but the slot stays
                    // OUT until the following edge captures its operands.
                    issue_active_q <= 1'b0;
                    issue_slot_q <= ready_slot_c;
                    issue_group_q <= '0;
                    slot_state_q[ready_slot_c] <= SLOT_OUT;
                end else begin
                    issue_active_q <= 1'b1;
                    issue_slot_q <= ready_slot_c;
                    issue_group_q <= 5'd1;
                    slot_state_q[ready_slot_c] <= SLOT_OUT;
                end
            end else if (issue_active_q) begin
                if (issue_group_q ==
                    (group_count_for(slot_output_size_q[issue_slot_q]) - 1'b1)) begin
                    issue_active_q <= 1'b0;
                    issue_group_q <= '0;
                end else begin
                    issue_group_q <= issue_group_q + 1'b1;
                end
            end

            // Release only after the registered descriptor has actually been
            // consumed by Stage 0. This prevents a new vector from
            // overwriting input_mem before its final operand capture.
            if (issue_desc_valid_q && issue_desc_last_q)
                slot_state_q[issue_desc_slot_q] <= SLOT_FREE;

            if (out_last_fire)
                done <= 1'b1;

            case ({start_accept, out_fire})
                2'b10: reserved_groups_q <= reserved_groups_q + new_group_count_c;
                2'b01: reserved_groups_q <= reserved_groups_q - 1'b1;
                2'b11: reserved_groups_q <= reserved_groups_q + new_group_count_c - 1'b1;
                default: reserved_groups_q <= reserved_groups_q;
            endcase
        end
    end

    always_comb begin
            busy = load_active_q || issue_active_q || issue_desc_valid_q ||
                   (fifo_count_q != 0) ||
               (reserved_groups_q != 0) || s0_valid_q || s1_valid_q ||
               s2_valid_q || s3_valid_q || s4_valid_q || s5_valid_q ||
               s6_valid_q || pipe_out_valid_q;
        for (busy_scan_i = 0; busy_scan_i < SLOT_COUNT;
             busy_scan_i = busy_scan_i + 1)
            if (slot_state_q[busy_scan_i] != SLOT_FREE)
                busy = 1'b1;
    end
endmodule
