// Gray-code asynchronous FIFO
// Parameterized depth (2^ADDR_WIDTH) and data width.
// Standard 2-FF synchronizer for pointer crossing.
// Provides wr_count for write-domain backpressure.
//
// Key design choices:
//   - Registered full flag (stable, independent of wr_en)
//   - Combinational empty flag (standard for async FIFO)
//   - FWFT read output
//   - wr_fire = wr_en & ~full (write only when not full)

module async_fifo #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 4   // depth = 2^ADDR_WIDTH
) (
    // Write port
    input  wire                   wr_clk,
    input  wire                   wr_rst_n,
    input  wire                   wr_en,
    input  wire [DATA_WIDTH-1:0]  wr_data,
    output reg                    full,
    output wire                   almost_full,
    output wire  [ADDR_WIDTH:0]   wr_count,    // occupancy seen from write domain
    // Read port
    input  wire                   rd_clk,
    input  wire                   rd_rst_n,
    input  wire                   rd_en,
    output wire [DATA_WIDTH-1:0]  rd_data,
    output wire                   empty
);

    localparam DEPTH = 1 << ADDR_WIDTH;

    // ---- Storage ----
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // ---- Gray-code conversion helpers ----
    function [ADDR_WIDTH:0] bin2gray;
        input [ADDR_WIDTH:0] bin;
        bin2gray = bin ^ (bin >> 1);
    endfunction

    function [ADDR_WIDTH:0] gray2bin;
        input [ADDR_WIDTH:0] gray;
        integer i;
        begin
            gray2bin[ADDR_WIDTH] = gray[ADDR_WIDTH];
            for (i = ADDR_WIDTH - 1; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ gray[i];
        end
    endfunction

    // ---- All register declarations ----
    reg [ADDR_WIDTH:0] wr_ptr_bin;
    reg [ADDR_WIDTH:0] wr_ptr_gray;
    reg [ADDR_WIDTH:0] rd_ptr_gray_sync1, rd_ptr_gray_sync2;
    reg [ADDR_WIDTH:0] rd_ptr_bin;
    reg [ADDR_WIDTH:0] rd_ptr_gray;
    reg [ADDR_WIDTH:0] wr_ptr_gray_sync1, wr_ptr_gray_sync2;

    // Simulation initialization (synthesis will use reset)
    initial begin
        wr_ptr_bin       = {(ADDR_WIDTH+1){1'b0}};
        wr_ptr_gray      = {(ADDR_WIDTH+1){1'b0}};
        rd_ptr_gray_sync1 = {(ADDR_WIDTH+1){1'b0}};
        rd_ptr_gray_sync2 = {(ADDR_WIDTH+1){1'b0}};
        rd_ptr_bin       = {(ADDR_WIDTH+1){1'b0}};
        rd_ptr_gray      = {(ADDR_WIDTH+1){1'b0}};
        wr_ptr_gray_sync1 = {(ADDR_WIDTH+1){1'b0}};
        wr_ptr_gray_sync2 = {(ADDR_WIDTH+1){1'b0}};
        full             = 1'b0;
    end

    // ================================================================
    // Write domain
    // ================================================================

    // Write fire: only write when enabled AND not full
    wire wr_fire = wr_en & ~full;

    // Next pointer values: advance ONLY on actual write (gated by wr_fire)
    // If wr_fire=0 (full or no wr_en), pointer stays → full_next stays correct
    wire [ADDR_WIDTH:0] wr_ptr_bin_next  = wr_ptr_bin + {{ADDR_WIDTH{1'b0}}, wr_fire};
    wire [ADDR_WIDTH:0] wr_ptr_gray_next = bin2gray(wr_ptr_bin_next);

    // Pointer update
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr_bin  <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
        end else if (wr_fire) begin
            wr_ptr_bin  <= wr_ptr_bin_next;
            wr_ptr_gray <= wr_ptr_gray_next;
        end
    end

    // Write data
    always @(posedge wr_clk) begin
        if (wr_fire)
            mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= wr_data;
    end

    // Synchronize rd_ptr_gray into wr_clk domain
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_ptr_gray_sync1 <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray_sync2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            rd_ptr_gray_sync1 <= rd_ptr_gray;
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end
    end

    // Full: registered, stable independent of wr_en
    // Condition: next write Gray == read Gray with inverted top 2 bits
    wire full_next = (wr_ptr_gray_next == {~rd_ptr_gray_sync2[ADDR_WIDTH:ADDR_WIDTH-1],
                                            rd_ptr_gray_sync2[ADDR_WIDTH-2:0]});

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n)
            full <= 1'b0;
        else
            full <= full_next;
    end

    // Almost full: 2 slots remaining
    wire [ADDR_WIDTH:0] wr_ptr_bin_plus2  = wr_ptr_bin + 2;
    wire [ADDR_WIDTH:0] wr_ptr_gray_plus2 = bin2gray(wr_ptr_bin_plus2);
    assign almost_full = (wr_ptr_gray_plus2 == {~rd_ptr_gray_sync2[ADDR_WIDTH:ADDR_WIDTH-1],
                                                 rd_ptr_gray_sync2[ADDR_WIDTH-2:0]});

    // Occupancy count in write domain (2-3 cycle stale, fine for backpressure)
    wire [ADDR_WIDTH:0] rd_ptr_bin_in_wr = gray2bin(rd_ptr_gray_sync2);
    assign wr_count = wr_ptr_bin - rd_ptr_bin_in_wr;

    // ================================================================
    // Read domain
    // ================================================================

    // Read fire: only read when enabled AND not empty
    wire rd_fire = rd_en & ~empty;

    wire [ADDR_WIDTH:0] rd_ptr_bin_next  = rd_ptr_bin + {{ADDR_WIDTH{1'b0}}, rd_fire};
    wire [ADDR_WIDTH:0] rd_ptr_gray_next = bin2gray(rd_ptr_bin_next);

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr_bin  <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
        end else if (rd_fire) begin
            rd_ptr_bin  <= rd_ptr_bin_next;
            rd_ptr_gray <= rd_ptr_gray_next;
        end
    end

    // FWFT read
    assign rd_data = mem[rd_ptr_bin[ADDR_WIDTH-1:0]];

    // Synchronize wr_ptr_gray into rd_clk domain
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_ptr_gray_sync1 <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray_sync2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end

    // Empty: combinational, standard for async FIFO
    assign empty = (rd_ptr_gray == wr_ptr_gray_sync2);

endmodule
