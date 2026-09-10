// Reset synchronizer: async assert, sync deassert
// Uses a chain of STAGES flip-flops to synchronize the deassert edge.

module rst_sync #(
    parameter STAGES = 3
) (
    input  clk,
    input  async_rst_n,   // active-low async reset
    output sync_rst_n     // active-low synchronized reset
);

    reg [STAGES-1:0] rst_pipe;

    always @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n)
            rst_pipe <= {STAGES{1'b0}};
        else
            rst_pipe <= {rst_pipe[STAGES-2:0], 1'b1};
    end

    assign sync_rst_n = rst_pipe[STAGES-1];

endmodule
