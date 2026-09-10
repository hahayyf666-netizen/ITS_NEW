// 500MHz single-clock submission wrapper.
// Ports match the competition its_top interface exactly; internally the
// proven dual-clock wrapper is driven with the same 500MHz clock on both
// clk_if and clk_core.

module its_top_500_singleclk (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [21:0] it_info,
    input  wire        it_info_vld,
    input  wire [15:0] it_data_in,
    input  wire [11:0] it_data_addr,
    input  wire        it_data_in_vld,
    input  wire        it_data_end,
    output wire        it_data_in_req,
    output wire [39:0] it_data_out,
    output wire        it_data_out_vld,
    input  wire        it_data_out_req,
    output wire        it_done
);

    its_top_500_wrapper u_wrapper (
        .clk_if         (clk),
        .clk_core       (clk),
        .rst_n          (rst_n),
        .it_info        (it_info),
        .it_info_vld    (it_info_vld),
        .it_data_in     (it_data_in),
        .it_data_addr   (it_data_addr),
        .it_data_in_vld (it_data_in_vld),
        .it_data_end    (it_data_end),
        .it_data_in_req (it_data_in_req),
        .it_data_out    (it_data_out),
        .it_data_out_vld(it_data_out_vld),
        .it_data_out_req(it_data_out_req),
        .it_done        (it_done)
    );

endmodule
