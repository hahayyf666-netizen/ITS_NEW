// One physical input-cache bank.  Data and validity are separate one-write
// memories so a scrub can clear validity without touching stale data.  There
// is exactly one data write and one valid write command per bank per edge.
module its_input_cache_bank #(
    parameter integer DATA_W = 16,
    parameter integer DEPTH  = 1024,
    parameter integer ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input  logic                  clk,
    input  logic                  data_wr_en,
    input  logic [ADDR_W-1:0]     data_wr_addr,
    input  logic [DATA_W-1:0]     data_wr_data,
    input  logic                  valid_wr_en,
    input  logic [ADDR_W-1:0]     valid_wr_addr,
    input  logic                  valid_wr_data,
    input  logic [ADDR_W-1:0]     rd_addr,
    output logic [DATA_W-1:0]     rd_data,
    output logic                  rd_valid
);
    (* ram_style = "auto" *) logic [DATA_W-1:0] data_mem [0:DEPTH-1];
    (* ram_style = "auto" *) logic              valid_mem[0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (data_wr_en)
            data_mem[data_wr_addr] <= data_wr_data;
        if (valid_wr_en)
            valid_mem[valid_wr_addr] <= valid_wr_data;
    end

    always_comb begin
        rd_data  = data_mem[rd_addr];
        rd_valid = valid_mem[rd_addr];
    end
endmodule
