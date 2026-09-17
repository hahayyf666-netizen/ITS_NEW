// Step12F P9-R5E: registered-neighbor integration qualification harness.
//
// The DUT RTL is intentionally frozen.  This harness supplies every logical
// data/protocol input from a live internal source register and captures every
// logical data/protocol output in a live internal sink register.  It is a
// timing-context harness, not a package-I/O top and not a functional DUT
// replacement.  The only top-level ports are clk and rst_n.

module step12f_registered_neighbor_harness (
    input logic clk,
    input logic rst_n
);

    // Use the same registered-neighbor clock topology as the historical
    // Step12C harness.  This is still not package-level signoff: data/source
    // and sink boundaries remain internal, while the clock is given an
    // explicit IBUF/BUFG implementation context for reproducible placement.
    wire clk_ibuf;
    wire clk_g;
    IBUF u_boundary_ibuf (.I(clk), .O(clk_ibuf));
    BUFG u_boundary_bufg (.I(clk_ibuf), .O(clk_g));

    localparam integer EXPECTED_SOURCE_FF_BITS = 54;
    localparam integer EXPECTED_SINK_FF_BITS   = 44;

    // Async assertion and synchronous deassertion preserve the DUT's
    // active-low asynchronous reset contract while giving the internal core
    // a deterministic registered-neighbor release boundary.
    (* ASYNC_REG = "TRUE", DONT_TOUCH = "TRUE", KEEP = "TRUE" *)
    logic [1:0] reset_sync_q;
    logic dut_rst_n;

    always_ff @(posedge clk_g or negedge rst_n) begin
        if (!rst_n)
            reset_sync_q <= 2'b00;
        else
            reset_sync_q <= {reset_sync_q[0], 1'b1};
    end

    assign dut_rst_n = reset_sync_q[1];

    // 54-bit live source boundary:
    // it_info(22) + it_info_vld(1) + it_data_in(16) + it_data_addr(12)
    // + it_data_in_vld(1) + it_data_end(1) + it_data_out_req(1).
    (* DONT_TOUCH = "TRUE", KEEP = "TRUE" *) logic [21:0] src_it_info_q;
    (* DONT_TOUCH = "TRUE", KEEP = "TRUE" *) logic        src_it_info_vld_q;
    (* DONT_TOUCH = "TRUE", KEEP = "TRUE" *) logic signed [15:0] src_it_data_in_q;
    (* DONT_TOUCH = "TRUE", KEEP = "TRUE" *) logic [11:0] src_it_data_addr_q;
    (* DONT_TOUCH = "TRUE", KEEP = "TRUE" *) logic        src_it_data_in_vld_q;
    (* DONT_TOUCH = "TRUE", KEEP = "TRUE" *) logic        src_it_data_end_q;
    (* DONT_TOUCH = "TRUE", KEEP = "TRUE" *) logic        src_it_data_out_req_q;

    // 44-bit live sink boundary:
    // it_data_in_req(1) + it_data_out(40) + it_data_out_vld(1)
    // + it_done(1) + protocol_error(1).
    (* DONT_TOUCH = "TRUE", KEEP = "TRUE" *) logic        sink_it_data_in_req_q;
    (* DONT_TOUCH = "TRUE", KEEP = "TRUE" *) logic [39:0] sink_it_data_out_q;
    (* DONT_TOUCH = "TRUE", KEEP = "TRUE" *) logic        sink_it_data_out_vld_q;
    (* DONT_TOUCH = "TRUE", KEEP = "TRUE" *) logic        sink_it_done_q;
    (* DONT_TOUCH = "TRUE", KEEP = "TRUE" *) logic        sink_protocol_error_q;

    logic [31:0] stimulus_q;

    logic        dut_it_data_in_req;
    logic [39:0] dut_it_data_out;
    logic        dut_it_data_out_vld;
    logic        dut_it_done;
    logic        dut_protocol_error;

    // Source registers have live, non-constant next state.  The generated
    // values are only for keeping the boundary electrically alive; this
    // harness does not claim to be a protocol regression testbench.
    always_ff @(posedge clk_g or negedge rst_n) begin
        if (!rst_n) begin
            stimulus_q             <= 32'h1;
            src_it_info_q          <= 22'h1;
            src_it_info_vld_q      <= 1'b0;
            src_it_data_in_q       <= 16'sd1;
            src_it_data_addr_q     <= 12'h1;
            src_it_data_in_vld_q   <= 1'b0;
            src_it_data_end_q      <= 1'b0;
            src_it_data_out_req_q  <= 1'b1;
        end else begin
            stimulus_q             <= {stimulus_q[30:0],
                                       stimulus_q[31] ^ stimulus_q[21] ^
                                       stimulus_q[1] ^ stimulus_q[0]};
            src_it_info_q          <= src_it_info_q + 22'h000001 +
                                       {21'b0, stimulus_q[0]};
            src_it_info_vld_q      <= ~src_it_info_vld_q;
            src_it_data_in_q       <= src_it_data_in_q + 16'sd3;
            src_it_data_addr_q     <= src_it_data_addr_q + 12'd1;
            src_it_data_in_vld_q   <= ~src_it_data_in_vld_q;
            src_it_data_end_q      <= stimulus_q[3] ^ stimulus_q[7];
            src_it_data_out_req_q  <= ~src_it_data_out_req_q;
        end
    end

    unified_its_wrapper u_dut (
        .clk              (clk_g),
        .rst_n            (dut_rst_n),
        .it_info          (src_it_info_q),
        .it_info_vld      (src_it_info_vld_q),
        .it_data_in       (src_it_data_in_q),
        .it_data_addr     (src_it_data_addr_q),
        .it_data_in_vld   (src_it_data_in_vld_q),
        .it_data_end      (src_it_data_end_q),
        .it_data_in_req   (dut_it_data_in_req),
        .it_data_out_req  (src_it_data_out_req_q),
        .it_data_out      (dut_it_data_out),
        .it_data_out_vld  (dut_it_data_out_vld),
        .it_done          (dut_it_done),
        .protocol_error   (dut_protocol_error)
    );

    // Direct DUT-output-to-sink-register capture.  These registers are kept
    // observable so implementation cannot prune the output timing boundary.
    always_ff @(posedge clk_g or negedge rst_n) begin
        if (!rst_n) begin
            sink_it_data_in_req_q  <= 1'b0;
            sink_it_data_out_q     <= '0;
            sink_it_data_out_vld_q <= 1'b0;
            sink_it_done_q         <= 1'b0;
            sink_protocol_error_q  <= 1'b0;
        end else begin
            sink_it_data_in_req_q  <= dut_it_data_in_req;
            sink_it_data_out_q     <= dut_it_data_out;
            sink_it_data_out_vld_q <= dut_it_data_out_vld;
            sink_it_done_q         <= dut_it_done;
            sink_protocol_error_q  <= dut_protocol_error;
        end
    end

endmodule

