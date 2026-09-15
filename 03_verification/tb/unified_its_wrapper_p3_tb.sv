`timescale 1ns/1ps

// Step12F-P3 directed contract bench.
//
// This bench observes the internal verification-only P3 signals to prove the
// transaction boundary, rather than inferring it from output latency alone:
// every accepted vertical group creates one registered command, the previous
// command is the only source of intermediate RAM write enables, and H_START
// is not visible until the final command has committed.
module unified_its_wrapper_p3_tb;
    logic clk = 1'b0;
    always #1 clk = ~clk;
    logic rst_n = 1'b0;
    logic [21:0] it_info = '0;
    logic it_info_vld = 1'b0;
    logic signed [15:0] it_data_in = '0;
    logic [11:0] it_data_addr = '0;
    logic it_data_in_vld = 1'b0;
    logic it_data_end = 1'b0;
    logic it_data_in_req;
    logic it_data_out_req = 1'b1;
    logic [39:0] it_data_out;
    logic it_data_out_vld;
    logic it_done;
    logic protocol_error;

    unified_its_wrapper dut (
        .clk(clk), .rst_n(rst_n),
        .it_info(it_info), .it_info_vld(it_info_vld),
        .it_data_in(it_data_in), .it_data_addr(it_data_addr),
        .it_data_in_vld(it_data_in_vld), .it_data_end(it_data_end),
        .it_data_in_req(it_data_in_req),
        .it_data_out_req(it_data_out_req),
        .it_data_out(it_data_out), .it_data_out_vld(it_data_out_vld),
        .it_done(it_done), .protocol_error(protocol_error)
    );

    function automatic [21:0] desc(input integer w, input integer h,
                                    input integer hor, input integer ver);
        desc = w[6:0] | (h[6:0] << 7) | (hor[1:0] << 14) |
               (ver[1:0] << 16);
    endfunction

    task automatic send_info(input [21:0] value);
        begin
            @(negedge clk);
            it_info <= value;
            it_info_vld <= 1'b1;
            @(posedge clk);
            @(negedge clk);
            it_info_vld <= 1'b0;
        end
    endtask

    task automatic send_data(input integer address, input integer value,
                             input bit last);
        begin
            while (!it_data_in_req) @(negedge clk);
            @(negedge clk);
            it_data_addr <= address[11:0];
            it_data_in <= value[15:0];
            it_data_in_vld <= 1'b1;
            it_data_end <= last;
            @(posedge clk);
            @(negedge clk);
            it_data_in_vld <= 1'b0;
            it_data_end <= 1'b0;
        end
    endtask

    integer cycle_i;
    integer command_count;
    integer commit_count;
    integer output_count;
    integer last_commit_cycle;
    bit saw_h_start;
    bit saw_last_commit;
    initial begin
        repeat (3) @(negedge clk);
        rst_n <= 1'b1;

        // A full 8x8 DCT2 TU exercises multiple consecutive V groups and the
        // final V-to-H barrier.  Sparse values keep the arithmetic simple.
        send_info(desc(8, 8, 0, 0));
        send_data(0, 123, 1'b0);
        send_data(4, -77, 1'b0);
        send_data(8, 55, 1'b0);
        send_data(12, -22, 1'b0);
        send_data(16, 19, 1'b0);
        send_data(20, -11, 1'b0);
        send_data(24, 7, 1'b0);
        send_data(28, -5, 1'b0);
        send_data(32, 3, 1'b0);
        send_data(36, -2, 1'b0);
        send_data(40, 1, 1'b0);
        send_data(44, -1, 1'b0);
        send_data(48, 0, 1'b0);
        send_data(52, 0, 1'b0);
        send_data(56, 0, 1'b0);
        send_data(60, 0, 1'b1);

        command_count = 0;
        commit_count = 0;
        output_count = 0;
        last_commit_cycle = -1;
        saw_h_start = 1'b0;
        saw_last_commit = 1'b0;

        for (cycle_i = 0; cycle_i < 30000; cycle_i = cycle_i + 1) begin
            @(posedge clk);

            // The pre-NBA command is the transaction committed by this edge.
            if (dut.vwrite_cmd_commit) begin
                commit_count = commit_count + 1;
                if (dut.vwrite_cmd_bank_mask_q == 4'b0000)
                    $fatal(1, "empty P3 command committed");
                for (integer b = 0; b < 4; b = b + 1) begin
                    if (dut.tmp_wr_en[b] !== dut.vwrite_cmd_bank_mask_q[b])
                        $fatal(1, "RAM write enable is not command-local bank=%0d", b);
                    if (dut.tmp_wr_addr[b] !== dut.vwrite_cmd_addr_q)
                        $fatal(1, "RAM write address mismatch bank=%0d", b);
                end
                if (dut.vwrite_cmd_last_q) begin
                    saw_last_commit = 1'b1;
                    last_commit_cycle = cycle_i;
                end
            end

            if (dut.vertical_result_fire) begin
                command_count = command_count + 1;
                if (dut.vwrite_cmd_bank_mask_c !== 4'b1111)
                    $fatal(1, "vertical group did not map to all banks: %b",
                           dut.vwrite_cmd_bank_mask_c);
            end

            // K_V_WAIT_COMMIT is enum value 4 and K_H_START is enum value 5.
            // H must not be admitted before the final command commit observed
            // above, including the pre-NBA edge at which the RAM writes.
            if (dut.kernel_phase_q == 4'd5) begin
                saw_h_start = 1'b1;
                if (!saw_last_commit)
                    $fatal(1, "H_START admitted before final V-write commit");
            end

            if (it_data_out_vld)
                output_count = output_count + 1;
            if (it_done)
                break;
        end

        if (protocol_error)
            $fatal(1, "unexpected protocol_error");
        if (command_count == 0 || commit_count == 0 || !saw_last_commit ||
            !saw_h_start || output_count != 16)
            $fatal(1,
                   "P3 contract incomplete commands=%0d commits=%0d last=%0b h_start=%0b outputs=%0d",
                   command_count, commit_count, saw_last_commit, saw_h_start,
                   output_count);

        $display("P3_VWRITE_TB_PASS commands=%0d commits=%0d last_commit_cycle=%0d outputs=%0d",
                 command_count, commit_count, last_commit_cycle, output_count);
        $finish;
    end
endmodule
