// FWFT FIFO register slice
// Breaks combinational path from FIFO rd_ptr → FIFO RAM → consumer.
// Inserts 1 cycle of latency but maintains FWFT semantics:
//   - Data is always available (registered) when not empty
//   - Consumer reads registered data; FIFO advances in background
//   - No data loss: every FIFO entry consumed exactly once
//   - core_empty holds 0 when valid data is present; consumer not reading
//     cannot clear the valid data.
//
// core_ready: must be HIGH when consumer can accept data.
//   Used to gate proactive fill — prevents consuming FIFO data
//   when consumer is busy (e.g. during memory clearing).
//   Tie to 1'b1 if not needed.

module fifo_fwft_reg_slice #(
    parameter DATA_WIDTH = 16
) (
    input  wire                   clk,
    input  wire                   rst_n,
    // FIFO side (combinational FWFT outputs)
    input  wire [DATA_WIDTH-1:0]  fifo_rdata,
    input  wire                   fifo_empty,
    output wire                   fifo_rd_en,
    // Consumer side (registered outputs)
    output reg  [DATA_WIDTH-1:0]  core_rdata,
    output reg                    core_empty,
    input  wire                   core_rd_en,
    // Consumer ready: gate for proactive fill
    input  wire                   core_ready
);

    // Need new data when:
    //   - consumer just read the current data, OR
    //   - slice is empty and consumer is ready
    wire need_fill = core_rd_en | (core_empty & core_ready);

    // Can fill when FIFO has data and we need it
    wire do_fill = need_fill & ~fifo_empty;

    assign fifo_rd_en = do_fill;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            core_rdata <= {DATA_WIDTH{1'b0}};
            core_empty <= 1'b1;
        end else begin
            if (core_rd_en) begin
                // Consumer reads: advance to next data
                if (do_fill) begin
                    core_rdata <= fifo_rdata;
                    core_empty <= 1'b0;
                end else begin
                    core_empty <= 1'b1;
                end
            end else if (do_fill) begin
                // Proactive fill when slice was empty
                core_rdata <= fifo_rdata;
                core_empty <= 1'b0;
            end else begin
                // Hold current data (core_empty unchanged)
                core_empty <= core_empty;
            end
        end
    end

endmodule
