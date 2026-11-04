`timescale 1ns/1ps
// Repository-contained end attribution supplement. Drive DUT ports only;
// internal state is observed to verify sampling-edge preconditions.
// Each case resets independently, uses bounded waits, and checks output data/order.
module end_attribution_ordering_tb;

    // ------------------------------------------------------------------ DUT
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

    // ------------------------------------------------------- observed states
    localparam logic [2:0] SLOT_FREE = 3'd0;
    localparam logic [2:0] SLOT_OUT  = 3'd3;

    localparam logic [21:0] INFO_4x4 = 22'd4 | (22'd4 << 7);   // 4x4 DCT-II
    localparam logic signed [9:0] VAL_DC511 = 10'sd511;         // sat(32767)
    localparam logic signed [9:0] VAL_ZERO  = 10'sd0;

    integer beats = 0;
    integer dones = 0;

    always @(posedge clk) if (rst_n) begin
        if (it_data_out_vld && it_data_out_req) beats = beats + 1;
        if (it_done)                            dones = dones + 1;
    end

    // ----------------------------------------------------------- bookkeeping
    string cname;
    bit    case_failed;
    integer pass_cnt = 0, fail_cnt = 0;

    task automatic chk(input bit cond, input string what);
        if (cond) $display("   ok   %s", what);
        else begin
            $display("   FAIL %s", what);
            case_failed = 1;
        end
    endtask

    // ------------------------------------------------------------------ reset
    task automatic reset_dut();
        @(negedge clk);
        rst_n         = 1'b0;
        it_info       = 0;
        it_info_vld   = 1'b0;
        it_data_in    = 0;
        it_data_addr  = 0;
        it_data_in_vld= 1'b0;
        it_data_end   = 1'b0;
        it_data_out_req = 1'b0;
        beats = 0;
        dones = 0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
    endtask

    task automatic begin_case(input string n);
        cname       = n;
        case_failed = 1'b0;
        reset_dut();
        $display("---- %s ----", n);
    endtask

    task automatic end_case();
        if (case_failed) begin
            fail_cnt = fail_cnt + 1;
            $display("CASE %s RESULT=FAIL", cname);
        end else begin
            pass_cnt = pass_cnt + 1;
            $display("CASE %s RESULT=PASS", cname);
        end
    endtask

    // --------------------------------------------------------------- driving
    task automatic send_info(input logic [21:0] info);
        @(negedge clk);
        it_info     = info;
        it_info_vld = 1'b1;
        @(negedge clk);
        it_info     = 0;
        it_info_vld = 1'b0;
    endtask

    task automatic wait_req(input integer limit, output bit ok);
        integer i;
        ok = 1'b0;
        for (i = 0; i < limit; i = i + 1) begin
            @(negedge clk);
            if (it_data_in_req) begin ok = 1'b1; break; end
        end
    endtask

    // Caller must already hold it_data_in_req high.
    task automatic send_point(input logic [11:0] addr,
                              input logic signed [15:0] val,
                              input bit with_end);
        @(negedge clk);
        it_data_addr   = addr;
        it_data_in     = val;
        it_data_in_vld = 1'b1;
        it_data_end    = with_end;
        @(negedge clk);
        it_data_in_vld = 1'b0;
        it_data_end    = 1'b0;
        it_data_in     = 0;
    endtask

    // One sampling cycle of it_data_end.  Deliberately does NOT require
    // it_data_in_req -- that is the whole point of the contract.
    task automatic send_end_pulse();
        @(negedge clk);
        it_data_end = 1'b1;
        @(negedge clk);
        it_data_end = 1'b0;
    endtask

    // ----------------------------------------------------------------- waits
    task automatic wait_dones(input integer target, input integer limit, output bit ok);
        integer i;
        ok = 1'b0;
        for (i = 0; i < limit; i = i + 1) begin
            @(negedge clk);
            if (dones >= target) begin ok = 1'b1; break; end
        end
    endtask

    task automatic wait_slot(input integer slot, input logic [2:0] state,
                             input integer limit, output bit ok);
        integer i;
        ok = 1'b0;
        for (i = 0; i < limit; i = i + 1) begin
            @(negedge clk);
            if (dut.u_unified_wrapper.slot_state[slot] === state) begin ok = 1'b1; break; end
        end
    endtask

    // Drain exactly n output beats, checking every one against `expect`.
    task automatic drain(input integer n,
                         input logic signed [9:0] exp_val,
                         output bit ok,
                         output integer bad);
        integer i, got;
        ok  = 1'b0;
        bad = 0;
        got = 0;
        it_data_out_req = 1'b1;
        for (i = 0; i < 8000; i = i + 1) begin
            @(posedge clk);
            if (it_data_out_vld && it_data_out_req) begin
                if (it_data_out !== {exp_val, exp_val, exp_val, exp_val}) bad = bad + 1;
                got = got + 1;
                if (got >= n) begin ok = 1'b1; break; end
            end
        end
        @(negedge clk);
        it_data_out_req = 1'b0;
    endtask

    // Send a zero TU and let it settle into SLOT_OUT (never drained), so its
    // slot stays busy.  Used to build "both slots occupied" states.
    task automatic occupy_out(input logic [21:0] info, output bit ok);
        bit rok, sok;
        send_info(info);
        wait_req(4000, rok);
        if (rok) send_end_pulse();
        // One of the two slots reaches OUT (bind prefers slot 0, then slot 1).
        ok = 1'b0;
        begin : occupy_wait
            integer i;
            for (i = 0; i < 8000; i = i + 1) begin
                @(negedge clk);
                if (dut.u_unified_wrapper.slot_state[0] === SLOT_OUT ||
                    dut.u_unified_wrapper.slot_state[1] === SLOT_OUT) begin
                    ok = 1'b1;
                    disable occupy_wait;
                end
            end
        end
    endtask

    // ------------------------------------------------------------------ sync
    bit  ok_req, ok_drain, ok_done, ok_slot, ok_occ;
    integer bad_beats;
    integer i;
    bit caught;


    always @(posedge clk) if(rst_n && it_data_out_vld && it_data_out_req)
        $display("ORDER_SAMPLE time=%0t word=%010h done=%b",$time,it_data_out,it_done);
    initial begin
        begin_case("S03_final_write_commit_overlaps_next_bind");
        occupy_out(INFO_4x4,ok_occ);chk(ok_occ,"A owns slot0");
        send_info(INFO_4x4);wait_req(4000,ok_req);chk(ok_req,"B fills slot1");
        send_info(INFO_4x4);chk(dut.u_unified_wrapper.desc_count==1,"C queued while B fills");
        drain(3,VAL_ZERO,ok_drain,bad_beats);chk(ok_drain && bad_beats==0,"first three A beats");
        @(negedge clk);
        it_data_out_req=1;it_data_addr=0;it_data_in=32767;it_data_in_vld=1;it_data_end=1;
        @(posedge clk);
        chk(it_done && it_data_out_vld && it_data_in_req,"A final output and B final input accepted together");
        @(negedge clk);it_data_out_req=0;it_data_in_vld=0;it_data_end=0;
        chk(dut.u_unified_wrapper.slot_state[0]==SLOT_FREE &&
            dut.u_unified_wrapper.desc_count==1 &&
            dut.u_unified_wrapper.fill_end_pending_q && dut.u_unified_wrapper.fill_wr_cmd_commit,
            "C queued and slot0 free while B final write commits");
        $display("COVER_BIND_BARRIER blocked=%0d", !dut.u_unified_wrapper.bind_event);
        @(posedge clk);
        chk(!dut.u_unified_wrapper.compute_valid,"B not READY before commit edge");
        @(negedge clk);
        chk(dut.u_unified_wrapper.slot_state[1]==2,"older B becomes READY after commit");
        send_end_pulse(); // independent end for C; B's end was on a separate edge
        drain(4,10'sd511,ok_drain,bad_beats);
        $display("ORDER_CHECK expected_TU=B expected_value=511 completed=%0d bad_beats=%0d",ok_drain,bad_beats);
        chk(ok_drain && bad_beats==0,"older B must output before C");
        drain(4,10'sd0,ok_drain,bad_beats);
        $display("ORDER_CHECK expected_TU=C expected_value=0 completed=%0d bad_beats=%0d",ok_drain,bad_beats);
        chk(ok_drain && bad_beats==0,"younger zero C follows B");
        chk(beats==12 && dones==3,"three complete TUs");
        chk(!dut.u_unified_wrapper.protocol_error,"stimulus remains legal");
        end_case();
        $finish;
    end
    initial begin #100000;$fatal(1,"ordering timeout");end
endmodule
