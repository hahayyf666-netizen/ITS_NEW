`timescale 1ns/1ps

// Directed verification for the H-read asynchronous-RAM to registered-raw
// capture boundary.  The internal kernel input is intentionally stalled in
// this simulation-only test so the three-entry response path fills; the
// external protocol and production RTL are not modified by the test.
module unified_its_hread_raw_capture_tb;
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
    logic it_data_out_req = 1'b0;
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

    localparam integer QUEUE_DEPTH = 8;
    logic [4:0] expected_group [0:QUEUE_DEPTH-1];
    logic [6:0] expected_vector [0:QUEUE_DEPTH-1];
    logic [63:0] expected_data [0:QUEUE_DEPTH-1];
    integer queue_wr = 0;
    integer queue_rd = 0;
    integer queue_count = 0;
    integer capture_count = 0;
    integer consume_count = 0;
    integer bank_i;
    integer cycle_count = 0;
    integer last_capture_cycle = -1;
    integer last_capture_group = -1;
    integer last_capture_vector = -1;
    integer ii1_pair_count = 0;
    bit measure_ii = 1'b0;
    bit have_last_capture = 1'b0;

    // Observe pre-edge transaction state.  Blocking assignments are confined
    // to this testbench scoreboard; all DUT stimulus changes on negedge.
    always @(posedge clk) begin
        if (!rst_n) begin
            queue_wr = 0;
            queue_rd = 0;
            queue_count = 0;
            capture_count = 0;
            consume_count = 0;
            cycle_count = 0;
            last_capture_cycle = -1;
            last_capture_group = -1;
            last_capture_vector = -1;
            ii1_pair_count = 0;
            measure_ii = 1'b0;
            have_last_capture = 1'b0;
        end else begin
            cycle_count = cycle_count + 1;
            if (dut.kernel_h_rd_consume) begin
                if (queue_count == 0)
                    $fatal(1, "H-read consume without an accepted raw capture");
                if (dut.kernel_h_rd_raw_group_q !== expected_group[queue_rd] ||
                    dut.kernel_h_rd_raw_vector_q !== expected_vector[queue_rd])
                    $fatal(1,
                           "H-read metadata reorder got=(v%0d,g%0d) expected=(v%0d,g%0d)",
                           dut.kernel_h_rd_raw_vector_q,
                           dut.kernel_h_rd_raw_group_q,
                           expected_vector[queue_rd], expected_group[queue_rd]);
                if (dut.kernel_h_rd_data_q !== expected_data[queue_rd])
                    $fatal(1,
                           "H-read payload/metadata misalignment v=%0d g=%0d got=%h expected=%h",
                           expected_vector[queue_rd], expected_group[queue_rd],
                           dut.kernel_h_rd_data_q, expected_data[queue_rd]);
                queue_rd = (queue_rd == QUEUE_DEPTH-1) ? 0 : queue_rd + 1;
                queue_count = queue_count - 1;
                consume_count = consume_count + 1;
            end

            if (dut.kernel_h_rd_capture) begin
                if (queue_count == QUEUE_DEPTH)
                    $fatal(1, "H-read scoreboard overflow");
                if (measure_ii && have_last_capture &&
                    (dut.kernel_h_rd_vector_q == last_capture_vector) &&
                    (dut.kernel_h_rd_group_q == last_capture_group + 1)) begin
                    if ((cycle_count - last_capture_cycle) != 1)
                        $fatal(1,
                               "H-read steady-state request II degraded vector=%0d groups=%0d->%0d cycles=%0d",
                               dut.kernel_h_rd_vector_q, last_capture_group,
                               dut.kernel_h_rd_group_q,
                               cycle_count - last_capture_cycle);
                    ii1_pair_count = ii1_pair_count + 1;
                end
                expected_group[queue_wr] = dut.kernel_h_rd_group_q;
                expected_vector[queue_wr] = dut.kernel_h_rd_vector_q;
                for (bank_i = 0; bank_i < 4; bank_i = bank_i + 1)
                    expected_data[queue_wr][bank_i*16 +: 16] =
                        dut.tmp_rd_data[bank_i];
                queue_wr = (queue_wr == QUEUE_DEPTH-1) ? 0 : queue_wr + 1;
                queue_count = queue_count + 1;
                capture_count = capture_count + 1;
                last_capture_cycle = cycle_count;
                last_capture_group = dut.kernel_h_rd_group_q;
                last_capture_vector = dut.kernel_h_rd_vector_q;
                have_last_capture = 1'b1;
            end
        end
    end

    task automatic send_descriptor_64x4;
        begin
            @(negedge clk);
            it_info = 22'd64 | (22'd4 << 7);
            it_info_vld = 1'b1;
            @(negedge clk);
            it_info_vld = 1'b0;
        end
    endtask

    task automatic send_sparse_point(input integer address,
                                     input logic signed [15:0] value,
                                     input bit last);
        integer timeout;
        begin
            timeout = 0;
            @(negedge clk);
            while (!it_data_in_req) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 4000)
                    $fatal(1, "H-read test input admission timeout addr=%0d", address);
            end
            it_data_addr = address[11:0];
            it_data_in = value;
            it_data_in_vld = 1'b1;
            it_data_end = last;
            @(negedge clk);
            it_data_in_vld = 1'b0;
            it_data_end = 1'b0;
        end
    endtask

    integer timeout;
    integer stall_cycles;
    integer output_beats;
    integer expected_capture_count;
    integer h_groups_per_vector;
    integer h_vectors;
    integer done_count;
    logic [63:0] held_raw_data;
    logic [4:0] held_raw_group;
    logic [6:0] held_raw_vector;

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        send_descriptor_64x4();
        send_sparse_point(0, 16'sd32767, 1'b0);
        send_sparse_point(255, -16'sd32768, 1'b1);

        // Wait until H has issued its start pulse.  Forcing the kernel-local
        // ready low isolates a real consumer stall without changing any
        // public ready/valid behavior or falsifying the wrapper's valid/data.
        timeout = 0;
        while (!(dut.kernel_run_q && dut.kernel_stage_q &&
                 dut.kernel_start_sent_q)) begin
            @(negedge clk);
            timeout = timeout + 1;
            if (timeout > 30000)
                $fatal(1, "H-read test did not reach horizontal start");
        end
        h_groups_per_vector = dut.kernel_h_groups_per_row_q;
        h_vectors = dut.kernel_h_q;
        expected_capture_count = h_groups_per_vector * h_vectors;
        force dut.u_unified_p4_kernel.in_req = 1'b0;
        timeout = 0;
        while (dut.kernel_phase_q !== 4'd6) begin
            @(negedge clk);
            timeout = timeout + 1;
            if (timeout > 100)
                $fatal(1, "H-read test did not enter K_H_FEED");
        end
        while (!(dut.kernel_h_rd_raw_stage_valid_q &&
                 !dut.kernel_h_rd_raw_stage_ready)) begin
            @(negedge clk);
            timeout = timeout + 1;
            if (timeout > 100)
                $fatal(1, "H-read raw stage did not reach a real full stall");
        end
        if (!dut.kernel_h_rd_pending_q ||
            !dut.kernel_h_rd_raw_pending_q ||
            !dut.kernel_h_rd_raw_tail_pending_q)
            $fatal(1, "H-read stall did not fill request/head/tail/raw ownership");

        held_raw_group = dut.kernel_h_rd_raw_stage_group_q;
        held_raw_vector = dut.kernel_h_rd_raw_stage_vector_q;
        for (bank_i = 0; bank_i < 4; bank_i = bank_i + 1)
            held_raw_data[bank_i*16 +: 16] = dut.kernel_h_rd_raw_data_q[bank_i];
        stall_cycles = 0;
        repeat (6) begin
            @(posedge clk);
            if (!dut.kernel_h_rd_raw_stage_valid_q ||
                dut.kernel_h_rd_raw_stage_ready ||
                !dut.kernel_h_rd_pending_q)
                $fatal(1, "H-read raw stall unexpectedly advanced before release");
            #0.1;
            if (!dut.kernel_h_rd_raw_stage_valid_q ||
                dut.kernel_h_rd_raw_stage_group_q !== held_raw_group ||
                dut.kernel_h_rd_raw_stage_vector_q !== held_raw_vector)
                $fatal(1, "H-read raw metadata changed while backpressured");
            for (bank_i = 0; bank_i < 4; bank_i = bank_i + 1)
                if (dut.kernel_h_rd_raw_data_q[bank_i] !==
                    held_raw_data[bank_i*16 +: 16])
                    $fatal(1, "H-read raw bank payload changed while backpressured bank=%0d",
                           bank_i);
            stall_cycles = stall_cycles + 1;
        end

        @(negedge clk);
        // The normal kernel-local ready is high in this uncongested directed
        // transaction; forcing it high resumes the same valid/data stream.
        // Keep the override through drain so simulator variable-release
        // scheduling cannot leave a procedural output at its forced value.
        force dut.u_unified_p4_kernel.in_req = 1'b1;
        have_last_capture = 1'b0;
        ii1_pair_count = 0;
        measure_ii = 1'b1;
        it_data_out_req = 1'b1;
        output_beats = 0;
        done_count = 0;
        timeout = 0;
        while (output_beats < 64) begin
            @(posedge clk);
            timeout = timeout + 1;
            if (timeout > 30000)
                $fatal(1,
                       "H-read test output timeout beats=%0d phase=%0d run=%b stage=%b start_sent=%b in_valid=%b in_req=%b fire=%b vector_done=%b feed_group=%0d drain_group=%0d h_pending=%b raw_valid=%b head=%b tail=%b queue=%0d captures=%0d consumes=%0d input_wait=%b kernel_busy=%b kernel_error=%b",
                       output_beats, dut.kernel_phase_q, dut.kernel_run_q,
                       dut.kernel_stage_q, dut.kernel_start_sent_q,
                       dut.kernel_in_valid, dut.kernel_in_req,
                       dut.kernel_input_group_fire,
                       dut.kernel_input_vector_done,
                       dut.kernel_feed_group_q, dut.kernel_drain_group_q,
                       dut.kernel_h_rd_pending_q,
                       dut.kernel_h_rd_raw_stage_valid_q,
                       dut.kernel_h_rd_raw_pending_q,
                       dut.kernel_h_rd_raw_tail_pending_q, queue_count,
                       capture_count, consume_count,
                       dut.kernel_h_input_commit_wait_q,
                       dut.kernel_busy, dut.kernel_error);
            if (it_data_out_vld) begin
                if ((^it_data_out) === 1'bx)
                    $fatal(1, "H-read output contains unknown data beat=%0d", output_beats);
                if (it_done !== (output_beats == 63))
                    $fatal(1, "H-read done mismatch beat=%0d done=%b",
                           output_beats, it_done);
                done_count = done_count + (it_done ? 1 : 0);
                output_beats = output_beats + 1;
            end
        end
        @(negedge clk);
        it_data_out_req = 1'b0;
        repeat (2) @(negedge clk);
        if (protocol_error || done_count != 1)
            $fatal(1, "H-read test completion failed error=%b done=%0d",
                   protocol_error, done_count);
        if (capture_count != expected_capture_count ||
            consume_count != expected_capture_count || queue_count != 0)
            $fatal(1,
                   "H-read transaction accounting mismatch expected=%0d vectors=%0d groups_per_vector=%0d captures=%0d consumes=%0d queued=%0d",
                   expected_capture_count, h_vectors, h_groups_per_vector,
                   capture_count, consume_count, queue_count);
        if (ii1_pair_count < (h_groups_per_vector - 2))
            $fatal(1,
                   "H-read steady-state II=1 pairs insufficient pairs=%0d groups_per_vector=%0d",
                   ii1_pair_count, h_groups_per_vector);
        $display("H_READ_RAW_CAPTURE_PASS captures=%0d consumes=%0d stall_cycles=%0d",
                 capture_count, consume_count, stall_cycles);
        $finish;
    end
endmodule
