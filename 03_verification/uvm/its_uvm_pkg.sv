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

        `uvm_object_utils(its_out_item)

        function new(string name = "its_out_item");
            super.new(name);
        endfunction
    endclass

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

        // Output grant with real back-pressure: the DUT must hold its pending
        // beat stable across the stalled cycles the monitor keeps sampling.
        task drive_output_grant();
            int unsigned cyc = 0;
            forever begin
                @(negedge vif.clk);
                cyc++;
                vif.it_data_out_req <= !((cyc % 7) == 2 || (cyc % 11) == 5);
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
            if (vif == null) `uvm_fatal("ITS_MON", "monitor has no virtual interface")
            forever begin
                @(posedge vif.clk);
                if (vif.it_data_out_vld && vif.it_data_out_req) begin
                    item      = its_out_item::type_id::create("beat");
                    item.data = vif.it_data_out;
                    item.done = vif.it_done;
                    item.cyc  = $time;
                    ap.write(item);
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
    // Environment
    // ------------------------------------------------------------------
    class its_env extends uvm_env;
        uvm_sequencer #(its_tu_item) seqr;
        its_driver   drv;
        its_monitor  mon;
        its_scoreboard sb;

        `uvm_component_utils(its_env)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            seqr = new("seqr", this);
            drv  = its_driver::type_id::create("drv", this);
            mon  = its_monitor::type_id::create("mon", this);
            sb   = its_scoreboard::type_id::create("sb", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            drv.seq_item_port.connect(seqr.seq_item_export);
            drv.ap_expected.connect(sb.imp_expected);
            mon.ap.connect(sb.imp_actual);
            mon.ap_err.connect(sb.imp_err);
            `uvm_info("ITS_ENV", "sequencer->driver, driver->scoreboard, monitor->scoreboard", UVM_LOW)
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
        // The bound is expressed in clock cycles so it does not depend on the
        // time unit visible inside the package.
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