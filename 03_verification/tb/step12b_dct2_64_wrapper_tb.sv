`timescale 1ns/1ps

module step12b_dct2_64_wrapper_tb;
    reg clk = 0;
    reg rst_n = 0;
    reg [21:0] it_info = 22'h002040;
    reg it_info_vld = 0;
    reg signed [15:0] it_data_in = 0;
    reg [11:0] it_data_addr = 0;
    reg it_data_in_vld = 0;
    reg it_data_end = 0;
    wire it_data_in_req;
    reg it_data_out_req = 1;
    wire [39:0] it_data_out;
    wire it_data_out_vld;
    wire it_done;
    wire protocol_error;
    wire debug_stage16_valid;
    wire [5:0] debug_stage16_row, debug_stage16_col;
    wire signed [15:0] debug_stage16_data;
    integer cycles, fires, data_errors, hold_errors, last_fire_cycle, fire_ii_errors;
    integer done_postnba_errors;
    reg [39:0] held_data;
    reg stall_active;
    reg stall_valid;
    reg [39:0] stall_data;
    integer trace_fd, trace_cycle;
    reg trace_input_s, trace_start_s, trace_result_s, trace_fire_s, trace_done_s;
    reg [15:0] trace_vid_s, trace_start_vid_s;
    reg [4:0] trace_group_s;
    reg [9:0] trace_index_s;
    reg [1:0] trace_phase_s;
    reg [11:0] trace_addr_s;
    reg trace_end_s;
    reg trace_stage_capture_s, trace_intermediate_write_s;
    reg trace_result_reserve_s, trace_result_read_request_s;
    reg trace_result_read_response_s, trace_scrub_s;
    reg [6:0] trace_internal_vector_s;
    reg [4:0] trace_internal_group_s;
    reg [9:0] trace_internal_index_s;
    reg [10:0] trace_result_issued_prev;
    reg scrub_prev_a, scrub_prev_b;

`ifdef SYNTHESIS
    localparam TRACE_FILE = "05_audit/current/18/m1/step12b_rtl_event_trace_synthesis.csv";
`else
    localparam TRACE_FILE = "05_audit/current/18/m1/step12b_rtl_event_trace_normal.csv";
`endif

    // Independent canonical DCT2-64 coefficient column A[i][1].  The
    // sparse test below injects only input[1][1]=100, so this single column
    // is sufficient to derive every expected 2-D output beat without using
    // RTL results as a golden source.
    function automatic integer coeff_col1(input integer idx);
        begin
            case (idx)
                0: coeff_col1=91;  1: coeff_col1=90;  2: coeff_col1=90;  3: coeff_col1=90;
                4: coeff_col1=88;  5: coeff_col1=87;  6: coeff_col1=86;  7: coeff_col1=84;
                8: coeff_col1=83;  9: coeff_col1=81; 10: coeff_col1=79; 11: coeff_col1=77;
               12: coeff_col1=73; 13: coeff_col1=71; 14: coeff_col1=69; 15: coeff_col1=65;
               16: coeff_col1=62; 17: coeff_col1=59; 18: coeff_col1=56; 19: coeff_col1=52;
               20: coeff_col1=48; 21: coeff_col1=44; 22: coeff_col1=41; 23: coeff_col1=37;
               24: coeff_col1=33; 25: coeff_col1=28; 26: coeff_col1=24; 27: coeff_col1=20;
               28: coeff_col1=15; 29: coeff_col1=11; 30: coeff_col1=7;  31: coeff_col1=2;
               32: coeff_col1=-2; 33: coeff_col1=-7; 34: coeff_col1=-11;35: coeff_col1=-15;
               36: coeff_col1=-20;37: coeff_col1=-24;38: coeff_col1=-28;39: coeff_col1=-33;
               40: coeff_col1=-37;41: coeff_col1=-41;42: coeff_col1=-44;43: coeff_col1=-48;
               44: coeff_col1=-52;45: coeff_col1=-56;46: coeff_col1=-59;47: coeff_col1=-62;
               48: coeff_col1=-65;49: coeff_col1=-69;50: coeff_col1=-71;51: coeff_col1=-73;
               52: coeff_col1=-77;53: coeff_col1=-79;54: coeff_col1=-81;55: coeff_col1=-83;
               56: coeff_col1=-84;57: coeff_col1=-86;58: coeff_col1=-87;59: coeff_col1=-88;
               60: coeff_col1=-90;61: coeff_col1=-90;62: coeff_col1=-90;63: coeff_col1=-91;
              default: coeff_col1=0;
            endcase
        end
    endfunction

    function automatic integer wrap16_i(input integer value);
        integer u;
        begin
            u = value & 32'hffff;
            if (u & 32'h8000) wrap16_i = u - 32'h10000;
            else wrap16_i = u;
        end
    endfunction

    function automatic [9:0] expected_point(input integer row, input integer col);
        integer stage1;
        integer raw2;
        begin
            // Stage-1 vertical: only column 1 has input value 100.
            stage1 = wrap16_i((coeff_col1(row) * 100 + 32) >>> 6);
            // Stage-2 horizontal: only intermediate column 1 is non-zero.
            raw2 = coeff_col1(col) * stage1;
            expected_point = wrap16_i((raw2 + 32) >>> 6) & 10'h3ff;
        end
    endfunction

    function automatic [39:0] expected_beat(input integer row, input integer group);
        integer k;
        begin
            expected_beat = 40'd0;
            for (k = 0; k < 4; k = k + 1)
                expected_beat[k*10 +: 10] = expected_point(row, group*4+k);
        end
    endfunction

    always #1 clk = ~clk;

    initial begin
        trace_fd = $fopen(TRACE_FILE, "w");
        trace_cycle = 0;
        if (trace_fd == 0) $fatal(1, "cannot open RTL event trace");
        $fwrite(trace_fd, "cycle,event,phase,vector,group,index,addr,end,cache,bank,request_id\n");
    end

    // The CSV is a transaction-edge trace.  Predicates and tags are captured
    // before NBA at the accepting rising edge; #1step only defers file I/O.
    // Post-NBA visibility is checked separately for it_done below.
    always @(posedge clk) begin
        if (!rst_n) begin
            trace_cycle = 0;
        end else begin
            trace_input_s = it_data_in_vld && it_data_in_req;
            trace_start_s = dut.r4c_start;
            trace_result_s = dut.r4c_result_valid;
            trace_fire_s = dut.result_hold_valid && it_data_out_req;
            trace_addr_s = it_data_addr;
            trace_end_s = it_data_end;
            trace_start_vid_s = dut.r4c_vector_id;
            trace_vid_s = dut.r4c_result_vector_id;
            trace_group_s = dut.r4c_result_group;
            trace_index_s = dut.result_read_index;
            trace_phase_s = dut.phase;
            // The completion transaction is the final output_fire, not a
            // mixed pre/post-NBA read of the it_done register.
            trace_done_s = trace_fire_s && (trace_index_s == 10'd1023);
            // M1 staging capture is the response edge of the explicit
            // request metadata pipeline, not the edge that launches the
            // next request.  A group-15 response is the stage_full event.
            trace_stage_capture_s = dut.stage_read_pending &&
                                    (dut.stage_read_group == 5'd15);
            trace_intermediate_write_s = trace_result_s && (dut.phase == 2'd1);
            trace_result_reserve_s = (dut.phase == 2'd3) && !dut.result_owner_valid;
            // A response and a new request may share one edge.  Therefore a
            // request is detected from the post-NBA issued-count increment,
            // not from the pre-edge pending bit alone.
            trace_result_read_request_s = 1'b0;
            trace_result_read_response_s = dut.result_read_pending;
            trace_scrub_s = 1'b0;
            trace_internal_vector_s = dut.stage_read_vector;
            trace_internal_group_s = dut.stage_read_group;
            trace_internal_index_s = dut.result_issue_index;
            #1step;
            trace_cycle = trace_cycle + 1;
            if (it_done !== trace_done_s) begin
                done_postnba_errors = done_postnba_errors + 1;
                $fatal(1, "it_done post-NBA mismatch at transaction cycle %0d expected=%0d got=%0d",
                       trace_cycle, trace_done_s, it_done);
            end
            if (trace_input_s)
                $fwrite(trace_fd, "%0d,input_fire,%0d,,,,%0d,%0d\n", trace_cycle,
                        trace_phase_s, trace_addr_s, trace_end_s);
            if (trace_start_s)
                $fwrite(trace_fd, "%0d,vector_start,%0d,%0d,,,,\n", trace_cycle,
                        trace_phase_s, trace_start_vid_s);
            if (trace_result_s) begin
                $fwrite(trace_fd, "%0d,kernel_group,%0d,%0d,%0d,,,\n", trace_cycle,
                        trace_phase_s, trace_vid_s, trace_group_s);
                if (trace_phase_s == 2)
                    $fwrite(trace_fd, "%0d,result_write,%0d,%0d,%0d,,,\n", trace_cycle,
                            trace_phase_s, trace_vid_s, trace_group_s);
            end
            if (trace_fire_s)
                $fwrite(trace_fd, "%0d,output_fire,,,,%0d,,\n", trace_cycle,
                        trace_index_s);
            if (trace_done_s)
                $fwrite(trace_fd, "%0d,it_done,,,,,,\n", trace_cycle);
            if (trace_stage_capture_s)
                $fwrite(trace_fd, "%0d,stage_capture,%0d,%0d,%0d,%0d,,\n", trace_cycle,
                        trace_phase_s, trace_internal_vector_s, trace_internal_group_s,
                        trace_internal_vector_s);
            if (trace_intermediate_write_s)
                $fwrite(trace_fd, "%0d,intermediate_write,%0d,%0d,%0d,,,%0d\n", trace_cycle,
                        trace_phase_s, trace_vid_s, trace_group_s, trace_group_s);
            if (trace_result_reserve_s)
                $fwrite(trace_fd, "%0d,result_reserve,%0d,,,,,,\n", trace_cycle, trace_phase_s);
            if (trace_result_read_request_s)
                $fwrite(trace_fd, "%0d,result_read_request,%0d,,,%0d,,\n", trace_cycle,
                        trace_phase_s, trace_internal_index_s);
            if (dut.result_issued != trace_result_issued_prev) begin
                $fwrite(trace_fd, "%0d,result_read_request,%0d,,,%0d,,\n", trace_cycle,
                        trace_phase_s, (dut.result_issued - 1'b1));
            end
            if (trace_result_read_response_s)
                $fwrite(trace_fd, "%0d,result_read_response,%0d,,,%0d,,\n", trace_cycle,
                        trace_phase_s, trace_internal_index_s);
            trace_result_issued_prev = dut.result_issued;
        end
    end

    // Scrub is a physical tag-bank transaction.  Observe it on the falling
    // edge after the accepting rising edge so the just-completed index is
    // unambiguous, without adding any DUT instrumentation.  While a cache
    // remains in SCRUB, scrub_index=N means index N-1 was cleared on the
    // preceding edge; the first edge therefore records index 0.  The edge
    // that leaves SCRUB records the final index 1023.
    always @(negedge clk) begin
        if (!rst_n) begin
            scrub_prev_a = 1'b0;
            scrub_prev_b = 1'b0;
        end else begin
            if (dut.cache_scrubbing[0]) begin
                if (dut.scrub_index[0] != 0) begin
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,%0d,,A,0,\n", trace_cycle, dut.scrub_index[0]-1'b1);
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,%0d,,A,1,\n", trace_cycle, dut.scrub_index[0]-1'b1);
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,%0d,,A,2,\n", trace_cycle, dut.scrub_index[0]-1'b1);
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,%0d,,A,3,\n", trace_cycle, dut.scrub_index[0]-1'b1);
                end
                scrub_prev_a = 1'b1;
            end else begin
                if (scrub_prev_a) begin
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,1023,,A,0,\n", trace_cycle);
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,1023,,A,1,\n", trace_cycle);
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,1023,,A,2,\n", trace_cycle);
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,1023,,A,3,\n", trace_cycle);
                end
                scrub_prev_a = 1'b0;
            end
            if (dut.cache_scrubbing[1]) begin
                if (dut.scrub_index[1] != 0) begin
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,%0d,,B,0,\n", trace_cycle, dut.scrub_index[1]-1'b1);
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,%0d,,B,1,\n", trace_cycle, dut.scrub_index[1]-1'b1);
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,%0d,,B,2,\n", trace_cycle, dut.scrub_index[1]-1'b1);
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,%0d,,B,3,\n", trace_cycle, dut.scrub_index[1]-1'b1);
                end
                scrub_prev_b = 1'b1;
            end else begin
                if (scrub_prev_b) begin
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,1023,,B,0,\n", trace_cycle);
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,1023,,B,1,\n", trace_cycle);
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,1023,,B,2,\n", trace_cycle);
                    $fwrite(trace_fd, "%0d,epoch_scrub,0,,,,1023,,B,3,\n", trace_cycle);
                end
                scrub_prev_b = 1'b0;
            end
        end
    end
    always @(posedge clk) begin
        if (rst_n && dut.r4c_start) $display("WRAP_START t=%0t phase=%0d lc=%0d lb=%0d readyA=%0d readyB=%0d since=%0d", $time, dut.phase, dut.launch_count, dut.launch_bank, dut.stage_ready_a, dut.stage_ready_b, dut.cycles_since_launch);
        if (rst_n && dut.r4c_result_valid && dut.r4c_result_last) $display("WRAP_LAST t=%0t phase=%0d vid=%0d", $time, dut.phase, dut.r4c_result_vector_id);
    end

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
        cycles = 0; fires = 0; data_errors = 0; hold_errors = 0;
        done_postnba_errors = 0;
        last_fire_cycle = -1; fire_ii_errors = 0; held_data = 0;
        stall_active = 1'b0; stall_valid = 1'b0; stall_data = 40'd0;
        trace_result_issued_prev = 11'd0;
        repeat (4) @(posedge clk);
        rst_n <= 1;
        @(posedge clk);
        // Descriptor bind; data is deliberately sent from the next cycle.
        it_info <= 22'h002040;
        it_info_vld <= 1;
        @(posedge clk);
        it_info_vld <= 0;
        wait (it_data_in_req);
        @(posedge clk);
        // Deterministic sparse non-zero input.  data+end on the same accepted
        // edge verifies that the final write is included before TU READY.
        it_data_addr <= 12'd65; // raster address (row=1,col=1)
        it_data_in <= 16'sd100;
        it_data_in_vld <= 1'b1;
        it_data_end <= 1;
        @(posedge clk);
        it_data_in_vld <= 1'b0;
        it_data_end <= 0;
        while (cycles < 8000) begin
            // At each negedge, drive the request for the next accepting edge
            // and inspect the currently held response.  The corresponding
            // fire occurs on the following posedge; this avoids counting a
            // response after it_done has already been asserted.
            @(negedge clk);
            cycles = cycles + 1;
            // Exercise the C request / C+1 response hold contract with a
            // deterministic 1->0 transition pattern.
            if ((cycles % 19) >= 5 && (cycles % 19) <= 8)
                it_data_out_req = 1'b0;
            else
                it_data_out_req = 1'b1;
            // Allow the combinational external vld (which is gated by the
            // newly driven req) to settle before sampling this accepting edge.
            #1step;
            // Official protocol: vld must be low while req is low.  The
            // internal hold/data must still remain stable until recovery.
            if (!it_data_out_req) begin
                if (it_data_out_vld)
                    hold_errors = hold_errors + 1;
                if (!stall_active) begin
                    stall_active = 1'b1;
                    stall_valid = dut.result_hold_valid;
                    if (dut.result_hold_valid)
                        stall_data = dut.result_hold_data;
                end else if (dut.result_hold_valid) begin
                    if (stall_valid && dut.result_hold_data !== stall_data)
                        hold_errors = hold_errors + 1;
                    else if (!stall_valid) begin
                        stall_valid = 1'b1;
                        stall_data = dut.result_hold_data;
                    end
                end
            end else begin
                stall_active = 1'b0;
                stall_valid = 1'b0;
            end
            if (!it_data_out_req)
                last_fire_cycle = -1;
            held_data = it_data_out;
            if (it_data_out_vld && it_data_out_req) begin
                if (last_fire_cycle >= 0 && cycles - last_fire_cycle != 1 &&
                    (cycles - last_fire_cycle) > 1)
                    fire_ii_errors = fire_ii_errors + 1;
                last_fire_cycle = cycles;
                fires = fires + 1;
                if (it_data_out !== expected_beat((fires-1) / 16, (fires-1) % 16)) begin
                    data_errors = data_errors + 1;
                    if (data_errors < 4)
                        $display("DATA_MISMATCH beat=%0d got=%h exp=%h", fires-1,
                                 it_data_out, expected_beat((fires-1) / 16, (fires-1) % 16));
                end
            end
            if (it_done)
                break;
        end
        if (protocol_error) $fatal(1, "Step12B protocol_error asserted");
        if (!it_done) begin
            $display("Step12B timeout state phase=%0d result_occ=%0d rd=%0d issue=%0d pending=%0d hold=%0d skid=%0d final=%0d", dut.phase, dut.result_occupied, dut.result_read_index, dut.result_issue_index, dut.result_read_pending, dut.result_hold_valid, dut.result_skid_valid, dut.final_compute_seen);
            $fatal(1, "Step12B timeout");
        end
        if (fires != 1024) $fatal(1, "Step12B expected 1024 output beats, got %0d", fires);
        if (data_errors != 0) $fatal(1, "Step12B sparse data errors=%0d", data_errors);
        if (hold_errors != 0) $fatal(1, "Step12B output hold errors=%0d", hold_errors);
        if (fire_ii_errors != 0) $fatal(1, "Step12B ready-high output II errors=%0d", fire_ii_errors);
        $display("STEP12B_WRAPPER_PASS cycles=%0d output_beats=%0d", cycles, fires);
        $fclose(trace_fd);
        $finish;
    end
endmodule
