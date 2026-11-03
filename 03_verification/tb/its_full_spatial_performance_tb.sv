`timescale 1ns/1ps
// Diagnostic test: preserve frozen RTL; compare existing model and a full
// spatial-output matrix equation, and measure no-stall single-TU latency.
module its_full_spatial_performance_tb;
    logic clk=0; always #1 clk=~clk;
    logic rst_n=0;
    logic [21:0] it_info=0;
    logic it_info_vld=0;
    logic signed [15:0] it_data_in=0;
    logic [11:0] it_data_addr=0;
    logic it_data_in_vld=0,it_data_end=0;
    wire it_data_in_req;
    logic it_data_out_req=1;
    wire [39:0] it_data_out;
    wire it_data_out_vld,it_done;
    its_unified_submission_top dut(.*);
    integer cycle=0;
    integer scrub_cycles=0,v_cycles=0,h_cycles=0,lfnst_cycles=0,issue_cycles=0;
    bit measuring=0;
    always @(posedge clk) begin
        cycle <= cycle+1;
        if (measuring) begin
            if(dut.u_unified_wrapper.scrub_active) scrub_cycles=scrub_cycles+1;
            if(dut.u_unified_wrapper.kernel_run_q) begin
                if(dut.u_unified_wrapper.kernel_stage_q) h_cycles=h_cycles+1;
                else v_cycles=v_cycles+1;
            end
            if(dut.u_unified_wrapper.lfnst_run_q) lfnst_cycles=lfnst_cycles+1;
            if(dut.u_unified_wrapper.u_unified_p4_kernel.issue_desc_valid_q) issue_cycles=issue_cycles+1;
        end
    end
    integer fd,csv,rc,count,ci,ni,nb,i,j,addr[0:4095],value[0:4095];
    logic [39:0] legacy[0:1023],ref_full[0:1023];
    logic [21:0] desc;
    integer tinfo,tinfirst,tinlast,toutfirst,toutlast,lastout;
    integer legacy_errors,full_errors,first_bad,done_count,output_gaps;
    logic [39:0] first_actual,first_expected;
    initial begin
        fd=$fopen("probe_vectors.txt","r");
        csv=$fopen("probe_metrics.csv","w");
        if(!fd || !csv) $fatal(1,"file open failure");
        $fwrite(csv,"case,total_cycles,admission_cycles,input_span,compute_wait,output_span,scrub_cycles,v_cycles,h_cycles,lfnst_cycles,issue_cycles,legacy_mismatch_beats,full_mismatch_beats,first_bad_beat,actual,expected,output_gaps\n");
        rc=$fscanf(fd,"%d",count);
        repeat(3) @(negedge clk); rst_n=1;
        for(ci=0;ci<count;ci=ci+1) begin
            rc=$fscanf(fd,"%h %d %d",desc,ni,nb);
            if(rc!=3 || ni>4096 || nb>1024) $fatal(1,"bad case header");
            for(i=0;i<ni;i=i+1) rc=$fscanf(fd,"%d %d",addr[i],value[i]);
            for(i=0;i<nb;i=i+1) rc=$fscanf(fd,"%h %h",legacy[i],ref_full[i]);
            @(negedge clk);
            scrub_cycles=0;v_cycles=0;h_cycles=0;lfnst_cycles=0;issue_cycles=0;
            measuring=1; it_info=desc; it_info_vld=1;
            @(posedge clk); tinfo=cycle;
            @(negedge clk); it_info_vld=0;
            for(i=0;i<ni;i=i+1) begin
                while(!it_data_in_req) @(negedge clk);
                it_data_in=value[i];it_data_addr=addr[i];it_data_in_vld=1;it_data_end=(i==ni-1);
                @(posedge clk);
                if(i==0) tinfirst=cycle;
                tinlast=cycle;
                @(negedge clk);it_data_in_vld=0;it_data_end=0;
            end
            legacy_errors=0;full_errors=0;first_bad=-1;done_count=0;
            output_gaps=0;lastout=-1;first_actual=0;first_expected=0;
            j=0;
            while(j<nb) begin
                @(posedge clk);
                if(cycle-tinfo>100000) $fatal(1,"timeout case %0d",ci);
                if(dut.u_unified_wrapper.protocol_error) $fatal(1,"protocol error case %0d",ci);
                if(it_data_out_vld) begin
                    if(j==0) toutfirst=cycle;
                    if(lastout>=0 && cycle!=lastout+1) output_gaps=output_gaps+1;
                    lastout=cycle;toutlast=cycle;
                    if(it_data_out!==legacy[j]) legacy_errors=legacy_errors+1;
                    if(it_data_out!==ref_full[j]) begin
                        full_errors=full_errors+1;
                        if(first_bad<0) begin
                            first_bad=j;first_actual=it_data_out;first_expected=ref_full[j];
                        end
                    end
                    if(it_done!==(j==nb-1)) $fatal(1,"done alignment error");
                    done_count=done_count+it_done;
                    j=j+1;
                end else if(it_done) $fatal(1,"done without output");
            end
            @(negedge clk);measuring=0;
            if(done_count!=1) $fatal(1,"done count error");
            $fwrite(csv,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%010h,%010h,%0d\n",ci,toutlast-tinfo+1,tinfirst-tinfo,tinlast-tinfirst+1,toutfirst-tinlast,toutlast-toutfirst+1,scrub_cycles,v_cycles,h_cycles,lfnst_cycles,issue_cycles,legacy_errors,full_errors,first_bad,first_actual,first_expected,output_gaps);
            $display("PROBE case=%0d total=%0d V=%0d H=%0d legacy_errors=%0d full_errors=%0d first_bad=%0d",ci,toutlast-tinfo+1,v_cycles,h_cycles,legacy_errors,full_errors,first_bad);
        end
        $fclose(fd);$fclose(csv);
        $display("PROBE_COMPLETED cases=%0d",count);
        $finish;
    end
endmodule
