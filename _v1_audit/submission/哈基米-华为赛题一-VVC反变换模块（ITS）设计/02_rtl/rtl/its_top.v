// ===================================================================
// ITS Top Level Module — final submission entry (v7.0)
// 22-bit it_info interface per competition spec.
//
// Instantiates its_top_500_singleclk — verified at 1539/1539 PASS,
// 500MHz UltraScale+ timing closed (see doc/core_500mhz_timing_report.md).
// ===================================================================

module its_top (
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

    its_top_500_singleclk u_final (
        .clk             (clk),
        .rst_n           (rst_n),
        .it_info         (it_info),
        .it_info_vld     (it_info_vld),
        .it_data_in      (it_data_in),
        .it_data_addr    (it_data_addr),
        .it_data_in_vld  (it_data_in_vld),
        .it_data_end     (it_data_end),
        .it_data_in_req  (it_data_in_req),
        .it_data_out     (it_data_out),
        .it_data_out_vld (it_data_out_vld),
        .it_data_out_req (it_data_out_req),
        .it_done         (it_done)
    );

endmodule
