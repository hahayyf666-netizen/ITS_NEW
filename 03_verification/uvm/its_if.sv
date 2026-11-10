// D3 UVM interface for the VVC ITS inverse-transform DUT.
//
// The DUT is unified_its_wrapper with FINAL_SATURATE=1, which is what
// its_unified_submission_top instantiates; using the wrapper directly keeps
// protocol_error observable (the competition-facing top hides it).
//
// Signals are driven on the falling edge and sampled on the rising edge, the
// same discipline the existing directed testbenches use.

`ifndef ITS_IF_SV
`define ITS_IF_SV

interface its_if (input logic clk);
    logic        rst_n          = 1'b0;
    logic [21:0] it_info        = '0;
    logic        it_info_vld    = 1'b0;
    logic signed [15:0] it_data_in  = '0;
    logic [11:0] it_data_addr   = '0;
    logic        it_data_in_vld = 1'b0;
    logic        it_data_end    = 1'b0;
    logic        it_data_in_req;
    logic        it_data_out_req = 1'b0;
    logic [39:0] it_data_out;
    logic        it_data_out_vld;
    logic        it_done;
    logic        protocol_error;

    task automatic drive_idle();
        rst_n          = 1'b0;
        it_info        = '0;
        it_info_vld    = 1'b0;
        it_data_in     = '0;
        it_data_addr   = '0;
        it_data_in_vld = 1'b0;
        it_data_end    = 1'b0;
        it_data_out_req = 1'b0;
    endtask
endinterface

`endif