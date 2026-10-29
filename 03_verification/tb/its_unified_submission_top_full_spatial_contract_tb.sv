`timescale 1ns/1ps
// Analytic DC scoreboard with queued mixed TUs and reset/reuse scenarios.
// Expected sample = DC/32 for the selected multiples of512, independent
// of the Python vector generator and the DUT's intermediate data.
module its_unified_submission_top_full_spatial_contract_tb;
    logic clk=0;always #1 clk=~clk;
    logic rst_n=0;
    logic [21:0] it_info=0;
    logic it_info_vld=0;
    logic signed [15:0] it_data_in=0;
    logic [11:0] it_data_addr=0;
    logic it_data_in_vld=0,it_data_end=0;
    wire it_data_in_req;
    logic it_data_out_req=0;
    wire [39:0] it_data_out;
    wire it_data_out_vld,it_done;
    its_unified_submission_top dut(.*);
    integer widths[0:7]='{64,4,16,4,32,64,8,64};
    integer heights[0:7]='{64,4,16,64,32,4,8,64};
    integer dcs[0:7]='{512,-512,1024,-1024,1536,-1536,2048,-2048};
    integer cycle=0,rx,tx,beat,timeout,done_count,stalls,wait_cycles;
    integer boundary_stalls=0,final_stalls=0,reset_cases=0;
    logic [39:0] held;
    bit holding,half_seen,last_seen;
    integer forced_left;
    always @(posedge clk) cycle<=cycle+1;
    task automatic reset_dut;
        begin
            @(negedge clk);rst_n=0;it_info_vld=0;it_data_in_vld=0;it_data_end=0;it_data_out_req=0;
            repeat(3) @(negedge clk);rst_n=1;
        end
    endtask
    task automatic send_dc(input integer w,h,dc,lfnst=0);
        begin
            @(negedge clk);it_info=w|(h<<7)|(lfnst<<20);it_info_vld=1;
            @(posedge clk);
            @(negedge clk);it_info_vld=0;
            wait_cycles=0;
            while(!it_data_in_req) begin
                @(negedge clk);wait_cycles=wait_cycles+1;
                if(wait_cycles>60000) $fatal(1,"input admission timeout");
            end
            // DC=0 is represented by an empty sparse TU, without a zero data point.
            it_data_addr=0;it_data_in=dc;it_data_in_vld=(dc!=0);it_data_end=1;
            @(posedge clk);
            if(!it_data_in_req) $fatal(1,"unaccepted input");
            @(negedge clk);it_data_in_vld=0;it_data_end=0;
        end
    endtask
    task automatic drain_zero(input integer w,h);
        integer count,guard;
        begin
            count=0;guard=0;
            @(negedge clk);it_data_out_req=1;
            while(count<w*h/4) begin
                @(posedge clk);guard=guard+1;
                if(guard>30000) $fatal(1,"reset reuse timeout");
                if(dut.u_unified_wrapper.protocol_error) $fatal(1,"reset reuse protocol error");
                if(it_data_out_vld) begin
                    if(it_data_out!==40'd0) $fatal(1,"stale payload after reset beat=%0d",count);
                    if(it_done!==(count==w*h/4-1)) $fatal(1,"reset reuse done mismatch");
                    count=count+1;
                end else if(it_done) $fatal(1,"reset done without output");
            end
            @(negedge clk);it_data_out_req=0;
            repeat(3) begin @(posedge clk);if(it_done||it_data_out_vld) $fatal(1,"stale extra output after reset");end
        end
    endtask
    initial begin
        reset_dut();
        rx=0;beat=0;done_count=0;stalls=0;forced_left=0;
        half_seen=0;last_seen=0;holding=0;timeout=0;
        fork
            begin
                for(tx=0;tx<8;tx=tx+1) send_dc(widths[tx],heights[tx],dcs[tx]);
            end
            begin
                while(rx<8) begin
                    @(negedge clk);
                    it_data_out_req=(cycle%7!=2 && cycle%11!=5);
                    if(beat==widths[rx]*heights[rx]/8 && !half_seen) begin
                        half_seen=1;forced_left=4;boundary_stalls=boundary_stalls+1;
                    end
                    if(beat==widths[rx]*heights[rx]/4-1 && !last_seen) begin
                        last_seen=1;forced_left=4;final_stalls=final_stalls+1;
                    end
                    if(forced_left>0) begin it_data_out_req=0;forced_left=forced_left-1;end
                    @(posedge clk);timeout=timeout+1;
                    if(timeout>200000) $fatal(1,"mixed stream timeout");
                    if(dut.u_unified_wrapper.protocol_error) $fatal(1,"mixed stream protocol error");
                    if(!it_data_out_req && dut.u_unified_wrapper.output_active) begin
                        if(it_data_out_vld||it_done) $fatal(1,"valid/done under output stall");
                        if(holding && it_data_out!==held) $fatal(1,"pending payload changed");
                        held=it_data_out;holding=1;stalls=stalls+1;
                    end else holding=0;
                    if(it_data_out_vld) begin
                        for(integer lane=0;lane<4;lane=lane+1)
                            if($isunknown(it_data_out[lane*10 +:10]) ||
                               $signed(it_data_out[lane*10 +:10])!=dcs[rx]/32)
                                $fatal(1,"mixed stream data/order error TU=%0d beat=%0d",rx,beat);
                        if(it_done!==(beat==widths[rx]*heights[rx]/4-1)) $fatal(1,"mixed done mismatch");
                        if(it_done) begin
                            rx=rx+1;beat=0;done_count=done_count+1;
                            half_seen=0;last_seen=0;
                        end else beat=beat+1;
                    end else if(it_done) $fatal(1,"mixed done without valid");
                end
            end
        join
        if(done_count!=8 || stalls==0 || boundary_stalls!=8 || final_stalls!=8)
            $fatal(1,"mixed stream coverage incomplete");
        // Reset in the newly reconstructed lower half of a vertical vector.
        reset_dut();send_dc(64,64,512);
        timeout=0;
        while(!(dut.u_unified_wrapper.vertical_result_fire &&
                dut.u_unified_wrapper.kernel_drain_group_q>=8)) begin
            @(negedge clk);timeout=timeout+1;if(timeout>10000)$fatal(1,"lower V reset target missing");
        end
        reset_dut();send_dc(64,64,0);drain_zero(64,64);reset_cases=reset_cases+1;
        // Reset after the final vertical result commits, before H completes.
        reset_dut();send_dc(64,64,-512);
        timeout=0;
        while(!(dut.u_unified_wrapper.vwrite_cmd_commit && dut.u_unified_wrapper.vwrite_cmd_last_q)) begin
            @(negedge clk);timeout=timeout+1;if(timeout>10000)$fatal(1,"last V commit reset target missing");
        end
        @(posedge clk);
        reset_dut();send_dc(4,64,0);drain_zero(4,64);reset_cases=reset_cases+1;
        // Reset while the final external output beat is genuinely pending.
        reset_dut();send_dc(64,64,512);
        beat=0;@(negedge clk);it_data_out_req=1;
        while(beat<1023) begin
            @(posedge clk);
            if(it_data_out_vld) begin
                if(it_done) $fatal(1,"early done before final-beat reset");
                beat=beat+1;
            end
        end
        @(negedge clk);it_data_out_req=0;
        repeat(4) begin @(posedge clk);if(it_done||it_data_out_vld)$fatal(1,"last beat escaped stall");end
        reset_dut();send_dc(4,4,0);drain_zero(4,4);reset_cases=reset_cases+1;
        // The LFNST path also reconstructs rows below its 8-row input support.
        reset_dut();send_dc(16,64,512,1);
        timeout=0;
        while(!(dut.u_unified_wrapper.vertical_result_fire &&
                dut.u_unified_wrapper.kernel_drain_group_q>=2)) begin
            @(negedge clk);timeout=timeout+1;if(timeout>10000)$fatal(1,"LFNST lower V reset target missing");
        end
        reset_dut();send_dc(16,64,0,1);drain_zero(16,64);reset_cases=reset_cases+1;
        if(reset_cases!=4) $fatal(1,"reset coverage incomplete");
        $display("FULL_SPATIAL_CONTRACT_PASS mixed_tus=8 boundary_stalls=8 final_stalls=8 reset_cases=4 pending_stalls=%0d",stalls);
        $finish;
    end
    initial begin #1500000;$fatal(1,"global timeout");end
endmodule
