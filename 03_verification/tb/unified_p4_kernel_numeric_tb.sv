`timescale 1ns/1ps

module unified_p4_kernel_numeric_tb;
    parameter string VECTOR_FILE = "unified_gate_b_vectors.txt";

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [1:0] tr_type = '0;
    logic [6:0] transform_size = '0;
    logic stage_sel = 1'b0;
    logic in_valid = 1'b0;
    logic in_req;
    logic signed [15:0] in_data = '0;
    logic out_valid;
    logic out_req = 1'b0;
    logic signed [63:0] out_data;
    logic done;
    logic busy;
    logic error;

    integer fd;
    integer scan_rc;
    integer case_count;
    integer case_i;
    integer type_i;
    integer size_i;
    integer stage_i;
    integer sample_i;
    integer group_i;
    integer sample_value;
    integer expected0;
    integer expected1;
    integer expected2;
    integer expected3;
    integer stall_cycle;
    logic [63:0] fire_data;

    always #1 clk = ~clk;

    unified_p4_kernel dut (
        .clk(clk), .rst_n(rst_n), .start(start), .tr_type(tr_type),
        .transform_size(transform_size), .stage_sel(stage_sel),
        .in_valid(in_valid), .in_req(in_req), .in_data(in_data),
        .out_valid(out_valid), .out_req(out_req), .out_data(out_data),
        .done(done), .busy(busy), .error(error)
    );

    task automatic run_case;
        integer lane0;
        integer lane1;
        integer lane2;
        integer lane3;
        begin
            while (busy) @(negedge clk);
            tr_type       = type_i[1:0];
            transform_size = size_i[6:0];
            stage_sel     = stage_i[0];
            start         = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;

            for (sample_i = 0; sample_i < size_i; sample_i = sample_i + 1) begin
                scan_rc = $fscanf(fd, "%d", sample_value);
                if (scan_rc != 1)
                    $fatal(1, "bad input vector case=%0d sample=%0d", case_i, sample_i);
                while (!in_req) @(negedge clk);
                in_data  = sample_value;
                in_valid = 1'b1;
                @(posedge clk);
                @(negedge clk);
            end
            in_valid = 1'b0;
            in_data  = '0;

            for (group_i = 0; group_i < (size_i / 4); group_i = group_i + 1) begin
                scan_rc = $fscanf(fd, "%d %d %d %d",
                                  expected0, expected1, expected2, expected3);
                if (scan_rc != 4)
                    $fatal(1, "bad expected vector case=%0d group=%0d", case_i, group_i);

                // Deterministic stalls exercise held group data and request-
                // gated valid without changing the expected transaction order.
                stall_cycle = 0;
                while (stall_cycle < ((case_i + group_i) % 3)) begin
                    out_req = 1'b0;
                    @(posedge clk);
                    if (out_valid)
                        $fatal(1, "out_valid asserted without request case=%0d group=%0d", case_i, group_i);
                    @(negedge clk);
                    stall_cycle = stall_cycle + 1;
                end
                out_req = 1'b1;
                @(posedge clk);
                if (!(out_valid && out_req))
                    $fatal(1, "missing output fire case=%0d group=%0d", case_i, group_i);
                fire_data = out_data;
                lane0 = $signed(fire_data[15:0]);
                lane1 = $signed(fire_data[31:16]);
                lane2 = $signed(fire_data[47:32]);
                lane3 = $signed(fire_data[63:48]);
                if ((lane0 != expected0) || (lane1 != expected1) ||
                    (lane2 != expected2) || (lane3 != expected3))
                    $fatal(1, "numeric mismatch case=%0d group=%0d got=%0d,%0d,%0d,%0d expected=%0d,%0d,%0d,%0d",
                           case_i, group_i, lane0, lane1, lane2, lane3,
                           expected0, expected1, expected2, expected3);
                #1step;
                if (group_i == ((size_i / 4) - 1)) begin
                    if (!done)
                        $fatal(1, "done missing on last fire case=%0d", case_i);
                end else if (done) begin
                    $fatal(1, "early done case=%0d group=%0d", case_i, group_i);
                end
                @(negedge clk);
                out_req = 1'b0;
            end

            @(posedge clk);
            #1step;
            if (done)
                $fatal(1, "done wider than one cycle case=%0d", case_i);
            if (error)
                $fatal(1, "kernel error case=%0d", case_i);
            @(negedge clk);
        end
    endtask

    initial begin
        fd = $fopen(VECTOR_FILE, "r");
        if (fd == 0)
            $fatal(1, "cannot open %s", VECTOR_FILE);
        scan_rc = $fscanf(fd, "%d", case_count);
        if (scan_rc != 1)
            $fatal(1, "bad vector header");

        repeat (3) @(posedge clk);
        #1step rst_n = 1'b1;
        @(negedge clk);

        for (case_i = 0; case_i < case_count; case_i = case_i + 1) begin
            scan_rc = $fscanf(fd, "%d %d %d", type_i, size_i, stage_i);
            if (scan_rc != 3)
                $fatal(1, "bad case header case=%0d", case_i);
            run_case();
        end

        $fclose(fd);
        $display("GATE_B_NUMERIC_TB_PASS cases=%0d", case_count);
        $finish;
    end
endmodule
