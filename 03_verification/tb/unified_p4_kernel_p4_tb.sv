`timescale 1ns/1ps

// Step12F-P4 directed contract bench.
//
// N=4 is intentionally exercised as a back-to-back stream: one accepted
// vector per cycle.  Every vector carries a unique four-lane payload, so an
// early slot release or operand overwrite is observable at the descriptor ->
// Stage-0 boundary even when the arithmetic result is not inspected here.
module unified_p4_kernel_p4_tb;
    localparam integer VECTOR_COUNT = 16;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [1:0] tr_type = 2'd0;
    logic [6:0] transform_size = 7'd4;
    logic [6:0] active_size = 7'd4;
    logic [6:0] output_size = 7'd4;
    logic stage_sel = 1'b0;
    logic in_valid = 1'b0;
    logic signed [63:0] in_data = '0;
    logic in_req;
    logic out_valid;
    logic out_req = 1'b1;
    logic signed [63:0] out_data;
    logic done;
    logic busy;
    logic error;

    integer vector_i;
    integer lane_i;
    integer start_count;
    integer desc_count;
    integer capture_count;
    integer release_count;
    integer last_desc_cycle;
    integer last_capture_cycle;
    integer cycle_i;
    integer wait_i;
    integer slot_i;
    integer prev_desc_slot;
    integer prev_desc_last;
    integer expected_value;
    integer got_value;
    integer slot_payload [0:3][0:3];
    integer desc_payload [0:3];
    logic slot_inflight [0:3];

    always #1 clk = ~clk;

    unified_p4_kernel dut (
        .clk(clk), .rst_n(rst_n), .start(start), .tr_type(tr_type),
        .transform_size(transform_size), .active_size(active_size),
        .output_size(output_size), .stage_sel(stage_sel),
        .in_valid(in_valid), .in_req(in_req), .in_data(in_data),
        .out_valid(out_valid), .out_req(out_req), .out_data(out_data),
        .done(done), .busy(busy), .error(error)
    );

    initial begin
        for (slot_i = 0; slot_i < 4; slot_i = slot_i + 1)
            for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1)
                slot_payload[slot_i][lane_i] = -1;
        for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1)
            desc_payload[lane_i] = -1;
        for (slot_i = 0; slot_i < 4; slot_i = slot_i + 1)
            slot_inflight[slot_i] = 1'b0;

        repeat (3) @(posedge clk);
        #1step rst_n = 1'b1;

        // Four-slot retirement must permit 16 consecutive N=4 admissions.
        for (vector_i = 0; vector_i < VECTOR_COUNT; vector_i = vector_i + 1) begin
            @(negedge clk);
            in_valid = 1'b1;
            start = 1'b1;
            in_data = '0;
            for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1)
                in_data[lane_i*16 +: 16] = vector_i*100 + lane_i;
            #1step;
            if (!in_req || !dut.start_accept)
                $fatal(1, "P4 N=4 start not accepted vector=%0d cycle=%0d",
                       vector_i, cycle_i);
            // start_accept selects the first free slot; remember the payload
            // for the descriptor that will issue after the load edge.
            for (slot_i = 0; slot_i < 4; slot_i = slot_i + 1)
                if (dut.free_slot_c == slot_i)
                    for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1)
                        slot_payload[slot_i][lane_i] = vector_i*100 + lane_i;
            @(posedge clk);
            #1step;
            // The descriptor visible after this edge was issued on this
            // edge; the preceding descriptor (if any) is the one whose
            // final capture/release must complete on this edge.
            if (prev_desc_last) begin
                if (dut.slot_state_q[prev_desc_slot] != 2'd0)
                    $fatal(1, "P4 slot not released after final capture slot=%0d cycle=%0d",
                           prev_desc_slot, cycle_i);
                if (!slot_inflight[prev_desc_slot])
                    $fatal(1, "P4 release without in-flight descriptor slot=%0d",
                           prev_desc_slot);
                slot_inflight[prev_desc_slot] = 1'b0;
                release_count = release_count + 1;
            end
            if (dut.s0_valid_q) begin
                capture_count = capture_count + 1;
                if ((last_capture_cycle >= 0) &&
                    (cycle_i - last_capture_cycle != 1))
                    $fatal(1, "P4 Stage-0 capture bubble cycle=%0d previous=%0d",
                           cycle_i, last_capture_cycle);
                last_capture_cycle = cycle_i;
                for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
                    expected_value = desc_payload[lane_i];
                    got_value = $signed(dut.s0_input_q[lane_i]);
                    if (got_value != expected_value)
                        $fatal(1, "P4 operand overwrite cycle=%0d lane=%0d got=%0d expected=%0d",
                               cycle_i, lane_i, got_value, expected_value);
                end
            end
            if (dut.issue_desc_valid_q) begin
                desc_count = desc_count + 1;
                if ((last_desc_cycle >= 0) && (cycle_i - last_desc_cycle != 1))
                    $fatal(1, "P4 descriptor bubble cycle=%0d previous=%0d",
                           cycle_i, last_desc_cycle);
                last_desc_cycle = cycle_i;
                slot_i = dut.issue_desc_slot_q;
                if (slot_inflight[slot_i])
                    $fatal(1, "P4 slot reused before final capture slot=%0d cycle=%0d",
                           slot_i, cycle_i);
                slot_inflight[slot_i] = 1'b1;
                prev_desc_slot = slot_i;
                prev_desc_last = dut.issue_desc_last_q;
                for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1)
                    desc_payload[lane_i] = slot_payload[slot_i][lane_i];
            end
            cycle_i = cycle_i + 1;
        end

        @(negedge clk);
        start = 1'b0;
        in_valid = 1'b0;
        in_data = '0;

        // Drain the descriptor and Stage-0 streams.
        wait_i = 0;
        while ((desc_count < VECTOR_COUNT || capture_count < VECTOR_COUNT) &&
               (wait_i < 64)) begin
            @(posedge clk);
            #1step;
            if (prev_desc_last) begin
                if (dut.slot_state_q[prev_desc_slot] != 2'd0)
                    $fatal(1, "P4 drain slot not released slot=%0d cycle=%0d",
                           prev_desc_slot, cycle_i);
                if (!slot_inflight[prev_desc_slot])
                    $fatal(1, "P4 drain release without in-flight slot=%0d",
                           prev_desc_slot);
                slot_inflight[prev_desc_slot] = 1'b0;
                release_count = release_count + 1;
            end
            if (dut.s0_valid_q) begin
                capture_count = capture_count + 1;
                if ((last_capture_cycle >= 0) &&
                    (cycle_i - last_capture_cycle != 1))
                    $fatal(1, "P4 Stage-0 drain bubble cycle=%0d previous=%0d",
                           cycle_i, last_capture_cycle);
                last_capture_cycle = cycle_i;
                for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
                    expected_value = desc_payload[lane_i];
                    got_value = $signed(dut.s0_input_q[lane_i]);
                    if (got_value != expected_value)
                        $fatal(1, "P4 drain operand overwrite lane=%0d got=%0d expected=%0d",
                               lane_i, got_value, expected_value);
                end
            end
            if (dut.issue_desc_valid_q) begin
                desc_count = desc_count + 1;
                if ((last_desc_cycle >= 0) && (cycle_i - last_desc_cycle != 1))
                    $fatal(1, "P4 descriptor drain bubble cycle=%0d previous=%0d",
                           cycle_i, last_desc_cycle);
                last_desc_cycle = cycle_i;
                slot_i = dut.issue_desc_slot_q;
                if (slot_inflight[slot_i])
                    $fatal(1, "P4 drain slot reused before final capture slot=%0d",
                           slot_i);
                slot_inflight[slot_i] = 1'b1;
                prev_desc_slot = slot_i;
                prev_desc_last = dut.issue_desc_last_q;
                for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1)
                    desc_payload[lane_i] = slot_payload[slot_i][lane_i];
            end
            cycle_i = cycle_i + 1;
            wait_i = wait_i + 1;
        end

        if (desc_count != VECTOR_COUNT || capture_count != VECTOR_COUNT)
            $fatal(1, "P4 counts desc=%0d/%0d capture=%0d/%0d",
                   desc_count, VECTOR_COUNT, capture_count, VECTOR_COUNT);
        if (release_count != VECTOR_COUNT)
            $fatal(1, "P4 release count=%0d/%0d", release_count, VECTOR_COUNT);
        for (slot_i = 0; slot_i < 4; slot_i = slot_i + 1)
            if (slot_inflight[slot_i])
                $fatal(1, "P4 slot remains in flight slot=%0d", slot_i);
        if (error)
            $fatal(1, "P4 kernel error asserted");
        $display("GATE_F_P4_STAGE0_TB_PASS vectors=%0d descriptors=%0d captures=%0d releases=%0d",
                 VECTOR_COUNT, desc_count, capture_count, release_count);
        $finish;
    end

    initial begin
        start_count = 0;
        desc_count = 0;
        capture_count = 0;
        release_count = 0;
        last_desc_cycle = -1;
        last_capture_cycle = -1;
        cycle_i = 0;
        prev_desc_slot = 0;
        prev_desc_last = 0;
    end
endmodule
