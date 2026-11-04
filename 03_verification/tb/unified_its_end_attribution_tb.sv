`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// unified_its_end_attribution_tb
//
// Directed regression for the it_data_end attribution contract
// (01_docs/current/END_ATTRIBUTION_CONTRACT.md).
//
//   19 independent cases.  Every case starts from reset, runs with its own
//   bounded timeout, and reports PASS / FAIL on its own line.  A case that
//   times out does NOT abort the run: the loop leaves on its own limit and the
//   next case re-resets the DUT.  "Simulation exited" is never counted as a
//   detection.
//
//   Only DUT ports are driven.  Internal signals are read for observation and
//   for stimulus timing only -- nothing is forced, and no internal signal of
//   the post-fix design is referenced, so this file compiles against both the
//   pre-fix and the post-fix RTL.
//
//   Run from the repository root so the coefficient hex files resolve.
// -----------------------------------------------------------------------------
module unified_its_end_attribution_tb;

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

    // =========================================================================
    initial begin
        $display("END_ATTRIBUTION_TB begin");

        // ------------------------------------------------------------- C01 ---
        // Baseline: admitted fill, independent end after waiting for req.
        begin_case("C01_independent_end_after_req");
        send_info(INFO_4x4);
        wait_req(4000, ok_req);
        chk(ok_req, "input req opened");
        chk(dones == 0 && beats == 0, "no output before end");
        send_end_pulse();
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "4 output beats observed");
        chk(bad_beats == 0, "all beats zero");
        chk(dones == 1, "exactly one done");
        chk(!dut.u_unified_wrapper.protocol_error, "no protocol error");
        end_case();

        // ------------------------------------------------------------- C02 ---
        // End on the cycle after the last data, while its write cmd commits.
        begin_case("C02_end_at_pending_write");
        send_info(INFO_4x4);
        wait_req(4000, ok_req);
        chk(ok_req, "input req opened");
        send_point(12'd0, 16'sd32767, 1'b0);
        send_end_pulse();
        drain(4, VAL_DC511, ok_drain, bad_beats);
        chk(ok_drain, "4 output beats observed");
        chk(bad_beats == 0, "all beats saturate to 511");
        chk(dones == 1, "exactly one done");
        end_case();

        // ------------------------------------------------------------- C03 ---
        // End on the same cycle as the last data beat.
        begin_case("C03_end_with_last_data");
        send_info(INFO_4x4);
        wait_req(4000, ok_req);
        chk(ok_req, "input req opened");
        send_point(12'd0, 16'sd32767, 1'b1);
        drain(4, VAL_DC511, ok_drain, bad_beats);
        chk(ok_drain, "4 output beats observed");
        chk(bad_beats == 0, "all beats saturate to 511");
        chk(dones == 1, "exactly one done");
        end_case();

        // ------------------------------------------------------------- C04 ---
        // First TU after reset, data then independent end.
        begin_case("C04_first_tu_after_reset");
        send_info(INFO_4x4);
        wait_req(4000, ok_req);
        chk(ok_req, "input req opened");
        send_point(12'd0, 16'sd32767, 1'b0);
        send_end_pulse();
        drain(4, VAL_DC511, ok_drain, bad_beats);
        chk(ok_drain, "4 output beats observed");
        chk(bad_beats == 0, "all beats saturate to 511");
        chk(dones == 1, "exactly one done");
        end_case();

        // ------------------------------------------------------------- C05 ---
        // End asserted inside the descriptor scrub window (req low).
        begin_case("C05_end_during_scrub");
        send_info(INFO_4x4);
        ok_slot = 1'b0;
        for (i = 0; i < 4000; i = i + 1) begin
            @(negedge clk);
            if (dut.u_unified_wrapper.scrub_active) begin ok_slot = 1'b1; break; end
        end
        chk(ok_slot, "PRE: entered scrub window");
        chk(!it_data_in_req, "PRE: req low at end time");
        send_end_pulse();
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "4 output beats observed within limit");
        chk(bad_beats == 0, "all beats zero");
        chk(dones == 1, "exactly one done");
        end_case();

        // ------------------------------------------------------------- C06 ---
        // End for a descriptor that is queued but not bound (both slots out).
        begin_case("C06_end_for_queued_unbound");
        occupy_out(INFO_4x4, ok_occ);
        chk(ok_occ, "PRE: first TU reached SLOT_OUT");
        occupy_out(INFO_4x4, ok_occ);
        chk(ok_occ, "PRE: second TU reached SLOT_OUT");
        send_info(INFO_4x4);
        chk(dut.u_unified_wrapper.desc_count == 2'd1, "PRE: descriptor queued and unbound");
        chk(!dut.u_unified_wrapper.fill_active &&
            !dut.u_unified_wrapper.scrub_active, "PRE: no un-ended active TU");
        send_end_pulse();
        // Drain in completion order: TU1, TU2, then the queued TU.  Freeing a
        // slot lets the queued TU bind, consume its saved end, and finish.
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "first occupying TU drained");
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "second occupying TU drained");
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "queued TU produced 4 beats after binding");
        chk(bad_beats == 0, "queued TU output is zero");
        chk(dones == 3, "three done pulses");
        end_case();

        // ------------------------------------------------------------ C07a ---
        // Queue full and a bind happens on the same cycle a new descriptor
        // arrives: pop + push on the same physical entry.
        begin_case("C07a_queue_full_push_with_bind");
        occupy_out(INFO_4x4, ok_occ);
        occupy_out(INFO_4x4, ok_occ);
        send_info(INFO_4x4);
        send_info(INFO_4x4);
        chk(dut.u_unified_wrapper.desc_count == 2'd2, "PRE: queue full");
        drain(4, VAL_ZERO, ok_drain, bad_beats);       // frees slot 0
        chk(ok_drain, "first TU drained");
        // Catch bind_event in the cycle it appears (no extra edge) and present
        // the new descriptor on that same sampling edge.
        caught = 1'b0;
        for (i = 0; i < 20; i = i + 1) begin
            if (dut.u_unified_wrapper.bind_event) begin
                it_info     = INFO_4x4;
                it_info_vld = 1'b1;
                @(negedge clk);
                it_info_vld = 1'b0;
                caught = 1'b1;
                break;
            end
            @(negedge clk);
        end
        chk(caught, "PRE: push landed on the same cycle as bind_event");
        chk(dut.u_unified_wrapper.desc_count == 2'd2, "queue full again after pop+push");
        // The end now belongs to the TU bound on that edge (now in scrub).
        send_end_pulse();
        // Drain in completion order: TU2, then the newly bound TU3.
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "second occupying TU drained");
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "bound TU3 produced 4 beats");
        chk(dones == 3, "three done pulses");
        chk(!dut.u_unified_wrapper.protocol_error, "no protocol error on legal push");
        end_case();

        // ------------------------------------------------------------ C07b ---
        // Queue full, no bind: end belongs to an existing queued TU.
        begin_case("C07b_queue_full_no_bind");
        occupy_out(INFO_4x4, ok_occ);
        occupy_out(INFO_4x4, ok_occ);
        send_info(INFO_4x4);
        send_info(INFO_4x4);
        chk(dut.u_unified_wrapper.desc_count == 2'd2, "PRE: queue full");
        send_end_pulse();
        chk(dut.u_unified_wrapper.desc_count == 2'd2, "queue still full");
        drain(4, VAL_ZERO, ok_drain, bad_beats);       // frees slot 0
        chk(ok_drain, "first occupying TU drained");
        drain(4, VAL_ZERO, ok_drain, bad_beats);       // frees slot 1
        chk(ok_drain, "second occupying TU drained");
        drain(4, VAL_ZERO, ok_drain, bad_beats);       // head queued TU completes
        chk(ok_drain, "head queued TU produced 4 beats");
        chk(dones == 3, "three done pulses");
        end_case();

        // ------------------------------------------------------------ C08a ---
        // A later end with no TU left to own it -> protocol error.
        begin_case("C08a_repeat_end_no_tu");
        send_info(INFO_4x4);
        wait_req(4000, ok_req);
        chk(ok_req, "input req opened");
        send_end_pulse();
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain && dones == 1, "TU completed");
        repeat (6) @(negedge clk);
        send_end_pulse();
        repeat (6) @(negedge clk);
        chk(dut.u_unified_wrapper.protocol_error === 1'b1, "unowned end flagged");
        end_case();

        // ------------------------------------------------------------ C08b ---
        // Second end while the next TU is already in fill.
        begin_case("C08b_repeat_end_next_in_fill");
        send_info(INFO_4x4);
        wait_req(4000, ok_req);
        chk(ok_req, "TU1 req opened");
        send_end_pulse();
        wait_slot(0, SLOT_OUT, 8000, ok_slot);
        chk(ok_slot, "TU1 reached SLOT_OUT");
        send_info(INFO_4x4);
        wait_req(4000, ok_req);
        chk(ok_req, "TU2 req opened (fill)");
        send_end_pulse();
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "TU1 drained");
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "TU2 drained");
        chk(dones == 2, "two done pulses");
        end_case();

        // ------------------------------------------------------------ C08c ---
        // Second end while the next TU is still in scrub.
        begin_case("C08c_repeat_end_next_in_scrub");
        send_info(INFO_4x4);
        wait_req(4000, ok_req);
        chk(ok_req, "TU1 req opened");
        send_end_pulse();
        wait_slot(0, SLOT_OUT, 8000, ok_slot);
        chk(ok_slot, "TU1 reached SLOT_OUT");
        send_info(INFO_4x4);
        ok_slot = 1'b0;
        for (i = 0; i < 4000; i = i + 1) begin
            @(negedge clk);
            if (dut.u_unified_wrapper.scrub_active) begin ok_slot = 1'b1; break; end
        end
        chk(ok_slot, "PRE: TU2 entered scrub");
        chk(!it_data_in_req, "PRE: req low");
        send_end_pulse();
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "TU1 drained");
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "TU2 drained");
        chk(dones == 2, "two done pulses");
        end_case();

        // ------------------------------------------------------------ C09a ---
        // Previous TU computing while the next TU legally ends its input.
        begin_case("C09a_prev_computing_next_ends");
        send_info(INFO_4x4);
        wait_req(4000, ok_req);
        chk(ok_req, "TU1 req opened");
        send_end_pulse();
        wait_slot(0, SLOT_OUT, 8000, ok_slot);
        chk(ok_slot, "PRE: TU1 in compute/output");
        send_info(INFO_4x4);
        wait_req(4000, ok_req);
        chk(ok_req, "TU2 req opened");
        send_end_pulse();
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "TU1 drained");
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "TU2 drained");
        chk(dones == 2, "two done pulses");
        chk(!dut.u_unified_wrapper.protocol_error, "no protocol error");
        end_case();

        // ------------------------------------------------------------ C09b ---
        // End with no admitted TU at all.
        begin_case("C09b_end_with_no_tu");
        repeat (4) @(negedge clk);
        chk(dut.u_unified_wrapper.desc_count == 2'd0, "PRE: no descriptor");
        send_end_pulse();
        repeat (6) @(negedge clk);
        chk(dut.u_unified_wrapper.protocol_error === 1'b1, "unowned end flagged");
        end_case();

        // ------------------------------------------------------------- C10 ---
        // End landing exactly on the last scrub cycle.
        begin_case("C10_end_on_last_scrub_cycle");
        send_info(INFO_4x4);
        ok_slot = 1'b0;
        for (i = 0; i < 4000; i = i + 1) begin
            @(negedge clk);
            if (dut.u_unified_wrapper.scrub_active &&
                dut.u_unified_wrapper.scrub_index ==
                    (dut.u_unified_wrapper.INPUT_VALID_WORDS - 1)) begin
                ok_slot = 1'b1;
                break;
            end
        end
        chk(ok_slot, "PRE: reached last scrub cycle");
        it_data_end = 1'b1;                 // sampled on the completing edge
        @(negedge clk);
        it_data_end = 1'b0;
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "4 output beats observed");
        chk(bad_beats == 0, "all beats zero");
        chk(dones == 1, "exactly one done");
        end_case();

        // ------------------------------------------------------------ C11a ---
        // Reset while a pending end is stored; next TU must be unaffected.
        begin_case("C11a_reset_with_pending");
        send_info(INFO_4x4);
        ok_slot = 1'b0;
        for (i = 0; i < 4000; i = i + 1) begin
            @(negedge clk);
            if (dut.u_unified_wrapper.scrub_active) begin ok_slot = 1'b1; break; end
        end
        chk(ok_slot, "PRE: in scrub");
        send_end_pulse();
        repeat (5) @(negedge clk);
        reset_dut();
        chk(!dut.u_unified_wrapper.protocol_error, "reset cleared error state");
        send_info(INFO_4x4);
        wait_req(4000, ok_req);
        chk(ok_req, "post-reset TU admitted");
        send_point(12'd0, 16'sd32767, 1'b1);
        drain(4, VAL_DC511, ok_drain, bad_beats);
        chk(ok_drain, "post-reset TU produced 4 beats");
        chk(bad_beats == 0, "post-reset data correct (no stale end)");
        chk(dones == 1, "exactly one done");
        end_case();

        // ------------------------------------------------------------ C11b ---
        // Two back-to-back zero TUs, both ending after req.
        begin_case("C11b_two_zero_tus_after_req");
        send_info(INFO_4x4);
        wait_req(4000, ok_req);
        chk(ok_req, "TU1 req opened");
        send_end_pulse();
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "TU1 drained");
        send_info(INFO_4x4);
        wait_req(4000, ok_req);
        chk(ok_req, "TU2 req opened");
        send_end_pulse();
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "TU2 drained");
        chk(dones == 2, "two done pulses");
        end_case();

        // ------------------------------------------------------------ C11c ---
        // Two zero TUs, first ends early inside its scrub window.
        begin_case("C11c_two_zero_tus_first_early");
        send_info(INFO_4x4);
        ok_slot = 1'b0;
        for (i = 0; i < 4000; i = i + 1) begin
            @(negedge clk);
            if (dut.u_unified_wrapper.scrub_active) begin ok_slot = 1'b1; break; end
        end
        chk(ok_slot, "PRE: TU1 in scrub");
        send_end_pulse();
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "TU1 drained");
        send_info(INFO_4x4);
        wait_req(4000, ok_req);
        chk(ok_req, "TU2 req opened");
        send_end_pulse();
        drain(4, VAL_ZERO, ok_drain, bad_beats);
        chk(ok_drain, "TU2 drained");
        chk(dones == 2, "two done pulses");
        end_case();

        // ------------------------------------------------------------- C12 ---
        // A is in scrub and has already taken its end; B is queued.  The next
        // end must go to B, not be dropped as a duplicate on A.
        begin_case("C12_skip_ended_scrub_owner");
        occupy_out(INFO_4x4, ok_occ);            // TU1 -> slot0 (busy)
        chk(ok_occ, "PRE: slot0 occupied");
        send_info(INFO_4x4);                     // A -> slot1
        ok_slot = 1'b0;
        for (i = 0; i < 4000; i = i + 1) begin
            @(negedge clk);
            if (dut.u_unified_wrapper.scrub_active &&
                dut.u_unified_wrapper.slot_state[1] !== SLOT_FREE) begin
                ok_slot = 1'b1; break;
            end
        end
        chk(ok_slot, "PRE: A (slot1) in scrub");
        send_end_pulse();                        // A takes its end
        send_info(INFO_4x4);                     // B queued (no free slot)
        chk(dut.u_unified_wrapper.desc_count == 2'd1, "PRE: B queued and unbound");
        send_end_pulse();                        // must be attributed to B
        drain(4, VAL_ZERO, ok_drain, bad_beats); // free slot0 (TU1)
        chk(ok_drain, "TU1 drained");
        drain(4, VAL_ZERO, ok_drain, bad_beats); // A
        chk(ok_drain, "A produced 4 beats");
        drain(4, VAL_ZERO, ok_drain, bad_beats); // B
        chk(ok_drain, "B produced 4 beats");
        chk(dones == 3, "three done pulses");
        end_case();

        // ------------------------------------------------------------- C13 ---
        // Queue holds two entries; the head already took its end.  The next
        // end must go to the second entry, not be discarded as a duplicate.
        begin_case("C13_skip_ended_queue_head");
        occupy_out(INFO_4x4, ok_occ);
        occupy_out(INFO_4x4, ok_occ);
        chk(ok_occ, "PRE: both slots occupied");
        send_info(INFO_4x4);                     // B1 -> queue head
        chk(dut.u_unified_wrapper.desc_count == 2'd1, "PRE: B1 queued");
        send_end_pulse();                        // B1 takes its end
        send_info(INFO_4x4);                     // B2 -> second entry
        chk(dut.u_unified_wrapper.desc_count == 2'd2, "PRE: two entries queued");
        send_end_pulse();                        // must be attributed to B2
        drain(4, VAL_ZERO, ok_drain, bad_beats); // frees slot0
        chk(ok_drain, "first occupying TU drained");
        drain(4, VAL_ZERO, ok_drain, bad_beats); // frees slot1
        chk(ok_drain, "second occupying TU drained");
        drain(4, VAL_ZERO, ok_drain, bad_beats); // B1
        chk(ok_drain, "B1 produced 4 beats");
        drain(4, VAL_ZERO, ok_drain, bad_beats); // B2
        chk(ok_drain, "B2 produced 4 beats");
        chk(dones == 4, "four done pulses");
        end_case();

        // ------------------------------------------------------------ summary
        $display("END_ATTRIBUTION_TB pass=%0d fail=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("END_ATTRIBUTION_RESULT=PASS");
        else               $display("END_ATTRIBUTION_RESULT=FAIL cases=%0d", fail_cnt);
        $finish;
    end

    // -------------------------------------------------------------- watchdog
    initial begin
        #2000000;
        $display("END_ATTRIBUTION_TB GLOBAL_TIMEOUT");
        $display("END_ATTRIBUTION_RESULT=FAIL reason=global_timeout");
        $finish;
    end

endmodule