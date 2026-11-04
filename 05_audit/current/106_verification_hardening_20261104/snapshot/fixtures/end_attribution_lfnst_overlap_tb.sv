`timescale 1ns/1ps
// P1: LFNST / primary-transform overlap scenarios.
// Drives DUT ports only; internal state is observed solely to confirm that the
// target overlap state was actually entered (a scenario that never reaches its
// target state counts as a FAIL, regardless of the data being correct).
//
// TU definitions (4x4, DCT-II, single DC coefficient):
//   L1 = set0 / lfnst_idx1 / dc=+512   -> distinguishable vector
//   L2 = set1 / lfnst_idx2 / dc=-512   -> distinguishable vector
//   P  = no LFNST       / dc=+32767    -> all lanes saturate to 511
module end_attribution_lfnst_overlap_tb;

    logic clk = 0;
    always #1 clk = ~clk;                 // 2 ns period == 500 MHz

    logic rst_n = 0;
    logic [21:0] it_info = 0;
    logic it_info_vld = 0;
    logic signed [15:0] it_data_in = 0;
    logic [11:0] it_data_addr = 0;
    logic it_data_in_vld = 0;
    logic it_data_end = 0;
    logic it_data_out_req = 0;
    wire  it_data_in_req;
    wire  it_data_out_vld;
    wire  it_done;
    wire  [39:0] it_data_out;

    its_unified_submission_top dut(.*);

    // ------------------------------------------------------------- encodings
    localparam logic [21:0] INFO_L1 = 22'h100204;  // 4x4 set0 lfnst1
    localparam logic [21:0] INFO_L2 = 22'h240204;  // 4x4 set1 lfnst2
    localparam logic [21:0] INFO_P  = 22'h000204;  // 4x4 DCT-II, no LFNST

    // Expected 10-bit output, raster order, packed little-endian by index.
    localparam logic [159:0] VEC_L1 = {
        10'sd15,  10'sd7, 10'sd13,  10'sd5, 10'sd24,  10'sd4, 10'sd16, 10'sd14,
        10'sd32,  10'sd9, 10'sd14, 10'sd11, 10'sd30, 10'sd12,  10'sd8,  10'sd1};
    localparam logic [159:0] VEC_L2 = {
        -10'sd25, -10'sd10, -10'sd13, 10'sd19, -10'sd16, -10'sd15, -10'sd18, 10'sd6,
        -10'sd12, -10'sd22, -10'sd18, 10'sd0, -10'sd11, -10'sd22, -10'sd22, 10'sd1};
    localparam logic [159:0] VEC_P  = {
        10'sd511, 10'sd511, 10'sd511, 10'sd511, 10'sd511, 10'sd511, 10'sd511, 10'sd511,
        10'sd511, 10'sd511, 10'sd511, 10'sd511, 10'sd511, 10'sd511, 10'sd511, 10'sd511};

    function automatic logic signed [9:0] vec_sel(input integer tu, input integer idx);
        logic [159:0] v;
        begin
            if (tu == 0)      v = VEC_L1;
            else if (tu == 1) v = VEC_L2;
            else              v = VEC_P;
            vec_sel = v[idx*10 +: 10];
        end
    endfunction

    // --------------------------------------------------------- coverage hooks
    integer cov_lfnst_active = 0;
    integer cov_desc_while_lfnst = 0;
    integer cov_kernel_and_lfnst = 0;
    integer cov_stall = 0;
    integer cov_queue_two = 0;
    integer cov_vld_without_req = 0;   // must stay 0: the output contract is req-gated

    always @(posedge clk) if (rst_n) begin
        if (dut.u_unified_wrapper.lfnst_run_q) cov_lfnst_active = cov_lfnst_active + 1;
        if (dut.u_unified_wrapper.lfnst_run_q && dut.u_unified_wrapper.desc_push)
            cov_desc_while_lfnst = cov_desc_while_lfnst + 1;
        if (dut.u_unified_wrapper.lfnst_run_q && dut.u_unified_wrapper.kernel_run_q)
            cov_kernel_and_lfnst = cov_kernel_and_lfnst + 1;
        if (dut.u_unified_wrapper.output_active && !it_data_out_req)
            cov_stall = cov_stall + 1;
        if (it_data_out_vld && !it_data_out_req) cov_vld_without_req = cov_vld_without_req + 1;
        if (dut.u_unified_wrapper.desc_count == 2'd2) cov_queue_two = cov_queue_two + 1;
    end

    integer beats = 0;
    integer dones = 0;
    always @(posedge clk) if (rst_n) begin
        if (it_data_out_vld && it_data_out_req) beats = beats + 1;
        if (it_done)                            dones = dones + 1;
    end

    // ----------------------------------------------------------- bookkeeping
    string  cname;
    bit     case_failed;
    integer pass_cnt = 0, fail_cnt = 0;

    task automatic chk(input bit cond, input string what);
        if (cond) $display("   ok   %s", what);
        else begin $display("   FAIL %s", what); case_failed = 1; end
    endtask

    task automatic reset_dut();
        @(negedge clk);
        rst_n = 1'b0; it_info = 0; it_info_vld = 1'b0;
        it_data_in = 0; it_data_addr = 0; it_data_in_vld = 1'b0;
        it_data_end = 1'b0; it_data_out_req = 1'b0;
        beats = 0; dones = 0;
        cov_lfnst_active = 0; cov_desc_while_lfnst = 0;
        cov_kernel_and_lfnst = 0; cov_stall = 0; cov_queue_two = 0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
    endtask

    task automatic begin_case(input string n);
        cname = n; case_failed = 1'b0; reset_dut();
        $display("---- %s ----", n);
    endtask

    task automatic end_case();
        if (case_failed) begin fail_cnt = fail_cnt + 1; $display("CASE %s RESULT=FAIL", cname); end
        else             begin pass_cnt = pass_cnt + 1; $display("CASE %s RESULT=PASS", cname); end
    endtask

    // --------------------------------------------------------------- driving
    task automatic send_info(input logic [21:0] info);
        @(negedge clk);
        it_info = info; it_info_vld = 1'b1;
        @(negedge clk);
        it_info = 0; it_info_vld = 1'b0;
    endtask

    task automatic wait_req(input integer limit, output bit ok);
        integer i;
        ok = 1'b0;
        for (i = 0; i < limit; i = i + 1) begin
            @(negedge clk);
            if (it_data_in_req) begin ok = 1'b1; break; end
        end
    endtask

    // Send one point that also carries it_data_end, i.e. last data + end together.
    task automatic send_point_end(input logic [11:0] addr, input logic signed [15:0] val);
        @(negedge clk);
        it_data_addr = addr; it_data_in = val;
        it_data_in_vld = 1'b1; it_data_end = 1'b1;
        @(negedge clk);
        it_data_in_vld = 1'b0; it_data_end = 1'b0; it_data_in = 0; it_data_addr = 0;
    endtask

    // Feed one TU: wait for request, then deliver its single DC point with end.
    task automatic feed_tu(input logic signed [15:0] dc, output bit ok);
        wait_req(6000, ok);
        if (ok) send_point_end(12'd0, dc);
    endtask

    // Drain n consecutive output beats of TU `tu`, starting at beat index `base`.
    task automatic drain_beats(input integer tu, input integer base, input integer n,
                               output bit ok, output integer bad);
        integer i, got, lane;
        ok = 1'b0; bad = 0; got = 0;
        it_data_out_req = 1'b1;
        for (i = 0; i < 8000; i = i + 1) begin
            @(posedge clk);
            if (it_data_out_vld && it_data_out_req) begin
                for (lane = 0; lane < 4; lane = lane + 1)
                    if ($signed(it_data_out[lane*10 +: 10]) !== vec_sel(tu, (base+got)*4 + lane))
                        bad = bad + 1;
                got = got + 1;
                if (got >= n) begin ok = 1'b1; break; end
            end
        end
        @(negedge clk);
        it_data_out_req = 1'b0;
    endtask

    // Wait until the LFNST phase is actually entered.
    task automatic wait_lfnst_active(input integer limit, output bit ok);
        integer i;
        ok = 1'b0;
        for (i = 0; i < limit; i = i + 1) begin
            @(negedge clk);
            if (dut.u_unified_wrapper.lfnst_run_q) begin ok = 1'b1; break; end
        end
    endtask

    // Wait until the primary-transform kernel is running.
    task automatic wait_kernel_active(input integer limit, output bit ok);
        integer i;
        ok = 1'b0;
        for (i = 0; i < limit; i = i + 1) begin
            @(negedge clk);
            if (dut.u_unified_wrapper.kernel_run_q) begin ok = 1'b1; break; end
        end
    endtask

    // ------------------------------------------------------------------ sync
    bit ok_a, ok_b, ok_c, ok_d;
    integer bad_a, bad_b;
    logic [39:0] held_word;
    integer held_bad, done_bad;

    initial begin
        // ---- S05: two LFNST TUs back-to-back plus a queued third ----------
        // Both slots can absorb one TU each, so a genuine queue depth of 2
        // needs a third descriptor.
        begin_case("S05_two_lfnst_back_to_back");
        send_info(INFO_L1);
        send_info(INFO_L2);
        send_info(INFO_P);
        chk(dut.u_unified_wrapper.desc_count != 2'd0, "third descriptor queued");
        feed_tu(16'sd512,  ok_a);  chk(ok_a, "L1 input request served");
        feed_tu(-16'sd512, ok_b);  chk(ok_b, "L2 input request served");
        // Both slots are now occupied; the third TU can only bind once a slot
        // frees, so drain the first two before serving it.
        drain_beats(0, 0, 4, ok_c, bad_a);
        chk(ok_c && bad_a == 0, "L1 vector intact");
        drain_beats(1, 0, 4, ok_d, bad_b);
        chk(ok_d && bad_b == 0, "L2 vector intact and after L1");
        feed_tu(16'sd32767, ok_c); chk(ok_c, "queued third TU input served after slot freed");
        drain_beats(2, 0, 4, ok_c, bad_a);
        chk(ok_c && bad_a == 0, "queued TU follows in order");
        chk(beats == 12 && dones == 3, "three complete TUs");
        chk(cov_queue_two > 0, "queue depth 2 actually reached");
        chk(!dut.u_unified_wrapper.protocol_error, "stimulus remains legal");
        $display("COVER_P1 case=S05 lfnst_active=%0d queue_two=%0d kernel_and_lfnst=%0d",
                 cov_lfnst_active, cov_queue_two, cov_kernel_and_lfnst);
        end_case();

        // ---- S06: LFNST TU, descriptor of a plain TU arrives during LFNST --
        begin_case("S06_lfnst_then_plain_descriptor_during_lfnst");
        send_info(INFO_L1);
        feed_tu(16'sd512, ok_a); chk(ok_a, "L1 input served");
        wait_lfnst_active(6000, ok_b);
        chk(ok_b, "L1 LFNST phase entered");
        send_info(INFO_P);
        feed_tu(16'sd32767, ok_c); chk(ok_c, "P input served during/after L1 LFNST");
        drain_beats(0, 0, 4, ok_d, bad_a); chk(ok_d && bad_a == 0, "L1 vector intact");
        drain_beats(2, 0, 4, ok_d, bad_b); chk(ok_d && bad_b == 0, "plain TU follows with 511");
        chk(beats == 8 && dones == 2, "two complete TUs");
        chk(cov_lfnst_active > 0, "LFNST phase actually exercised");
        chk(cov_desc_while_lfnst > 0, "descriptor accepted while LFNST active");
        chk(!dut.u_unified_wrapper.protocol_error, "stimulus remains legal");
        $display("COVER_P1 case=S06 lfnst_active=%0d desc_while_lfnst=%0d kernel_and_lfnst=%0d",
                 cov_lfnst_active, cov_desc_while_lfnst, cov_kernel_and_lfnst);
        end_case();

        // ---- S07: plain TU, then a LFNST TU while the kernel runs ---------
        begin_case("S07_plain_then_lfnst");
        send_info(INFO_P);
        feed_tu(16'sd32767, ok_a); chk(ok_a, "P input served");
        wait_kernel_active(6000, ok_b);
        chk(ok_b, "primary kernel phase entered");
        send_info(INFO_L2);
        feed_tu(-16'sd512, ok_c); chk(ok_c, "L2 input served");
        drain_beats(2, 0, 4, ok_d, bad_a); chk(ok_d && bad_a == 0, "plain TU emits 511");
        drain_beats(1, 0, 4, ok_d, bad_b); chk(ok_d && bad_b == 0, "LFNST TU follows intact");
        chk(beats == 8 && dones == 2, "two complete TUs");
        chk(cov_lfnst_active > 0, "LFNST phase actually exercised");
        chk(!dut.u_unified_wrapper.protocol_error, "stimulus remains legal");
        $display("COVER_P1 case=S07 lfnst_active=%0d desc_while_lfnst=%0d kernel_and_lfnst=%0d",
                 cov_lfnst_active, cov_desc_while_lfnst, cov_kernel_and_lfnst);
        end_case();

        // ---- S08: LFNST overlap with a real output stall ------------------
        begin_case("S08_lfnst_overlap_with_output_stall");
        send_info(INFO_L1);
        feed_tu(16'sd512, ok_a); chk(ok_a, "L1 input served");
        wait_lfnst_active(6000, ok_b);
        chk(ok_b, "L1 LFNST phase entered");
        send_info(INFO_L2);
        feed_tu(-16'sd512, ok_c); chk(ok_c, "L2 input served while L1 LFNST active");
        drain_beats(0, 0, 1, ok_d, bad_a); chk(ok_d && bad_a == 0, "first L1 beat correct");
        // Real backpressure.  The output contract is req-gated: vld is a transfer
        // qualifier, so during the stall vld must stay low, the word must be held
        // and done must not pulse.  No beat may be lost.
        @(negedge clk); it_data_out_req = 1'b0;
        held_word = it_data_out;
        held_bad = 0; done_bad = 0;
        repeat (200) begin
            @(negedge clk);
            if (it_data_out !== held_word) held_bad = held_bad + 1;
            if (it_done)                   done_bad = done_bad + 1;
        end
        chk(cov_stall > 100, "output stall actually applied");
        chk(cov_vld_without_req == 0, "vld never asserted while req is low");
        chk(held_bad == 0, "output word held stable across the stall");
        chk(done_bad == 0, "done suppressed during the stall");
        drain_beats(0, 1, 3, ok_d, bad_a); chk(ok_d && bad_a == 0, "L1 tail intact after stall");
        drain_beats(1, 0, 4, ok_d, bad_b); chk(ok_d && bad_b == 0, "L2 intact after stall");
        chk(beats == 8 && dones == 2, "two complete TUs");
        chk(!dut.u_unified_wrapper.protocol_error, "stimulus remains legal");
        $display("COVER_P1 case=S08 lfnst_active=%0d desc_while_lfnst=%0d stall=%0d",
                 cov_lfnst_active, cov_desc_while_lfnst, cov_stall);
        end_case();

        $display("LFNST_OVERLAP_TB pass=%0d fail=%0d", pass_cnt, fail_cnt);
        if (fail_cnt != 0) $fatal(1, "LFNST overlap scenarios failed");
        $finish;
    end

    initial begin #600000; $fatal(1, "lfnst overlap timeout"); end
endmodule