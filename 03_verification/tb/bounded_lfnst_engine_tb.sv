`timescale 1ns/1ps

// Focused arithmetic/issue-contract gate for bounded_lfnst_engine.  Expected
// groups are generated independently from canonical_matrices.json.
module bounded_lfnst_engine_tb;
    parameter string VECTOR_FILE = "lfnst_engine_vectors.txt";

    logic clk = 1'b0;
    always #1 clk = ~clk;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [1:0] set_idx = '0;
    logic [1:0] lfnst_idx = '0;
    logic ntrs48 = 1'b0;
    logic nonzero8 = 1'b0;
    logic signed [255:0] input_terms = '0;
    logic busy;
    logic out_valid;
    logic signed [63:0] out_data;
    logic [3:0] out_group;
    logic out_last;
    logic done;
    logic error;

    bounded_lfnst_engine dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .set_idx(set_idx), .lfnst_idx(lfnst_idx), .ntrs48(ntrs48),
        .nonzero8(nonzero8), .input_terms(input_terms),
        .busy(busy), .out_valid(out_valid), .out_data(out_data),
        .out_group(out_group), .out_last(out_last), .done(done),
        .error(error)
    );

    integer fd;
    integer scan_rc;
    integer case_count;
    integer case_i;
    integer set_i;
    integer idx_i;
    integer ntrs48_i;
    integer nonzero8_i;
    integer group_count;
    integer expected_group_i;
    integer cycles_since_output;
    integer output_count;
    integer done_count;
    logic [255:0] terms_word;
    logic [63:0] expected_group[0:11];

    task automatic run_case;
        begin
            @(negedge clk);
            set_idx = set_i[1:0];
            lfnst_idx = idx_i[1:0];
            ntrs48 = ntrs48_i[0];
            nonzero8 = nonzero8_i[0];
            input_terms = terms_word;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            output_count = 0;
            done_count = 0;
            cycles_since_output = 0;
            while (done_count == 0) begin
                @(negedge clk);
                cycles_since_output = cycles_since_output + 1;
                if (error)
                    $fatal(1, "engine error case=%0d", case_i);
                if (out_valid) begin
                    if (out_group !== expected_group_i[3:0])
                        $fatal(1, "group mismatch case=%0d got=%0d expected=%0d",
                               case_i, out_group, expected_group_i);
                    if (out_data !== expected_group[expected_group_i])
                        $fatal(1,
                               "data mismatch case=%0d group=%0d got=%016h expected=%016h",
                               case_i, expected_group_i, out_data,
                               expected_group[expected_group_i]);
                    if ((out_last !== (expected_group_i == group_count - 1)) ||
                        (done !== (expected_group_i == group_count - 1)))
                        $fatal(1, "last/done mismatch case=%0d group=%0d",
                               case_i, expected_group_i);
                    if ((output_count != 0) && (cycles_since_output != 1))
                        $fatal(1,
                               "issue II mismatch case=%0d group=%0d gap=%0d",
                               case_i, expected_group_i, cycles_since_output);
                    cycles_since_output = 0;
                    output_count = output_count + 1;
                    expected_group_i = expected_group_i + 1;
                    if (done)
                        done_count = done_count + 1;
                end else if (done || out_last) begin
                    $fatal(1, "spurious done/last case=%0d", case_i);
                end
                if (cycles_since_output > 32)
                    $fatal(1, "engine timeout case=%0d", case_i);
            end
            if (output_count != group_count || expected_group_i != group_count)
                $fatal(1, "group count mismatch case=%0d got=%0d expected=%0d",
                       case_i, output_count, group_count);
            @(negedge clk);
            if (out_valid || done || out_last || busy)
                $fatal(1, "engine did not return idle case=%0d", case_i);
        end
    endtask

    initial begin
        fd = $fopen(VECTOR_FILE, "r");
        if (fd == 0)
            $fatal(1, "cannot open %s", VECTOR_FILE);
        scan_rc = $fscanf(fd, "%d", case_count);
        if (scan_rc != 1)
            $fatal(1, "invalid vector header");

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        for (case_i = 0; case_i < case_count; case_i = case_i + 1) begin
            scan_rc = $fscanf(fd, "%d %d %d %d %h %d",
                              set_i, idx_i, ntrs48_i, nonzero8_i,
                              terms_word, group_count);
            if (scan_rc != 6 || group_count < 1 || group_count > 12)
                $fatal(1, "invalid case header case=%0d", case_i);
            for (expected_group_i = 0; expected_group_i < group_count;
                 expected_group_i = expected_group_i + 1) begin
                scan_rc = $fscanf(fd, "%h", expected_group[expected_group_i]);
                if (scan_rc != 1)
                    $fatal(1, "invalid expected group case=%0d group=%0d",
                           case_i, expected_group_i);
            end
            expected_group_i = 0;
            run_case();
        end

        $fclose(fd);
        $display("LFNST_ENGINE_TB_PASS cases=%0d", case_count);
        $finish;
    end
endmodule
