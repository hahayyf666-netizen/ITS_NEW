// ===================================================================
// ITS Core 500MHz - Compute core for dual-clock architecture
// Functionally equivalent to its_top with FIFO-based I/O interface.
//
// FIFO Protocol:
//   cmd_fifo:   FWFT (First Word Fall Through), 23-bit, depth 4
//               [22]=reserved(0), [21:0]=it_info
//               Core reads 1 entry per TU in S_IDLE. No end marker.
//
//   input_fifo: FWFT, 29-bit, depth 16
//               [28]=last, [27:16]=it_data_addr, [15:0]=it_data_in
//               Data available when !empty. Core reads 1 entry/cycle.
//               last=1 marks final entry of current TU (pure control signal, no data).
//
//   output_fifo: Standard write (registered), 40-bit, depth 16
//                [39:0]=4x10-bit output. wr_en pulses with valid data.
//                Full backpressures core output stage.
//
// All I/O ports registered. No OBUF/IOB paths.
// ROMs instantiated internally (synchronous read).
// ===================================================================

`include "its_pkg.v"

module its_core_500 (
    input  wire        clk_core,
    input  wire        rst_n,

    // Command FIFO interface — FWFT required
    input  wire [22:0] cmd_fifo_rdata,      // [21:0]=it_info, [22]=reserved(0)
    input  wire        cmd_fifo_empty,       // FWFT: data valid when !empty
    output wire        cmd_fifo_rd_en,       // pulse: consume 1 entry

    // Input data FIFO interface — FWFT required
    input  wire [28:0] input_fifo_rdata,     // [28]=last, [27:16]=addr, [15:0]=coeff
    input  wire        input_fifo_empty,      // FWFT: data valid when !empty
    output wire        input_fifo_rd_en,      // pulse: consume 1 entry

    // Output data FIFO interface — standard write
    output reg  [39:0] output_fifo_wdata,    // 4x10-bit output
    output reg         output_fifo_wr_en,    // pulse: write 1 entry
    input  wire        output_fifo_full,
    input  wire        output_fifo_almost_full,

    // Status
    output reg         core_done,            // TU completion pulse
    output wire        core_ready            // HIGH when core can accept input data
);

    // ========================================
    // Control signals
    // ========================================
    reg [6:0]  tu_width;
    reg [6:0]  tu_height;
    reg [1:0]  tr_type_hor;
    reg [1:0]  tr_type_ver;
    reg [1:0]  lfnst_tr_set_idx;
    reg [1:0]  lfnst_idx;
    reg [12:0] total_points;

    // State machine (from its_pkg)
    import its_pkg::*;

    reg [3:0] state;
    reg        out_pipe_flush;
    reg        out_valid_pipe;

    // Memory clear control
    reg        clearing;
    reg [11:0] clr_cnt;

    // Load pipeline registers: break input_fifo → in_mem write critical path
    reg        load_valid_r;   // registered FIFO read valid
    reg        load_last_r;    // registered last flag
    reg [11:0] load_addr_r;    // registered address
    reg [15:0] load_data_r;    // registered data

    // core_ready is assigned with load_accepting below, after the end-marker
    // detector is declared.

    // Input buffer: XPM for synthesis, reg array for simulation
    reg [11:0] in_mem_rd_addr;
    reg signed [15:0] in_mem_dout_r;

    // Write port signals (used by both XPM and simulation model)
    reg        in_mem_wr_en;
    reg [11:0] in_mem_wr_addr;
    reg [15:0] in_mem_wr_data;

`ifdef SYNTHESIS
    wire [15:0] in_mem_dout;
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A        (12),
        .ADDR_WIDTH_B        (12),
        .BYTE_WRITE_WIDTH_A  (16),
        .CLOCKING_MODE       ("common_clock"),
        .ECC_MODE            ("no_ecc"),
        .MEMORY_INIT_FILE    ("none"),
        .MEMORY_INIT_PARAM   ("0"),
        .MEMORY_OPTIMIZATION ("true"),
        .MEMORY_PRIMITIVE    ("auto"),
        .MEMORY_SIZE         (65536),
        .MESSAGE_CONTROL     (0),
        .READ_DATA_WIDTH_B   (16),
        .READ_LATENCY_B      (1),
        .READ_RESET_VALUE_B  ("0"),
        .RST_MODE_A          ("SYNC"),
        .RST_MODE_B          ("SYNC"),
        .SIM_ASSERT_CHK      (0),
        .USE_MEM_INIT        (0),
        .USE_MEM_INIT_MMI    (0),
        .WAKEUP_TIME         ("disable_sleep"),
        .WRITE_DATA_WIDTH_A  (16),
        .WRITE_MODE_B        ("no_change"),
        .WRITE_PROTECT       (1)
    ) u_in_mem (
        .clka   (clk_core),
        .ena    (1'b1),
        .wea    (in_mem_wr_en ? 1'b1 : 1'b0),
        .addra  (in_mem_wr_addr),
        .dina   (in_mem_wr_data),
        .clkb   (clk_core),
        .enb    (1'b1),
        .rstb   (1'b0),
        .regceb (1'b1),
        .addrb  (in_mem_rd_addr),
        .doutb  (in_mem_dout)
    );
    // XPM output is already registered (READ_LATENCY_B = 1)
    always @(*) in_mem_dout_r = in_mem_dout;
`else
    // Simulation model: reg array with 1-cycle read latency
    (* ram_style = "block" *) reg signed [15:0] in_mem [0:4095];
    always @(posedge clk_core) begin
        if (in_mem_wr_en)
            in_mem[in_mem_wr_addr] <= in_mem_wr_data;
        in_mem_dout_r <= in_mem[in_mem_rd_addr];
    end
`endif

    // LFNST overlay buffer: small buffer for LFNST results, avoids
    // writing back to large in_mem (eliminates high-fanout write path)
    reg signed [15:0] lfnst_out_buf [0:47];

    reg [11:0] in_wr_cnt;

    // Row/Column loop counters
    reg [6:0]  row_idx;
    reg [6:0]  col_idx;
    reg [11:0] row_base_addr;
    reg [6:0]  ver_step;     // row-within-column during vertical phase

    // Forward declarations (used before defined)
    wire        lfnst_ntrs_is_48;
    wire        lfnst_active;
    reg         out_done;

    // Engine address signals
    reg [11:0] col_eng_rd_addr;

    // Row engine signals
    wire [15:0] row_out_data;
    wire        row_out_vld;
    wire        row_done;
    wire        row_data_in_req;
    wire [13:0] row_rom_addr;
    wire [15:0] row_rom_coeff;

    // Row engine: absolute address counter (replaces base+offset)
    reg [11:0] row_in_mem_addr;

    // BRAM read: moved to combined always block below (with write port)
    // for proper BRAM inference

    // Overlay detection (combinational from registered signals)
    // LFNST output write-back per attachment spec:
    // nTrs=16: top-left 4x4 row-major (indices 0..15)
    // nTrs=48: top 4x8 row-major (0..31) + bottom-left 4x4 row-major (32..47)
    wire [6:0]  over_row = ver_step;
    wire [6:0]  over_col = row_idx[6:0];
    wire        overlay_top_48 = lfnst_ntrs_is_48 && (over_row < 7'd4) && (over_col < 7'd8);
    wire        overlay_bot_48 = lfnst_ntrs_is_48 && (over_row >= 7'd4) && (over_row < 7'd8) && (over_col < 7'd4);
    wire        overlay_hit_16 = lfnst_active && !lfnst_ntrs_is_48 &&
                                 (over_row < 7'd4) && (over_col < 7'd4);
    wire        overlay_hit_48 = lfnst_active && (overlay_top_48 || overlay_bot_48);
    wire        overlay_hit = lfnst_ntrs_is_48 ? overlay_hit_48 : overlay_hit_16;

    // overlay_idx: map position -> lfnst_out_buf index
    // nTrs=16: row-major within 4x4: idx = row*4 + col
    // nTrs=48: top 4x8: idx = row*8 + col; bottom 4x4: idx = 32 + (row-4)*4 + col
    wire [5:0] overlay_idx_16   = {2'd0, over_row[1:0], over_col[1:0]};
    wire [5:0] overlay_idx_48_top = {over_row[2:0], 3'b000} + {3'b000, over_col[2:0]};
    wire [5:0] overlay_idx_48_bot = 6'd32 + {over_row[1:0], 2'b00} + {4'b0000, over_col[1:0]};
    wire [5:0] overlay_idx_ntrs48 = overlay_top_48 ? overlay_idx_48_top : overlay_idx_48_bot;
    wire [5:0] overlay_idx = lfnst_ntrs_is_48 ? overlay_idx_ntrs48 : overlay_idx_16;

    // Registered overlay selection (aligns with BRAM 1-cycle read latency)
    reg        overlay_hit_r;
    reg [5:0]  overlay_idx_r;
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n) begin
            overlay_hit_r <= 1'b0;
            overlay_idx_r <= 6'd0;
        end else begin
            overlay_hit_r <= overlay_hit;
            overlay_idx_r <= overlay_idx;
        end
    end

    // Overlay data: read from lfnst_out_buf (DistRAM, combinational)
    wire [15:0] overlay_data = lfnst_out_buf[overlay_idx_r];

    // Mux: overlay vs in_mem BRAM output
    wire [15:0] row_in_mem_data = overlay_hit_r ? overlay_data : in_mem_dout_r;

    // Row engine valid (1 cycle: aligns with BRAM read latency)
    reg        row_data_in_vld_r;

    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            row_data_in_vld_r <= 1'b0;
        else
            row_data_in_vld_r <= (state == S_ROW_RUN);
    end

    // Column engine signals
    wire [15:0] col_out_data;
    wire        col_out_vld;
    wire        col_done;
    wire        col_data_in_req;
    wire [13:0] col_rom_addr;
    wire [15:0] col_rom_coeff;

    // Transpose buffer
    reg signed [15:0] tp_buf [0:4095];
    reg [11:0] tp_wr_cnt;
    reg [11:0] tp_rd_base;

    // Output reorder buffer
    reg signed [9:0] out_mem [0:4095];
    // out_row_cnt / out_col_cnt removed — debug-only, unused by logic

    // Output control
    reg [12:0] out_cnt;
    reg [39:0] data_out_r;

    // ========================================
    // LFNST signals
    // ========================================
    wire [15:0] lfnst_data_out;
    wire        lfnst_data_out_vld;
    wire        lfnst_data_out_wr_en;
    wire        lfnst_done;
    wire        lfnst_data_in_req;

    assign      lfnst_ntrs_is_48 = (tu_width >= 7'd8 && tu_height >= 7'd8);
    wire [5:0]  lfnst_ntrs = lfnst_ntrs_is_48 ? 6'd48 : 6'd16;

    reg [5:0]  lfnst_rd_addr;
    reg [5:0]  lfnst_wr_addr;

    // LFNST 4x4 diagonal scan (VVC attachment spec):
    // scan[0..15] = (0,0),(1,0),(0,1),(2,0),(1,1),(0,2),(3,0),(2,1),
    //               (1,2),(0,3),(3,1),(2,2),(1,3),(3,2),(2,3),(3,3)
    reg [1:0] lfnst_rd_row_d;
    reg [1:0] lfnst_rd_col_d;
    always @(*) begin
        case (lfnst_rd_addr[3:0])
            4'd0:  begin lfnst_rd_row_d = 2'd0; lfnst_rd_col_d = 2'd0; end
            4'd1:  begin lfnst_rd_row_d = 2'd1; lfnst_rd_col_d = 2'd0; end
            4'd2:  begin lfnst_rd_row_d = 2'd0; lfnst_rd_col_d = 2'd1; end
            4'd3:  begin lfnst_rd_row_d = 2'd2; lfnst_rd_col_d = 2'd0; end
            4'd4:  begin lfnst_rd_row_d = 2'd1; lfnst_rd_col_d = 2'd1; end
            4'd5:  begin lfnst_rd_row_d = 2'd0; lfnst_rd_col_d = 2'd2; end
            4'd6:  begin lfnst_rd_row_d = 2'd3; lfnst_rd_col_d = 2'd0; end
            4'd7:  begin lfnst_rd_row_d = 2'd2; lfnst_rd_col_d = 2'd1; end
            4'd8:  begin lfnst_rd_row_d = 2'd1; lfnst_rd_col_d = 2'd2; end
            4'd9:  begin lfnst_rd_row_d = 2'd0; lfnst_rd_col_d = 2'd3; end
            4'd10: begin lfnst_rd_row_d = 2'd3; lfnst_rd_col_d = 2'd1; end
            4'd11: begin lfnst_rd_row_d = 2'd2; lfnst_rd_col_d = 2'd2; end
            4'd12: begin lfnst_rd_row_d = 2'd1; lfnst_rd_col_d = 2'd3; end
            4'd13: begin lfnst_rd_row_d = 2'd3; lfnst_rd_col_d = 2'd2; end
            4'd14: begin lfnst_rd_row_d = 2'd2; lfnst_rd_col_d = 2'd3; end
            4'd15: begin lfnst_rd_row_d = 2'd3; lfnst_rd_col_d = 2'd3; end
            default: begin lfnst_rd_row_d = 2'd0; lfnst_rd_col_d = 2'd0; end
        endcase
    end

    // Read top-left 4x4 block using 2D row/col address (works for all TU widths)
    wire [11:0] lfnst_rd_mem_addr =
        row_times_width(lfnst_rd_row_d, tu_width) + {10'd0, lfnst_rd_col_d};

    // LFNST BRAM read pipeline: delay data_in_vld by 1 cycle to match BRAM read latency
    reg        lfnst_data_in_vld_d;

    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            lfnst_data_in_vld_d <= 1'b0;
        else
            lfnst_data_in_vld_d <= (state == S_LFNST && lfnst_data_in_req);
    end


    // in_mem read address mux: LFNST vs row engine (combinational)
    always @(*) begin
        if (state == S_LFNST)
            in_mem_rd_addr = lfnst_rd_mem_addr;
        else
            in_mem_rd_addr = row_in_mem_addr;
    end

    wire [12:0] lfnst_rom_addr;
    wire [15:0] lfnst_rom_coeff;

    assign      lfnst_active = (lfnst_idx != 2'd0);
    wire [1:0]  row_tr_type = lfnst_active ? 2'd0 : tr_type_ver;   // first phase = vertical
    wire [1:0]  col_tr_type = lfnst_active ? 2'd0 : tr_type_hor;   // second phase = horizontal

    // ========================================
    // Command FIFO read pipeline (registered)
    // Breaks combinational path: empty → rd_en → data decode
    // ========================================
    reg        cmd_fifo_rd_en_r;
    reg [22:0] cmd_fifo_data_r;

    // Assert rd_en: only in S_IDLE to read it_info (1 entry per TU)
    assign cmd_fifo_rd_en = (state == S_IDLE && !cmd_fifo_empty && !cmd_fifo_rd_en_r);

    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n) begin
            cmd_fifo_rd_en_r <= 1'b0;
            cmd_fifo_data_r  <= 23'd0;
        end else begin
            cmd_fifo_rd_en_r <= cmd_fifo_rd_en;
            if (cmd_fifo_rd_en && !cmd_fifo_empty)
                cmd_fifo_data_r <= cmd_fifo_rdata;
        end
    end

    // ========================================
    // Command FIFO decode (from registered pipeline)
    // ========================================
    // total_points_next: combinational, used to avoid NBA stale-read bug
    // when latching clr_limit_r / last_out_cnt in the same cycle as total_points
    wire [12:0] total_points_next = cmd_fifo_data_r[6:0] * cmd_fifo_data_r[13:7];
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n) begin
            tu_width         <= 7'd0;
            tu_height        <= 7'd0;
            tr_type_hor      <= 2'd0;
            tr_type_ver      <= 2'd0;
            lfnst_tr_set_idx <= 2'd0;
            lfnst_idx        <= 2'd0;
            total_points     <= 13'd0;
        end else if (cmd_fifo_rd_en_r && state == S_IDLE) begin
            tu_width         <= cmd_fifo_data_r[6:0];
            tu_height        <= cmd_fifo_data_r[13:7];
            tr_type_hor      <= cmd_fifo_data_r[15:14];
            tr_type_ver      <= cmd_fifo_data_r[17:16];
            lfnst_tr_set_idx <= cmd_fifo_data_r[19:18];
            lfnst_idx        <= cmd_fifo_data_r[21:20];
            total_points     <= total_points_next;
        end
    end

    // ========================================
    // Load end detection (from input_fifo last flag)
    // ========================================
    reg input_last_detected;
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            input_last_detected <= 1'b0;
        else if (state == S_IDLE)
            input_last_detected <= 1'b0;
        // last=1 in input_fifo[28]: final entry of current TU
        else if (state == S_LOAD && input_fifo_rd_en && !input_fifo_empty && input_fifo_rdata[28])
            input_last_detected <= 1'b1;
    end

    // LFNST start: same condition, using registered flag
    wire lfnst_start = (state == S_LOAD && input_last_detected && lfnst_idx != 2'd0);

    // ========================================
    // Input FIFO read (FWFT: data valid when !empty)
    // Stop immediately after the end marker is observed.  The state machine
    // leaves S_LOAD one cycle later, so this prevents the next TU's first data
    // word from being consumed by the current TU.
    // ========================================
    wire load_accepting = (state == S_LOAD) && !clearing && !input_last_detected;
    assign core_ready = load_accepting;

    wire load_fifo_read = load_accepting && !input_fifo_empty;
    assign input_fifo_rd_en = load_fifo_read;

    // Load pipeline: register FIFO output to break critical path to in_mem
    wire load_fifo_valid = load_fifo_read && !input_fifo_empty;
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n) begin
            load_valid_r <= 1'b0;
            load_last_r  <= 1'b0;
            load_addr_r  <= 12'd0;
            load_data_r  <= 16'd0;
        end else begin
            load_valid_r <= load_fifo_valid;
            load_last_r  <= input_fifo_rdata[28];
            load_addr_r  <= input_fifo_rdata[27:16];
            load_data_r  <= input_fifo_rdata[15:0];
        end
    end

    // ========================================
    // Input buffer (async read, sync write — same as its_top)
    // ========================================
    integer i;
    initial begin
        for (i = 0; i < 4096; i = i + 1)
            tp_buf[i] = 16'sd0;
        for (i = 0; i < 4096; i = i + 1)
            out_mem[i] = 10'sd0;
        for (i = 0; i < 48; i = i + 1)
            lfnst_out_buf[i] = 16'sd0;
        clearing = 1'b0;
        clr_cnt  = 12'd0;
    end

    // in_mem write port logic
    always @(posedge clk_core) begin
        if (clearing) begin
            in_mem_wr_en   <= 1'b1;
            in_mem_wr_addr <= clr_cnt;
            in_mem_wr_data <= 16'sd0;
        end else if (state == S_LOAD && load_valid_r && !load_last_r) begin
            in_mem_wr_en   <= 1'b1;
            in_mem_wr_addr <= load_addr_r;
            in_mem_wr_data <= load_data_r;
        end else begin
            in_mem_wr_en   <= 1'b0;
            in_mem_wr_addr <= 12'd0;
            in_mem_wr_data <= 16'd0;
        end
    end

    // LFNST overlay buffer write (direct, no pipeline, small buffer, low fanout)
    // No clearing is needed: the LFNST module writes all active entries before use.
    always @(posedge clk_core) begin
        if (lfnst_data_out_wr_en) begin
            lfnst_out_buf[lfnst_wr_addr] <= lfnst_data_out;
        end
    end

    // Input write counter (registered)
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n) begin
            in_wr_cnt <= 12'd0;
        end else if (cmd_fifo_rd_en_r) begin
            in_wr_cnt <= 12'd0;
        end else if (state == S_LOAD && load_valid_r && !load_last_r) begin
            in_wr_cnt <= in_wr_cnt + 12'd1;
        end
    end

    // ========================================
    // ROM Instantiation (shared: row/col engines are strictly sequential)
    // ========================================
    wire [13:0] shared_eng_rom_addr;
    wire [15:0] shared_rom_coeff;

    its_rom u_shared_rom (
        .clk   (clk_core),
        .addr  (shared_eng_rom_addr),
        .coeff (shared_rom_coeff)
    );

    its_lfnst_rom u_lfnst_rom (
        .clk   (clk_core),
        .addr  (lfnst_rom_addr),
        .coeff (lfnst_rom_coeff)
    );

    // ========================================
    // LFNST Module
    // ========================================
    its_lfnst u_lfnst (
        .clk             (clk_core),
        .rst_n           (rst_n),
        .start           (lfnst_start),
        .lfnst_idx       (lfnst_idx),
        .lfnst_tr_set_idx(lfnst_tr_set_idx),
        .tu_width        (tu_width),
        .tu_height       (tu_height),
        .data_in         (in_mem_dout_r),
        .data_in_vld     (lfnst_data_in_vld_d),
        .data_in_req     (lfnst_data_in_req),
        .data_out        (lfnst_data_out),
        .data_out_vld    (lfnst_data_out_vld),
        .data_out_wr_en  (lfnst_data_out_wr_en),
        .data_out_req    (1'b1),
        .done            (lfnst_done),
        .rom_addr        (lfnst_rom_addr),
        .rom_coeff       (lfnst_rom_coeff)
    );

    // LFNST read address
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            lfnst_rd_addr <= 6'd0;
        else if (state == S_LFNST && lfnst_data_in_req)
            lfnst_rd_addr <= lfnst_rd_addr + 6'd1;
        else if (state != S_LFNST)
            lfnst_rd_addr <= 6'd0;
    end

    // LFNST overlay buffer write — lfnst_out_buf is used directly,
    // no in_mem write-back needed in core_500 (overlay handles reads).

    // LFNST write-back address counter (direct, no pipeline)
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            lfnst_wr_addr <= 6'd0;
        else if (lfnst_data_out_wr_en)
            lfnst_wr_addr <= lfnst_wr_addr + 6'd1;
        else if (state != S_LFNST)
            lfnst_wr_addr <= 6'd0;
    end

    // ========================================
    // Memory clear control
    // ========================================
    // Delay clearing start by 1 cycle so clr_limit_r latches from registered
    // total_points (not combinational total_points_next), avoiding multiplier
    // on critical path. total_points is stable 1 cycle after cmd_fifo_rd_en_r.
    reg clearing_start;
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            clearing_start <= 1'b0;
        else if (cmd_fifo_rd_en_r && state == S_IDLE)
            clearing_start <= 1'b1;
        else
            clearing_start <= 1'b0;
    end

    reg [11:0] clr_limit_r;
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            clr_limit_r <= 12'd0;
        else if (clearing_start)
            clr_limit_r <= total_points[11:0] - 12'd1;
    end

    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n) begin
            clearing <= 1'b0;
            clr_cnt  <= 12'd0;
        end else if (clearing_start) begin
            clearing <= 1'b1;
            clr_cnt  <= 12'd0;
        end else if (clearing) begin
            if (clr_cnt == clr_limit_r)
                clearing <= 1'b0;
            else
                clr_cnt <= clr_cnt + 12'd1;
        end
    end

    // ========================================
    // Main state machine
    // ========================================
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else case (state)
            S_IDLE: begin
                if (cmd_fifo_rd_en_r) state <= S_CLEAR;
            end
            S_CLEAR: begin
                if (clr_cnt == clr_limit_r) state <= S_LOAD;
            end
            S_LOAD: begin
                if (input_last_detected) begin
                    if (lfnst_idx != 2'd0)
                        state <= S_LFNST;
                    else
                        state <= S_ROW_START;
                end
            end
            S_LFNST: begin
                if (lfnst_done) state <= S_ROW_START;
            end
            S_ROW_START: begin
                state <= S_ROW_RUN;
            end
            S_ROW_RUN: begin
                if (row_done) begin
                    if (row_idx + 7'd1 >= tu_width[6:0])
                        state <= S_COL_START;
                    else
                        state <= S_ROW_START;
                end
            end
            S_COL_START: begin
                state <= S_COL_RUN;
            end
            S_COL_RUN: begin
                if (col_done) begin
                    if (col_idx + 7'd1 >= tu_height[6:0]) begin
                        state <= S_OUT;
                    end else
                        state <= S_COL_START;
                end
            end
            S_OUT: begin
                if (total_points == 0)
                    state <= S_DONE;
                else if (out_done)
                    state <= S_DONE;
            end
            S_DONE: state <= S_IDLE;
            default: state <= S_IDLE;
        endcase
    end

    // ========================================
    // Row/Column loop counters
    // ========================================
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n) begin
            row_idx       <= 7'd0;
            row_base_addr <= 12'd0;
        end else if (state == S_LFNST && lfnst_done) begin
            row_idx       <= 7'd0;
            row_base_addr <= 12'd0;
        end else if (state == S_LOAD && input_last_detected && lfnst_idx == 2'd0) begin
            row_idx       <= 7'd0;
            row_base_addr <= 12'd0;
        end else if (state == S_ROW_RUN && row_done && row_idx + 7'd1 < tu_width[6:0]) begin
            row_idx       <= row_idx + 7'd1;
            row_base_addr <= row_base_addr + 12'd1;
        end else if (state != S_ROW_START && state != S_ROW_RUN && state != S_LFNST) begin
            row_idx       <= 7'd0;
            row_base_addr <= 12'd0;
        end
    end

    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n) begin
            col_idx     <= 7'd0;
            tp_rd_base  <= 12'd0;
        end else if (state == S_ROW_RUN && row_done && row_idx + 7'd1 >= tu_width[6:0]) begin
            col_idx     <= 7'd0;
            tp_rd_base  <= 12'd0;
        end else if (state == S_COL_RUN && col_done && col_idx + 7'd1 < tu_height[6:0]) begin
            col_idx    <= col_idx + 7'd1;
            tp_rd_base <= tp_rd_base + {5'd0, tu_width[6:0]};
        end else if (state != S_COL_START && state != S_COL_RUN) begin
            col_idx     <= 7'd0;
            tp_rd_base  <= 12'd0;
        end
    end

    // ========================================
    // ver_step — row-within-column counter for vertical phase overlay
    // ========================================
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            ver_step <= 7'd0;
        else if (state == S_ROW_START)
            ver_step <= 7'd0;
        else if (state == S_ROW_RUN && row_data_in_req)
            ver_step <= ver_step + 7'd1;
        else if (state != S_ROW_RUN)
            ver_step <= 7'd0;
    end

    // ========================================
    // Column Engine Input Pipeline
    // ========================================
    // Pipeline register: break tp_buf DistRAM to engine line_buf path.
    reg signed [15:0] tp_buf_rd_data;
    always @(posedge clk_core) begin
        tp_buf_rd_data <= tp_buf[tp_rd_base + col_eng_rd_addr];
    end

    // Delay data_in_vld to align with pipelined tp_buf_rd_data.
    reg col_data_in_vld_d;
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            col_data_in_vld_d <= 1'b0;
        else
            col_data_in_vld_d <= (state == S_COL_RUN);
    end

    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            col_eng_rd_addr <= 12'd0;
        else if (state == S_COL_START)
            col_eng_rd_addr <= 12'd0;
        else if (state == S_COL_RUN && col_data_in_req)
            col_eng_rd_addr <= col_eng_rd_addr + 12'd1;
        else if (state != S_COL_RUN)
            col_eng_rd_addr <= 12'd0;
    end

    // ========================================
    // Shared Transform Engine
    // ========================================
    // Row and column transforms are serialized, so one transform engine is reused.
    wire        is_row_phase = (state == S_ROW_START) || (state == S_ROW_RUN);
    wire        is_col_phase_eng = (state == S_COL_START) || (state == S_COL_RUN);

    wire [15:0] shared_data_in = is_row_phase ? row_in_mem_data : tp_buf_rd_data;
    wire        shared_data_in_vld = is_row_phase ? row_data_in_vld_r : col_data_in_vld_d;
    wire [1:0]  shared_tr_type = is_row_phase ? row_tr_type : col_tr_type;
    wire [6:0]  shared_size = is_row_phase ? tu_height[6:0] : tu_width[6:0];

    wire        shared_done;
    wire        shared_data_in_req;
    wire [15:0] shared_eng_out_data;
    wire        shared_eng_out_vld;

    its_transform_engine u_shared_engine (
        .clk        (clk_core),
        .rst_n      (rst_n),
        .start      (is_row_phase ? (state == S_ROW_START) : (state == S_COL_START)),
        .tr_type    (shared_tr_type),
        .size       (shared_size),
        .data_in    (shared_data_in),
        .data_in_vld(shared_data_in_vld),
        .data_in_req(shared_data_in_req),
        .rom_addr   (shared_eng_rom_addr),
        .rom_coeff  (shared_rom_coeff),
        .data_out   (shared_eng_out_data),
        .data_out_vld(shared_eng_out_vld),
        .data_out_req(1'b1),
        .done       (shared_done)
    );

    assign row_out_data = shared_eng_out_data;
    assign row_out_vld = is_row_phase ? shared_eng_out_vld : 1'b0;
    assign row_done = is_row_phase ? shared_done : 1'b0;
    assign col_out_data = shared_eng_out_data;
    assign col_out_vld = is_col_phase_eng ? shared_eng_out_vld : 1'b0;
    assign col_done = is_col_phase_eng ? shared_done : 1'b0;

    assign row_rom_addr = shared_eng_rom_addr;
    assign col_rom_addr = shared_eng_rom_addr;

    assign row_data_in_req = is_row_phase ? shared_data_in_req : 1'b0;
    assign col_data_in_req = is_col_phase_eng ? shared_data_in_req : 1'b0;

    // Row engine address counter — column-major read from in_mem
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            row_in_mem_addr <= 12'd0;
        else if (state == S_ROW_START)
            row_in_mem_addr <= {5'd0, row_idx[6:0]};
        else if (state == S_ROW_RUN && row_data_in_req)
            row_in_mem_addr <= row_in_mem_addr + {5'd0, tu_width[6:0]};
        else if (state != S_ROW_RUN)
            row_in_mem_addr <= 12'd0;
    end

    // ========================================
    // Transpose Buffer Write
    // ========================================
    always @(posedge clk_core) begin
        if (state == S_ROW_RUN && row_out_vld)
            tp_buf[tp_wr_cnt] <= row_out_data;
    end

    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n) begin
            tp_wr_cnt <= 12'd0;
        end else if (cmd_fifo_rd_en_r) begin
            tp_wr_cnt <= 12'd0;
        end else if (state == S_ROW_START) begin
            tp_wr_cnt <= {5'd0, row_idx[6:0]};
        end else if (state == S_ROW_RUN && row_out_vld) begin
            tp_wr_cnt <= tp_wr_cnt + {5'd0, tu_width[6:0]};
        end
    end

    // ========================================
    // Output Control — zero-bubble pipeline (V3.1)
    // Stage 0: out_mem read (can overlap with Stage 2 FIFO write)
    // Stage 1: data_out_r + out_valid_pipe (holds under backpressure)
    // Stage 2: FIFO write (write_fire = valid && !almost_full)
    //
    // out_cnt = NEXT address to read from out_mem.
    // Advances on out_read_en.  Continuous output at 1 beat/cycle
    // when FIFO has space (no-bubble, fire-fire-fire-fire).
    // almost_full reserves 1 slot for the registered wr_en path.
    // ========================================

    // Use almost_full to reserve 1 slot for registered wr_en
    wire write_fire  = out_valid_pipe && !output_fifo_almost_full;
    // Can read next beat when: pipeline empty OR current beat is writing out
    wire out_pipe_ready = !out_valid_pipe || write_fire;
    wire out_read_en = (state == S_OUT && out_pipe_ready && !out_pipe_flush);

    // Stage 1: capture out_mem read using out_cnt as base
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            data_out_r <= 40'd0;
        else if (out_read_en)
            data_out_r <= {out_mem[out_cnt+12'd3], out_mem[out_cnt+12'd2],
                           out_mem[out_cnt+12'd1], out_mem[out_cnt]};
    end

    // Stage 1 valid: set on read; stay set when read+write overlap;
    // clear only when write_fire without new read
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            out_valid_pipe <= 1'b0;
        else if (out_read_en && write_fire)
            out_valid_pipe <= 1'b1;   // continuous: old written, new loaded
        else if (out_read_en)
            out_valid_pipe <= 1'b1;   // first beat after idle
        else if (write_fire)
            out_valid_pipe <= 1'b0;   // last beat written, no more to read
        // else: hold (backpressure)
    end

    // Stage 2: FIFO write
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n) begin
            output_fifo_wdata <= 40'd0;
            output_fifo_wr_en <= 1'b0;
        end else begin
            output_fifo_wdata <= data_out_r;
            output_fifo_wr_en <= write_fire;
        end
    end

    // out_cnt: NEXT address to read. Advances on read_en.
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            out_cnt <= 12'd0;
        else if (state != S_OUT)
            out_cnt <= 12'd0;
        else if (out_read_en)
            out_cnt <= out_cnt + 12'd4;
    end

    // last_out_addr: the LAST address to read (= total_points - 4)
    reg [11:0] last_out_addr;
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            last_out_addr <= 12'd0;
        else if (state == S_COL_RUN && col_done && col_idx + 7'd1 >= tu_height[6:0])
            last_out_addr <= total_points[11:0] - 12'd4;
    end

    // out_pipe_flush: set when last beat has been READ from out_mem
    wire last_beat_read = (state == S_OUT && out_read_en && out_cnt == last_out_addr);
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            out_pipe_flush <= 1'b0;
        else if (state != S_OUT)
            out_pipe_flush <= 1'b0;
        else if (last_beat_read || out_pipe_flush)
            out_pipe_flush <= 1'b1;
    end

    // out_done: all beats written, pipeline idle, no in-flight FIFO write
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            out_done <= 1'b0;
        else if (state != S_OUT)
            out_done <= 1'b0;
        else if (out_pipe_flush && !out_valid_pipe && !write_fire)
            out_done <= 1'b1;
    end

    // out_mem write port
    reg [11:0] out_mem_wr_addr;
    always @(posedge clk_core) begin
        if (state == S_COL_RUN && col_out_vld)
            out_mem[out_mem_wr_addr] <= col_out_data[9:0];
    end

    always @(posedge clk_core) begin
        if (!rst_n || cmd_fifo_rd_en_r)
            out_mem_wr_addr <= 12'd0;
        else if (state == S_COL_START)
            out_mem_wr_addr <= tp_rd_base;
        else if (state == S_COL_RUN && col_out_vld)
            out_mem_wr_addr <= out_mem_wr_addr + 12'd1;
    end

    // out_row_cnt / out_col_cnt always block removed — debug-only

    // Done pulse
    always @(posedge clk_core or negedge rst_n) begin
        if (!rst_n)
            core_done <= 1'b0;
        else
            core_done <= (state == S_DONE);
    end

endmodule
