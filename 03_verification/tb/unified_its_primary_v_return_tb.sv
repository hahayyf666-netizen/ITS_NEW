`timescale 1ns/1ps

// Directed primary-V return-credit test.  A 4x64 transform creates sixteen
// vertical read groups.  The kernel-local request is deliberately stalled
// after start so the registered four-entry return reservation fills, then the
// exact SAT10 output stream is checked after release.
module unified_its_primary_v_return_tb;
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

    unified_its_wrapper #(.FINAL_SATURATE(1)) dut (
        .clk(clk), .rst_n(rst_n),
        .it_info(it_info), .it_info_vld(it_info_vld),
        .it_data_in(it_data_in), .it_data_addr(it_data_addr),
        .it_data_in_vld(it_data_in_vld), .it_data_end(it_data_end),
        .it_data_in_req(it_data_in_req),
        .it_data_out_req(it_data_out_req),
        .it_data_out(it_data_out), .it_data_out_vld(it_data_out_vld),
        .it_done(it_done), .protocol_error(protocol_error)
    );

    function automatic [21:0] desc_4x64;
        desc_4x64 = 22'd4 | (22'd64 << 7);
    endfunction

    function automatic [39:0] expected_beat(input integer beat);
        reg signed [9:0] lane0, lane1, lane2, lane3;
        begin
            lane0 = 10'sd0;
            lane1 = 10'sd0;
            lane2 = 10'sd0;
            lane3 = 10'sd0;
            case (beat)
                0: begin lane0=10'sd511; lane1=10'sd277; lane2=10'sd277; lane3=10'sd511; end
                1: begin lane0=10'sd511; lane1=10'sd302; lane2=10'sd302; lane3=10'sd511; end
                2: begin lane0=10'sd511; lane1=10'sd360; lane2=10'sd360; lane3=10'sd511; end
                3: begin lane0=10'sd511; lane1=10'sd443; lane2=10'sd443; lane3=10'sd511; end
                12: begin lane0=10'sd443; lane1=10'sd511; lane2=10'sd511; lane3=10'sd443; end
                13: begin lane0=10'sd360; lane1=10'sd511; lane2=10'sd511; lane3=10'sd360; end
                14: begin lane0=10'sd302; lane1=10'sd511; lane2=10'sd511; lane3=10'sd302; end
                15: begin lane0=10'sd277; lane1=10'sd511; lane2=10'sd511; lane3=10'sd277; end
                16: begin lane0=10'sd277; lane1=10'sd511; lane2=10'sd511; lane3=10'sd277; end
                17: begin lane0=10'sd302; lane1=10'sd511; lane2=10'sd511; lane3=10'sd302; end
                18: begin lane0=10'sd360; lane1=10'sd511; lane2=10'sd511; lane3=10'sd360; end
                19: begin lane0=10'sd443; lane1=10'sd511; lane2=10'sd511; lane3=10'sd443; end
                28: begin lane0=10'sd511; lane1=10'sd443; lane2=10'sd443; lane3=10'sd511; end
                29: begin lane0=10'sd511; lane1=10'sd360; lane2=10'sd360; lane3=10'sd511; end
                30: begin lane0=10'sd511; lane1=10'sd302; lane2=10'sd302; lane3=10'sd511; end
                31: begin lane0=10'sd511; lane1=10'sd277; lane2=10'sd277; lane3=10'sd511; end
                default: begin
                    if ((beat >= 4) && (beat <= 11) ||
                        (beat >= 20) && (beat <= 27)) begin
                        lane0=10'sd511; lane1=10'sd511;
                        lane2=10'sd511; lane3=10'sd511;
                    end
                end
            endcase
            expected_beat = {lane3, lane2, lane1, lane0};
        end
    endfunction

    task automatic send_info;
        begin
            @(negedge clk);
            it_info = desc_4x64();
            it_info_vld = 1'b1;
            @(posedge clk);
            @(negedge clk);
            it_info_vld = 1'b0;
        end
    endtask

    task automatic send_point(input integer address,
                              input logic signed [15:0] value,
                              input bit last);
        integer timeout;
        begin
            timeout = 0;
            @(negedge clk);
            while (!it_data_in_req) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 6000)
                    $fatal(1,
                           "primary-V test input request timeout addr=%0d info=%h legal=%b error=%b desc_count=%0d fill=%b scrub=%b slots=%0d/%0d",
                           address, it_info, dut.descriptor_legal,
                           protocol_error, dut.desc_count, dut.fill_active,
                           dut.scrub_active, dut.slot_state[0],
                           dut.slot_state[1]);
            end
            it_data_addr = address[11:0];
            it_data_in = value;
            it_data_in_vld = 1'b1;
            it_data_end = last;
            @(posedge clk);
            if (!it_data_in_req)
                $fatal(1, "primary-V test input was not accepted addr=%0d", address);
            @(negedge clk);
            it_data_in_vld = 1'b0;
            it_data_end = 1'b0;
        end
    endtask

    integer timeout;
    integer beat_count;
    integer done_count;
    integer stall_count;
    integer cycle_count;
    integer request_count;
    integer request_ii_pairs;
    integer last_request_cycle;
    integer last_request_group;
    integer last_request_vector;
    bit measure_request_ii;
    bit have_last_request;
    logic [63:0] held_head;
    logic [4:0] held_request_group;

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count = 0;
            request_count = 0;
            request_ii_pairs = 0;
            last_request_cycle = -1;
            last_request_group = -1;
            last_request_vector = -1;
            measure_request_ii = 1'b0;
            have_last_request = 1'b0;
        end else begin
            cycle_count = cycle_count + 1;
            if (measure_request_ii && dut.primary_logical_req_fire) begin
                if (have_last_request &&
                    (dut.rd_cmd_candidate_vector == last_request_vector) &&
                    (dut.rd_cmd_candidate_group == last_request_group + 1)) begin
                    if ((cycle_count - last_request_cycle) != 1)
                        $fatal(1,
                               "primary-V request II degraded groups=%0d->%0d cycles=%0d",
                               last_request_group,
                               dut.rd_cmd_candidate_group,
                               cycle_count - last_request_cycle);
                    request_ii_pairs = request_ii_pairs + 1;
                end
                request_count = request_count + 1;
                last_request_cycle = cycle_count;
                last_request_group = dut.rd_cmd_candidate_group;
                last_request_vector = dut.rd_cmd_candidate_vector;
                have_last_request = 1'b1;
                if ((dut.rd_cmd_candidate_vector == 0) &&
                    (dut.rd_cmd_candidate_group == 7))
                    measure_request_ii = 1'b0;
            end
        end
    end

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        send_info();
        send_point(0, 16'sd32767, 1'b0);
        send_point(18, 16'sd17000, 1'b0);
        send_point(255, -16'sd32768, 1'b1);

        timeout = 0;
        while (!(dut.kernel_run_q && !dut.kernel_stage_q &&
                 dut.kernel_start_sent_q)) begin
            @(negedge clk);
            timeout = timeout + 1;
            if (timeout > 12000)
                $fatal(1, "primary-V test did not reach vertical start");
        end

        // Pause the actual P4 ready output, not the wrapper scoreboard.  This
        // creates a real held valid/data transaction and fills all reserved
        // in-flight capacity without accepting or duplicating kernel input.
        force dut.u_unified_p4_kernel.in_req = 1'b0;
        timeout = 0;
        while (dut.primary_outstanding_q != 3'd4) begin
            @(negedge clk);
            timeout = timeout + 1;
            if (timeout > 100)
                $fatal(1,
                       "primary-V reservations did not fill outstanding=%0d count=%0d group=%0d raw=%b cmd=%b",
                       dut.primary_outstanding_q, dut.primary_return_count_q,
                       dut.kernel_rd_req_group_q, dut.kernel_rd_raw_pending_q,
                       dut.rd_cmd_valid_q);
        end
        if (!dut.kernel_in_valid || dut.kernel_group_accept ||
            dut.primary_return_count_q == 0)
            $fatal(1, "primary-V test did not establish a real return stall");
        held_head = dut.kernel_rd_return_data;
        held_request_group = dut.kernel_rd_req_group_q;
        stall_count = 0;
        repeat (8) begin
            @(posedge clk);
            if (dut.primary_outstanding_q != 3'd4 ||
                !dut.kernel_rd_return_valid || dut.kernel_group_accept ||
                dut.kernel_rd_return_data !== held_head ||
                dut.kernel_rd_req_group_q !== held_request_group)
                $fatal(1,
                       "primary-V stall changed out=%0d fifo=%0d valid=%b pop=%b accept=%b head=%h held=%h req_group=%0d held_req_group=%0d raw=%b cmd=%b",
                       dut.primary_outstanding_q,
                       dut.primary_return_count_q,
                       dut.kernel_rd_return_valid, dut.primary_return_pop,
                       dut.kernel_group_accept, dut.kernel_rd_return_data,
                       held_head, dut.kernel_rd_req_group_q,
                       held_request_group,
                       dut.kernel_rd_raw_pending_q, dut.rd_cmd_valid_q);
            @(negedge clk);
            stall_count = stall_count + 1;
        end

        @(negedge clk);
        force dut.u_unified_p4_kernel.in_req = 1'b1;
        measure_request_ii = 1'b1;
        have_last_request = 1'b0;
        request_count = 0;
        request_ii_pairs = 0;
        beat_count = 0;
        done_count = 0;
        timeout = 0;
        while (beat_count < 64) begin
            @(posedge clk);
            timeout = timeout + 1;
            if (timeout > 30000)
                $fatal(1,
                       "primary-V output timeout beats=%0d out=%0d fifo=%0d group=%0d phase=%0d",
                       beat_count, dut.primary_outstanding_q,
                       dut.primary_return_count_q,
                       dut.kernel_feed_group_q, dut.kernel_phase_q);
            if (it_data_out_vld && it_data_out_req) begin
                if (it_data_out !== expected_beat(beat_count))
                    $fatal(1,
                           "primary-V return data mismatch beat=%0d got=%h expected=%h",
                           beat_count, it_data_out, expected_beat(beat_count));
                if (it_done !== (beat_count == 63))
                    $fatal(1, "primary-V done mismatch beat=%0d done=%b",
                           beat_count, it_done);
                done_count = done_count + (it_done ? 1 : 0);
                beat_count = beat_count + 1;
            end
        end
        @(negedge clk);
        force dut.u_unified_p4_kernel.in_req = 1'b1;
        repeat (2) @(negedge clk);
        if (protocol_error || done_count != 1 ||
            dut.primary_outstanding_q != 0 ||
            dut.primary_return_count_q != 0 ||
            dut.kernel_rd_raw_pending_q || dut.rd_cmd_valid_q)
            $fatal(1,
                   "primary-V drain mismatch error=%b done=%0d outstanding=%0d fifo=%0d raw=%b cmd=%b",
                   protocol_error, done_count, dut.primary_outstanding_q,
                   dut.primary_return_count_q, dut.kernel_rd_raw_pending_q,
                   dut.rd_cmd_valid_q);
        if (request_count != 4 || request_ii_pairs != 3)
            $fatal(1,
                   "primary-V request cadence coverage mismatch requests=%0d II1_pairs=%0d",
                   request_count, request_ii_pairs);
        $display("PRIMARY_V_RETURN_PASS outstanding_depth=4 real_stall_cycles=%0d beats=%0d done=%0d request_ii_pairs=%0d",
                 stall_count, beat_count, done_count, request_ii_pairs);
        $finish;
    end
endmodule
