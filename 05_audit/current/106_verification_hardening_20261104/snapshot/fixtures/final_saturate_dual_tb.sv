`timescale 1ns/1ps
// P2: SAT10 vs LOW10 lockstep hardware comparison.
//
// Two instances of the SAME wrapper source differ only in FINAL_SATURATE.
// They receive identical stimulus, so every beat must arrive on the same cycle
// and only the final mapping may differ. Each instance is checked against its
// own golden; neither golden may stand in for the other.
//
// No RTL file is modified: the production top keeps FINAL_SATURATE=1.
module final_saturate_dual_tb;

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

    logic sat_in_req,  low_in_req;
    logic sat_out_vld, low_out_vld;
    logic sat_done,    low_done;
    logic sat_perr,    low_perr;
    logic [39:0] sat_out, low_out;

    unified_its_wrapper #(.FINAL_SATURATE(1)) u_sat (
        .clk(clk), .rst_n(rst_n),
        .it_info(it_info), .it_info_vld(it_info_vld),
        .it_data_in(it_data_in), .it_data_addr(it_data_addr),
        .it_data_in_vld(it_data_in_vld), .it_data_end(it_data_end),
        .it_data_in_req(sat_in_req),
        .it_data_out_req(it_data_out_req), .it_data_out(sat_out),
        .it_data_out_vld(sat_out_vld), .it_done(sat_done),
        .protocol_error(sat_perr)
    );

    unified_its_wrapper #(.FINAL_SATURATE(0)) u_low (
        .clk(clk), .rst_n(rst_n),
        .it_info(it_info), .it_info_vld(it_info_vld),
        .it_data_in(it_data_in), .it_data_addr(it_data_addr),
        .it_data_in_vld(it_data_in_vld), .it_data_end(it_data_end),
        .it_data_in_req(low_in_req),
        .it_data_out_req(it_data_out_req), .it_data_out(low_out),
        .it_data_out_vld(low_out_vld), .it_done(low_done),
        .protocol_error(low_perr)
    );

    // ------------------------------------------------------------- vectors
    logic [39:0] sat_mem [0:4095];
    logic [39:0] low_mem [0:4095];

    integer beat_idx   = 0;
    integer bad_sat    = 0;
    integer bad_low    = 0;
    integer diff_beats = 0;   // beats where the two mappings actually disagree
    integer vld_skew   = 0;   // cycles where the two vld disagree
    integer done_sat   = 0;
    integer done_low   = 0;

    always @(posedge clk) if (rst_n) begin
        if (sat_out_vld !== low_out_vld) vld_skew = vld_skew + 1;
        if (sat_done) done_sat = done_sat + 1;
        if (low_done) done_low = done_low + 1;
    end

    // -------------------------------------------------------------- driving
    task automatic reset_dut();
        @(negedge clk);
        rst_n = 1'b0; it_info = 0; it_info_vld = 0; it_data_in = 0;
        it_data_addr = 0; it_data_in_vld = 0; it_data_end = 0; it_data_out_req = 0;
        beat_idx = 0; done_sat = 0; done_low = 0;
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
            if (sat_in_req) begin ok = 1'b1; break; end

        end
    endtask

    task automatic send_point(input logic [11:0] addr, input logic signed [15:0] val,
                              input bit with_end);
        @(negedge clk);
        it_data_addr = addr; it_data_in = val;
        it_data_in_vld = 1'b1; it_data_end = with_end;
        @(negedge clk);
        it_data_in_vld = 1'b0; it_data_end = 1'b0;
        it_data_in = 0; it_data_addr = 0;
    endtask

    // Drain `n` beats and check both instances against their own golden.
    task automatic drain(input integer n, output bit ok, output integer bad_s, output integer bad_l);
        integer i, got, lane;
        logic [39:0] w_sat, w_low;
        ok = 1'b0; bad_s = 0; bad_l = 0; got = 0;
        it_data_out_req = 1'b1;
        for (i = 0; i < 200000; i = i + 1) begin
            @(posedge clk);
            if (sat_out_vld && it_data_out_req) begin
                w_sat = sat_out; w_low = low_out;
                if (w_sat !== sat_mem[beat_idx]) bad_s = bad_s + 1;
                if (w_low !== low_mem[beat_idx]) bad_l = bad_l + 1;
                if (w_sat !== w_low) diff_beats = diff_beats + 1;
                // per-lane detail for the first offending beat
                if ((w_sat !== sat_mem[beat_idx] || w_low !== low_mem[beat_idx]) && got == 0)
                    $display("   beat %0d got sat=%010h low=%010h exp sat=%010h low=%010h",
                             beat_idx, w_sat, w_low, sat_mem[beat_idx], low_mem[beat_idx]);
                beat_idx = beat_idx + 1;
                got = got + 1;
                if (got >= n) begin ok = 1'b1; break; end
            end
        end
        @(negedge clk);
        it_data_out_req = 1'b0;
    endtask

    // ----------------------------------------------------------------- main
    integer fd, r;
    logic [21:0] f_info, prev_info;
    logic [11:0] f_addr;
    logic [15:0] f_val;
    integer f_last, tu_beats, tu_w, tu_h;
    bit ok_req, ok_drain, started, fin, need_info;
    integer bs, bl;

    initial begin
        $readmemh("p2_sat.hex", sat_mem);
        $readmemh("p2_low.hex", low_mem);
        reset_dut();
        diff_beats = 0; vld_skew = 0; bad_sat = 0; bad_low = 0;
        started = 1'b0; fin = 1'b0; need_info = 1'b1;
        prev_info = 22'h3fffff;

        fd = $fopen("p2_stim.hex", "r");
        if (fd == 0) $fatal(1, "cannot open p2_stim.hex");

        while (!$feof(fd) && !fin) begin
            r = $fscanf(fd, "%h %h %h %d\n", f_info, f_addr, f_val, f_last);
            if (r != 4) begin
                $fclose(fd);
                fin = 1'b1;
            end else begin
            if (need_info) begin
                send_info(f_info);
                prev_info = f_info;
                need_info = 1'b0;
            end
            wait_req(20000, ok_req);
            if (!ok_req) begin
                $display("STATE slot0=%0d slot1=%0d scrub=%b fill=%b bind=%b desc=%0d perr=%b req=%b",
                         u_sat.slot_state[0], u_sat.slot_state[1], u_sat.scrub_active,
                         u_sat.fill_active, u_sat.bind_event, u_sat.desc_count,
                         u_sat.protocol_error, sat_in_req);
                $fatal(1, "input request timeout for info=%h", f_info);
            end
            send_point(f_addr, $signed(f_val), f_last[0]);
            if (f_last == 1) begin
                tu_w = f_info[6:0];
                tu_h = f_info[13:7];
                tu_beats = (tu_w * tu_h) / 4;
                drain(tu_beats, ok_drain, bs, bl);
                bad_sat = bad_sat + bs;
                bad_low = bad_low + bl;
                if (!ok_drain) $fatal(1, "drain timeout for info=%h", f_info);
                if (bs != 0 || bl != 0)
                    $display("   TU info=%h mismatch sat=%0d low=%0d", f_info, bs, bl);
                need_info = 1'b1;
            end
            started = 1'b1;
            end
        end

        $display("P2_RESULT beats=%0d sat_mismatch=%0d low_mismatch=%0d diff_beats=%0d vld_skew=%0d done_sat=%0d done_low=%0d",
                 beat_idx, bad_sat, bad_low, diff_beats, vld_skew, done_sat, done_low);
        $display("P2_PROTOCOL sat_error=%b low_error=%b", sat_perr, low_perr);
        if (bad_sat != 0 || bad_low != 0) $fatal(1, "data mismatch versus per-mode golden");
        if (diff_beats == 0)              $fatal(1, "SAT10 and LOW10 never disagreed: test is not discriminating");
        if (vld_skew != 0)                $fatal(1, "the two instances are not in lockstep");
        if (done_sat != 8 || done_low != 8) $fatal(1, "done count wrong");
        if (sat_perr || low_perr)         $fatal(1, "protocol error raised");
        $display("P2_PASS");
        $finish;
    end

    initial begin #2000000; $fatal(1, "P2 timeout"); end
endmodule