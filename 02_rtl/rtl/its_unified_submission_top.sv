// Step12F SAT10 competition-facing top.
//
// The legacy its_top.v remains the frozen V3.4 compatibility baseline.  This
// top exposes the supplied 22-bit/40-bit interface while selecting the v2
// SAT10 engineering profile explicitly; it does not rely on the wrapper's
// parameter default.  protocol_error is retained internally for the DUT
// safety contract but is not added to the competition-facing port list.
module its_unified_submission_top (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [21:0] it_info,
    input  logic        it_info_vld,
    input  logic signed [15:0] it_data_in,
    input  logic [11:0] it_data_addr,
    input  logic        it_data_in_vld,
    input  logic        it_data_end,
    output logic        it_data_in_req,
    output logic [39:0] it_data_out,
    output logic        it_data_out_vld,
    input  logic        it_data_out_req,
    output logic        it_done
);
    logic protocol_error_unused;

    unified_its_wrapper #(
        .FINAL_SATURATE(1)
    ) u_unified_wrapper (
        .clk              (clk),
        .rst_n            (rst_n),
        .it_info          (it_info),
        .it_info_vld      (it_info_vld),
        .it_data_in       (it_data_in),
        .it_data_addr     (it_data_addr),
        .it_data_in_vld   (it_data_in_vld),
        .it_data_end      (it_data_end),
        .it_data_in_req   (it_data_in_req),
        .it_data_out_req  (it_data_out_req),
        .it_data_out      (it_data_out),
        .it_data_out_vld  (it_data_out_vld),
        .it_done          (it_done),
        .protocol_error   (protocol_error_unused)
    );
endmodule

