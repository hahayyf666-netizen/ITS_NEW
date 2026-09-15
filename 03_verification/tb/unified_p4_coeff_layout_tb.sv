`timescale 1ns/1ps
// Exhaustive data-layout test, independent of the DUT's address functions.
// The canonical flat coefficient file is traversed sequentially by matrix.
module unified_p4_coeff_layout_tb;
    logic signed [15:0] canonical [0:8175];
    integer typ, lg, n, row, term, bundle, cursor, checked, padding;
    logic signed [15:0] observed;
    unified_p4_kernel dut (
        .clk(1'b0), .rst_n(1'b0), .start(1'b0), .tr_type(2'd0),
        .transform_size(7'd4), .active_size(7'd4), .output_size(7'd4),
        .output_group_count(6'd1),
        .stage_sel(1'b0), .in_valid(1'b0), .in_data(64'd0), .out_req(1'b0),
        .in_req(), .out_valid(), .out_data(), .done(), .busy(), .error()
    );
    initial begin
        $readmemh("03_verification/sim/rom_coeffs.hex", canonical);
        #1;
        cursor = 0;
        bundle = 0;
        checked = 0;
        padding = 0;
        for (typ = 0; typ < 3; typ = typ + 1)
            for (lg = 2; lg <= ((typ == 0) ? 6 : 5); lg = lg + 1) begin
                n = 1 << lg;
                for (row = 0; row < n; row = row + 1)
                    for (term = 0; term < 64; term = term + 1) begin
                        observed = dut.coeff_bundle_mem[bundle + row/4][((row%4)*64 + term)*16 +: 16];
                        if (term < n) begin
                            if (observed !== canonical[cursor])
                                $fatal(1, "COEFF_MISMATCH type=%0d n=%0d row=%0d term=%0d", typ,n,row,term);
                            cursor = cursor + 1;
                            checked = checked + 1;
                        end else begin
                            if (observed !== 16'sd0)
                                $fatal(1, "NONZERO_PADDING type=%0d n=%0d row=%0d term=%0d", typ,n,row,term);
                            padding = padding + 1;
                        end
                    end
                bundle = bundle + n/4;
            end
        if (checked != 8176 || bundle != 61 || padding != 7440)
            $fatal(1, "INCOMPLETE_LAYOUT_COVERAGE");
        $display("P4_COEFF_LAYOUT_PASS canonical=8176 padding=7440 bundles=61");
        $finish;
    end
endmodule
