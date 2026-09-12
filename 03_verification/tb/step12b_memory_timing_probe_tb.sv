`timescale 1ns/1ps

// Verification-only probe for v3.5-17.2.
// It observes the frozen wrapper hierarchically and records the actual edge
// at which the clocked array read RHS is evaluated and staging is updated.
// No DUT source is modified by this probe.
module step12b_memory_timing_probe_tb;
    reg clk = 0, rst_n = 0;
    reg [21:0] it_info = 22'h002040;
    reg it_info_vld = 0;
    reg signed [15:0] it_data_in = 0;
    reg [11:0] it_data_addr = 0;
    reg it_data_in_vld = 0, it_data_end = 0;
    wire it_data_in_req;
    reg it_data_out_req = 1'b1;
    wire [39:0] it_data_out;
    wire it_data_out_vld, it_done, protocol_error;
    wire debug_stage16_valid;
    wire [5:0] debug_stage16_row, debug_stage16_col;
    wire signed [15:0] debug_stage16_data;

`ifdef SYNTHESIS
    localparam TRACE_FILE = "05_audit/current/17_2/memory_timing_probe_synthesis.csv";
`else
    localparam TRACE_FILE = "05_audit/current/17_2/memory_timing_probe_normal.csv";
`endif

    localparam [1:0] PH_VERTICAL = 2'd1;
    localparam [1:0] PH_HORIZONTAL = 2'd2;
    localparam [1:0] PH_WAIT_H = 2'd3;

    integer fd;
    integer cycle;
    integer lane;
    integer row;
    integer col;
    integer bank;
    integer addr;
    integer vec;
    integer req_count;
    integer response_count;
    integer capture_count;
    integer full_count;
    integer v_write_count;
    integer reserve_count;
    integer scrub_count;
    integer errors;
    reg can_load;
    reg [1:0] phase_snapshot;
    reg load_bank_snapshot;
    reg [6:0] vector_snapshot;
    reg [4:0] group_snapshot;
    reg [15:0] tu_snapshot;
    reg [1:0] slot_snapshot;
    integer bank_snapshot [0:3];
    integer addr_snapshot [0:3];
    integer row_snapshot [0:3];
    integer source_value_snapshot [0:3];

    function automatic integer coord_bank(input integer r, input integer c);
        coord_bank = ((r & 3) ^ (c & 3));
    endfunction
    function automatic integer coord_addr(input integer r, input integer c);
        coord_addr = r * 16 + (c >> 2);
    endfunction

    always #1 clk = ~clk;

    step12b_dct2_64_wrapper dut (
        .clk(clk), .rst_n(rst_n), .it_info(it_info), .it_info_vld(it_info_vld),
        .it_data_in(it_data_in), .it_data_addr(it_data_addr),
        .it_data_in_vld(it_data_in_vld), .it_data_end(it_data_end),
        .it_data_in_req(it_data_in_req), .it_data_out_req(it_data_out_req),
        .it_data_out(it_data_out), .it_data_out_vld(it_data_out_vld),
        .it_done(it_done), .protocol_error(protocol_error),
        .debug_stage16_valid(debug_stage16_valid),
        .debug_stage16_row(debug_stage16_row), .debug_stage16_col(debug_stage16_col),
        .debug_stage16_data(debug_stage16_data)
    );

    initial begin
        fd = $fopen(TRACE_FILE, "w");
        if (fd == 0) $fatal(1, "cannot open %s", TRACE_FILE);
        $fwrite(fd, "cycle,event,phase,tu,vector,group,lane,slot,bank,addr,epoch,request_id\n");
        cycle = 0;
        req_count = 0;
        response_count = 0;
        capture_count = 0;
        full_count = 0;
        v_write_count = 0;
        reserve_count = 0;
        scrub_count = 0;
        errors = 0;
    end

    // All predicates below are sampled before the DUT NBA update.  The
    // response/capture records are written after #1step for post-NBA data
    // validation, but retain the same accepting edge number.
    always @(posedge clk) begin
        if (!rst_n) begin
            cycle = 0;
        end else begin
            phase_snapshot = dut.phase;
            load_bank_snapshot = dut.load_bank;
            vector_snapshot = dut.load_vector;
            group_snapshot = dut.load_group;
            tu_snapshot = dut.active_tu;
            slot_snapshot = (dut.load_bank == 1'b0) ? 2'd0 : 2'd1;
            can_load = 1'b0;
            if ((dut.phase == PH_VERTICAL || dut.phase == PH_HORIZONTAL) &&
                dut.load_vector < 64) begin
                if ((dut.load_bank == 1'b0 && !dut.stage_ready_a) ||
                    (dut.load_bank == 1'b1 && !dut.stage_ready_b))
                    can_load = 1'b1;
                if (dut.r4c_start && (dut.load_bank == dut.launch_bank))
                    can_load = 1'b0;
            end

            if (can_load) begin
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    row = group_snapshot * 4 + lane;
                    col = vector_snapshot;
                    if (phase_snapshot == PH_VERTICAL) begin
                        bank = coord_bank(row, col);
                        addr = coord_addr(row, col);
                    end else begin
                        bank = coord_bank(col, row);
                        addr = coord_addr(col, row);
                    end
                    row_snapshot[lane] = row;
                    bank_snapshot[lane] = bank;
                    addr_snapshot[lane] = addr;
                    $fwrite(fd, "%0d,read_request,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,,%0d\n",
                            cycle, phase_snapshot, tu_snapshot, vector_snapshot,
                            group_snapshot, lane, slot_snapshot, bank, addr,
                            req_count);
                    req_count = req_count + 1;
                end
            end

            if (dut.phase == PH_WAIT_H && !dut.result_owner_valid) begin
                $fwrite(fd, "%0d,result_reserve,%0d,%0d,,,,,,,1024,%0d\n",
                        cycle, dut.phase, dut.active_tu, reserve_count);
                reserve_count = reserve_count + 1;
            end

            if (dut.r4c_result_valid && dut.phase == PH_VERTICAL) begin
                vec = dut.r4c_result_vector_id - dut.phase_vector_base;
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    row = dut.r4c_result_group * 4 + lane;
                    bank = coord_bank(row, vec);
                    addr = coord_addr(row, vec);
                    $fwrite(fd, "%0d,intermediate_write,%0d,%0d,%0d,%0d,%0d,,%0d,%0d,,vw%0d\n",
                            cycle, dut.phase, dut.active_tu, vec,
                            dut.r4c_result_group, lane, bank, addr, v_write_count);
                    v_write_count = v_write_count + 1;
                end
            end

            if (dut.cache_scrubbing[0] || dut.cache_scrubbing[1]) begin
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    if (dut.cache_scrubbing[0]) begin
                        $fwrite(fd, "%0d,epoch_scrub,%0d,%0d,,,,0,%0d,%0d,%0d,s0b%0d\n",
                                cycle, dut.phase, dut.cache_tu_id[0], lane,
                                dut.scrub_index[0], dut.cache_epoch[0], scrub_count);
                        scrub_count = scrub_count + 1;
                    end
                    if (dut.cache_scrubbing[1]) begin
                        $fwrite(fd, "%0d,epoch_scrub,%0d,%0d,,,,1,%0d,%0d,%0d,s1b%0d\n",
                                cycle, dut.phase, dut.cache_tu_id[1], lane,
                                dut.scrub_index[1], dut.cache_epoch[1], scrub_count);
                        scrub_count = scrub_count + 1;
                    end
                end
            end

            #1step;

            if (can_load) begin
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    $fwrite(fd, "%0d,read_response,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,,%0d\n",
                            cycle, phase_snapshot, tu_snapshot, vector_snapshot,
                            group_snapshot, lane, slot_snapshot,
                            bank_snapshot[lane], addr_snapshot[lane], req_count - 4 + lane);
                    $fwrite(fd, "%0d,stage_lane_capture,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,,%0d\n",
                            cycle, phase_snapshot, tu_snapshot, vector_snapshot,
                            group_snapshot, lane, slot_snapshot,
                            bank_snapshot[lane], addr_snapshot[lane], req_count - 4 + lane);
                    response_count = response_count + 1;
                    capture_count = capture_count + 1;
                end
                if (group_snapshot == 15) begin
                    $fwrite(fd, "%0d,stage_full,%0d,%0d,%0d,%0d,,%0d,,,,\n",
                            cycle, phase_snapshot, tu_snapshot, vector_snapshot,
                            group_snapshot, slot_snapshot);
                    full_count = full_count + 1;
                end
            end

            if (protocol_error)
                $fatal(1, "probe observed protocol_error at cycle %0d", cycle);
            cycle = cycle + 1;
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);
        it_info <= 22'h002040;
        it_info_vld <= 1'b1;
        @(posedge clk);
        it_info_vld <= 1'b0;
        wait (it_data_in_req);
        @(posedge clk);
        it_data_addr <= 12'd65;
        it_data_in <= 16'sd100;
        it_data_in_vld <= 1'b1;
        it_data_end <= 1'b1;
        @(posedge clk);
        it_data_in_vld <= 1'b0;
        it_data_end <= 1'b0;
        wait (it_done);
        #2;
        if (req_count != 8192) $fatal(1, "memory probe read_request count=%0d", req_count);
        if (response_count != 8192) $fatal(1, "memory probe response count=%0d", response_count);
        if (capture_count != 8192) $fatal(1, "memory probe capture count=%0d", capture_count);
        if (full_count != 128) $fatal(1, "memory probe stage_full count=%0d", full_count);
        if (v_write_count != 4096) $fatal(1, "memory probe V write count=%0d", v_write_count);
        $display("STEP12B_MEMORY_TIMING_PROBE_PASS requests=%0d responses=%0d captures=%0d stage_full=%0d v_writes=%0d scrub=%0d",
                 req_count, response_count, capture_count, full_count, v_write_count, scrub_count);
        $fclose(fd);
        $finish;
    end
endmodule
