// ===================================================================
// ITS MAC Unit - Pipelined Multiply-Accumulate
// Used for matrix-vector multiplication in inverse transforms
// ===================================================================

module its_mac (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,          // Enable
    input  wire        clr,         // Clear accumulator
    input  wire [15:0] a,           // Input coefficient (signed)
    input  wire [15:0] b,           // Transform kernel coefficient (signed)
    output reg signed [39:0] result,  // Accumulated result
    output reg         valid        // Result valid
);

    // Pipeline stage 1: multiply
    reg [31:0] product;
    reg        valid_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            product  <= 32'd0;
            valid_s1 <= 1'b0;
        end else if (en) begin
            product  <= $signed(a) * $signed(b);
            valid_s1 <= 1'b1;
        end else begin
            valid_s1 <= 1'b0;
        end
    end

    // Pipeline stage 2: accumulate
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result <= 40'd0;
            valid  <= 1'b0;
        end else if (clr) begin
            result <= 40'd0;
            valid  <= 1'b0;
        end else if (valid_s1) begin
            result <= $signed(result) + $signed({{8{product[31]}}, product});
            valid  <= 1'b1;
        end else begin
            valid <= 1'b0;
        end
    end

endmodule
