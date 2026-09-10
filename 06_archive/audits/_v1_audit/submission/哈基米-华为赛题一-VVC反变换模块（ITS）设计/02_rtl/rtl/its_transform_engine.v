// ===================================================================
// ITS Transform Engine - 4 points per clock with parallel MACs
// Performs 1D inverse transform: y = T^T * x
// 4 MAC units compute 4 output rows simultaneously
//
// For N>4, multiple row groups are processed sequentially:
//   Each group: prefetch 4 rows of coefficients → compute 4 outputs
//   Total groups: ceil(N/4) = N/4
// ===================================================================

module its_transform_engine (
    input  wire        clk,
    input  wire        rst_n,

    // Control
    input  wire        start,
    input  wire [1:0]  tr_type,
    input  wire [6:0]  size,

    // Data input
    input  wire [15:0] data_in,
    input  wire        data_in_vld,
    output wire        data_in_req,

    // ROM interface
    output wire [13:0] rom_addr,
    input  wire [15:0] rom_coeff,

    // Data output
    output reg  [15:0] data_out,
    output reg         data_out_vld,
    input  wire        data_out_req,

    // Status
    output wire        done
);

    // State machine
    localparam S_IDLE    = 3'd0;
    localparam S_LOAD    = 3'd1;
    localparam S_PREFETCH = 3'd2;
    localparam S_COMPUTE = 3'd3;
    localparam S_OUTPUT  = 3'd4;

    // Transform rounding parameters
    localparam ROUND_SHIFT = 6;
    localparam ROUND_CONST = 40'sd32;  // 2^(ROUND_SHIFT-1)

    reg [2:0] state;

    // Line buffer (input data) - shared across all row groups
    reg signed [15:0] line_buf [0:63];
    reg [5:0] load_cnt;

    // Coefficient buffer: 4 rows x N coeffs
    // Re-populated for each row group
    reg signed [15:0] coeff_buf [0:255];

    // Pre-fetch counters
    reg [7:0] pf_cnt;
    reg [1:0] pf_row;
    reg [5:0] pf_rom_col;
    reg [1:0] pf_rom_row;

    // Row group counter (which group of 4 rows we're processing)
    reg [5:0] row_group;

    // Compute counters
    reg [5:0] comp_col;
    reg [6:0] comp_row_base;

    // Output counters
    reg [5:0] out_cnt;

    // Result buffer
    reg signed [39:0] result_buf [0:63];

    // ============================================================
    // ROM address computation
    // ============================================================
    // Registered size parameters: latched on start to break high-fanout
    // combinational path (tu_width → size_shift → coeff_buf write addr)
    reg [5:0] size_shift;
    reg [6:0] size_m1;  // size - 1, for boundary conditions

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            size_shift <= 6'd0;
            size_m1    <= 7'd0;
        end else if (start) begin
            size_m1 <= size - 7'd1;
            case (size)
                7'd4:    size_shift <= 6'd2;
                7'd8:    size_shift <= 6'd3;
                7'd16:   size_shift <= 6'd4;
                7'd32:   size_shift <= 6'd5;
                7'd64:   size_shift <= 6'd6;
                default: size_shift <= 6'd0;
            endcase
        end
    end

    // base_addr: registered on start to break tu_width → ROM address combinational path
    reg [13:0] base_addr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            base_addr <= 14'd0;
        else if (start) begin
            case ({tr_type, size})
                {2'd0, 7'd4}:   base_addr <= 14'd0;
                {2'd0, 7'd8}:   base_addr <= 14'd16;
                {2'd0, 7'd16}:  base_addr <= 14'd80;
                {2'd0, 7'd32}:  base_addr <= 14'd336;
                {2'd0, 7'd64}:  base_addr <= 14'd1360;
                {2'd1, 7'd4}:   base_addr <= 14'd5456;
                {2'd1, 7'd8}:   base_addr <= 14'd5472;
                {2'd1, 7'd16}:  base_addr <= 14'd5536;
                {2'd1, 7'd32}:  base_addr <= 14'd5792;
                {2'd2, 7'd4}:   base_addr <= 14'd6816;
                {2'd2, 7'd8}:   base_addr <= 14'd6832;
                {2'd2, 7'd16}:  base_addr <= 14'd6896;
                {2'd2, 7'd32}:  base_addr <= 14'd7152;
                default:         base_addr <= 14'd0;
            endcase
        end
    end

    // ============================================================
    // ROM address computation helpers (declared early)
    // ============================================================
    wire [7:0] rom_row_idx = {row_group[5:0], 2'b00} + {6'd0, pf_rom_row};

`ifdef TRANSFORM_TIMING_OPT
    // Pre-computed next row base: base_addr + ((rom_row_idx+1) << size_shift)
    // Barrel shifter is in this path, NOT in ROM address critical path.
    reg [13:0] next_row_base;
    wire [7:0] next_rom_row_idx = rom_row_idx + 8'd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            next_row_base <= 14'd0;
        else if (start)
            next_row_base <= base_addr;
        else if (state == S_PREFETCH)
            next_row_base <= base_addr + ({6'd0, next_rom_row_idx} << size_shift);
    end

    wire       is_last_col = (pf_rom_col == size_m1[5:0]);
`else
    // Simulation: combinational ROM address (no barrel shifter optimization needed)
    wire [13:0] rom_addr_r = base_addr + ({6'd0, rom_row_idx} << size_shift) + {8'd0, pf_rom_col};
`endif

    // ============================================================
    // Pipeline registers (declared before MAC to avoid forward refs)
    // ============================================================
    // Pipeline register for ROM latency (1 stage - ROM has internal register)
    reg [1:0]  pf_dly_row;
    reg [5:0]  pf_dly_col;
    reg        pf_dly_valid;

    // Second pipeline stage (synthesis only): compensates for registered ROM address
`ifdef TRANSFORM_TIMING_OPT
    reg [1:0]  pf_ddly_row;
    reg [5:0]  pf_ddly_col;
    reg        pf_ddly_valid;
`endif

    // mac_final: 1-cycle delayed signal indicating all MAC inputs for a group are done
    reg        mac_final;

    // ============================================================
    // 4 MAC units
    // ============================================================
    // mac_en: gates MAC multiply stage
    // Simulation: direct (0-cycle read latency)
    // Synthesis:  2-cycle delay (BRAM read + P0 pipeline = 2 cycles)
`ifdef SYNTHESIS
    wire        mac_en_raw = (state == S_COMPUTE);
    reg         mac_en;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mac_en <= 1'b0;
        else
            mac_en   <= mac_en_raw;
    end
`else
    wire        mac_en = (state == S_COMPUTE);
`endif
    // Clear MAC at start of loading AND at each row group transition
    // pf_to_compute fires when ROM reads the last coefficient (pf_rom_col == N-1).
    // With registered ROM address, the accumulator pre-computes the address,
    // but pf_to_compute timing stays the same: it marks the end of prefetch.
    wire        pf_to_compute = (state == S_PREFETCH &&
                                 pf_rom_row == 2'd3 && pf_rom_col >= size_m1[5:0]);
    wire        mac_clr = (state == S_LOAD && load_cnt == 6'd0 && data_in_vld) || pf_to_compute;

    // Register mac_clr to break pf_to_compute → mac_clr → result_reg combinational path
    // (10 logic levels → 4 + 6). Timing safe: MAC pipeline has 2-cycle en delay,
    // so 1-cycle clr delay clears before first accumulate.
`ifdef SYNTHESIS
    (* max_fanout = 16 *) reg mac_clr_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mac_clr_r <= 1'b0;
        else
            mac_clr_r <= mac_clr;
    end
`endif

    // pf_to_compute_d: 1-cycle delayed pf_to_compute
    // Used to write the last coefficient from ROM pipeline to coeff_buf
    reg        pf_to_compute_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pf_to_compute_d <= 1'b0;
        else
            pf_to_compute_d <= pf_to_compute;
    end

    // P0 pipeline: registers between memory outputs and MAC inputs
    // Simulation: not needed (0-cycle read latency)
    // Synthesis:  breaks long combinational paths for timing
    //             line_buf + coeff_buf both through P0, mac_en (1-cycle delay)
`ifdef SYNTHESIS
    // Replicate mac_data_r per MAC to reduce fanout (60 → 15) and
    // allow Vivado to place each copy near its DSP48E2.
    (* max_fanout = 16 *) reg signed [15:0] mac_data_r0;
    (* max_fanout = 16 *) reg signed [15:0] mac_data_r1;
    (* max_fanout = 16 *) reg signed [15:0] mac_data_r2;
    (* max_fanout = 16 *) reg signed [15:0] mac_data_r3;
    (* dont_touch = "yes" *) reg signed [15:0] mac_coeff_p0 [0:3];

    wire [15:0] mac_coeff_raw [0:3];
    assign mac_coeff_raw[0] = coeff_buf[{2'd0, comp_col}];
    assign mac_coeff_raw[1] = coeff_buf[(8'd1 << size_shift) + {2'd0, comp_col}];
    assign mac_coeff_raw[2] = coeff_buf[(8'd2 << size_shift) + {2'd0, comp_col}];
    assign mac_coeff_raw[3] = coeff_buf[(8'd3 << size_shift) + {2'd0, comp_col}];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_data_r0     <= 16'sd0;
            mac_data_r1     <= 16'sd0;
            mac_data_r2     <= 16'sd0;
            mac_data_r3     <= 16'sd0;
            mac_coeff_p0[0] <= 16'sd0;
            mac_coeff_p0[1] <= 16'sd0;
            mac_coeff_p0[2] <= 16'sd0;
            mac_coeff_p0[3] <= 16'sd0;
        end else begin
            mac_data_r0     <= line_buf[comp_col];
            mac_data_r1     <= line_buf[comp_col];
            mac_data_r2     <= line_buf[comp_col];
            mac_data_r3     <= line_buf[comp_col];
            mac_coeff_p0[0] <= mac_coeff_raw[0];
            mac_coeff_p0[1] <= mac_coeff_raw[1];
            mac_coeff_p0[2] <= mac_coeff_raw[2];
            mac_coeff_p0[3] <= mac_coeff_raw[3];
        end
    end
`else
    wire [15:0] mac_data = line_buf[comp_col];
`endif

    // mac_coeff: shared across SYNTHESIS and simulation paths
    wire [15:0] mac_coeff [0:3];
`ifdef SYNTHESIS
    assign mac_coeff[0] = mac_coeff_p0[0];
    assign mac_coeff[1] = mac_coeff_p0[1];
    assign mac_coeff[2] = mac_coeff_p0[2];
    assign mac_coeff[3] = mac_coeff_p0[3];
`else
    assign mac_coeff[0] = coeff_buf[{2'd0, comp_col}];
    assign mac_coeff[1] = coeff_buf[(8'd1 << size_shift) + {2'd0, comp_col}];
    assign mac_coeff[2] = coeff_buf[(8'd2 << size_shift) + {2'd0, comp_col}];
    assign mac_coeff[3] = coeff_buf[(8'd3 << size_shift) + {2'd0, comp_col}];
`endif

    wire signed [39:0] mac_result [0:3];
    wire        mac_valid [0:3];

`ifdef SYNTHESIS
    its_mac u_mac0 (.clk(clk), .rst_n(rst_n), .en(mac_en), .clr(mac_clr_r), .a(mac_data_r0), .b(mac_coeff[0]), .result(mac_result[0]), .valid(mac_valid[0]));
    its_mac u_mac1 (.clk(clk), .rst_n(rst_n), .en(mac_en), .clr(mac_clr_r), .a(mac_data_r1), .b(mac_coeff[1]), .result(mac_result[1]), .valid(mac_valid[1]));
    its_mac u_mac2 (.clk(clk), .rst_n(rst_n), .en(mac_en), .clr(mac_clr_r), .a(mac_data_r2), .b(mac_coeff[2]), .result(mac_result[2]), .valid(mac_valid[2]));
    its_mac u_mac3 (.clk(clk), .rst_n(rst_n), .en(mac_en), .clr(mac_clr_r), .a(mac_data_r3), .b(mac_coeff[3]), .result(mac_result[3]), .valid(mac_valid[3]));
`else
    its_mac u_mac0 (.clk(clk), .rst_n(rst_n), .en(mac_en), .clr(mac_clr), .a(mac_data), .b(mac_coeff[0]), .result(mac_result[0]), .valid(mac_valid[0]));
    its_mac u_mac1 (.clk(clk), .rst_n(rst_n), .en(mac_en), .clr(mac_clr), .a(mac_data), .b(mac_coeff[1]), .result(mac_result[1]), .valid(mac_valid[1]));
    its_mac u_mac2 (.clk(clk), .rst_n(rst_n), .en(mac_en), .clr(mac_clr), .a(mac_data), .b(mac_coeff[2]), .result(mac_result[2]), .valid(mac_valid[2]));
    its_mac u_mac3 (.clk(clk), .rst_n(rst_n), .en(mac_en), .clr(mac_clr), .a(mac_data), .b(mac_coeff[3]), .result(mac_result[3]), .valid(mac_valid[3]));
`endif

    // mac_final: 1-cycle delayed from last column
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mac_final <= 1'b0;
        else
            mac_final <= (state == S_COMPUTE && comp_col >= size_m1);
    end

    // mac_final_d: 2-cycle delayed - accounts for MAC pipeline latency
    // MAC: cycle N-1 multiply, cycle N accumulate. Result fully ready at cycle N.
    // mac_final_d fires at cycle N+1 when result has the complete sum.
    reg mac_final_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mac_final_d <= 1'b0;
        else
            mac_final_d <= mac_final;
    end

    // mac_final_e: 3-cycle delayed (synthesis only, for P0 pipeline)
    // Simulation: mac_final_d (2 cycles) — no P0, result ready at mac_final_d
    // Synthesis:  mac_final_e (3 cycles) — P0 adds 1 cycle to coeff path
`ifdef SYNTHESIS
    reg mac_final_e;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mac_final_e <= 1'b0;
        else
            mac_final_e <= mac_final_d;
    end
    wire mac_final_ok = mac_final_e;
`else
    wire mac_final_ok = mac_final_d;
`endif

    // ============================================================
    // Registered ROM address (accumulator pattern) — SYNTHESIS ONLY
    // ============================================================
    // Eliminates barrel shifter from critical path by pre-computing
    // row base address and using incremental update.
    // ROM has 1-cycle read latency; registered addr adds 1 more cycle.
    // Total 2-cycle latency compensated by pf_ddly pipeline.
    //
    // Simulation: uses combinational ROM address (rom_addr_r) + pf_dly (1 stage)
    // Synthesis:  uses registered ROM address (rom_addr_reg) + pf_ddly (2 stages)
`ifdef TRANSFORM_TIMING_OPT
    // ROM address accumulator: registered, updated each cycle
    // Common case: acc + 1 (simple increment, no barrel shifter)
    // Row transition: next_row_base + 0 (pre-computed, no barrel shifter)
    // Group transition: stable sources (base_addr or next_row_base) — avoids NBA stale-read
    reg [13:0] rom_addr_reg;

    wire entering_prefetch = (state == S_LOAD && load_cnt >= size_m1 && data_in_vld) ||
                             (state == S_COMPUTE && mac_final_ok && mac_valid[0] && comp_row_base < size);

    // Use stable registered sources directly — no intermediate register needed
    wire [13:0] prefetch_start_addr = (state == S_LOAD) ? base_addr : next_row_base;
    wire [13:0] acc_next = entering_prefetch ? prefetch_start_addr :
                           is_last_col      ? next_row_base :
                                              (rom_addr_reg + 14'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rom_addr_reg <= 14'd0;
        else if (state == S_PREFETCH || entering_prefetch)
            rom_addr_reg <= acc_next;
    end

    assign rom_addr = rom_addr_reg;
`else
    // Simulation: combinational ROM address
    assign rom_addr = rom_addr_r;
`endif

    // entering_compute: 1-cycle pulse on S_PREFETCH→S_COMPUTE transition
    // Used to write the last coefficient from ROM pipeline to coeff_buf
    reg entering_compute;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            entering_compute <= 1'b0;
        else
            entering_compute <= (state == S_PREFETCH && pf_to_compute_d);
    end

    // Coefficient buffer write address computation
`ifdef TRANSFORM_TIMING_OPT
    // Synthesis: uses pf_ddly (2-stage pipeline for registered ROM address)
    wire [7:0] pf_ddly_row_ext = {6'd0, pf_ddly_row};
    wire [7:0] coeff_buf_wr_addr = (pf_ddly_row_ext << size_shift) + {2'd0, pf_ddly_col};

    reg [7:0]  coeff_buf_wr_addr_r;
    reg        pf_ddly_valid_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            coeff_buf_wr_addr_r <= 8'd0;
            pf_ddly_valid_d     <= 1'b0;
        end else begin
            coeff_buf_wr_addr_r <= coeff_buf_wr_addr;
            pf_ddly_valid_d     <= pf_ddly_valid;
        end
    end
    reg entering_compute_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            entering_compute_d <= 1'b0;
        else
            entering_compute_d <= entering_compute;
    end
`else
    // Simulation: uses pf_dly (1-stage pipeline with combinational ROM address)
    wire [7:0] pf_dly_row_ext = {6'd0, pf_dly_row};
    wire [7:0] coeff_buf_wr_addr = (pf_dly_row_ext << size_shift) + {2'd0, pf_dly_col};
`endif

    // ============================================================
    // State machine
    // ============================================================
    // Loop: S_PREFETCH → S_COMPUTE → (if more groups) S_PREFETCH → ...
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else if (state == S_IDLE) begin
            if (start) state <= S_LOAD;
        end else case (state)
            S_LOAD:     if (load_cnt >= size_m1 && data_in_vld) state <= S_PREFETCH;
            S_PREFETCH: if (pf_to_compute_d) state <= S_COMPUTE;
            S_COMPUTE:  if (mac_final_ok && mac_valid[0]) begin
                            if (comp_row_base >= size)
                                state <= S_OUTPUT;
                            else
                                state <= S_PREFETCH;  // More groups to process
                        end
            S_OUTPUT:   if (out_cnt >= size_m1 && data_out_req) state <= S_IDLE;
            default:    state <= S_IDLE;
        endcase
    end

    assign data_in_req = (state == S_LOAD);

    // ============================================================
    // Input load
    // ============================================================
    // line_buf write (no async reset for Block RAM inference)
    always @(posedge clk) begin
        if (state == S_LOAD && data_in_vld && data_in_req)
            line_buf[load_cnt] <= data_in;
    end

    // load_cnt control
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            load_cnt <= 6'd0;
        else if (state == S_IDLE && start)
            load_cnt <= 6'd0;
        else if (state == S_LOAD && data_in_vld && data_in_req)
            load_cnt <= load_cnt + 6'd1;
    end

    // ============================================================
    // Row group counter
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            row_group <= 6'd0;
        else if (state == S_LOAD && load_cnt >= size_m1 && data_in_vld)
            row_group <= 6'd0;
        else if (state == S_COMPUTE && comp_col >= size_m1)
            row_group <= row_group + 6'd1;
        else if (state != S_COMPUTE && state != S_PREFETCH)
            row_group <= 6'd0;
    end

    // ============================================================
    // Pre-fetch coefficients
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pf_rom_row <= 2'd0;
            pf_rom_col <= 6'd0;
            pf_cnt <= 8'd0;
            pf_row <= 2'd0;
        end else if (state == S_IDLE && start) begin
            // Clear prefetch counters when starting new transform
            pf_rom_row <= 2'd0;
            pf_rom_col <= 6'd0;
            pf_cnt <= 8'd0;
            pf_row <= 2'd0;
        end else if (state == S_LOAD && load_cnt >= size_m1 && data_in_vld) begin
            // Initialize for first group
            pf_rom_row <= 2'd0;
            pf_rom_col <= 6'd0;
            pf_cnt <= 8'd0;
            pf_row <= 2'd0;
        end else if (state == S_PREFETCH && pf_to_compute_d) begin
            // Extra cycle complete - reset counters for next group
            pf_rom_row <= 2'd0;
            pf_rom_col <= 6'd0;
            pf_cnt <= 8'd0;
            pf_row <= 2'd0;
        end else if (state == S_PREFETCH) begin
            if (pf_rom_col >= size_m1) begin
                pf_rom_col <= 6'd0;
                if (pf_rom_row < 2'd3)
                    pf_rom_row <= pf_rom_row + 2'd1;
                pf_row <= pf_row + 2'd1;
            end else begin
                pf_rom_col <= pf_rom_col + 6'd1;
            end
            pf_cnt <= pf_cnt + 8'd1;
        end
    end

    // Pipeline register for ROM latency (stage 1)
    // Hold pf_dly_row/col at last prefetch values when entering S_COMPUTE
    // so the last coefficient can be captured from ROM pipeline
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pf_dly_row  <= 2'd0;
            pf_dly_col  <= 6'd0;
            pf_dly_valid <= 1'b0;
        end else if (state == S_PREFETCH) begin
            pf_dly_row  <= pf_rom_row;
            pf_dly_col  <= pf_rom_col;
            pf_dly_valid <= 1'b1;
        end else if (state == S_COMPUTE && pf_dly_valid) begin
            pf_dly_valid <= 1'b0;
        end
    end

`ifdef TRANSFORM_TIMING_OPT
    // Pipeline register for ROM latency (stage 2 - compensates registered ROM address)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pf_ddly_row   <= 2'd0;
            pf_ddly_col   <= 6'd0;
            pf_ddly_valid <= 1'b0;
        end else if (state == S_PREFETCH) begin
            pf_ddly_row   <= pf_dly_row;
            pf_ddly_col   <= pf_dly_col;
            pf_ddly_valid <= pf_dly_valid;
        end else if (state == S_COMPUTE && pf_ddly_valid) begin
            pf_ddly_valid <= 1'b0;
        end
    end
`endif

    // Store ROM output into coeff_buf (no async reset for Block RAM inference)
`ifdef TRANSFORM_TIMING_OPT
    // Synthesis: uses pf_ddly (2-stage) to compensate for registered ROM address
    // Registered write address breaks high-fanout path
    always @(posedge clk) begin
        if (entering_compute_d) begin
            coeff_buf[coeff_buf_wr_addr_r] <= rom_coeff;
        end else if (pf_ddly_valid_d) begin
            coeff_buf[coeff_buf_wr_addr_r] <= rom_coeff;
        end
    end
`else
    // Simulation: uses pf_dly (1-stage) with combinational ROM address
    always @(posedge clk) begin
        if (entering_compute) begin
            coeff_buf[(pf_dly_row << size_shift) + {2'd0, pf_dly_col}] <= rom_coeff;
        end else if (state == S_PREFETCH && pf_dly_valid) begin
            coeff_buf[coeff_buf_wr_addr] <= rom_coeff;
        end
    end
`endif

    // ============================================================
    // Compute phase
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            comp_col <= 6'd0;
            comp_row_base <= 7'd0;
        end else if (state == S_LOAD && load_cnt >= size_m1 && data_in_vld) begin
            comp_col <= 6'd0;
            comp_row_base <= 7'd0;
        end else if (state == S_COMPUTE) begin
            if (comp_col >= size_m1) begin
                comp_col <= 6'd0;
                comp_row_base <= comp_row_base + 7'd4;
            end else begin
                comp_col <= comp_col + 6'd1;
            end
        end else if (state != S_COMPUTE) begin
            comp_col <= 6'd0;
        end
    end

    // Capture MAC results into result_buf (no async reset for Block RAM inference)
    always @(posedge clk) begin
        if (mac_final_ok && mac_valid[0]) begin
            result_buf[comp_row_base - 6'd4]         <= ($signed(mac_result[0]) + ROUND_CONST) >>> ROUND_SHIFT;
            result_buf[comp_row_base - 6'd4 + 6'd1] <= ($signed(mac_result[1]) + ROUND_CONST) >>> ROUND_SHIFT;
            result_buf[comp_row_base - 6'd4 + 6'd2] <= ($signed(mac_result[2]) + ROUND_CONST) >>> ROUND_SHIFT;
            result_buf[comp_row_base - 6'd4 + 6'd3] <= ($signed(mac_result[3]) + ROUND_CONST) >>> ROUND_SHIFT;
        end
    end

    // ============================================================
    // Output phase
    // ============================================================
    reg done_r;
    // done clears when start is asserted to prevent stale done from previous
    // row/test causing double processing
    assign done = done_r & ~start;

    // done_r management: set on output completion, clear on start
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            done_r <= 1'b0;
        else if (start)
            done_r <= 1'b0;
        else if (state == S_OUTPUT && data_out_req && out_cnt >= size_m1)
            done_r <= 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out     <= 16'd0;
            data_out_vld <= 1'b0;
            out_cnt      <= 6'd0;
        end else if (state == S_IDLE && start) begin
            out_cnt <= 6'd0;
        end else if (state == S_OUTPUT && data_out_req) begin
            data_out     <= result_buf[out_cnt];
            data_out_vld <= 1'b1;
            out_cnt      <= out_cnt + 6'd1;
        end else begin
            data_out_vld <= 1'b0;
        end
    end

endmodule
