`timescale 1ns/1ps
// P4: reset and first-read safety.
//
// Two things are checked and reported separately:
//   (a) outputs are never X while it_data_out_vld is high, across every phase;
//   (b) after a reset injected into any phase, the very next TU still produces
//       the exact golden vector, i.e. no stale state survives the reset.
//
// A phase that is never actually entered fails the case, so a "reset test"
// cannot silently pass by resetting an idle design.
module reset_first_read_tb;

    logic clk = 0;
    always #1 clk = ~clk;

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

    localparam logic [21:0] INFO_L1 = 22'h100204;   // 4x4 set0 lfnst1, dc=+512
    localparam logic [21:0] INFO_P  = 22'h000204;   // 4x4 DCT-II, dc=+32767

    localparam logic [159:0] VEC_L1 = {
        10'sd15,  10'sd7, 10'sd13,  10'sd5, 10'sd24,  10'sd4, 10'sd16, 10'sd14,
        10'sd32,  10'sd9, 10'sd14, 10'sd11, 10'sd30, 10'sd12,  10'sd8,  10'sd1};

    function automatic logic signed [9:0] vec_l1(input integer idx);
        vec_l1 = VEC_L1[idx*10 +: 10];
    endfunction

    // ---------------------------------------------------------- X observability
    integer x_out_violations = 0;
    integer x_done_violations = 0;
    integer vld_cycles = 0;
    always @(posedge clk) if (rst_n) begin
        if (it_data_out_vld === 1'b1) begin
            vld_cycles = vld_cycles + 1;
            if ($isunknown(it_data_out)) x_out_violations = x_out_violations + 1;
            if ($isunknown(it_done))     x_done_violations = x_done_violations + 1;
        end
    end

    // ------------------------------------------------------------- bookkeeping
    string  cname;
    bit     case_failed;
    integer pass_cnt = 0, fail_cnt = 0;

    task automatic chk(input bit cond, input string what);
        if (cond) $display("   ok   %s", what);
        else begin $display("   FAIL %s", what); case_failed = 1; end
    endtask

    task automatic begin_case(input string n);
        cname = n; case_failed = 1'b0;
        $display("---- %s ----", n);
    endtask

    task automatic end_case();
        if (case_failed) begin fail_cnt = fail_cnt + 1; $display("CASE %s RESULT=FAIL", cname); end
        else             begin pass_cnt = pass_cnt + 1; $display("CASE %s RESULT=PASS", cname); end
    endtask

    // ----------------------------------------------------------------- driving
    task automatic hard_reset();
        @(negedge clk);
        rst_n = 1'b0; it_info = 0; it_info_vld = 0; it_data_in = 0;
        it_data_addr = 0; it_data_in_vld = 0; it_data_end = 0; it_data_out_req = 0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
    endtask

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

    task automatic send_point_end(input logic [11:0] addr, input logic signed [15:0] val);
        @(negedge clk);
        it_data_addr = addr; it_data_in = val;
        it_data_in_vld = 1'b1; it_data_end = 1'b1;
        @(negedge clk);
        it_data_in_vld = 1'b0; it_data_end = 1'b0; it_data_in = 0; it_data_addr = 0;
    endtask

    // Full known-good TU: descriptor, single DC point carrying end, drain 4 beats.
    task automatic run_l1(output bit ok, output integer bad);
        bit rok, dok;
        integer i, got, lane;
        ok = 1'b0; bad = 0;
        send_info(INFO_L1);
        wait_req(20000, rok);
        if (!rok) begin $display("   run_l1: input request timeout"); return; end
        send_point_end(12'd0, 16'sd512);
        it_data_out_req = 1'b1;
        got = 0;
        for (i = 0; i < 20000; i = i + 1) begin
            @(posedge clk);
            if (it_data_out_vld && it_data_out_req) begin
                for (lane = 0; lane < 4; lane = lane + 1)
                    if ($signed(it_data_out[lane*10 +: 10]) !== vec_l1(got*4 + lane))
                        bad = bad + 1;
                got = got + 1;
                if (got >= 4) begin ok = 1'b1; break; end
            end
        end
        @(negedge clk);
        it_data_out_req = 1'b0;
    endtask

    // Wait for a target phase, bounded.
    task automatic wait_phase(input integer which, input integer limit, output bit ok);
        integer i;
        ok = 1'b0;
        for (i = 0; i < limit; i = i + 1) begin
            @(negedge clk);
            case (which)
              0: if (dut.u_unified_wrapper.scrub_active) begin ok = 1'b1; break; end
              1: if (dut.u_unified_wrapper.fill_active) begin ok = 1'b1; break; end
              2: if (dut.u_unified_wrapper.lfnst_run_q) begin ok = 1'b1; break; end
              3: if (dut.u_unified_wrapper.output_active && !it_data_out_req)
                     begin ok = 1'b1; break; end
              default: ok = 1'b0;
            endcase
        end
    endtask

    // ------------------------------------------------------------------- main
    bit     ok_a, ok_b, ok_c;
    integer bad_a, bad_b;

    initial begin
        x_out_violations = 0;
        x_done_violations = 0;
        vld_cycles = 0;
        hard_reset();

        // ---- R1: reset while the slot is scrubbing ----------------------
        begin_case("R1_reset_during_scrub");
        send_info(INFO_L1);
        wait_phase(0, 5000, ok_a);
        chk(ok_a, "scrub phase entered");
        hard_reset();
        chk(dut.u_unified_wrapper.slot_state[0] == 3'd0 &&
            dut.u_unified_wrapper.slot_state[1] == 3'd0 &&
            dut.u_unified_wrapper.desc_count == 2'd0, "all slots and queue cleared");
        run_l1(ok_b, bad_a);
        chk(ok_b && bad_a == 0, "first TU after scrub reset is exact");
        end_case();

        // ---- R2: reset while the slot is accepting input ----------------
        begin_case("R2_reset_during_fill");
        send_info(INFO_P);
        wait_req(20000, ok_a);
        chk(ok_a, "fill phase entered");
        @(negedge clk);
        it_data_addr = 12'd0; it_data_in = 16'sd1000; it_data_in_vld = 1'b1;
        @(negedge clk);
        it_data_in_vld = 1'b0; it_data_in = 0;
        chk(dut.u_unified_wrapper.fill_active, "fill still active with partial data");
        hard_reset();
        run_l1(ok_b, bad_a);
        chk(ok_b && bad_a == 0, "first TU after fill reset is exact");
        end_case();

        // ---- R3: reset during the LFNST phase ---------------------------
        begin_case("R3_reset_during_lfnst");
        send_info(INFO_L1);
        wait_req(20000, ok_a);
        if (ok_a) send_point_end(12'd0, 16'sd512);
        wait_phase(2, 20000, ok_b);
        chk(ok_b, "LFNST phase entered");
        hard_reset();
        run_l1(ok_c, bad_a);
        chk(ok_c && bad_a == 0, "first TU after LFNST reset is exact");
        end_case();

        // ---- R4: reset during a stalled output --------------------------
        begin_case("R4_reset_during_output_stall");
        send_info(INFO_P);
        wait_req(20000, ok_a);
        if (ok_a) send_point_end(12'd0, 16'sd32767);
        wait_phase(3, 20000, ok_b);
        chk(ok_b, "output asserted with req low");
        repeat (50) @(negedge clk);
        hard_reset();
        run_l1(ok_c, bad_a);
        chk(ok_c && bad_a == 0, "first TU after output reset is exact");
        end_case();

        // ---- R5: reset with descriptors queued --------------------------
        begin_case("R5_reset_with_queued_descriptors");
        send_info(INFO_L1);
        send_info(INFO_L1);
        send_info(INFO_L1);
        chk(dut.u_unified_wrapper.desc_count != 2'd0, "descriptor queued before reset");
        hard_reset();
        chk(dut.u_unified_wrapper.desc_count == 2'd0, "queue cleared by reset");
        run_l1(ok_b, bad_a);
        chk(ok_b && bad_a == 0, "first TU after queue reset is exact");
        run_l1(ok_c, bad_b);
        chk(ok_c && bad_b == 0, "second TU after queue reset is exact");
        end_case();

        // ---- X containment summary --------------------------------------
        $display("P4_XCHECK vld_cycles=%0d x_out=%0d x_done=%0d",
                 vld_cycles, x_out_violations, x_done_violations);
        chk(x_out_violations == 0, "no X on it_data_out while vld is high");
        chk(x_done_violations == 0, "no X on it_done while vld is high");

        $display("RESET_FIRST_READ_TB pass=%0d fail=%0d", pass_cnt, fail_cnt);
        if (fail_cnt != 0) $fatal(1, "reset / first-read scenarios failed");
        $finish;
    end

    initial begin #1500000; $fatal(1, "P4 timeout"); end
endmodule