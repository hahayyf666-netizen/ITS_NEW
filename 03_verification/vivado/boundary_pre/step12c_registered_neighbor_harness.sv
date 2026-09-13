`timescale 1ns/1ps

// Verification-only Boundary-PRE harness.
//
// The DUT is intentionally not edited.  Every DUT input is launched by a
// registered neighbor and every DUT output is captured by a registered
// neighbor.  This gives implementation a physical context in which the
// input-port -> first-command-FF hold result can be separated from the
// actual registered-neighbor -> DUT timing paths.
module step12c_registered_neighbor_harness (
    input  wire                         clk
    // All data/control source registers are internal registered neighbors.
    // No data output ports are exposed; sink D pins are the endpoints.
);

    wire clk_ibuf;
    wire clk_g;
    IBUF u_boundary_ibuf (.I(clk), .O(clk_ibuf));
    BUFG u_boundary_bufg (.I(clk_ibuf), .O(clk_g));

    (* DONT_TOUCH = "yes" *) reg [21:0] src_it_info_q;
    (* DONT_TOUCH = "yes" *) reg src_it_info_vld_q;
    (* DONT_TOUCH = "yes" *) reg signed [15:0] src_it_data_in_q;
    (* DONT_TOUCH = "yes" *) reg [11:0] src_it_data_addr_q;
    (* DONT_TOUCH = "yes" *) reg src_it_data_in_vld_q;
    (* DONT_TOUCH = "yes" *) reg src_it_data_end_q;
    (* DONT_TOUCH = "yes" *) reg src_it_data_out_req_q;
    (* DONT_TOUCH = "yes", KEEP = "yes" *) reg [31:0] source_lfsr_q;

    wire dut_it_data_in_req;
    wire [39:0] dut_it_data_out;
    wire dut_it_data_out_vld;
    wire dut_it_done;
    wire dut_protocol_error;
    wire dut_debug_stage16_valid;
    wire [5:0] dut_debug_stage16_row;
    wire [5:0] dut_debug_stage16_col;
    wire signed [15:0] dut_debug_stage16_data;

    (* DONT_TOUCH = "yes", KEEP_HIERARCHY = "yes" *)
    step12b_dct2_64_wrapper u_dut (
        .clk                    (clk_g),
        .rst_n                  (1'b1),
        .it_info                (src_it_info_q),
        .it_info_vld            (src_it_info_vld_q),
        .it_data_in             (src_it_data_in_q),
        .it_data_addr           (src_it_data_addr_q),
        .it_data_in_vld         (src_it_data_in_vld_q),
        .it_data_end            (src_it_data_end_q),
        .it_data_in_req         (dut_it_data_in_req),
        .it_data_out_req        (src_it_data_out_req_q),
        .it_data_out            (dut_it_data_out),
        .it_data_out_vld        (dut_it_data_out_vld),
        .it_done                (dut_it_done),
        .protocol_error         (dut_protocol_error),
        .debug_stage16_valid    (dut_debug_stage16_valid),
        .debug_stage16_row      (dut_debug_stage16_row),
        .debug_stage16_col      (dut_debug_stage16_col),
        .debug_stage16_data    (dut_debug_stage16_data)
    );

    // Output registers model the downstream registered neighbor. They are
    // retained internally and are not exposed as package ports in this PRE.
    (* DONT_TOUCH = "yes" *) reg sink_it_data_in_req_q;
    (* DONT_TOUCH = "yes" *) reg [39:0] sink_it_data_out_q;
    (* DONT_TOUCH = "yes" *) reg sink_it_data_out_vld_q;
    (* DONT_TOUCH = "yes" *) reg sink_it_done_q;
    (* DONT_TOUCH = "yes" *) reg sink_protocol_error_q;
    (* DONT_TOUCH = "yes" *) reg sink_debug_stage16_valid_q;
    (* DONT_TOUCH = "yes" *) reg [5:0] sink_debug_stage16_row_q;
    (* DONT_TOUCH = "yes" *) reg [5:0] sink_debug_stage16_col_q;
    (* DONT_TOUCH = "yes" *) reg signed [15:0] sink_debug_stage16_data_q;

    // Keep the sink bank observable inside the implementation without making
    // sink-Q -> package-port timing part of this Boundary-PRE experiment.
    (* DONT_TOUCH = "yes", KEEP = "yes" *) reg [7:0] sink_observation_q;

    always @(posedge clk_g) begin
        source_lfsr_q <= {source_lfsr_q[30:0],
                          source_lfsr_q[31] ^ source_lfsr_q[21] ^
                          source_lfsr_q[1] ^ source_lfsr_q[0]};
        src_it_info_q <= source_lfsr_q[21:0];
        src_it_info_vld_q <= source_lfsr_q[0];
        src_it_data_in_q <= source_lfsr_q[15:0];
        src_it_data_addr_q <= source_lfsr_q[11:0];
        src_it_data_in_vld_q <= source_lfsr_q[1];
        src_it_data_end_q <= 1'b0;
        src_it_data_out_req_q <= 1'b1;
        sink_it_data_in_req_q <= dut_it_data_in_req;
        sink_it_data_out_q <= dut_it_data_out;
        sink_it_data_out_vld_q <= dut_it_data_out_vld;
        sink_it_done_q <= dut_it_done;
        sink_protocol_error_q <= dut_protocol_error;
        sink_debug_stage16_valid_q <= dut_debug_stage16_valid;
        sink_debug_stage16_row_q <= dut_debug_stage16_row;
        sink_debug_stage16_col_q <= dut_debug_stage16_col;
        sink_debug_stage16_data_q <= dut_debug_stage16_data;
        sink_observation_q <= {
            dut_it_data_in_req,
            dut_it_data_out_vld,
            dut_it_done,
            dut_protocol_error,
            dut_debug_stage16_valid,
            source_lfsr_q[2],
            dut_debug_stage16_row[0],
            dut_debug_stage16_col[0]
        };
    end

endmodule
