`timescale 1ns/1ps

module unified_p4_kernel_numeric_tb;
    parameter string VECTOR_FILE = "unified_gate_b_vectors.txt";

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [1:0] tr_type = '0;
    logic [6:0] transform_size = '0;
    logic [6:0] active_size = '0;
    logic [6:0] output_size = '0;
    logic [5:0] output_group_count;
    logic stage_sel = 1'b0;
    logic in_valid = 1'b0;
    logic in_req;
    logic signed [63:0] in_data = '0;
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
    integer group_count;
    integer group_i;
    integer lane_i;
    integer value_i;
    integer expected_i;
    integer sample_values [0:63];
    integer expected_values [0:63];
    integer stall_count;
    integer output_wait;
    integer sample_base;
    integer expected_base;
    logic signed [63:0] group_data;
    logic signed [63:0] held_data;
    logic have_held;
    integer got_lane;

    always #1 clk = ~clk;

    assign output_group_count = output_size[6:2];

    unified_p4_kernel dut (
        .clk(clk), .rst_n(rst_n), .start(start), .tr_type(tr_type),
        .transform_size(transform_size), .active_size(active_size),
        .output_size(output_size), .output_group_count(output_group_count),
        .stage_sel(stage_sel),
        .in_valid(in_valid), .in_req(in_req), .in_data(in_data),
        .out_valid(out_valid), .out_req(out_req), .out_data(out_data),
        .done(done), .busy(busy), .error(error)
    );

    task automatic run_case;
        begin
            group_count = size_i / 4;
            for (group_i = 0; group_i < group_count; group_i = group_i + 1) begin
                sample_base = group_i * 4;
                for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
                    scan_rc = $fscanf(fd, "%d", value_i);
                    if (scan_rc != 1)
                        $fatal(1, "bad input vector case=%0d group=%0d lane=%0d",
                               case_i, group_i, lane_i);
                    sample_values[sample_base + lane_i] = value_i;
                end
            end
            for (group_i = 0; group_i < group_count; group_i = group_i + 1) begin
                expected_base = group_i * 4;
                for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
                    scan_rc = $fscanf(fd, "%d", expected_i);
                    if (scan_rc != 1)
                        $fatal(1, "bad expected vector case=%0d group=%0d lane=%0d",
                               case_i, group_i, lane_i);
                    expected_values[expected_base + lane_i] = expected_i;
                end
            end

            while (busy) @(negedge clk);
            tr_type        = type_i[1:0];
            transform_size = size_i[6:0];
            active_size    = size_i[6:0];
            output_size    = size_i[6:0];
            stage_sel      = stage_i[0];

            group_data = '0;
            for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1)
                group_data[lane_i*16 +: 16] = sample_values[lane_i];
            in_data  = group_data;
            in_valid = 1'b1;
            start    = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;

            for (group_i = 1; group_i < group_count; group_i = group_i + 1) begin
                while (!in_req) @(negedge clk);
                group_data = '0;
                for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1)
                    group_data[lane_i*16 +: 16] =
                        sample_values[group_i*4 + lane_i];
                in_data = group_data;
                in_valid = 1'b1;
                @(posedge clk);
                @(negedge clk);
            end
            in_valid = 1'b0;
            in_data  = '0;

            for (group_i = 0; group_i < group_count; group_i = group_i + 1) begin
                stall_count = 0;
                have_held = 1'b0;
                while (stall_count < ((case_i + group_i) % 3)) begin
                    out_req = 1'b0;
                    @(posedge clk);
                    if (out_valid)
                        $fatal(1, "out_valid asserted without request case=%0d group=%0d",
                               case_i, group_i);
                    if (dut.output_active_q) begin
                        if (have_held && (out_data !== held_data))
                            $fatal(1, "output changed during stall case=%0d group=%0d",
                                   case_i, group_i);
                        held_data = out_data;
                        have_held = 1'b1;
                    end
                    @(negedge clk);
                    stall_count = stall_count + 1;
                end
                out_req = 1'b1;
                output_wait = 0;
                while (1) begin
                    @(posedge clk);
                    output_wait = output_wait + 1;
                    if (out_valid && out_req)
                        break;
                    if (output_wait > 512)
                        $fatal(1, "missing output fire case=%0d group=%0d", case_i, group_i);
                end
                for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
                    got_lane = $signed(out_data[lane_i*16 +: 16]);
                    if (got_lane != expected_values[group_i*4 + lane_i])
                        $fatal(1, "numeric mismatch case=%0d group=%0d lane=%0d got=%0d expected=%0d",
                               case_i, group_i, lane_i, got_lane,
                               expected_values[group_i*4 + lane_i]);
                end
                #1step;
                if (group_i == (group_count - 1)) begin
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
