// D3 minimal UVM protocol layer for the VVC ITS inverse-transform DUT.
//
// Scope is deliberately narrow (plan block D3-63): agent + driver + monitor +
// scoreboard with an independent golden source, plus three sequences.  The
// numerics are NOT recomputed here: expected beats come from the project's own
// vector file produced by generate_gate_c_hdl_vectors.py from the VTM10 oracle,
// so the UVM layer adds protocol checking, not a second numeric model.

`ifndef ITS_UVM_PKG_SV
`define ITS_UVM_PKG_SV

package its_uvm_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    localparam int MAX_INPUTS = 16;
    localparam int MAX_BEATS  = 1024;

    // A scoreboard with three analysis exports needs one declared implementation
    // type per suffix; these macros synthesise uvm_analysis_imp_<suffix>.
    `uvm_analysis_imp_decl(_expected)
    `uvm_analysis_imp_decl(_actual)
    `uvm_analysis_imp_decl(_err)

    // ------------------------------------------------------------------
    // Transaction: one transform unit (TU) with its independent golden beats
    // ------------------------------------------------------------------
    class its_tu_item extends uvm_sequence_item;
        logic [21:0] case_desc   = '0;
        int unsigned input_count = 0;
        int          input_addr  [MAX_INPUTS];
        int          input_value [MAX_INPUTS];
        int unsigned beat_count  = 0;
        logic [39:0] expected    [MAX_BEATS];
        string       tag         = "tu";
        bit          illegal_desc = 1'b0;

        `uvm_object_utils(its_tu_item)

        function new(string name = "its_tu_item");
            super.new(name);
        endfunction

        function int unsigned width();
            return case_desc[6:0];
        endfunction

        function int unsigned height();
            return case_desc[13:7];
        endfunction

        virtual function string convert2string();
            return $sformatf("%s w=%0d h=%0d in=%0d beats=%0d%s",
                             tag, width(), height(), input_count, beat_count,
                             illegal_desc ? " ILLEGAL" : "");
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Output beat as observed by the monitor
    // ------------------------------------------------------------------
    class its_out_item extends uvm_object;
        logic [39:0] data = '0;
        bit          done = 1'b0;
        time         cyc  = 0;
        // Back-pressure observed before this beat: how many consecutive cycles
        // the DUT had a beat pending while the grant was low, and which stages
        // were busy during those cycles (see its_phase_e).
        int unsigned stall_depth = 0;
        bit   [4:0]  stall_phases = 5'b0;

        `uvm_object_utils(its_out_item)

        function new(string name = "its_out_item");
            super.new(name);
        endfunction
    endclass

    // Stage attribution for a stalled output cycle.
    typedef enum bit [2:0] {
        PH_SCRUB   = 3'd0,
        PH_FILL    = 3'd1,
        PH_LFNST   = 3'd2,
        PH_COMPUTE = 3'd3,
        PH_OUTPUT  = 3'd4
    } its_phase_e;

    // ------------------------------------------------------------------
    // Case database: loads the project vector file once per simulation
    // ------------------------------------------------------------------
    class its_case_db;
        static its_tu_item items[$];
        static bit         loaded = 1'b0;
        static int unsigned load_count = 0;

        static function int unsigned load(string path);
            int          fd;
            int          rc;
            int          n;
            int          i;
            int          j;
            int          ic;
            int          bc;
            logic [21:0] desc;
            its_tu_item  it;

            if (loaded) return load_count;
            fd = $fopen(path, "r");
            if (fd == 0) begin
                `uvm_fatal("ITS_DB", $sformatf("cannot open vector file %s", path))
                return 0;
            end
            rc = $fscanf(fd, "%d", n);
            if (rc != 1) begin
                $fclose(fd);
                `uvm_fatal("ITS_DB", $sformatf("invalid vector header in %s", path))
                return 0;
            end
            for (i = 0; i < n; i++) begin
                rc = $fscanf(fd, "%h %d %d", desc, ic, bc);
                if (rc != 3 || ic > MAX_INPUTS || bc > MAX_BEATS) begin
                    $fclose(fd);
                    `uvm_fatal("ITS_DB", $sformatf("bad case header at case %0d", i))
                    return 0;
                end
                it = its_tu_item::type_id::create($sformatf("case%0d", i));
                it.case_desc   = desc;
                it.input_count = ic;
                it.beat_count  = bc;
                it.tag         = $sformatf("case%0d", i);
                for (j = 0; j < ic; j++) begin
                    rc = $fscanf(fd, "%d %d", it.input_addr[j], it.input_value[j]);
                end
                for (j = 0; j < bc; j++) begin
                    rc = $fscanf(fd, "%h", it.expected[j]);
                end
                items.push_back(it);
            end
            $fclose(fd);
            loaded     = 1'b1;
            load_count = n;
            `uvm_info("ITS_DB", $sformatf("loaded %0d cases from %s", n, path), UVM_LOW)
            return n;
        endfunction

        // First case whose TU is not square; used by the rectangle sequence.
        static function int unsigned first_rect_index();
            foreach (items[i]) begin
                if (items[i].width() != items[i].height()) return i;
            end
            return 0;
        endfunction

        // First case with an empty input list (sparse TU driven only by end).
        static function int unsigned first_empty_index();
            foreach (items[i]) begin
                if (items[i].input_count == 0) return i;
            end
            return 0;
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Sequences
    // ------------------------------------------------------------------
    class its_single_tu_sequence extends uvm_sequence #(its_tu_item);
        int unsigned case_index = 0;

        `uvm_object_utils(its_single_tu_sequence)

        function new(string name = "its_single_tu_sequence");
            super.new(name);
        endfunction

        task body();
            its_tu_item req;
            if (its_case_db::items.size() == 0)
                `uvm_fatal("ITS_SEQ", "case database is empty")
            req = its_case_db::items[case_index % its_case_db::items.size()];
            `uvm_info("ITS_SEQ", $sformatf("single TU %s", req.convert2string()), UVM_LOW)
            start_item(req);
            finish_item(req);
        endtask
    endclass

    class its_rect_tu_sequence extends uvm_sequence #(its_tu_item);
        `uvm_object_utils(its_rect_tu_sequence)

        function new(string name = "its_rect_tu_sequence");
            super.new(name);
        endfunction

        task body();
            its_tu_item req;
            int unsigned idx;
            idx = its_case_db::first_rect_index();
            req = its_case_db::items[idx];
            `uvm_info("ITS_SEQ", $sformatf("rectangle TU %s", req.convert2string()), UVM_LOW)
            start_item(req);
            finish_item(req);
        endtask
    endclass

    // Several TUs back to back.  The driver never waits for a TU to finish
    // draining, so a new TU is admitted while the previous one is still
    // producing output: this is the multi-TU overlap the plan asks for.
    class its_multi_tu_sequence extends uvm_sequence #(its_tu_item);
        int unsigned count       = 8;
        int unsigned start_index = 0;
        int unsigned stride      = 7;

        `uvm_object_utils(its_multi_tu_sequence)

        function new(string name = "its_multi_tu_sequence");
            super.new(name);
        endfunction

        task body();
            its_tu_item req;
            int unsigned idx;
            int unsigned n;
            n = its_case_db::items.size();
            if (n == 0) `uvm_fatal("ITS_SEQ", "case database is empty")
            for (int unsigned i = 0; i < count; i++) begin
                idx = (start_index + i * stride) % n;
                req = its_case_db::items[idx];
                `uvm_info("ITS_SEQ", $sformatf("multi TU %0d/%0d %s",
                          i + 1, count, req.convert2string()), UVM_MEDIUM)
                start_item(req);
                finish_item(req);
            end
        endtask
    endclass

    // Every case of the vector set in order.  This is the D4 stimulus: the
    // functional coverage numbers are only meaningful if the whole set runs in
    // one simulation.
    class its_full_sweep_sequence extends uvm_sequence #(its_tu_item);
        int unsigned limit = 0;   // 0 means the whole set

        `uvm_object_utils(its_full_sweep_sequence)

        function new(string name = "its_full_sweep_sequence");
            super.new(name);
        endfunction

        task body();
            int unsigned n = its_case_db::items.size();
            int unsigned m = (limit == 0 || limit > n) ? n : limit;
            if (n == 0) `uvm_fatal("ITS_SEQ", "case database is empty")
            for (int unsigned i = 0; i < m; i++) begin
                its_tu_item req = its_case_db::items[i];
                start_item(req);
                finish_item(req);
            end
            `uvm_info("ITS_SEQ", $sformatf("sweep sent %0d TUs of %0d", m, n), UVM_LOW)
        endtask
    endclass

    // Illegal descriptor: width 2 is not a legal DCT2 axis length, so the DUT
    // must raise the sticky protocol error and stop admitting input.
    class its_illegal_desc_sequence extends uvm_sequence #(its_tu_item);
        `uvm_object_utils(its_illegal_desc_sequence)

        function new(string name = "its_illegal_desc_sequence");
            super.new(name);
        endfunction

        task body();
            its_tu_item req;
            req = its_tu_item::type_id::create("illegal");
            req.case_desc    = 22'd2 | (22'd4 << 7);
            req.illegal_desc = 1'b1;
            req.input_count  = 0;
            req.beat_count   = 0;
            req.tag          = "illegal_desc";
            start_item(req);
            finish_item(req);
        endtask
    endclass

    // ------------------------------------------------------------------
    // Driver: owns every DUT input pin
    // ------------------------------------------------------------------
    class its_driver extends uvm_driver #(its_tu_item);
        virtual its_if             vif;
        uvm_analysis_port #(its_tu_item) ap_expected;

        `uvm_component_utils(its_driver)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ap_expected = new("ap_expected", this);
            if (!uvm_config_db #(virtual its_if)::get(this, "", "vif", vif))
                `uvm_fatal("ITS_DRV", "driver has no virtual interface in config db")
        endfunction

        task do_reset();
            vif.drive_idle();
            repeat (4) @(negedge vif.clk);
            vif.rst_n = 1'b1;
            repeat (2) @(negedge vif.clk);
        endtask

        task send_info(logic [21:0] value);
            @(negedge vif.clk);
            vif.it_info     = value;
            vif.it_info_vld = 1'b1;
            @(posedge vif.clk);
            @(negedge vif.clk);
            vif.it_info_vld = 1'b0;
        endtask

        task send_data(int address, int value, bit last);
            while (!vif.it_data_in_req) @(negedge vif.clk);
            vif.it_data_addr   = address[11:0];
            vif.it_data_in     = value[15:0];
            vif.it_data_in_vld = 1'b1;
            vif.it_data_end    = last;
            @(posedge vif.clk);
            @(negedge vif.clk);
            vif.it_data_in_vld = 1'b0;
            vif.it_data_end    = 1'b0;
        endtask

        // Sparse TU: no data beat, only the independent end marker.
        task send_end_only();
            while (!vif.it_data_in_req) @(negedge vif.clk);
            vif.it_data_end = 1'b1;
            @(posedge vif.clk);
            @(negedge vif.clk);
            vif.it_data_end = 1'b0;
        endtask

        // Output grant with real back-pressure.
        //
        // Two behaviours are needed to reach every back-pressure bin: a light
        // periodic stall (%7/%11) and a periodic deep stall of eight cycles.
        // The deep stall is what lets a younger TU start filling/computing
        // while an older TU is still holding a pending beat, which is the only
        // way the compute and LFNST stall phases can be observed.
        task drive_output_grant();
            int unsigned cyc  = 0;
            int unsigned hold = 0;
            forever begin
                @(negedge vif.clk);
                cyc++;
                if (hold > 0) begin
                    vif.it_data_out_req <= 1'b0;
                    hold--;
                end else if ((cyc % 64) == 0) begin
                    hold = 8;
                    vif.it_data_out_req <= 1'b0;
                end else begin
                    vif.it_data_out_req <= !((cyc % 7) == 2 || (cyc % 11) == 5);
                end
            end
        endtask

        task stream_items();
            forever begin
                seq_item_port.get_next_item(req);
                ap_expected.write(req);
                if (req.illegal_desc) begin
                    send_info(req.case_desc);
                    repeat (6) @(negedge vif.clk);
                end else begin
                    send_info(req.case_desc);
                    if (req.input_count == 0) begin
                        send_end_only();
                    end else begin
                        for (int unsigned i = 0; i < req.input_count; i++) begin
                            send_data(req.input_addr[i], req.input_value[i],
                                      i == req.input_count - 1);
                        end
                    end
                end
                seq_item_port.item_done();
            end
        endtask

        task run_phase(uvm_phase phase);
            if (vif == null) `uvm_fatal("ITS_DRV", "driver has no virtual interface")
            do_reset();
            fork
                drive_output_grant();
                stream_items();
            join
        endtask
    endclass

    // ------------------------------------------------------------------
    // Monitor: samples the output handshake and the sticky protocol error
    // ------------------------------------------------------------------
    class its_monitor extends uvm_monitor;
        virtual its_if               vif;
        uvm_analysis_port #(its_out_item) ap;
        uvm_analysis_port #(its_out_item) ap_err;
        bit prev_error = 1'b0;

        `uvm_component_utils(its_monitor)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ap     = new("ap", this);
            ap_err = new("ap_err", this);
            if (!uvm_config_db #(virtual its_if)::get(this, "", "vif", vif))
                `uvm_fatal("ITS_MON", "monitor has no virtual interface in config db")
        endfunction

        task run_phase(uvm_phase phase);
            its_out_item item;
            int unsigned depth   = 0;
            bit   [4:0]  phases  = 5'b0;
            bit          stalled = 1'b0;
            if (vif == null) `uvm_fatal("ITS_MON", "monitor has no virtual interface")
            forever begin
                @(posedge vif.clk);
                stalled = vif.dbg_output_active && !vif.it_data_out_req;
                if (stalled) begin
                    depth++;
                    // Attribute the stall to every stage that is busy now; a
                    // cycle can legitimately have more than one active.
                    if (vif.dbg_scrub_active)  phases[PH_SCRUB]   = 1'b1;
                    if (vif.dbg_fill_active)   phases[PH_FILL]    = 1'b1;
                    if (vif.dbg_lfnst_busy)    phases[PH_LFNST]   = 1'b1;
                    if (vif.dbg_kernel_busy)   phases[PH_COMPUTE] = 1'b1;
                    if (vif.dbg_output_active) phases[PH_OUTPUT]  = 1'b1;
                end
                if (vif.it_data_out_vld && vif.it_data_out_req) begin
                    item      = its_out_item::type_id::create("beat");
                    item.data = vif.it_data_out;
                    item.done = vif.it_done;
                    item.cyc  = $time;
                    item.stall_depth  = depth;
                    item.stall_phases = phases;
                    ap.write(item);
                    depth  = 0;
                    phases = 5'b0;
                end
                if (vif.protocol_error && !prev_error) begin
                    item      = its_out_item::type_id::create("err");
                    item.data = '0;
                    item.done = 1'b0;
                    item.cyc  = $time;
                    ap_err.write(item);
                end
                prev_error = vif.protocol_error;
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Scoreboard: ordered beat comparison against the independent golden
    // ------------------------------------------------------------------
    class its_scoreboard extends uvm_scoreboard;
        uvm_analysis_imp_expected #(its_tu_item,  its_scoreboard) imp_expected;
        uvm_analysis_imp_actual   #(its_out_item, its_scoreboard) imp_actual;
        uvm_analysis_imp_err      #(its_out_item, its_scoreboard) imp_err;

        its_tu_item  pending[$];
        int unsigned beat_idx       = 0;
        int unsigned tus_completed  = 0;
        int unsigned beats_seen     = 0;
        int unsigned data_errors    = 0;
        int unsigned done_errors    = 0;
        int unsigned protocol_errors = 0;
        int unsigned unexpected     = 0;
        // Counts how many TUs were admitted while an earlier TU still had
        // beats outstanding: proof that TUs actually overlap in the DUT.
        int unsigned overlap_admissions = 0;
        bit          wrong_golden   = 1'b0;

        `uvm_component_utils(its_scoreboard)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            imp_expected = new("imp_expected", this);
            imp_actual   = new("imp_actual",   this);
            imp_err      = new("imp_err",      this);
            if ($test$plusargs("WRONG_GOLDEN")) wrong_golden = 1'b1;
        endfunction

        function void write_expected(its_tu_item t);
            // A descriptor that is not even admitted by the DUT never produces
            // beats, so it must not occupy the expectation queue.
            if (t.illegal_desc) return;
            if (pending.size() > 0) overlap_admissions++;
            pending.push_back(t);
        endfunction

        function void write_actual(its_out_item item);
            its_tu_item  cur;
            logic [39:0] exp;
            bit          exp_done;

            if (pending.size() == 0) begin
                unexpected++;
                `uvm_error("ITS_UNEXPECTED_BEAT",
                           $sformatf("beat with no outstanding TU data=%010h t=%0t",
                                     item.data, item.cyc))
                return;
            end
            cur      = pending[0];
            exp      = cur.expected[beat_idx];
            exp_done = (beat_idx == cur.beat_count - 1);
            // Negative control: corrupt the golden so a vacuous checker would
            // still report a pass.
            if (wrong_golden) exp = exp ^ 40'h1;

            if (item.data !== exp) begin
                data_errors++;
                `uvm_error("ITS_DATA_MISMATCH",
                           $sformatf("%s beat=%0d/%0d got=%010h expected=%010h",
                                     cur.tag, beat_idx, cur.beat_count - 1,
                                     item.data, exp))
            end
            if (item.done !== exp_done) begin
                done_errors++;
                `uvm_error("ITS_DONE_MISMATCH",
                           $sformatf("%s beat=%0d/%0d done=%0b expected=%0b",
                                     cur.tag, beat_idx, cur.beat_count - 1,
                                     item.done, exp_done))
            end

            beats_seen++;
            if (exp_done) begin
                tus_completed++;
                void'(pending.pop_front());
                beat_idx = 0;
                `uvm_info("ITS_TU_COMPLETE",
                          $sformatf("%s finished beats=%0d tus_completed=%0d",
                                    cur.tag, cur.beat_count, tus_completed),
                          UVM_MEDIUM)
            end else begin
                beat_idx++;
            end
        endfunction

        function void write_err(its_out_item item);
            protocol_errors++;
            `uvm_error("ITS_PROTOCOL_ERROR",
                       $sformatf("sticky protocol error observed at t=%0t", item.cyc))
        endfunction

        function void check_phase(uvm_phase phase);
            super.check_phase(phase);
            if (pending.size() != 0)
                `uvm_error("ITS_INCOMPLETE_TU",
                           $sformatf("%0d TU(s) never drained their outputs",
                                     pending.size()))
            if (data_errors == 0 && done_errors == 0 && protocol_errors == 0 &&
                unexpected == 0 && pending.size() == 0)
                `uvm_info("ITS_CHECK_PASS",
                          $sformatf("tus=%0d beats=%0d overlap=%0d data_err=0 done_err=0 proto_err=0",
                                    tus_completed, beats_seen, overlap_admissions), UVM_LOW)
            else
                `uvm_info("ITS_CHECK_FAIL",
                          $sformatf("tus=%0d beats=%0d overlap=%0d data_err=%0d done_err=%0d proto_err=%0d unexpected=%0d pending=%0d",
                                    tus_completed, beats_seen, overlap_admissions,
                                    data_errors, done_errors, protocol_errors,
                                    unexpected, pending.size()), UVM_LOW)
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Functional coverage, descriptor side.
    //
    // The six dimensions come from the D4 coverage table in the plan.  Bins are
    // limited to values the DUT actually accepts (see shape_supported and
    // axis_supported in the wrapper), so a bin that never fills is a stimulus
    // gap rather than an illegal value.
    // ------------------------------------------------------------------
    class its_desc_coverage extends uvm_subscriber #(its_tu_item);

        int unsigned n_tu = 0;
        int unsigned shape_hit[5][5];   // [w][h]
        int unsigned xform_hit[3][3];   // [t0][t1]
        int unsigned lfnst_mode_hit[3]; // 0 off, 1 set1, 2 set2
        int unsigned lfnst_idx_hit[4];

        int unsigned cur_w, cur_h, cur_t0, cur_t1, cur_mode, cur_idx;

        covergroup cg_shape;
            option.per_instance = 1;
            option.name         = "its_shape";
            cp_w: coverpoint cur_w {
                bins b4[] = {4}; bins b8[] = {8}; bins b16[] = {16};
                bins b32[] = {32}; bins b64[] = {64};
            }
            cp_h: coverpoint cur_h {
                bins b4[] = {4}; bins b8[] = {8}; bins b16[] = {16};
                bins b32[] = {32}; bins b64[] = {64};
            }
            cx_wh: cross cp_w, cp_h;
        endgroup

        covergroup cg_xform;
            option.per_instance = 1;
            option.name         = "its_xform";
            cp_t0: coverpoint cur_t0 {
                bins dct2[] = {0}; bins dst7[] = {1}; bins dct8[] = {2};
            }
            cp_t1: coverpoint cur_t1 {
                bins dct2[] = {0}; bins dst7[] = {1}; bins dct8[] = {2};
            }
            cx_tt: cross cp_t0, cp_t1;
        endgroup

        covergroup cg_lfnst_mode;
            option.per_instance = 1;
            option.name         = "its_lfnst_mode";
            cp_mode: coverpoint cur_mode {
                bins off[]  = {0};
                bins set1[] = {1};
                bins set2[] = {2};
            }
        endgroup

        // Only sampled when LFNST is enabled, so all four indices are legal
        // samples rather than dead bins.
        covergroup cg_lfnst_idx;
            option.per_instance = 1;
            option.name         = "its_lfnst_idx";
            cp_idx: coverpoint cur_idx {
                bins i0[] = {0}; bins i1[] = {1}; bins i2[] = {2}; bins i3[] = {3};
            }
        endgroup

        `uvm_component_utils(its_desc_coverage)

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_shape       = new();
            cg_xform       = new();
            cg_lfnst_mode  = new();
            cg_lfnst_idx   = new();
        endfunction

        function void write(its_tu_item t);
            n_tu++;
            cur_w  = t.width();
            cur_h  = t.height();
            cur_t0 = t.case_desc[15:14];
            cur_t1 = t.case_desc[17:16];
            cur_mode = t.case_desc[21:20];
            cur_idx  = t.case_desc[19:18];
            cg_shape.sample();
            cg_xform.sample();
            cg_lfnst_mode.sample();
            if (cur_mode != 0) cg_lfnst_idx.sample();
            if (cur_w inside {4,8,16,32,64} && cur_h inside {4,8,16,32,64})
                shape_hit[wid(cur_w)][wid(cur_h)]++;
            if (cur_t0 <= 2 && cur_t1 <= 2) xform_hit[cur_t0][cur_t1]++;
            if (cur_mode <= 2) lfnst_mode_hit[cur_mode]++;
            if (cur_mode != 0) lfnst_idx_hit[cur_idx]++;
        endfunction

        function int unsigned wid(int unsigned v);
            case (v)
                4:       return 0;
                8:       return 1;
                16:      return 2;
                32:      return 3;
                default: return 4;
            endcase
        endfunction

        function int unsigned xform_hit_total();
            int unsigned n = 0;
            foreach (xform_hit[i, j]) if (xform_hit[i][j] > 0) n++;
            return n;
        endfunction

        function int unsigned shape_hit_total();
            int unsigned n = 0;
            foreach (shape_hit[i, j]) if (shape_hit[i][j] > 0) n++;
            return n;
        endfunction

        function void report_phase(uvm_phase phase);
            int unsigned mode_bins = 0;
            int unsigned idx_bins  = 0;
            super.report_phase(phase);
            foreach (lfnst_mode_hit[i]) if (lfnst_mode_hit[i] > 0) mode_bins++;
            foreach (lfnst_idx_hit[i])  if (lfnst_idx_hit[i]  > 0) idx_bins++;
            `uvm_info("ITS_CG",
                      $sformatf("ITS_CG shape %.2f bins=%0d/25 tus=%0d",
                                cg_shape.get_coverage(), shape_hit_total(), n_tu),
                      UVM_LOW)
            `uvm_info("ITS_CG",
                      $sformatf("ITS_CG xform %.2f bins=%0d/9",
                                cg_xform.get_coverage(), xform_hit_total()),
                      UVM_LOW)
            `uvm_info("ITS_CG",
                      $sformatf("ITS_CG lfnst_mode %.2f bins=%0d/3 off=%0d set1=%0d set2=%0d",
                                cg_lfnst_mode.get_coverage(), mode_bins,
                                lfnst_mode_hit[0], lfnst_mode_hit[1],
                                lfnst_mode_hit[2]), UVM_LOW)
            `uvm_info("ITS_CG",
                      $sformatf("ITS_CG lfnst_idx %.2f bins=%0d/4 i0=%0d i1=%0d i2=%0d i3=%0d",
                                cg_lfnst_idx.get_coverage(), idx_bins,
                                lfnst_idx_hit[0], lfnst_idx_hit[1],
                                lfnst_idx_hit[2], lfnst_idx_hit[3]), UVM_LOW)
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Functional coverage, output side: saturation class, back-pressure depth
    // and which stage was busy while the beat was held.
    // ------------------------------------------------------------------
    class its_out_coverage extends uvm_subscriber #(its_out_item);

        int unsigned n_beats = 0;
        int unsigned sat_hit[3];        // none / positive clamp / negative clamp
        int unsigned depth_hit[4];      // 0 / 1 / 2 / 3+
        int unsigned phase_hit[6];      // five stages + no_stall

        int unsigned cur_sat, cur_depth, cur_phase;

        covergroup cg_sat;
            option.per_instance = 1;
            option.name         = "its_sat";
            cp_sat: coverpoint cur_sat {
                bins none[]  = {0};
                bins pos[]   = {1};
                bins neg[]   = {2};
            }
        endgroup

        covergroup cg_depth;
            option.per_instance = 1;
            option.name         = "its_backpressure";
            cp_depth: coverpoint cur_depth {
                bins d0[]    = {0};
                bins d1[]    = {1};
                bins d2[]    = {2};
                bins d3plus[] = {3};
            }
        endgroup

        covergroup cg_phase;
            option.per_instance = 1;
            option.name         = "its_stall_phase";
            cp_phase: coverpoint cur_phase {
                bins scrub[]   = {0};
                bins fill[]    = {1};
                bins lfnst[]   = {2};
                bins compute[] = {3};
                bins out_stage[] = {4};
                bins no_stall[] = {5};
            }
        endgroup

        `uvm_component_utils(its_out_coverage)

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_sat   = new();
            cg_depth = new();
            cg_phase = new();
        endfunction

        function void write(its_out_item t);
            int unsigned cls = 0;
            its_out_item item;
            item = t;
            n_beats++;
            // A word saturates when any 10-bit lane sits on the clamp rail.
            foreach (item.data[i]) begin
                if (item.data[i*10 +: 10] == 10'h1FF) cls = 1;
            end
            foreach (item.data[i]) begin
                if (item.data[i*10 +: 10] == 10'h200) begin
                    cls = (cls == 1) ? 0 : 2;
                end
            end
            cur_sat = cls;
            cg_sat.sample();
            sat_hit[cls]++;

            cur_depth = (item.stall_depth >= 3) ? 3 : item.stall_depth;
            cg_depth.sample();
            depth_hit[cur_depth]++;

            if (item.stall_phases == 5'b0) begin
                cur_phase = 5;
                cg_phase.sample();
                phase_hit[5]++;
            end else begin
                for (int p = 0; p < 5; p++) begin
                    if (item.stall_phases[p]) begin
                        cur_phase = p;
                        cg_phase.sample();
                        phase_hit[p]++;
                    end
                end
            end
        endfunction

        function void report_phase(uvm_phase phase);
            int unsigned sat_bins = 0, depth_bins = 0, phase_bins = 0;
            super.report_phase(phase);
            foreach (sat_hit[i])   if (sat_hit[i]   > 0) sat_bins++;
            foreach (depth_hit[i]) if (depth_hit[i] > 0) depth_bins++;
            foreach (phase_hit[i]) if (phase_hit[i] > 0) phase_bins++;
            `uvm_info("ITS_CG",
                      $sformatf("ITS_CG sat %.2f bins=%0d/3 none=%0d pos=%0d neg=%0d",
                                cg_sat.get_coverage(), sat_bins, sat_hit[0],
                                sat_hit[1], sat_hit[2]), UVM_LOW)
            `uvm_info("ITS_CG",
                      $sformatf("ITS_CG backpressure %.2f bins=%0d/4 d0=%0d d1=%0d d2=%0d d3plus=%0d",
                                cg_depth.get_coverage(), depth_bins,
                                depth_hit[0], depth_hit[1], depth_hit[2],
                                depth_hit[3]), UVM_LOW)
            `uvm_info("ITS_CG",
                      $sformatf("ITS_CG stall_phase %.2f bins=%0d/6 scrub=%0d fill=%0d lfnst=%0d compute=%0d output=%0d none=%0d",
                                cg_phase.get_coverage(), phase_bins,
                                phase_hit[0], phase_hit[1], phase_hit[2],
                                phase_hit[3], phase_hit[4], phase_hit[5]), UVM_LOW)
            `uvm_info("ITS_CG",
                      $sformatf("ITS_CG beats=%0d", n_beats), UVM_LOW)
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Environment
    // ------------------------------------------------------------------
    class its_env extends uvm_env;
        uvm_sequencer #(its_tu_item) seqr;
        its_driver   drv;
        its_monitor  mon;
        its_scoreboard sb;
        its_desc_coverage desc_cov;
        its_out_coverage  out_cov;

        `uvm_component_utils(its_env)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            seqr     = new("seqr", this);
            drv      = its_driver::type_id::create("drv", this);
            mon      = its_monitor::type_id::create("mon", this);
            sb       = its_scoreboard::type_id::create("sb", this);
            desc_cov = its_desc_coverage::type_id::create("desc_cov", this);
            out_cov  = its_out_coverage::type_id::create("out_cov", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            drv.seq_item_port.connect(seqr.seq_item_export);
            drv.ap_expected.connect(sb.imp_expected);
            mon.ap.connect(sb.imp_actual);
            mon.ap_err.connect(sb.imp_err);
            drv.ap_expected.connect(desc_cov.analysis_export);
            mon.ap.connect(out_cov.analysis_export);
            `uvm_info("ITS_ENV", "sequencer->driver, driver->scoreboard, monitor->scoreboard, coverage subscribers attached", UVM_LOW)
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    class its_base_test extends uvm_test;
        its_env      env;
        virtual its_if vif;
        string       vector_file = "unified_gate_c_vectors.txt";

        `uvm_component_utils(its_base_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            int unsigned n;
            super.build_phase(phase);
            void'($value$plusargs("VECTOR_FILE=%s", vector_file));
            if (!uvm_config_db #(virtual its_if)::get(this, "", "vif", vif))
                `uvm_fatal("ITS_TEST", "no virtual interface in config db")
            uvm_config_db #(virtual its_if)::set(this, "env.drv", "vif", vif);
            uvm_config_db #(virtual its_if)::set(this, "env.mon", "vif", vif);
            n = its_case_db::load(vector_file);
            `uvm_info("ITS_TEST", $sformatf("case database holds %0d cases", n), UVM_LOW)
            env = its_env::type_id::create("env", this);
        endfunction

        // Wait until the scoreboard has retired `want` TUs, or time out.
        task wait_for_tus(int unsigned want, int unsigned max_cycles = 1_000_000);
            fork
                begin
                    forever begin
                        @(posedge vif.clk);
                        if (env.sb.tus_completed >= want) break;
                    end
                end
                begin
                    repeat (max_cycles) @(posedge vif.clk);
                    `uvm_fatal("ITS_TIMEOUT",
                               $sformatf("only %0d of %0d TUs completed",
                                         env.sb.tus_completed, want))
                end
            join_any
            disable fork;
        endtask

        // Machine-readable result file.
        //
        // The regression runner decides pass/fail from this file only; it never
        // parses log text.  Every value is a plain key=value pair on its own
        // line so a reader does not depend on message formatting.
        // A function, not a task: report_phase is a function and cannot call a
        // task.  Only file I/O happens here, so nothing needs time.
        function void write_result_file();
            int               fd;
            string            path;
            uvm_report_server srv;
            if (!$value$plusargs("RESULT_FILE=%s", path)) return;
            fd = $fopen(path, "w");
            if (fd == 0) begin
                `uvm_error("ITS_RESULT",
                           $sformatf("cannot open result file %s", path))
                return;
            end
            srv = uvm_report_server::get_server();
            $fdisplay(fd, "test=%s",    get_type_name());
            $fdisplay(fd, "tus=%0d",    env.sb.tus_completed);
            $fdisplay(fd, "beats=%0d",  env.sb.beats_seen);
            $fdisplay(fd, "data_errors=%0d",     env.sb.data_errors);
            $fdisplay(fd, "done_errors=%0d",     env.sb.done_errors);
            $fdisplay(fd, "protocol_errors=%0d", env.sb.protocol_errors);
            $fdisplay(fd, "unexpected=%0d",      env.sb.unexpected);
            $fdisplay(fd, "pending=%0d",         env.sb.pending.size());
            $fdisplay(fd, "overlap=%0d",         env.sb.overlap_admissions);
            $fdisplay(fd, "uvm_error=%0d", srv.get_severity_count(UVM_ERROR));
            $fdisplay(fd, "uvm_fatal=%0d", srv.get_severity_count(UVM_FATAL));
            // Functional coverage counters, one line per bin.
            for (int i = 0; i < 5; i++)
                for (int j = 0; j < 5; j++)
                    $fdisplay(fd, "cg.shape.%0d_%0d=%0d", i, j,
                              env.desc_cov.shape_hit[i][j]);
            for (int i = 0; i < 3; i++)
                for (int j = 0; j < 3; j++)
                    $fdisplay(fd, "cg.xform.%0d_%0d=%0d", i, j,
                              env.desc_cov.xform_hit[i][j]);
            for (int i = 0; i < 3; i++)
                $fdisplay(fd, "cg.lfnst_mode.%0d=%0d", i,
                          env.desc_cov.lfnst_mode_hit[i]);
            for (int i = 0; i < 4; i++)
                $fdisplay(fd, "cg.lfnst_idx.%0d=%0d", i,
                          env.desc_cov.lfnst_idx_hit[i]);
            for (int i = 0; i < 3; i++)
                $fdisplay(fd, "cg.sat.%0d=%0d", i, env.out_cov.sat_hit[i]);
            for (int i = 0; i < 4; i++)
                $fdisplay(fd, "cg.backpressure.%0d=%0d", i,
                          env.out_cov.depth_hit[i]);
            for (int i = 0; i < 6; i++)
                $fdisplay(fd, "cg.stall_phase.%0d=%0d", i,
                          env.out_cov.phase_hit[i]);
            $fclose(fd);
            `uvm_info("ITS_RESULT", $sformatf("result file written: %s", path),
                      UVM_LOW)
        endfunction

        function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            write_result_file();
        endfunction
    endclass

    class its_single_tu_test extends its_base_test;
        `uvm_component_utils(its_single_tu_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_single_tu_sequence seq;
            int unsigned idx;
            phase.raise_objection(this);
            idx = 0;
            void'($value$plusargs("CASE_INDEX=%d", idx));
            seq = its_single_tu_sequence::type_id::create("seq");
            seq.case_index = idx;
            seq.start(env.seqr);
            wait_for_tus(1);
            phase.drop_objection(this);
        endtask
    endclass

    class its_rect_tu_test extends its_base_test;
        `uvm_component_utils(its_rect_tu_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_rect_tu_sequence seq;
            phase.raise_objection(this);
            seq = its_rect_tu_sequence::type_id::create("seq");
            seq.start(env.seqr);
            wait_for_tus(1);
            phase.drop_objection(this);
        endtask
    endclass

    class its_multi_tu_test extends its_base_test;
        `uvm_component_utils(its_multi_tu_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_multi_tu_sequence seq;
            int unsigned count;
            int unsigned start;
            phase.raise_objection(this);
            count = 8;
            start = 0;
            void'($value$plusargs("TU_COUNT=%d", count));
            void'($value$plusargs("TU_START=%d", start));
            seq = its_multi_tu_sequence::type_id::create("seq");
            seq.count       = count;
            seq.start_index = start;
            seq.start(env.seqr);
            wait_for_tus(count);
            phase.drop_objection(this);
        endtask
    endclass

    class its_illegal_desc_test extends its_base_test;
        `uvm_component_utils(its_illegal_desc_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_illegal_desc_sequence seq;
            phase.raise_objection(this);
            seq = its_illegal_desc_sequence::type_id::create("seq");
            seq.start(env.seqr);
            // The DUT must answer with the sticky protocol error, not silence.
            fork
                begin
                    forever begin
                        @(posedge vif.clk);
                        if (env.sb.protocol_errors > 0) break;
                    end
                end
                begin
                    repeat (50_000) @(posedge vif.clk);
                    `uvm_fatal("ITS_NO_PROTOCOL_ERROR",
                               "illegal descriptor did not raise protocol_error")
                end
            join_any
            disable fork;
            `uvm_info("ITS_NEGATIVE_CONTROL",
                      $sformatf("illegal descriptor detected, protocol_errors=%0d",
                                env.sb.protocol_errors), UVM_LOW)
            phase.drop_objection(this);
        endtask
    endclass

    class its_sweep_test extends its_base_test;
        `uvm_component_utils(its_sweep_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_full_sweep_sequence seq;
            int unsigned limit;
            int unsigned total;
            phase.raise_objection(this);
            limit = 0;
            void'($value$plusargs("SWEEP_LIMIT=%d", limit));
            total = its_case_db::items.size();
            if (limit != 0 && limit < total) total = limit;
            seq = its_full_sweep_sequence::type_id::create("seq");
            seq.limit = limit;
            seq.start(env.seqr);
            wait_for_tus(total, 50_000_000);
            `uvm_info("ITS_SWEEP",
                      $sformatf("sweep done tus=%0d beats=%0d",
                                env.sb.tus_completed, env.sb.beats_seen), UVM_LOW)
            phase.drop_objection(this);
        endtask
    endclass

    class its_wrong_golden_test extends its_base_test;
        `uvm_component_utils(its_wrong_golden_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_single_tu_sequence seq;
            phase.raise_objection(this);
            seq = its_single_tu_sequence::type_id::create("seq");
            seq.case_index = 0;
            seq.start(env.seqr);
            wait_for_tus(1);
            // This test is SUPPOSED to fail its data comparison; the runner
            // checks that the mismatch was reported.
            phase.drop_objection(this);
        endtask
    endclass

endpackage

`endif