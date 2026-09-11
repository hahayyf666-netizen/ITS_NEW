// ===================================================================
// ITS Top Level Module — LEGACY / V3.4 compatibility baseline
// 22-bit it_info interface per competition spec.
//
// This file instantiates the frozen V3.4 single-clock top.  It is not the
// current P4/Step12B integration and must not be used to claim full-core
// 500MHz closure.
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
