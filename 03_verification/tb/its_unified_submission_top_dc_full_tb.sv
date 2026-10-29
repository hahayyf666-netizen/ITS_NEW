`timescale 1ns/1ps
// No vector file, Python model or DUT-derived expected data.
// DC basis coefficient=64 from contest attachment. Frozen stage shifts=7/10.
// DC +512 => +256 after V => +16 after H; -512 => -256 => -16.
module its_unified_submission_top_dc_full_tb;
    logic clk=0;always #1 clk=~clk;
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
    integer report;
    integer total_bad=0;
    task automatic check_dc(input integer w,h,dc,expected);
        integer beat,beats,lane,actual,row,mismatches,first_bad,done_count;
        integer row_matches[0:63],row_zeros[0:63],row_other[0:63];
        logic [39:0] first_word;
        begin
            @(negedge clk);rst_n=0;it_info_vld=0;it_data_in_vld=0;it_data_end=0;
            repeat(3) @(negedge clk);rst_n=1;
            @(negedge clk);it_info=w|(h<<7);it_info_vld=1;
            @(negedge clk);it_info_vld=0;
            while(!it_data_in_req) @(negedge clk);
            it_data_in=dc;it_data_addr=0;it_data_in_vld=1;it_data_end=1;
            @(negedge clk);it_data_in_vld=0;it_data_end=0;
            beats=w*h/4;beat=0;mismatches=0;first_bad=-1;done_count=0;first_word=0;
            for(row=0;row<64;row=row+1) begin row_matches[row]=0;row_zeros[row]=0;row_other[row]=0;end
            while(beat<beats) begin
                @(posedge clk);
                if(dut.u_unified_wrapper.protocol_error) $fatal(1,"invalid stimulus/protocol error");
                if(it_done!== (it_data_out_vld && beat==beats-1)) $fatal(1,"done/protocol mismatch");
                if(it_data_out_vld) begin
                    done_count=done_count+it_done;
                    for(lane=0;lane<4;lane=lane+1) begin
                        actual=$signed(it_data_out[lane*10 +:10]);
                        row=(beat*4+lane)/w;
                        if(actual==expected) row_matches[row]=row_matches[row]+1;
                        else if(actual==0) row_zeros[row]=row_zeros[row]+1;
                        else row_other[row]=row_other[row]+1;
                        if($isunknown(it_data_out[lane*10 +:10]) || actual!=expected) begin
                            mismatches=mismatches+1;
                            if(first_bad<0) begin first_bad=beat;first_word=it_data_out;end
                        end
                    end
                    beat=beat+1;
                end
            end
            if(done_count!=1) $fatal(1,"done count");
            total_bad=total_bad+mismatches;
            $display("DC_REQUIREMENT w=%0d h=%0d dc=%0d expected=%0d beats=%0d bad_samples=%0d first_bad_beat=%0d first_actual=%010h",w,h,dc,expected,beat,mismatches,first_bad,first_word);
            $fwrite(report,"CASE width=%0d height=%0d dc=%0d expected=%0d beats=%0d mismatches=%0d first_bad_beat=%0d first_actual=%010h\n",w,h,dc,expected,beat,mismatches,first_bad,first_word);
            for(row=0;row<h;row=row+1)
                $fwrite(report,"ROW %0d matches=%0d unexpected_zeros=%0d other=%0d\n",row,row_matches[row],row_zeros[row],row_other[row]);
        end
    endtask
    initial begin
        report=$fopen("dc_requirement_results.txt","w");
        if(!report) $fatal(1,"cannot write report");
        check_dc(4,4,512,16);
        check_dc(64,4,512,16);
        check_dc(4,64,512,16);
        check_dc(64,64,512,16);
        check_dc(64,64,-512,-16);
        $fclose(report);
        $display("DC_REQUIREMENT_DIAGNOSTIC_COMPLETED cases=5");
        if(total_bad!=0) $fatal(1,"full spatial DC mismatch samples=%0d",total_bad);
        $display("FULL_SPATIAL_DC_PASS cases=5");
        $finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
