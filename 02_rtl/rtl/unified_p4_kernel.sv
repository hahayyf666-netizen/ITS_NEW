// Step12E unified P4 1-D transform kernel.
//
// Four samples are accepted per input group and four complete transform
// outputs are emitted per output group.  Four ping-pong slots decouple input
// loading from output draining: while one slot is emitted, the next slot can
// be loaded.  Under ready-high, equal-size traffic, vector start II is N/4.
// This module is new code; the v3.5-18 R4C and historical wrapper are not
// modified or imported.

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
    // Coefficient-matrix dimension and active leading dimension are kept
    // separate for transform-support cuts (for example DST7/DCT8-32 and
    // DCT2-64).  Ordinary cases pass the same value on both ports.
    input  logic [6:0]                   active_size,
    // Number of output rows/columns emitted.  The horizontal pass can emit
    // the full matrix dimension while consuming only its active leading
    // terms (the skipped high-frequency terms are zero).
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
    localparam logic [1:0] SLOT_FREE  = 2'd0;
    localparam logic [1:0] SLOT_LOAD  = 2'd1;
    localparam logic [1:0] SLOT_READY = 2'd2;
    localparam logic [1:0] SLOT_OUT   = 2'd3;

    logic signed [COEFF_W-1:0] coeff_mem [0:COEFF_DEPTH-1];
    logic signed [DATA_W-1:0]  input_mem [0:SLOT_COUNT-1][0:MAX_N-1];
    logic [1:0] slot_state_q [0:SLOT_COUNT-1];
    logic [1:0] slot_type_q  [0:SLOT_COUNT-1];
    logic [6:0] slot_size_q  [0:SLOT_COUNT-1];
    logic [6:0] slot_matrix_size_q [0:SLOT_COUNT-1];
    logic [6:0] slot_output_size_q [0:SLOT_COUNT-1];
    logic       slot_stage_q [0:SLOT_COUNT-1];

    logic       load_active_q;
    logic [1:0] load_slot_q;
    logic [4:0] load_group_q;
    logic       output_active_q;
    logic [1:0] output_slot_q;
    logic [4:0] output_group_q;

    logic       free_found_c;
    logic [1:0] free_slot_c;
    logic       ready_found_c;
    logic [1:0] ready_slot_c;
    logic       start_accept;
    logic       input_group_accept;
    logic       pending_load_last;
    logic       output_fire;
    logic       output_last_fire;

    integer free_scan_i;
    integer ready_scan_i;
    integer busy_scan_i;
    integer lane_i;
    integer output_lane_i;
    integer input_i;
    integer coeff_index_i;
    logic signed [ACC_W-1:0] accum_c [0:3];
    logic signed [DATA_W-1:0] scaled_c [0:3];

    initial $readmemh(COEFF_FILE, coeff_mem);

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

    // A free slot is selected for a new vector.  The four-slot depth avoids a
    // same-edge free/reuse dependency and gives the ready-high pipeline room
    // for the smallest N=4 mode.
    always_comb begin
        free_found_c = 1'b0;
        free_slot_c  = 2'd0;
        for (free_scan_i = 0; free_scan_i < SLOT_COUNT;
             free_scan_i = free_scan_i + 1) begin
            if (!free_found_c && (slot_state_q[free_scan_i] == SLOT_FREE)) begin
                free_found_c = 1'b1;
                free_slot_c  = free_scan_i[1:0];
            end
        end
        in_req      = load_active_q || free_found_c;
        start_accept = start && !load_active_q && free_found_c && in_req;
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
                ready_slot_c  = ready_scan_i[1:0];
            end
        end
        // A final group accepted in this edge becomes ready after the edge;
        // make it eligible for the next output burst without a bubble.
        if (!ready_found_c && input_group_accept && pending_load_last) begin
            ready_found_c = 1'b1;
            ready_slot_c  = start_accept ? free_slot_c : load_slot_q;
        end
    end

    always_comb begin
        for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
            accum_c[lane_i] = '0;
            if (output_active_q &&
                valid_config(slot_type_q[output_slot_q],
                             slot_size_q[output_slot_q]) &&
                ((output_group_q * 4 + lane_i) < slot_output_size_q[output_slot_q])) begin
                for (input_i = 0; input_i < MAX_N; input_i = input_i + 1) begin
                    if (input_i < slot_size_q[output_slot_q]) begin
                        coeff_index_i =
                            rom_base(slot_type_q[output_slot_q],
                                     slot_matrix_size_q[output_slot_q]) +
                            ((output_group_q * 4 + lane_i) *
                             slot_matrix_size_q[output_slot_q]) + input_i;
                        accum_c[lane_i] = accum_c[lane_i] +
                            ($signed(coeff_mem[coeff_index_i]) *
                             $signed(input_mem[output_slot_q][input_i]));
                    end
                end
            end
            scaled_c[lane_i] = post_process(
                accum_c[lane_i],
                slot_stage_q[output_slot_q] ? 4'd10 : 4'd7);
        end
    end

    always_comb begin
        out_data = '0;
        for (output_lane_i = 0; output_lane_i < 4;
             output_lane_i = output_lane_i + 1)
            out_data[output_lane_i*DATA_W +: DATA_W] = scaled_c[output_lane_i];
        output_fire      = output_active_q && out_req;
        output_last_fire = output_fire &&
                           (output_group_q ==
                            ((slot_output_size_q[output_slot_q] >> 2) - 1'b1));
        out_valid = output_active_q && out_req;
        busy      = load_active_q || output_active_q;
        for (busy_scan_i = 0; busy_scan_i < SLOT_COUNT;
             busy_scan_i = busy_scan_i + 1)
            if (slot_state_q[busy_scan_i] != SLOT_FREE)
                busy = 1'b1;
    end

    integer reset_i;
    integer write_lane_i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_active_q  <= 1'b0;
            load_slot_q    <= 2'd0;
            load_group_q   <= 5'd0;
            output_active_q <= 1'b0;
            output_slot_q  <= 2'd0;
            output_group_q <= 5'd0;
            error          <= 1'b0;
            done           <= 1'b0;
            for (reset_i = 0; reset_i < SLOT_COUNT; reset_i = reset_i + 1) begin
                slot_state_q[reset_i] <= SLOT_FREE;
                slot_type_q[reset_i]  <= 2'd0;
                slot_size_q[reset_i]  <= 7'd0;
                slot_matrix_size_q[reset_i] <= 7'd0;
                slot_output_size_q[reset_i] <= 7'd0;
                slot_stage_q[reset_i] <= 1'b0;
            end
        end else begin
            done <= 1'b0;

            if (start && !start_accept)
                error <= 1'b1;
            if (start_accept && !valid_config(tr_type, transform_size))
                error <= 1'b1;

            if (start_accept) begin
                slot_type_q[free_slot_c]  <= tr_type;
                slot_size_q[free_slot_c]  <= active_size;
                slot_matrix_size_q[free_slot_c] <= transform_size;
                slot_output_size_q[free_slot_c] <= output_size;
                slot_stage_q[free_slot_c] <= stage_sel;
                load_slot_q              <= free_slot_c;
                load_group_q             <= 5'd0;
                load_active_q            <= 1'b1;
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
                    load_group_q <= 5'd0;
                end else begin
                    load_group_q <= load_group_q + 1'b1;
                end
            end

            if (output_active_q && output_fire) begin
                if (output_last_fire) begin
                    slot_state_q[output_slot_q] <= SLOT_FREE;
                    output_active_q <= 1'b0;
                    output_group_q <= 5'd0;
                end else begin
                    output_group_q <= output_group_q + 1'b1;
                end
            end

            if ((!output_active_q || output_last_fire) && ready_found_c) begin
                slot_state_q[ready_slot_c] <= SLOT_OUT;
                output_slot_q <= ready_slot_c;
                output_group_q <= 5'd0;
                output_active_q <= 1'b1;
            end

            if (output_last_fire)
                done <= 1'b1;
        end
    end
endmodule
