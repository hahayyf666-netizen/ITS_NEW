// Small, inference-friendly single-write-port RAM primitive used by the
// unified engineering wrapper.  The array deliberately has no reset branch:
// resettable ownership/valid state lives outside the memory, while the
// synchronous write and asynchronous read match the prototype's same-edge
// transaction contract.
module its_simple_ram #(
    parameter integer DATA_W = 16,
    parameter integer DEPTH  = 1024,
    parameter integer ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input  logic                  clk,
    input  logic                  wr_en,
    input  logic [ADDR_W-1:0]     wr_addr,
    input  logic [DATA_W-1:0]     wr_data,
    input  logic [ADDR_W-1:0]     rd_addr,
    output logic [DATA_W-1:0]     rd_data
);
    (* ram_style = "auto" *) logic [DATA_W-1:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    always_comb begin
        rd_data = mem[rd_addr];
    end
endmodule
