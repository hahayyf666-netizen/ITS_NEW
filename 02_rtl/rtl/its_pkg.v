// ===================================================================
// ITS Shared Package - Common functions and state encodings
// Used by its_top.v and its_core_500.v
// Include guard prevents redefinition when both `include and
// standalone compilation are present in the same build.
// ===================================================================

`ifndef ITS_PKG_V
`define ITS_PKG_V

package its_pkg;

    // State machine encoding
    localparam S_IDLE      = 4'd0;
    localparam S_LOAD      = 4'd1;
    localparam S_ROW_START = 4'd2;
    localparam S_ROW_RUN   = 4'd3;
    localparam S_COL_START = 4'd4;
    localparam S_COL_RUN   = 4'd5;
    localparam S_OUT       = 4'd6;
    localparam S_DONE      = 4'd7;
    localparam S_LFNST     = 4'd8;
    localparam S_CLEAR     = 4'd9;

    // row * tu_width via case-shift (replaces 12-bit multiplier)
    function [11:0] row_times_width;
        input [1:0] row;
        input [6:0] tw;
        begin
            case (tw)
                7'd4:    row_times_width = {8'd0, row, 2'd0};
                7'd8:    row_times_width = {7'd0, row, 3'd0};
                7'd16:   row_times_width = {6'd0, row, 4'd0};
                7'd32:   row_times_width = {5'd0, row, 5'd0};
                7'd64:   row_times_width = {4'd0, row, 6'd0};
                default: row_times_width = {8'd0, row, 2'd0};
            endcase
        end
    endfunction

endpackage

`endif
