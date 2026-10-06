`timescale 1ns/1ps
module its_unified_submission_top_protocol_tb;
    logic clk=0;
    always #1 clk=~clk;
    logic rst_n=0;
    logic [21:0] it_info=0;
    logic it_info_vld=0;
    logic signed [15:0] it_data_in=0;
    logic [11:0] it_data_addr=0;
    logic it_data_in_vld=0, it_data_end=0, it_data_out_req=0;
    wire it_data_in_req, it_data_out_vld, it_done;
    wire [39:0] it_data_out;
    its_unified_submission_top dut(.*);
    integer beats, dones, waits, pending_stalls=0;
    logic [39:0] held;
    task automatic reset_dut;
        @(negedge clk);
        rst_n=0; it_info_vld=0; it_data_in_vld=0;
        it_data_end=0; it_data_out_req=0;
        repeat(4) @(negedge clk);
        rst_n=1;
        repeat(2) @(negedge clk);
    endtask
    task automatic begin_tu;
        @(negedge clk); it_info=22'd4 | (22'd4<<7); it_info_vld=1;
        @(negedge clk); it_info_vld=0;
        waits=0;
        while(!it_data_in_req) begin
            @(negedge clk); waits=waits+1;
            if(waits>2000) $fatal(1,"input admission timeout");
        end
        repeat(3) begin
            @(posedge clk);
            if(it_done || it_data_out_vld) $fatal(1,"completion before end");
        end
        @(negedge clk);
    endtask
    task automatic drain(input logic signed [9:0] expected);
        waits=0;
        while(!dut.u_unified_wrapper.output_active) begin
            @(negedge clk); waits=waits+1;
            if(waits>2000) $fatal(1,"output admission timeout");
        end
        held=it_data_out;
        repeat(8) begin
            @(posedge clk);
            if(it_data_out!==held || it_done || it_data_out_vld)
                $fatal(1,"pending stall violation");
            pending_stalls=pending_stalls+1;
        end
        @(negedge clk); it_data_out_req=1;
        beats=0; dones=0; waits=0;
        while(beats<4) begin
            @(posedge clk); waits=waits+1;
            if(waits>2000) $fatal(1,"drain timeout");
            if(it_data_out_vld) begin
                if(it_data_out!=={expected,expected,expected,expected})
                    $fatal(1,"output mismatch beat=%0d got=%h",beats,it_data_out);
                if(it_done!==(beats==3)) $fatal(1,"done pairing");
                dones=dones+it_done; beats=beats+1;
            end else if(it_done) $fatal(1,"done without fire");
        end
        @(negedge clk); it_data_out_req=0;
        repeat(3) begin
            @(posedge clk);
            if(it_done) $fatal(1,"duplicate done");
        end
        if(dones!=1 || dut.u_unified_wrapper.protocol_error)
            $fatal(1,"legal TU completion/error");
    endtask
    initial begin
        reset_dut(); begin_tu();
        // Empty sparse TU: independent end marker creates no data command.
        it_data_end=1;
        @(posedge clk);
        if(dut.u_unified_wrapper.input_fire) $fatal(1,"empty end became data");
        @(negedge clk); it_data_end=0;
        drain(10'sd0);
        begin_tu(); it_data_in=32767; it_data_addr=0; it_data_in_vld=1;
        @(negedge clk); it_data_in_vld=0; it_data_end=1;
        @(posedge clk);
        if(!dut.u_unified_wrapper.fill_wr_cmd_commit)
            $fatal(1,"end-only did not overlap pending commit");
        @(negedge clk); it_data_end=0;
        drain(10'sd511);
        begin_tu(); it_data_in=-32768; it_data_in_vld=1; it_data_end=1;
        @(negedge clk); it_data_in_vld=0; it_data_end=0;
        drain(-10'sd512);
        begin_tu(); it_data_in=32767; it_data_in_vld=1; it_data_end=1;
        @(negedge clk); it_data_in_vld=0; it_data_end=0;
        // Abort an accepted TU during processing, then prove fresh zero output.
        repeat(2) @(negedge clk);
        reset_dut(); begin_tu(); it_data_end=1;
        @(negedge clk); it_data_end=0;
        drain(10'sd0);
        @(negedge clk); it_info=22'd2 | (22'd4<<7); it_info_vld=1;
        @(negedge clk); it_info_vld=0;
        if(!dut.u_unified_wrapper.protocol_error) $fatal(1,"illegal descriptor error missing");
        repeat(4) begin
            @(negedge clk);
            if(!dut.u_unified_wrapper.protocol_error || it_data_in_req || it_done)
                $fatal(1,"error not sticky/fail-closed");
        end
        reset_dut();
        if(dut.u_unified_wrapper.protocol_error) $fatal(1,"reset did not clear error");
        $display("SUBMISSION_TOP_PROTOCOL_PASS end_empty=1 end_commit=1 final_same_edge=1 reset_inflight=1 input_gaps=1 illegal_sticky=1 pending_stalls=%0d",pending_stalls);
        $finish;
    end
endmodule
