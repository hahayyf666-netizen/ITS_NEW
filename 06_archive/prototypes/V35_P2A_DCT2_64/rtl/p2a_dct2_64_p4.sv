`timescale 1ns/1ps
// P2A prototype: DCT2-64, one-dimensional, four complete results per cycle.
//
// This is deliberately independent of the V3.4 core.  It has:
//   * two 64x16-bit vector buffers;
//   * 64 input-index PEs, each with four multiplication lanes (256 lanes);
//   * four six-level, registered 64-term reduction trees;
//   * 40-bit signed raw accumulation and V3.4 +32 >>>6 wrap16;
//   * a non-stalling compute pipeline and a 32-group result FIFO;
//   * strategy-B reservation: a new vector is admitted only when 16 slots
//     are available, including all reserved in-flight groups.
//
// The coefficient file is generated from canonical inverse_operator A=C^T.
// It is row-major A[output_row][input_col], and is selected dynamically for
// all 16 out_group values.  No second transpose is performed here.

module p2a_dct2_64_p4 #(
    parameter integer VECTOR_ID_W = 32,
    parameter integer FIFO_DEPTH = 32,
    parameter integer COEFF_COUNT = 4096
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // Four-point/cycle vector loader.  vector_start starts one 64-point
    // invocation; the following 16 load_valid beats fill the selected A/B
    // buffer.  The external V3.4 one-point interface is not used here.
    input  logic                         vector_start,
    input  logic [VECTOR_ID_W-1:0]       vector_start_id,
    output logic                         vector_start_ready,
    input  logic                         load_valid,
    input  logic [63:0]                   load_data,
    output logic                         load_ready,

    // Four complete signed16 results per output beat.
    output logic                         result_valid,
    input  logic                         result_ready,
    output logic [63:0]                   result_data,
    output logic [3:0]                    result_group,
    output logic [VECTOR_ID_W-1:0]        result_vector_id,
    output logic                         result_first,
    output logic                         result_last,

    // Observable audit counters/events.
    output logic [5:0]                    fifo_occupied,
    output logic [5:0]                    reserved_count,
    output logic                         launch_pulse,
    output logic                         issue_pulse,
    output logic [3:0]                    issue_group,
    output logic [VECTOR_ID_W-1:0]        issue_vector_id
);

    localparam integer ADDR_W = $clog2(FIFO_DEPTH);

    // Canonical DCT2-64 inverse operator A=C^T.  The source artifact remains
    // row-major, but synthesis uses four lane-partitioned ROMs.  The lane
    // dimension is static while all 16 output groups remain dynamically
    // selectable; this avoids a single 4096-entry, 256-read-port mux cone.
    logic signed [15:0] coeff_lane0 [0:1023];
    logic signed [15:0] coeff_lane1 [0:1023];
    logic signed [15:0] coeff_lane2 [0:1023];
    logic signed [15:0] coeff_lane3 [0:1023];
    initial begin
        $readmemh("dct2_64_coeff_l0.hex", coeff_lane0);
        $readmemh("dct2_64_coeff_l1.hex", coeff_lane1);
        $readmemh("dct2_64_coeff_l2.hex", coeff_lane2);
        $readmemh("dct2_64_coeff_l3.hex", coeff_lane3);
    end

    logic signed [15:0] vec_a [0:63];
    logic signed [15:0] vec_b [0:63];
    logic               ready_a, ready_b;
    logic [VECTOR_ID_W-1:0] ready_id_a, ready_id_b;
    logic               load_active;
    logic               load_sel;
    logic [3:0]         load_group;
    logic [VECTOR_ID_W-1:0] load_id;

    logic               compute_active;
    logic               compute_sel;
    logic [3:0]         compute_group;
    logic [VECTOR_ID_W-1:0] compute_id;

    logic               candidate_valid;
    logic               candidate_sel;
    logic [VECTOR_ID_W-1:0] candidate_id;
    integer             free_slots;
    logic               launch_accept;
    logic               issue_fire;
    logic               issue_sel;
    logic [3:0]         issue_group_w;
    logic [VECTOR_ID_W-1:0] issue_id_w;

    // Register issue metadata before it fans out into the 64 vector
    // selection muxes.  This removes the direct compute_active -> mux-bank
    // timing arc while preserving one group issue per cycle.
    logic               issue_fire_r;
    logic               issue_sel_r;
    logic [3:0]         issue_group_r;
    logic [VECTOR_ID_W-1:0] issue_id_r;

    // Each generated product tap has a constant input-column index and a
    // dynamic 4-bit group index.  Generate-time lane selection keeps the
    // four ROM banks physically separate without fixing any group.
    wire signed [15:0] coeff_lookup [0:3][0:63];
    genvar coeff_gl, coeff_gk;
    generate
        for (coeff_gl = 0; coeff_gl < 4; coeff_gl = coeff_gl + 1) begin : GEN_COEFF_LANE
            for (coeff_gk = 0; coeff_gk < 64; coeff_gk = coeff_gk + 1) begin : GEN_COEFF_COL
                if (coeff_gl == 0)
                    assign coeff_lookup[coeff_gl][coeff_gk] = coeff_lane0[issue_group_r*64 + coeff_gk];
                else if (coeff_gl == 1)
                    assign coeff_lookup[coeff_gl][coeff_gk] = coeff_lane1[issue_group_r*64 + coeff_gk];
                else if (coeff_gl == 2)
                    assign coeff_lookup[coeff_gl][coeff_gk] = coeff_lane2[issue_group_r*64 + coeff_gk];
                else
                    assign coeff_lookup[coeff_gl][coeff_gk] = coeff_lane3[issue_group_r*64 + coeff_gk];
            end
        end
    endgenerate

    assign load_ready = load_active;

    // A buffer cannot be overwritten while it is being computed or while a
    // complete vector is waiting for admission.
    always_comb begin
        vector_start_ready = !load_active;
        if (!load_sel && (ready_a || (compute_active && !compute_sel)))
            vector_start_ready = 1'b0;
        if (load_sel && (ready_b || (compute_active && compute_sel)))
            vector_start_ready = 1'b0;
    end

    always_comb begin
        if (ready_a) begin
            candidate_valid = 1'b1;
            candidate_sel   = 1'b0;
            candidate_id    = ready_id_a;
        end else if (ready_b) begin
            candidate_valid = 1'b1;
            candidate_sel   = 1'b1;
            candidate_id    = ready_id_b;
        end else begin
            candidate_valid = 1'b0;
            candidate_sel   = 1'b0;
            candidate_id    = '0;
        end
        free_slots = FIFO_DEPTH - fifo_occupied - reserved_count;
        launch_accept = (!compute_active && candidate_valid && (free_slots >= 16));
        issue_fire    = compute_active || launch_accept;
        issue_sel     = compute_active ? compute_sel : candidate_sel;
        issue_group_w = compute_active ? compute_group : 4'd0;
        issue_id_w    = compute_active ? compute_id : candidate_id;
    end

    assign launch_pulse  = launch_accept;
    assign issue_pulse   = issue_fire;
    assign issue_group   = issue_group_w;
    assign issue_vector_id = issue_id_w;

    // Vector loading and compute admission.  A completed vector is admitted
    // at the same edge that its group 0 is issued, so group issue interval is
    // 1 cycle and vector invocation interval is 16 cycles when both buffers
    // are ready and the FIFO has capacity.
    integer li;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_active <= 1'b0;
            load_sel    <= 1'b0;
            load_group  <= 4'd0;
            load_id     <= '0;
            ready_a     <= 1'b0;
            ready_b     <= 1'b0;
            ready_id_a  <= '0;
            ready_id_b  <= '0;
            compute_active <= 1'b0;
            compute_sel <= 1'b0;
            compute_group <= 4'd0;
            compute_id <= '0;
            issue_fire_r <= 1'b0;
            issue_sel_r <= 1'b0;
            issue_group_r <= 4'd0;
            issue_id_r <= '0;
        end else begin
            if (vector_start && vector_start_ready) begin
                load_active <= 1'b1;
                load_group  <= 4'd0;
                load_id     <= vector_start_id;
                // Permit the first four points to be presented with the
                // start handshake.  This removes a loader bubble and lets
                // the next A/B vector be prepared while group 0 is issued.
                if (load_valid) begin
                    for (li = 0; li < 4; li = li + 1) begin
                        if (!load_sel)
                            vec_a[li] <= $signed(load_data[li*16 +: 16]);
                        else
                            vec_b[li] <= $signed(load_data[li*16 +: 16]);
                    end
                    load_group <= 4'd1;
                end
            end else if (load_active && load_valid) begin
                for (li = 0; li < 4; li = li + 1) begin
                    if (!load_sel)
                        vec_a[load_group*4+li] <= $signed(load_data[li*16 +: 16]);
                    else
                        vec_b[load_group*4+li] <= $signed(load_data[li*16 +: 16]);
                end
                if (load_group == 4'd15) begin
                    load_active <= 1'b0;
                    if (!load_sel) begin
                        ready_a    <= 1'b1;
                        ready_id_a <= load_id;
                    end else begin
                        ready_b    <= 1'b1;
                        ready_id_b <= load_id;
                    end
                    load_sel <= ~load_sel;
                end else begin
                    load_group <= load_group + 4'd1;
                end
            end

            if (compute_active) begin
                if (compute_group == 4'd15) begin
                    compute_active <= 1'b0;
                    compute_group  <= 4'd0;
                end else begin
                    compute_group <= compute_group + 4'd1;
                end
            end else if (launch_accept) begin
                compute_active <= 1'b1;
                compute_sel    <= candidate_sel;
                compute_id     <= candidate_id;
                compute_group  <= 4'd1;
                if (!candidate_sel)
                    ready_a <= 1'b0;
                else
                    ready_b <= 1'b0;
            end

            // Delay metadata by one cycle for the registered selection
            // stage.  The corresponding valid/group/id pipeline entries are
            // sourced from these delayed registers below.
            issue_fire_r   <= issue_fire;
            issue_sel_r    <= issue_sel;
            issue_group_r  <= issue_group_w;
            issue_id_r     <= issue_id_w;
        end
    end

    // 256 multiplication lanes.  In synthesis each lane is an explicit
    // DSP48E2 with AREG/BREG/MREG/PREG enabled.  The simulation-only path below
    // models the same four-clock multiplier latency without requiring a
    // vendor simulation library.  Every reduction level is registered below,
    // forming four fully pipelined six-level trees.  This keeps the
    // ready/compute control and coefficient-group muxes out of the DSP input
    // timing arc.
    logic signed [15:0] vec_selected_r [0:63];
    logic signed [15:0] coeff_selected_r [0:3][0:63];
    wire signed [31:0] prod_r [0:3][0:63];

`ifndef SYNTHESIS
    logic signed [31:0] prod_beh_pipe0 [0:3][0:63];
    logic signed [31:0] prod_beh_pipe1 [0:3][0:63];
    logic signed [31:0] prod_beh_pipe2 [0:3][0:63];
`else
    wire [47:0] dsp_p [0:3][0:63];
`endif
    logic signed [39:0] tree0_r [0:3][0:31];
    logic signed [39:0] tree1_r [0:3][0:15];
    logic signed [39:0] tree2_r [0:3][0:7];
    logic signed [39:0] tree3_r [0:3][0:3];
    logic signed [39:0] tree4_r [0:3][0:1];
    logic signed [39:0] tree5_r [0:3];

    wire signed [39:0] tree0_w [0:3][0:31];
    wire signed [39:0] tree1_w [0:3][0:15];
    wire signed [39:0] tree2_w [0:3][0:7];
    wire signed [39:0] tree3_w [0:3][0:3];
    wire signed [39:0] tree4_w [0:3][0:1];
    wire signed [39:0] tree5_w [0:3];

    genvar gl, gk;
    generate
        for (gl = 0; gl < 4; gl = gl + 1) begin : GEN_TREE_LANE
            for (gk = 0; gk < 32; gk = gk + 1) begin : GEN_T0
                assign tree0_w[gl][gk] =
                    $signed({{8{prod_r[gl][2*gk][31]}}, prod_r[gl][2*gk]}) +
                    $signed({{8{prod_r[gl][2*gk+1][31]}}, prod_r[gl][2*gk+1]});
            end
            for (gk = 0; gk < 16; gk = gk + 1) begin : GEN_T1
                assign tree1_w[gl][gk] = tree0_r[gl][2*gk] + tree0_r[gl][2*gk+1];
            end
            for (gk = 0; gk < 8; gk = gk + 1) begin : GEN_T2
                assign tree2_w[gl][gk] = tree1_r[gl][2*gk] + tree1_r[gl][2*gk+1];
            end
            for (gk = 0; gk < 4; gk = gk + 1) begin : GEN_T3
                assign tree3_w[gl][gk] = tree2_r[gl][2*gk] + tree2_r[gl][2*gk+1];
            end
            for (gk = 0; gk < 2; gk = gk + 1) begin : GEN_T4
                assign tree4_w[gl][gk] = tree3_r[gl][2*gk] + tree3_r[gl][2*gk+1];
            end
            assign tree5_w[gl] = tree4_r[gl][0] + tree4_r[gl][1];
        end
    endgenerate

    // One extra stage is present before prod_r for the registered selection.
    logic [10:0] valid_pipe;
    logic [3:0] group_pipe [0:10];
    logic [VECTOR_ID_W-1:0] id_pipe [0:10];
    logic signed [40:0] biased_r [0:3];
    logic signed [40:0] shifted_r [0:3];
    logic signed [15:0] stage16_r [0:3];
    logic               stage_valid;
    logic [3:0]         stage_group;
    logic [VECTOR_ID_W-1:0] stage_id;
    // The inferred-multiply baseline had one registered product boundary.
    // The DSP AREG/BREG/MREG/PREG path adds two effective clocks beyond that
    // boundary (selection is already registered), so two token stages are
    // sufficient before reduction stage 0.
    logic               prod_valid_pipe [0:1];
    logic [3:0]         prod_group_pipe [0:1];
    logic [VECTOR_ID_W-1:0] prod_id_pipe [0:1];
    integer pl, pj;

    // Synthesis path: use the DSP48E2's input, multiplier, and output
    // registers.  A/B are sign-extended to the primitive's native widths;
    // OPMODE=000000101 selects the registered multiplier result (P=M).
    // The upper 16 product bits are intentionally retained in the 48-bit DSP
    // result and the lower 32 bits are the exact signed16* signed16 product.
`ifdef SYNTHESIS
    genvar dsp_gl, dsp_gk;
    generate
        for (dsp_gl = 0; dsp_gl < 4; dsp_gl = dsp_gl + 1) begin : GEN_DSP_LANE
            for (dsp_gk = 0; dsp_gk < 64; dsp_gk = dsp_gk + 1) begin : GEN_DSP_COL
                wire [29:0] dsp_a = {{14{vec_selected_r[dsp_gk][15]}}, vec_selected_r[dsp_gk]};
                wire [17:0] dsp_b = {{2{coeff_selected_r[dsp_gl][dsp_gk][15]}}, coeff_selected_r[dsp_gl][dsp_gk]};
                DSP48E2 #(
                    .A_INPUT("DIRECT"),
                    .B_INPUT("DIRECT"),
                    .AREG(1),
                    .ACASCREG(1),
                    .BREG(1),
                    .BCASCREG(1),
                    .MREG(1),
                    .PREG(1),
                    .ADREG(0),
                    .ALUMODEREG(0),
                    .CARRYINREG(0),
                    .CARRYINSELREG(0),
                    .CREG(0),
                    .DREG(0),
                    .INMODEREG(0),
                    .OPMODEREG(0),
                    .USE_MULT("MULTIPLY"),
                    .USE_SIMD("ONE48")
                ) u_dsp48e2 (
                    .A(dsp_a),
                    .ACIN(30'b0),
                    .ALUMODE(4'b0000),
                    .B(dsp_b),
                    .BCIN(18'b0),
                    .C(48'b0),
                    .CARRYCASCIN(1'b0),
                    .CARRYIN(1'b0),
                    .CARRYINSEL(3'b000),
                    .CEA1(1'b1),
                    .CEA2(1'b1),
                    .CEAD(1'b0),
                    .CEALUMODE(1'b0),
                    .CEB1(1'b1),
                    .CEB2(1'b1),
                    .CEC(1'b0),
                    .CECARRYIN(1'b0),
                    .CECTRL(1'b0),
                    .CED(1'b0),
                    .CEINMODE(1'b0),
                    .CEM(1'b1),
                    .CEP(1'b1),
                    .CLK(clk),
                    .D(27'b0),
                    .INMODE(5'b00000),
                    .MULTSIGNIN(1'b0),
                    .OPMODE(9'b000000101),
                    .PCIN(48'b0),
                    .RSTA(!rst_n),
                    .RSTALLCARRYIN(1'b0),
                    .RSTALUMODE(1'b0),
                    .RSTB(!rst_n),
                    .RSTC(1'b0),
                    .RSTCTRL(1'b0),
                    .RSTD(1'b0),
                    .RSTINMODE(1'b0),
                    .RSTM(!rst_n),
                    .RSTP(!rst_n),
                    .P(dsp_p[dsp_gl][dsp_gk])
                );
                assign prod_r[dsp_gl][dsp_gk] = dsp_p[dsp_gl][dsp_gk][31:0];
            end
        end
    endgenerate
`else
    genvar beh_gl, beh_gk;
    generate
        for (beh_gl = 0; beh_gl < 4; beh_gl = beh_gl + 1) begin : GEN_BEH_LANE
            for (beh_gk = 0; beh_gk < 64; beh_gk = beh_gk + 1) begin : GEN_BEH_COL
                assign prod_r[beh_gl][beh_gk] = prod_beh_pipe2[beh_gl][beh_gk];
            end
        end
    endgenerate
`endif

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe <= '0;
            for (pl = 0; pl < 4; pl = pl + 1) begin
                biased_r[pl] <= '0;
                shifted_r[pl] <= '0;
            end
            stage_valid <= 1'b0;
            stage_group <= '0;
            stage_id <= '0;
            for (pl = 0; pl < 4; pl = pl + 1) begin
                stage16_r[pl] <= '0;
                for (pj = 0; pj < 64; pj = pj + 1) begin
                    coeff_selected_r[pl][pj] <= '0;
                end
            end
            for (pj = 0; pj < 64; pj = pj + 1) begin
                vec_selected_r[pj] <= '0;
            end
            for (pj = 0; pj < 2; pj = pj + 1) begin
                prod_valid_pipe[pj] <= 1'b0;
                prod_group_pipe[pj] <= '0;
                prod_id_pipe[pj] <= '0;
            end
`ifndef SYNTHESIS
            for (pl = 0; pl < 4; pl = pl + 1)
                for (pj = 0; pj < 64; pj = pj + 1) begin
                    prod_beh_pipe0[pl][pj] <= '0;
                    prod_beh_pipe1[pl][pj] <= '0;
                    prod_beh_pipe2[pl][pj] <= '0;
                end
`endif
        end else begin
            // Registered product-input selection.  The valid pipe masks
            // non-issued cycles, so the extra registers do not change the
            // mathematical contract but remove the long issue_sel path from
            // the DSP input timing arc.
            for (pj = 0; pj < 64; pj = pj + 1) begin
                if (!issue_sel_r)
                    vec_selected_r[pj] <= $signed(vec_a[pj]);
                else
                    vec_selected_r[pj] <= $signed(vec_b[pj]);
            end
            for (pl = 0; pl < 4; pl = pl + 1) begin
                for (pj = 0; pj < 64; pj = pj + 1) begin
                    coeff_selected_r[pl][pj] <= $signed(coeff_lookup[pl][pj]);
                end
            end

`ifndef SYNTHESIS
            // Match the four registered DSP48E2 multiplier clocks.  The
            // input selection registers above are the first cycle; this
            // behavioral pipe produces the product after the same boundary
            // at which the DSP PREG result is visible.
            for (pl = 0; pl < 4; pl = pl + 1)
                for (pj = 0; pj < 64; pj = pj + 1) begin
                    prod_beh_pipe0[pl][pj] <= $signed(vec_selected_r[pj]) *
                        $signed(coeff_selected_r[pl][pj]);
                    prod_beh_pipe1[pl][pj] <= prod_beh_pipe0[pl][pj];
                    prod_beh_pipe2[pl][pj] <= prod_beh_pipe1[pl][pj];
                end
`endif

            // Six registered reduction levels: 64->32->16->8->4->2->1.
            for (pl = 0; pl < 4; pl = pl + 1) begin
                for (pj = 0; pj < 32; pj = pj + 1) tree0_r[pl][pj] <= tree0_w[pl][pj];
                for (pj = 0; pj < 16; pj = pj + 1) tree1_r[pl][pj] <= tree1_w[pl][pj];
                for (pj = 0; pj < 8; pj = pj + 1)  tree2_r[pl][pj] <= tree2_w[pl][pj];
                for (pj = 0; pj < 4; pj = pj + 1)  tree3_r[pl][pj] <= tree3_w[pl][pj];
                for (pj = 0; pj < 2; pj = pj + 1)  tree4_r[pl][pj] <= tree4_w[pl][pj];
                tree5_r[pl] <= tree5_w[pl];
            end

            // Product-valid/tag pipeline matches the effective DSP product
            // boundary.  Reduction stage 0 sees only a product-ready token,
            // never an early issue token.
            prod_valid_pipe[0] <= issue_fire_r;
            prod_group_pipe[0] <= issue_group_r;
            prod_id_pipe[0] <= issue_id_r;
            for (pj = 1; pj <= 1; pj = pj + 1) begin
                prod_valid_pipe[pj] <= prod_valid_pipe[pj-1];
                prod_group_pipe[pj] <= prod_group_pipe[pj-1];
                prod_id_pipe[pj] <= prod_id_pipe[pj-1];
            end
            valid_pipe[0] <= prod_valid_pipe[1];
            group_pipe[0] <= prod_group_pipe[1];
            id_pipe[0] <= prod_id_pipe[1];
            for (pj = 1; pj <= 7; pj = pj + 1) begin
                valid_pipe[pj] <= valid_pipe[pj-1];
                group_pipe[pj] <= group_pipe[pj-1];
                id_pipe[pj] <= id_pipe[pj-1];
            end

            if (valid_pipe[7]) begin
                for (pl = 0; pl < 4; pl = pl + 1)
                    biased_r[pl] <= $signed({{1{tree5_r[pl][39]}},tree5_r[pl]}) + 41'sd32;
            end
            valid_pipe[8] <= valid_pipe[7];
            group_pipe[8] <= group_pipe[7];
            id_pipe[8] <= id_pipe[7];
            if (valid_pipe[8]) begin
                for (pl = 0; pl < 4; pl = pl + 1)
                    shifted_r[pl] <= $signed(biased_r[pl]) >>> 6;
            end
            valid_pipe[9] <= valid_pipe[8];
            group_pipe[9] <= group_pipe[8];
            id_pipe[9] <= id_pipe[8];
            if (valid_pipe[9]) begin
                for (pl = 0; pl < 4; pl = pl + 1)
                    stage16_r[pl] <= shifted_r[pl][15:0];
            end
            // stage16_r is written when valid_pipe[9] is true.  Publish the
            // matching valid/tag on that same pipeline boundary.
            valid_pipe[10] <= valid_pipe[9];
            group_pipe[10] <= group_pipe[9];
            id_pipe[10] <= id_pipe[9];
            stage_valid <= valid_pipe[9];
            stage_group <= group_pipe[9];
            stage_id <= id_pipe[9];
        end
    end

    // Result FIFO: 32 groups, each group has four signed16 results.
    logic signed [15:0] fifo_data [0:FIFO_DEPTH-1][0:3];
    logic [3:0] fifo_group [0:FIFO_DEPTH-1];
    logic [VECTOR_ID_W-1:0] fifo_id [0:FIFO_DEPTH-1];
    logic fifo_first [0:FIFO_DEPTH-1];
    logic fifo_last [0:FIFO_DEPTH-1];
    logic [ADDR_W-1:0] fifo_wr_ptr, fifo_rd_ptr;
    wire fifo_wr_fire = stage_valid;
    wire fifo_rd_fire = result_valid && result_ready;
    integer fi;

    assign result_valid = (fifo_occupied != 0);
    assign result_data = {fifo_data[fifo_rd_ptr][3], fifo_data[fifo_rd_ptr][2],
                          fifo_data[fifo_rd_ptr][1], fifo_data[fifo_rd_ptr][0]};
    assign result_group = fifo_group[fifo_rd_ptr];
    assign result_vector_id = fifo_id[fifo_rd_ptr];
    assign result_first = fifo_first[fifo_rd_ptr];
    assign result_last = fifo_last[fifo_rd_ptr];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_occupied <= 6'd0;
            reserved_count <= 6'd0;
            fifo_wr_ptr <= '0;
            fifo_rd_ptr <= '0;
        end else begin
            if (fifo_wr_fire) begin
                if (fifo_occupied >= FIFO_DEPTH)
                    $fatal(1, "P2A result FIFO overflow");
                fifo_data[fifo_wr_ptr][0] <= stage16_r[0];
                fifo_data[fifo_wr_ptr][1] <= stage16_r[1];
                fifo_data[fifo_wr_ptr][2] <= stage16_r[2];
                fifo_data[fifo_wr_ptr][3] <= stage16_r[3];
                fifo_group[fifo_wr_ptr] <= stage_group;
                fifo_id[fifo_wr_ptr] <= stage_id;
                fifo_first[fifo_wr_ptr] <= (stage_group == 0);
                fifo_last[fifo_wr_ptr] <= (stage_group == 15);
                fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
            end
            if (fifo_rd_fire)
                fifo_rd_ptr <= fifo_rd_ptr + 1'b1;

            case ({fifo_wr_fire, fifo_rd_fire})
                2'b10: fifo_occupied <= fifo_occupied + 1'b1;
                2'b01: fifo_occupied <= fifo_occupied - 1'b1;
                default: fifo_occupied <= fifo_occupied;
            endcase

            // Strategy-B accounting.  A launch reserves all 16 groups;
            // each FIFO write transfers one slot from reserved to occupied.
            case ({launch_accept, fifo_wr_fire})
                2'b10: reserved_count <= reserved_count + 6'd16;
                2'b01: reserved_count <= reserved_count - 1'b1;
                // A new invocation may launch on the same edge that the
                // previous pipeline's final result enters the FIFO.
                // Reserve 16 and retire 1 on that edge.
                2'b11: reserved_count <= reserved_count + 6'd15;
                default: reserved_count <= reserved_count;
            endcase
            if ((fifo_occupied + reserved_count > FIFO_DEPTH) ||
                (launch_accept && (free_slots < 16)))
                $fatal(1, "P2A capacity overcommit occupied=%0d reserved=%0d",
                       fifo_occupied, reserved_count);
        end
    end

endmodule
