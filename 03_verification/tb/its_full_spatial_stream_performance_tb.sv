`timescale 1ns/1ps
// Eight queued DC-only DCT2 TUs per shape, no output backpressure.
module its_full_spatial_stream_performance_tb;
    logic clk=0;always #1 clk=~clk;
    logic rst_n=0;
    logic [21:0] it_info=0;
    logic it_info_vld=0;
    logic signed [15:0] it_data_in=512;
    logic [11:0] it_data_addr=0;
    logic it_data_in_vld=0,it_data_end=0;
    wire it_data_in_req;
    logic it_data_out_req=1;
    wire [39:0] it_data_out;
    wire it_data_out_vld,it_done;
    its_unified_submission_top dut(.*);
    integer cycle=0;always @(posedge clk) cycle<=cycle+1;
    integer n,ci,tx,rx,beat,total_beats,first_info,first_done,last_done,prev_done,first_interval,last_interval,minimum_interval,maximum_interval;
    integer errors,fd;
    integer sizes[0:3]='{4,16,32,64};
    initial begin
        fd=$fopen("stream_metrics.csv","w");
        $fwrite(fd,"n,tus,first_done_latency,total_cycles,first_interval,last_interval,min_interval,max_interval,steady_mean_interval,output_beats,full_spatial_mismatch_beats\n");
        for(ci=0;ci<4;ci=ci+1) begin
            n=sizes[ci];
            @(negedge clk);rst_n=0;it_info_vld=0;it_data_in_vld=0;it_data_end=0;
            repeat(3) @(negedge clk);rst_n=1;
            rx=0;beat=0;total_beats=0;errors=0;prev_done=0;minimum_interval=1000000;maximum_interval=0;
            fork
                begin
                    for(tx=0;tx<8;tx=tx+1) begin
                        @(negedge clk);it_info=n|(n<<7);it_info_vld=1;
                        @(posedge clk);if(tx==0) first_info=cycle;
                        @(negedge clk);it_info_vld=0;
                        while(!it_data_in_req) @(negedge clk);
                        it_data_in_vld=1;it_data_end=1;
                        @(posedge clk);
                        @(negedge clk);it_data_in_vld=0;it_data_end=0;
                    end
                end
                begin
                    while(rx<8) begin
                        @(posedge clk);
                        if(it_data_out_vld) begin
                            if(it_data_out!=={4{10'd16}}) errors=errors+1;
                            if(it_done!==(beat==n*n/4-1)) $fatal(1,"stream done mismatch");
                            total_beats=total_beats+1;
                            if(it_done) begin
                                if(rx==0) first_done=cycle;
                                else begin
                                    last_interval=cycle-prev_done;
                                    if(rx==1) first_interval=last_interval;
                                    if(last_interval<minimum_interval) minimum_interval=last_interval;
                                    if(last_interval>maximum_interval) maximum_interval=last_interval;
                                end
                                prev_done=cycle;last_done=cycle;rx=rx+1;beat=0;
                            end else beat=beat+1;
                        end
                        if(dut.u_unified_wrapper.protocol_error) $fatal(1,"stream protocol error");
                    end
                end
            join
            $fwrite(fd,"%0d,8,%0d,%0d,%0d,%0d,%0d,%0d,%0f,%0d,%0d\n",n,first_done-first_info+1,last_done-first_info+1,first_interval,last_interval,minimum_interval,maximum_interval,real'(last_done-first_done)/7,total_beats,errors);
            $display("STREAM n=%0d first_latency=%0d steady_interval=%0f min=%0d max=%0d errors=%0d",n,first_done-first_info+1,real'(last_done-first_done)/7,minimum_interval,maximum_interval,errors);
        end
        $fclose(fd);$display("STREAM_COMPLETED");$finish;
    end
    initial begin #1000000; $fatal(1,"timeout");end
endmodule
