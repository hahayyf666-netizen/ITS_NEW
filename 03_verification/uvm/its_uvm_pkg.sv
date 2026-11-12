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

        // Stimulus controls for the negative and reset tests.  They live on the
        // item so a sequence can express "drive this, then do something odd"
        // without the driver knowing any test name.
        int unsigned gap_cycles    = 0;      // idle clocks before the descriptor
        bit          trigger_reset = 1'b0;   // abort mid-flight with a reset
        bit          stray_end     = 1'b0;   // end marker with no TU outstanding
        bit          skip_end      = 1'b0;   // never close the fill
        bit          short_beats   = 1'b0;   // stop halfway through the inputs
        int unsigned addr_overrun  = 0;      // added to the last beat address
        // Push this many descriptors back to back before driving data.  The
        // scrub window keeps bind_event low for INPUT_VALID_WORDS cycles, so a
        // burst larger than the queue depth drives desc_count to 2 and trips
        // the "descriptor queue full without a bind" guard.
        int unsigned desc_burst    = 1;
        // End marker that belongs to a descriptor already sitting in the queue
        // rather than to the slot being filled.  The DUT parks it in
        // end_seen_desc[] and hands it to the slot at bind time; such a TU
        // retires with zero data, so the golden expectation is all zeros.
        bit          end_only_queued = 1'b0;
        // Retire this TU as zero-data (end inside the scrub window) and check
        // it against an all-zero golden instead of the database vector.
        bit          zero_golden   = 1'b0;
        // 0 = normal; 1 = end marker once the fill window is open; 2 = end
        // marker during the pre-fill scrub window, which makes the DUT retire
        // the TU as zero-data instead of opening a fill.
        int unsigned sparse_mode   = 0;

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

        // Without this, uvm_object::copy() silently copies nothing, which makes
        // a derived item look like a zero descriptor.  Sequences copy DB entries
        // so the per-test knobs never leak back into the shared database.
        virtual function void do_copy(uvm_object rhs);
            its_tu_item src;
            if (!$cast(src, rhs)) return;
            super.do_copy(rhs);
            case_desc     = src.case_desc;
            input_count   = src.input_count;
            beat_count    = src.beat_count;
            tag           = src.tag;
            illegal_desc  = src.illegal_desc;
            gap_cycles    = src.gap_cycles;
            trigger_reset = src.trigger_reset;
            stray_end     = src.stray_end;
            skip_end      = src.skip_end;
            short_beats   = src.short_beats;
            addr_overrun  = src.addr_overrun;
            desc_burst    = src.desc_burst;
            sparse_mode   = src.sparse_mode;
            end_only_queued = src.end_only_queued;
            zero_golden   = src.zero_golden;
            for (int i = 0; i < MAX_INPUTS; i++) begin
                input_addr[i]  = src.input_addr[i];
                input_value[i] = src.input_value[i];
            end
            for (int i = 0; i < src.beat_count; i++)
                expected[i] = src.expected[i];
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Report server: counts messages by (severity, id).
    //
    // UVM 1.1d only offers get_id_count(id) and get_severity_count(severity),
    // so an id-level expectation cannot be paired with its severity through the
    // stock server.  Overriding compose_message supplies that pairing without
    // having to instrument every call site.
    // ------------------------------------------------------------------
    class its_report_server extends uvm_report_server;
        int unsigned err_id[string];   // UVM_ERROR counts per id
        int unsigned fat_id[string];   // UVM_FATAL counts per id
        int unsigned tot_err = 0;
        int unsigned tot_fat = 0;

        function new();
            super.new();
        endfunction

        virtual function string compose_message(uvm_severity severity,
                                                string name,
                                                string id,
                                                string message,
                                                string filename,
                                                int line);
            if (severity == UVM_ERROR) begin
                err_id[id] = err_id.exists(id) ? (err_id[id] + 1) : 1;
                tot_err++;
            end else if (severity == UVM_FATAL) begin
                fat_id[id] = fat_id.exists(id) ? (fat_id[id] + 1) : 1;
                tot_fat++;
            end
            return super.compose_message(severity, name, id, message,
                                         filename, line);
        endfunction
    endclass

    // Package-scope handle: the result writer reads the counters from here.
    its_report_server its_srv = null;

    // ------------------------------------------------------------------
    // Output beat as observed by the monitor
    // ------------------------------------------------------------------
    class its_out_item extends uvm_object;
        logic [39:0] data = '0;
        // Four-state on purpose: the interface signal is `logic`, and folding an
        // X into 1'b0 here would let a broken beat pass the done check.
        logic        done = 1'b0;
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
    // Output-side back-pressure request.  its_grant_driver owns the
    // it_data_out_req pin; this item only describes the stall profile.
    // ------------------------------------------------------------------
    class its_grant_item extends uvm_sequence_item;
        rand bit          always_grant    = 1'b0;
        rand int unsigned light_mod       = 7;    // light stall period
        rand int unsigned light_off       = 11;
        rand int unsigned deep_period     = 64;   // deep stall period
        rand int unsigned deep_len        = 8;    // deep stall length
        // How long this profile applies before the driver reverts to the
        // default profile.  0 means "until superseded".
        int unsigned      duration_cycles = 0;

        constraint c_light { light_mod   inside {[3:13]};
                             light_off   inside {[3:13]}; }
        constraint c_deep  { deep_period inside {[8:128]};
                             deep_len    inside {[1:16]}; }
        constraint c_dur   { duration_cycles inside {[100:8000]}; }

        `uvm_object_utils(its_grant_item)

        function new(string name = "its_grant_item");
            super.new(name);
        endfunction

        virtual function string convert2string();
            return $sformatf("grant always=%0b light=%0d/%0d deep=%0d/%0d dur=%0d",
                             always_grant, light_mod, light_off,
                             deep_period, deep_len, duration_cycles);
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Virtual sequencer: coordinates the stimulus agent and the back-pressure
    // agent.  The DUT has a single input channel and a single output channel,
    // so a second stimulus agent would only double-drive the same pins; the
    // second agent here is the one that genuinely has its own pin group.
    //
    // Declared before the sequences that reference it: SystemVerilog needs the
    // type to exist before `uvm_declare_p_sequencer expands.
    // ------------------------------------------------------------------
    class its_virtual_sequencer extends uvm_sequencer;
        uvm_sequencer #(its_tu_item)    in_seqr;
        uvm_sequencer #(its_grant_item) grant_seqr;

        `uvm_component_utils(its_virtual_sequencer)

        function new(string name, uvm_component parent);
            super.new(name, parent);
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

    // ------------------------------------------------------------------
    // Negative stimulus: each one violates exactly one rule the wrapper checks,
    // so the expected reaction is traceable to a specific RTL line.
    // ------------------------------------------------------------------
    // LFNST enabled while a transform type is non-zero: descriptor_legal drops
    // at unified_its_wrapper.sv:775-778, and :2430 raises protocol_error.
    class its_lfnst_xform_sequence extends uvm_sequence #(its_tu_item);
        `uvm_object_utils(its_lfnst_xform_sequence)

        function new(string name = "its_lfnst_xform_sequence");
            super.new(name);
        endfunction

        task body();
            its_tu_item req = its_tu_item::new("lfnst_bad_xform");
            req.case_desc = '0;
            req.case_desc[6:0]   = 7'd4;   // 4 wide
            req.case_desc[13:7]  = 7'd4;   // 4 high
            req.case_desc[15:14] = 2'd1;   // DST-VII, illegal with LFNST
            req.case_desc[17:16] = 2'd0;
            req.case_desc[19:18] = 2'd0;
            req.case_desc[21:20] = 2'd1;   // LFNST set 1
            req.input_count      = 0;
            req.illegal_desc     = 1'b1;
            req.tag              = "neg_lfnst_xform";
            start_item(req);
            finish_item(req);
        endtask
    endclass

    // LFNST mode 3: the encoding only allows 1 or 2, see
    // unified_its_wrapper.sv:780-781.
    class its_lfnst_mode3_sequence extends uvm_sequence #(its_tu_item);
        `uvm_object_utils(its_lfnst_mode3_sequence)

        function new(string name = "its_lfnst_mode3_sequence");
            super.new(name);
        endfunction

        task body();
            its_tu_item req = its_tu_item::new("lfnst_mode3");
            req.case_desc = '0;
            req.case_desc[6:0]   = 7'd8;
            req.case_desc[13:7]  = 7'd8;
            req.case_desc[21:20] = 2'd3;   // not a legal LFNST mode
            req.input_count      = 0;
            req.illegal_desc     = 1'b1;
            req.tag              = "neg_lfnst_mode3";
            start_item(req);
            finish_item(req);
        endtask
    endclass

    // Data beat addressed past the last point of the TU: caught by
    // unified_its_wrapper.sv:2434-2436 while filling.
    class its_addr_overrun_sequence extends uvm_sequence #(its_tu_item);
        `uvm_object_utils(its_addr_overrun_sequence)

        function new(string name = "its_addr_overrun_sequence");
            super.new(name);
        endfunction

        task body();
            its_tu_item req;
            req = its_tu_item::new("addr_overrun");
            if (its_case_db::items.size() == 0)
                `uvm_fatal("ITS_SEQ", "case database is empty")
            req.copy(its_case_db::items[0]);
            req.tag          = "neg_addr_overrun";
            req.addr_overrun = 16;   // 4x4 has 16 points, so index 15 is last
            start_item(req);
            finish_item(req);
        endtask
    endclass

    // End marker with no TU outstanding: unified_its_wrapper.sv:2438-2439.
    class its_stray_end_sequence extends uvm_sequence #(its_tu_item);
        `uvm_object_utils(its_stray_end_sequence)

        function new(string name = "its_stray_end_sequence");
            super.new(name);
        endfunction

        task body();
            its_tu_item req = its_tu_item::new("stray_end");
            req.stray_end = 1'b1;
            req.tag       = "neg_stray_end";
            start_item(req);
            finish_item(req);
        endtask
    endclass

    // Fill never closed: the TU cannot compute, so no beat may appear and the
    // scoreboard ends the run with one TU still outstanding.
    class its_no_end_sequence extends uvm_sequence #(its_tu_item);
        `uvm_object_utils(its_no_end_sequence)

        function new(string name = "its_no_end_sequence");
            super.new(name);
        endfunction

        task body();
            its_tu_item req;
            if (its_case_db::items.size() == 0)
                `uvm_fatal("ITS_SEQ", "case database is empty")
            req = its_tu_item::new("no_end");
            req.copy(its_case_db::items[0]);
            req.tag      = "neg_no_end";
            req.skip_end = 1'b1;
            start_item(req);
            finish_item(req);
        endtask
    endclass

    // Half the inputs, then end: a short TU must not reproduce the golden.
    class its_short_beats_sequence extends uvm_sequence #(its_tu_item);
        `uvm_object_utils(its_short_beats_sequence)

        function new(string name = "its_short_beats_sequence");
            super.new(name);
        endfunction

        task body();
            its_tu_item req;
            if (its_case_db::items.size() == 0)
                `uvm_fatal("ITS_SEQ", "case database is empty")
            req = its_tu_item::new("short_beats");
            req.copy(its_case_db::items[0]);
            req.tag         = "neg_short_beats";
            req.short_beats = 1'b1;
            start_item(req);
            finish_item(req);
        endtask
    endclass

    // Two real TUs, then a reset while beats are still streaming, then one more
    // TU that must come out bit-exact.  Proves the DUT restarts cleanly.
    class its_reset_sequence extends uvm_sequence #(its_tu_item);
        `uvm_object_utils(its_reset_sequence)

        function new(string name = "its_reset_sequence");
            super.new(name);
        endfunction

        task body();
            its_tu_item req;
            if (its_case_db::items.size() < 3)
                `uvm_fatal("ITS_SEQ", "case database too small for reset test")
            for (int unsigned i = 0; i < 2; i++) begin
                req = its_tu_item::new($sformatf("pre_reset_%0d", i));
                req.copy(its_case_db::items[i]);
                req.tag = $sformatf("pre_reset_%0d", i);
                start_item(req);
                finish_item(req);
            end
            req = its_tu_item::new("reset_marker");
            req.trigger_reset = 1'b1;
            req.tag           = "reset_marker";
            start_item(req);
            finish_item(req);
            req = its_tu_item::new("post_reset");
            req.copy(its_case_db::items[2]);
            req.tag = "post_reset";
            start_item(req);
            finish_item(req);
        endtask
    endclass

    // ------------------------------------------------------------------
    // Constrained random stimulus.
    //
    // The golden beats still come from the vector file, so the randomisation is
    // over which legal cases are drawn, in what order, and with what idle gaps.
    // A shape mask makes the draw cover a random subset of the 25 legal shapes
    // instead of drifting towards whatever the file happens to list first.
    // ------------------------------------------------------------------
    class its_random_sequence extends uvm_sequence #(its_tu_item);
        rand int unsigned n_tu;
        rand bit [24:0]   shape_pick;   // one bit per (w,h) combination
        rand int unsigned max_gap;
        // Set by the test when it wants to randomize up front and know n_tu.
        bit pre_randomized = 1'b0;

        constraint c_count { n_tu inside {[8:20]}; }
        constraint c_gap   { max_gap inside {[0:6]}; }
        constraint c_pop   { $countones(shape_pick) inside {[4:10]}; }

        `uvm_object_utils(its_random_sequence)

        function new(string name = "its_random_sequence");
            super.new(name);
        endfunction

        function int unsigned shape_bit(int unsigned w, int unsigned h);
            int unsigned wi, hi;
            case (w)
                4:       wi = 0;
                8:       wi = 1;
                16:      wi = 2;
                32:      wi = 3;
                default: wi = 4;
            endcase
            case (h)
                4:       hi = 0;
                8:       hi = 1;
                16:      hi = 2;
                32:      hi = 3;
                default: hi = 4;
            endcase
            return wi * 5 + hi;
        endfunction

        task body();
            its_tu_item req;
            int unsigned pool[$];
            int unsigned total;
            int unsigned drawn;
            int unsigned tmp;
            int unsigned sel;

            total = its_case_db::items.size();
            if (total == 0) `uvm_fatal("ITS_SEQ", "case database is empty")
            if (!pre_randomized && !randomize())
                `uvm_fatal("ITS_SEQ", "cannot randomize sequence")

            // Collect the case indices whose shape is in the picked mask.
            foreach (its_case_db::items[i]) begin
                its_tu_item c = its_case_db::items[i];
                if (shape_pick[shape_bit(c.width(), c.height())])
                    pool.push_back(i);
            end
            if (pool.size() == 0)
                for (int unsigned i = 0; i < total; i++) pool.push_back(i);

            `uvm_info("ITS_RAND",
                      $sformatf("n_tu=%0d mask=%05h pool=%0d max_gap=%0d",
                                n_tu, shape_pick, pool.size(), max_gap),
                      UVM_LOW)

            for (int unsigned k = 0; k < n_tu; k++) begin
                // Fisher-Yates style draw without replacement from the pool,
                // falling back to a fresh random pick once it is exhausted.
                if (pool.size() > 0) begin
                    sel = $urandom_range(pool.size() - 1, 0);
                    drawn = pool[sel];
                    tmp = pool[sel];
                    pool[sel] = pool[pool.size() - 1];
                    pool[pool.size() - 1] = tmp;
                    void'(pool.pop_back());
                end else begin
                    drawn = $urandom_range(total - 1, 0);
                end
                req = its_tu_item::new($sformatf("rand_%0d", k));
                req.copy(its_case_db::items[drawn]);
                req.tag        = $sformatf("rand_%0d_case%0d", k, drawn);
                req.gap_cycles = $urandom_range(max_gap, 0);
                start_item(req);
                finish_item(req);
            end
        endtask
    endclass

    // ------------------------------------------------------------------
    // Multi-agent sequences
    // ------------------------------------------------------------------
    // Back-pressure profile sequence: a few disturbing windows, then the driver
    // reverts to its default profile by itself.
    class its_grant_profile_sequence extends uvm_sequence #(its_grant_item);
        `uvm_object_utils(its_grant_profile_sequence)

        // single == 1 replaces the three-window script with one window, used
        // by the tail-stress virtual sequence to hold the grant closed for a
        // long, exactly-known stretch.
        bit          single   = 1'b0;
        int unsigned s_mod    = 7;
        int unsigned s_off    = 11;
        int unsigned s_dper   = 1;
        int unsigned s_dlen   = 600;
        int unsigned s_dur    = 600;

        function new(string name = "its_grant_profile_sequence");
            super.new(name);
        endfunction

        task send(bit always_grant, int unsigned lmod, int unsigned loff,
                  int unsigned dper, int unsigned dlen, int unsigned dur);
            its_grant_item g = its_grant_item::type_id::create("g");
            g.always_grant    = always_grant;
            g.light_mod       = lmod;
            g.light_off       = loff;
            g.deep_period     = dper;
            g.deep_len        = dlen;
            g.duration_cycles = dur;
            start_item(g);
            finish_item(g);
        endtask

        task body();
            if (single) begin
                send(1'b0, s_mod, s_off, s_dper, s_dlen, s_dur);
                return;
            end
            // Tight stalls early, then a long grant-open window, then a deep
            // stall pattern.  Each window is long enough to straddle a TU
            // boundary, which is what makes the two agents actually interact.
            send(1'b0, 5, 9,  32,  4, 6000);
            send(1'b1, 7, 11, 64,  8, 3000);
            send(1'b0, 3, 5,  24, 10, 6000);
        endtask
    endclass

    // Virtual sequence: runs the stimulus on the input agent while the
    // back-pressure agent changes the output timing underneath it.
    class its_vseq_stress extends uvm_sequence;
        `uvm_declare_p_sequencer(its_virtual_sequencer)

        int unsigned tu_count = 12;
        int unsigned tu_start = 0;

        `uvm_object_utils(its_vseq_stress)

        function new(string name = "its_vseq_stress");
            super.new(name);
        endfunction

        task body();
            its_multi_tu_sequence     stim;
            its_grant_profile_sequence prof;
            `uvm_info("ITS_VSEQ",
                      $sformatf("vseq tu_count=%0d tu_start=%0d",
                                tu_count, tu_start), UVM_LOW)
            fork
                begin
                    stim = its_multi_tu_sequence::type_id::create("stim");
                    stim.count       = tu_count;
                    stim.start_index = tu_start;
                    stim.start(p_sequencer.in_seqr);
                end
                begin
                    prof = its_grant_profile_sequence::type_id::create("prof");
                    prof.start(p_sequencer.grant_seqr);
                end
            join
            `uvm_info("ITS_VSEQ", "vseq done", UVM_LOW)
        endtask
    endclass

    // Raw-capture tail stress: the widest TU in the database driven against a
    // long output-grant blackout.
    //
    // The H read sequencer keeps one group of bank responses in a registered
    // head and has a one-deep tail for the case where the kernel consumer
    // misses a fire while the request pipeline is still producing words.  The
    // tail only fills when the consumer stalls (kernel input not accepted)
    // while at least two groups remain in the row, so this needs both a wide
    // transform (cut_w > 4, i.e. more than one H group per row) and a stall
    // long enough to reach the kernel.  Nothing in the directed flows paired
    // those two, which is why the tail path stayed dark.
    class its_vseq_tail_stress extends uvm_sequence;
        `uvm_declare_p_sequencer(its_virtual_sequencer)

        int unsigned stall_cycles = 600;
        int unsigned pick         = 0;   // index override, 0 = widest

        `uvm_object_utils(its_vseq_tail_stress)

        function new(string name = "its_vseq_tail_stress");
            super.new(name);
        endfunction

        task body();
            its_multi_tu_sequence    stim;
            its_grant_profile_sequence prof;
            int unsigned             best;
            int unsigned             cand;

            if (its_case_db::items.size() == 0)
                `uvm_fatal("ITS_SEQ", "case database is empty")

            // Widest transform wins: cut_w > 4 is what gives a row more than
            // one H read group, and the tail can only fill when a second group
            // is in flight while the consumer stalls.
            best = pick;
            if (best == 0) begin
                best = 1;
                for (int i = 1; i < its_case_db::items.size(); i++)
                    if (its_case_db::items[i].beat_count >
                        its_case_db::items[best-1].beat_count)
                        best = i + 1;
            end
            cand = best - 1;
            `uvm_info("ITS_VSEQ",
                      $sformatf("tail stress: case%0d inputs=%0d beats=%0d stall=%0d",
                                cand, its_case_db::items[cand].input_count,
                                its_case_db::items[cand].beat_count,
                                stall_cycles), UVM_LOW)

            // The sequence must run on the stimulus sequencer itself; calling
            // start_item/finish_item from the virtual sequence would hand the
            // item to a sequencer that has no driver, and finish_item would
            // wait for an item_done that never comes.
            fork
                begin
                    stim = its_multi_tu_sequence::type_id::create("stim");
                    stim.count       = 1;
                    stim.start_index = cand;
                    stim.start(p_sequencer.in_seqr);
                end
                begin
                    // Held from before the descriptor, so the stall is already
                    // in force when the kernel reaches its first H row.
                    prof = its_grant_profile_sequence::type_id::create("prof");
                    prof.single = 1'b1;
                    prof.s_dper = 1;
                    prof.s_dlen = stall_cycles;
                    prof.s_dur  = stall_cycles;
                    prof.start(p_sequencer.grant_seqr);
                end
            join
        endtask
    endclass

    // Zero-data TU: the descriptor is followed by an end marker inside the scrub
    // window, so the DUT retires the slot as READY without ever opening a fill.
    class its_zero_data_sequence extends uvm_sequence #(its_tu_item);
        // 2 = end inside the scrub window (retire as zero-data),
        // 0 = end once the fill window is open (end-only marker, no beat)
        int unsigned mode = 2;

        `uvm_object_utils(its_zero_data_sequence)

        function new(string name = "its_zero_data_sequence");
            super.new(name);
        endfunction

        task body();
            its_tu_item req;
            if (its_case_db::items.size() == 0)
                `uvm_fatal("ITS_SEQ", "case database is empty")
            req = its_tu_item::new("zero_data");
            req.copy(its_case_db::items[0]);
            req.tag         = (mode == 2) ? "zero_data_scrub" : "zero_data_fill";
            req.input_count = 0;
            req.sparse_mode = mode;
            start_item(req);
            finish_item(req);
        endtask
    endclass

    // Descriptor flood: four descriptors pushed while the scrub window still
    // blocks bind_event, so desc_count reaches 2 and the next push trips the
    // "queue full without a bind" guard.  No data follows.
    class its_desc_flood_sequence extends uvm_sequence #(its_tu_item);
        `uvm_object_utils(its_desc_flood_sequence)

        function new(string name = "its_desc_flood_sequence");
            super.new(name);
        endfunction

        task body();
            its_tu_item req;
            if (its_case_db::items.size() == 0)
                `uvm_fatal("ITS_SEQ", "case database is empty")
            req = its_tu_item::new("desc_flood");
            req.copy(its_case_db::items[0]);
            req.tag         = "desc_flood";
            req.input_count = 0;
            req.skip_end    = 1'b1;
            req.desc_burst  = 4;
            start_item(req);
            finish_item(req);
        endtask
    endclass

    // A second TU waits in the descriptor queue while the first one is still
    // being processed, and its end marker arrives before the second TU binds.
    //
    // The wrapper has an explicit path for that (end_to_queue_store): the end is
    // parked in end_seen_desc[] and handed to the slot at bind time.  Every
    // other sequence sends an end only while a slot owns it, so that whole path
    // stayed dark even though the RTL is written to accept it.
    class its_queued_end_sequence extends uvm_sequence #(its_tu_item);
        `uvm_object_utils(its_queued_end_sequence)

        int unsigned pick = 0;

        function new(string name = "its_queued_end_sequence");
            super.new(name);
        endfunction

        task body();
            its_tu_item req;
            its_tu_item tail;
            int unsigned cand;

            if (its_case_db::items.size() == 0)
                `uvm_fatal("ITS_SEQ", "case database is empty")

            cand = pick;
            if (cand >= its_case_db::items.size()) cand = 0;

            // Head: two descriptors pushed back to back, so the second one has
            // to queue up behind the first.  The head gets its own data and end.
            req = its_tu_item::new("queued_end");
            req.copy(its_case_db::items[cand]);
            req.tag        = "queued_end";
            req.desc_burst = 2;
            req.skip_end   = 1'b0;
            start_item(req);
            finish_item(req);

            // The queued TU is still missing its end, so this extra end belongs
            // to it.  It is sent without waiting for it_data_in_req because a
            // queue-owned end never accompanies a data word.
            tail = its_tu_item::new("queued_end_tail");
            tail.copy(its_case_db::items[cand]);
            tail.tag            = "queued_end_tail";
            tail.input_count    = 0;
            tail.desc_burst     = 1;
            tail.skip_end       = 1'b0;
            tail.end_only_queued = 1'b1;
            start_item(tail);
            finish_item(tail);
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

        // Reset while the DUT is in the middle of streaming beats.
        //
        // Waiting for dbg_output_active is what makes the reset land inside a
        // TU rather than between TUs: there is a beat pending when rst_n drops.
        task do_mid_reset();
            int unsigned guard = 0;
            while (!vif.dbg_output_active && guard < 50_000) begin
                @(negedge vif.clk);
                guard++;
            end
            if (guard >= 50_000)
                `uvm_error("ITS_DRV", "mid-reset never saw an active output")
            repeat (2) @(negedge vif.clk);
            vif.rst_n = 1'b0;
            repeat (4) @(negedge vif.clk);
            vif.drive_idle();
            repeat (2) @(negedge vif.clk);
            vif.rst_n = 1'b1;
            repeat (4) @(negedge vif.clk);
            `uvm_info("ITS_DRV", "mid-TU reset applied while output was active",
                      UVM_LOW)
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
            int unsigned guard = 0;
            // A guard here turns "the DUT stopped asking for input" into a
            // reported error instead of a simulation that hangs forever.
            while (!vif.it_data_in_req) begin
                @(negedge vif.clk);
                guard++;
                if (guard > 200_000) begin
                    `uvm_fatal("ITS_DRV",
                               "it_data_in_req never rose; DUT stopped accepting input")
                    return;
                end
            end
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
        //
        // ignore_req is for the stray-end test: there is no TU in fill, so
        // it_data_in_req never rises and waiting for it would hang forever.
        task send_end_only(bit ignore_req = 1'b0);
            int unsigned guard = 0;
            if (ignore_req) @(negedge vif.clk);
            else begin
                while (!vif.it_data_in_req) begin
                    @(negedge vif.clk);
                    guard++;
                    if (guard > 200_000) begin
                        `uvm_fatal("ITS_DRV",
                                   "it_data_in_req never rose for the end marker")
                        return;
                    end
                end
            end
            vif.it_data_end = 1'b1;
            @(posedge vif.clk);
            @(negedge vif.clk);
            vif.it_data_end = 1'b0;
        endtask

        // Output grant lives in its_grant_driver now; this agent no longer owns
        // the it_data_out_req pin.

        // End marker asserted inside the pre-fill scrub window.
        //
        // Every bind raises scrub_active for INPUT_VALID_WORDS cycles before the
        // fill window opens.  An end that lands in that window (scrub_ended in
        // the RTL) tells the DUT this TU carries no data at all, so it retires
        // the slot READY instead of opening a fill.  Nothing in the directed
        // flows ever drove an end there, so the whole scrub_ended branch was
        // dark.
        task send_end_in_scrub();
            int unsigned guard = 0;
            while (!vif.dbg_scrub_active) begin
                @(negedge vif.clk);
                guard++;
                if (guard > 400) begin
                    `uvm_fatal("ITS_DRV",
                               "scrub window never observed; cannot place the end marker")
                    return;
                end
            end
            vif.it_data_end = 1'b1;
            @(posedge vif.clk);
            @(negedge vif.clk);
            vif.it_data_end = 1'b0;
        endtask

        task stream_items();
            int unsigned n;
            forever begin
                seq_item_port.get_next_item(req);

                if (req.trigger_reset) begin
                    // The marker is not a TU.  Reset while the DUT is mid-beat,
                    // then tell the scoreboard to drop whatever it was still
                    // expecting: those beats are never going to arrive.
                    do_mid_reset();
                    ap_expected.write(req);
                    seq_item_port.item_done();
                end else if (req.end_only_queued) begin
                    // The descriptor is already queued; this end belongs to it.
                    // The TU retires with zero data, so the golden is all zero
                    // and the beats are still checked one by one.
                    for (int unsigned i = 0; i < req.beat_count; i++)
                        req.expected[i] = '0;
                    ap_expected.write(req);
                    send_end_only(1'b1);
                    seq_item_port.item_done();
                end else if (req.stray_end) begin
                    send_end_only(1'b1);
                    seq_item_port.item_done();
                end else if (req.illegal_desc) begin
                    // The DUT must reject the descriptor, so no data follows.
                    send_info(req.case_desc);
                    repeat (6) @(negedge vif.clk);
                    seq_item_port.item_done();
                end else begin
                    if (req.zero_golden)
                        for (int unsigned i = 0; i < req.beat_count; i++)
                            req.expected[i] = '0;
                    ap_expected.write(req);
                    repeat (req.gap_cycles) @(negedge vif.clk);
                    send_info(req.case_desc);
                    for (int unsigned b = 1; b < req.desc_burst; b++)
                        send_info(req.case_desc);
                    if (req.input_count == 0) begin
                        if (req.sparse_mode == 2) send_end_in_scrub();
                        else if (!req.skip_end) send_end_only();
                    end else begin
                        n = req.short_beats ? (req.input_count / 2)
                                            : req.input_count;
                        if (n == 0) n = 1;
                        for (int unsigned i = 0; i < n; i++) begin
                            int unsigned addr;
                            addr = req.input_addr[i];
                            if (i == n - 1) addr = addr + req.addr_overrun;
                            send_data(addr, req.input_value[i],
                                      (i == n - 1) && !req.skip_end);
                        end
                    end
                    seq_item_port.item_done();
                end
            end
        endtask

        task run_phase(uvm_phase phase);
            if (vif == null) `uvm_fatal("ITS_DRV", "driver has no virtual interface")
            do_reset();
            stream_items();
        endtask
    endclass

    // ------------------------------------------------------------------
    // Back-pressure agent: owns it_data_out_req.
    //
    // A profile item stays in force for its duration_cycles and the driver then
    // falls back to the default profile, so a sequence only has to name the
    // disturbing windows and never has to know the clock period.
    // ------------------------------------------------------------------
    class its_grant_driver extends uvm_driver #(its_grant_item);
        virtual its_if vif;

        bit          always_grant = 1'b0;
        int unsigned light_mod    = 7;
        int unsigned light_off    = 11;
        int unsigned deep_period  = 64;
        int unsigned deep_len     = 8;
        int unsigned remaining    = 0;

        int unsigned cyc  = 0;
        int unsigned hold = 0;

        `uvm_component_utils(its_grant_driver)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual its_if)::get(this, "", "vif", vif))
                `uvm_fatal("ITS_GRANT", "grant driver has no virtual interface")
        endfunction

        function void apply_profile(its_grant_item g);
            always_grant = g.always_grant;
            light_mod    = g.light_mod;
            light_off    = g.light_off;
            deep_period  = g.deep_period;
            deep_len     = g.deep_len;
            remaining    = g.duration_cycles;
            hold         = 0;
        endfunction

        function void revert_to_default();
            always_grant = 1'b0;
            light_mod    = 7;
            light_off    = 11;
            deep_period  = 64;
            deep_len     = 8;
        endfunction

        task drive();
            forever begin
                @(negedge vif.clk);
                cyc++;
                if (remaining > 0) begin
                    remaining--;
                    if (remaining == 0) begin
                        revert_to_default();
                        `uvm_info("ITS_GRANT", "profile expired, default restored",
                                  UVM_MEDIUM)
                    end
                end
                if (always_grant) begin
                    hold = 0;
                    vif.it_data_out_req <= 1'b1;
                end else if (hold > 0) begin
                    vif.it_data_out_req <= 1'b0;
                    hold--;
                end else if (deep_period != 0 && (cyc % deep_period) == 0) begin
                    hold = deep_len;
                    vif.it_data_out_req <= 1'b0;
                end else begin
                    vif.it_data_out_req <=
                        !((cyc % light_mod) == 2 || (cyc % light_off) == 5);
                end
            end
        endtask

        task run_phase(uvm_phase phase);
            if (vif == null) `uvm_fatal("ITS_GRANT", "grant driver has no vif")
            fork
                drive();
            join_none
            forever begin
                seq_item_port.get_next_item(req);
                apply_profile(req);
                `uvm_info("ITS_GRANT", $sformatf("profile: %s", req.convert2string()),
                          UVM_LOW)
                seq_item_port.item_done();
            end
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

        // --------------------------------------------------------------
        // Independent protocol checks.
        //
        // These are separate from the scoreboard on purpose: a beat that the
        // handshake drops never reaches the scoreboard, so a protocol violation
        // would otherwise be invisible.  Every check below is reported with its
        // own id so a case can state exactly which diagnostics it accepts.
        // --------------------------------------------------------------
        int unsigned sig_errors      = 0;  // done with no completed handshake
        int unsigned x_errors        = 0;  // X/Z on a control or data signal
        int unsigned vld_stall_guard = 0;  // vld high while req low
        int unsigned in_errors       = 0;  // stimulus side: in_vld while in_req low

        // Reset state machine.  Checks only run once reset has been seen low and
        // then high for WARMUP cycles, so a half-initialised DUT cannot produce
        // a burst of spurious X reports.
        localparam int unsigned WARMUP = 3;
        bit          rst_seen_low = 1'b0;
        bit          checks_on    = 1'b0;
        int unsigned warmup       = 0;

        `uvm_component_utils(its_monitor)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        // A control signal carries information only when it is 0 or 1.  Both X
        // and Z fail this test; asking "== 1'bx" would accept Z, which is how
        // an undriven request line used to pass unnoticed.
        function automatic bit not_two_state(logic v);
            return !((v === 1'b0) || (v === 1'b1));
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

                // ---- reset state machine -----------------------------
                if (vif.rst_n === 1'b0) begin
                    rst_seen_low = 1'b1;
                    checks_on    = 1'b0;
                    warmup       = 0;
                    depth        = 0;
                    phases       = 5'b0;
                    prev_error   = 1'b0;
                end else if (vif.rst_n === 1'b1) begin
                    if (!checks_on) begin
                        warmup++;
                        if (rst_seen_low && warmup >= WARMUP) checks_on = 1'b1;
                    end
                end else begin
                    // rst_n itself is X/Z: report once and stop checking until
                    // the next clean reset.
                    if (checks_on) begin
                        x_errors++;
                        `uvm_error("ITS_RST_X",
                                   $sformatf("rst_n is %b while checking t=%0t",
                                             vif.rst_n, $time))
                    end
                    checks_on  = 1'b0;
                    warmup     = 0;
                    depth      = 0;
                    phases     = 5'b0;
                    prev_error = 1'b0;
                end

                if (checks_on) begin
                    // Control signals must be two-state while checking: a value
                    // that is neither 0 nor 1 makes every downstream decision
                    // meaningless, so it is an error rather than a warning.
                    // Testing "not 0 and not 1" covers X and Z; the earlier
                    // "=== 1'bx" form silently accepted Z, and it never looked
                    // at req or protocol_error at all.
                    if (not_two_state(vif.it_data_out_vld) ||
                        not_two_state(vif.it_done)         ||
                        not_two_state(vif.it_data_out_req) ||
                        not_two_state(vif.protocol_error)  ||
                        not_two_state(vif.it_data_in_vld)  ||
                        not_two_state(vif.it_data_in_req)) begin
                        x_errors++;
                        `uvm_error("ITS_SIG_X",
                                   $sformatf("control not two-state: out_vld=%b done=%b out_req=%b perr=%b in_vld=%b in_req=%b t=%0t",
                                             vif.it_data_out_vld, vif.it_done,
                                             vif.it_data_out_req, vif.protocol_error,
                                             vif.it_data_in_vld, vif.it_data_in_req,
                                             $time))
                    end
                    // vld while req is low.  The current RTL gates the external
                    // valid by the request (wrapper:1678), so this state cannot
                    // arise from legal behaviour today.  It is still an error:
                    // a checker that stays quiet when a contract is violated
                    // would pass exactly the regression it exists to catch.
                    // The counter stays separate from the error count so the
                    // runner can cross-check that the two paths agree.
                    if ((vif.it_data_out_vld === 1'b1) &&
                        (vif.it_data_out_req === 1'b0)) begin
                        vld_stall_guard++;
                        `uvm_error("ITS_VLD_STALL",
                                   $sformatf("vld high while req low: t=%0t", $time))
                    end
                    // done must ride a completed handshake.
                    if ((vif.it_done === 1'b1) &&
                        !((vif.it_data_out_vld === 1'b1) &&
                          (vif.it_data_out_req === 1'b1))) begin
                        sig_errors++;
                        `uvm_error("ITS_DONE_NO_FIRE",
                                   $sformatf("src=done_no_fire done without a completed handshake: vld=%b req=%b t=%0t",
                                             vif.it_data_out_vld, vif.it_data_out_req,
                                             $time))
                    end
                    // Stimulus side: the driver must not present a beat while
                    // the DUT is not asking for one, otherwise a lost input word
                    // would be blamed on the DUT.
                    if ((vif.it_data_in_vld === 1'b1) &&
                        (vif.it_data_in_req === 1'b0)) begin
                        in_errors++;
                        `uvm_error("ITS_IN_VLD_NO_REQ",
                                   $sformatf("stimulus presented in_vld while in_req low: addr=%0h t=%0t",
                                             vif.it_data_addr, $time))
                    end
                end

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
                    if (checks_on && ((^vif.it_data_out) === 1'bx)) begin
                        x_errors++;
                        `uvm_error("ITS_DATA_X",
                                   $sformatf("accepted beat carries X: data=%010h t=%0t",
                                             vif.it_data_out, $time))
                    end
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
        // Resets that aborted in-flight TUs.  Their remaining beats will never
        // arrive, so the expectation queue is dropped at the marker.
        int unsigned resets_seen    = 0;
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
            // A marker arrives after the driver has already deasserted reset;
            // every TU still queued was aborted by it, so drop them.
            if (t.trigger_reset) begin
                resets_seen++;
                if (pending.size() > 0)
                    `uvm_info("ITS_RESET",
                              $sformatf("reset aborted %0d in-flight TU(s)",
                                        pending.size()), UVM_LOW)
                pending.delete();
                beat_idx = 0;
                return;
            end
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
        // Stimulus agent
        uvm_sequencer #(its_tu_item) seqr;
        its_driver   drv;
        // Observation
        its_monitor  mon;
        its_scoreboard sb;
        its_desc_coverage desc_cov;
        its_out_coverage  out_cov;
        // Back-pressure agent, plus the virtual sequencer that ties it to the
        // stimulus side.
        uvm_sequencer #(its_grant_item) grant_seqr;
        its_grant_driver grant_drv;
        its_virtual_sequencer vseqr;

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
            grant_seqr = new("grant_seqr", this);
            grant_drv  = its_grant_driver::type_id::create("grant_drv", this);
            vseqr      = its_virtual_sequencer::type_id::create("vseqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            drv.seq_item_port.connect(seqr.seq_item_export);
            grant_drv.seq_item_port.connect(grant_seqr.seq_item_export);
            drv.ap_expected.connect(sb.imp_expected);
            mon.ap.connect(sb.imp_actual);
            mon.ap_err.connect(sb.imp_err);
            drv.ap_expected.connect(desc_cov.analysis_export);
            mon.ap.connect(out_cov.analysis_export);
            // The virtual sequencer only holds handles; it is not connected to
            // any driver itself.
            vseqr.in_seqr    = seqr;
            vseqr.grant_seqr = grant_seqr;
            `uvm_info("ITS_ENV", "stimulus agent, back-pressure agent, scoreboard, coverage and virtual sequencer attached", UVM_LOW)
        endfunction
    endclass

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    class its_base_test extends uvm_test;
        its_env      env;
        virtual its_if vif;
        string       vector_file = "unified_gate_c_vectors.txt";
        // Run identity: written into the result file so a reader can prove the
        // file belongs to this run and this case, not to a stale artefact.
        string       run_id    = "unknown";
        string       case_name = "unknown";

        `uvm_component_utils(its_base_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            int unsigned n;
            super.build_phase(phase);
            void'($value$plusargs("VECTOR_FILE=%s", vector_file));
            void'($value$plusargs("RUN_ID=%s", run_id));
            void'($value$plusargs("CASE_NAME=%s", case_name));
            // Install the id-counting server before any child can report.
            if (its_srv == null) begin
                its_srv = new();
                uvm_report_server::set_server(its_srv);
            end
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

        // Plain cycle budget, for negative tests where no TU is expected to
        // retire and wait_for_tus would only ever report a timeout.
        task wait_cycles(int unsigned n);
            repeat (n) @(posedge vif.clk);
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
            string            k;
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
            $fdisplay(fd, "resets=%0d",          env.sb.resets_seen);
            $fdisplay(fd, "uvm_error=%0d", srv.get_severity_count(UVM_ERROR));
            $fdisplay(fd, "uvm_fatal=%0d", srv.get_severity_count(UVM_FATAL));
            // ---- run identity -------------------------------------------
            $fdisplay(fd, "run_id=%s", run_id);
            $fdisplay(fd, "case=%s", case_name);
            // ---- independent protocol checks -----------------------------
            $fdisplay(fd, "sig_errors=%0d",       env.mon.sig_errors);
            $fdisplay(fd, "x_errors=%0d",         env.mon.x_errors);
            $fdisplay(fd, "vld_stall_guard=%0d",  env.mon.vld_stall_guard);
            $fdisplay(fd, "in_errors=%0d",        env.mon.in_errors);
            // ---- per-id severity counts ---------------------------------
            // The runner asserts on ids, not just totals, so that a case can
            // say which diagnostics it accepts and reject every other one.
            if (its_srv != null) begin
                if (its_srv.err_id.first(k)) begin
                    do begin
                        $fdisplay(fd, "err.error.%s=%0d", k, its_srv.err_id[k]);
                    end while (its_srv.err_id.next(k));
                end
                if (its_srv.fat_id.first(k)) begin
                    do begin
                        $fdisplay(fd, "err.fatal.%s=%0d", k, its_srv.fat_id[k]);
                    end while (its_srv.fat_id.next(k));
                end
                $fdisplay(fd, "err_server_total_error=%0d", its_srv.tot_err);
                $fdisplay(fd, "err_server_total_fatal=%0d", its_srv.tot_fat);
            end
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

        // Fault injection for the A5 self-test only: report_phase has already
        // written and closed a complete result file by the time final_phase
        // runs, so this reproduces the one path where a fatal leaves a clean,
        // finished-looking artefact behind.  The regression must judge it FAIL;
        // nothing in normal operation sets the plusarg.
        function void final_phase(uvm_phase phase);
            bit inject;
            super.final_phase(phase);
            if (!$value$plusargs("FATAL_IN_FINAL=%b", inject)) inject = 1'b0;
            if (inject)
                uvm_report_fatal("ITS_INJECTED_FINAL_FATAL",
                                 "injected in final_phase for the A5 self-test");
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

    // ------------------------------------------------------------------
    // Negative tests.  Each drives one protocol violation and expects the
    // DUT to flag it; the runner checks the resulting error counts.
    // ------------------------------------------------------------------
    class its_lfnst_xform_test extends its_base_test;
        `uvm_component_utils(its_lfnst_xform_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_lfnst_xform_sequence seq;
            phase.raise_objection(this);
            seq = its_lfnst_xform_sequence::type_id::create("seq");
            seq.start(env.seqr);
            wait_cycles(400);
            phase.drop_objection(this);
        endtask
    endclass

    class its_lfnst_mode3_test extends its_base_test;
        `uvm_component_utils(its_lfnst_mode3_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_lfnst_mode3_sequence seq;
            phase.raise_objection(this);
            seq = its_lfnst_mode3_sequence::type_id::create("seq");
            seq.start(env.seqr);
            wait_cycles(400);
            phase.drop_objection(this);
        endtask
    endclass

    class its_addr_overrun_test extends its_base_test;
        `uvm_component_utils(its_addr_overrun_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_addr_overrun_sequence seq;
            phase.raise_objection(this);
            seq = its_addr_overrun_sequence::type_id::create("seq");
            seq.start(env.seqr);
            wait_cycles(4_000);
            phase.drop_objection(this);
        endtask
    endclass

    class its_stray_end_test extends its_base_test;
        `uvm_component_utils(its_stray_end_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_stray_end_sequence seq;
            phase.raise_objection(this);
            seq = its_stray_end_sequence::type_id::create("seq");
            seq.start(env.seqr);
            wait_cycles(400);
            phase.drop_objection(this);
        endtask
    endclass

    class its_no_end_test extends its_base_test;
        `uvm_component_utils(its_no_end_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_no_end_sequence seq;
            phase.raise_objection(this);
            seq = its_no_end_sequence::type_id::create("seq");
            seq.start(env.seqr);
            wait_cycles(6_000);
            phase.drop_objection(this);
        endtask
    endclass

    class its_short_beats_test extends its_base_test;
        `uvm_component_utils(its_short_beats_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_short_beats_sequence seq;
            phase.raise_objection(this);
            seq = its_short_beats_sequence::type_id::create("seq");
            seq.start(env.seqr);
            wait_cycles(6_000);
            phase.drop_objection(this);
        endtask
    endclass

    // Reset in the middle of streaming beats, then a clean TU.
    class its_reset_test extends its_base_test;
        `uvm_component_utils(its_reset_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_reset_sequence seq;
            phase.raise_objection(this);
            seq = its_reset_sequence::type_id::create("seq");
            seq.start(env.seqr);
            wait_for_tus(1, 400_000);
            wait_cycles(200);
            phase.drop_objection(this);
        endtask
    endclass

    // Constrained random run.  The seed is reported so a failure can be
    // replayed with -sv_seed.
    class its_random_test extends its_base_test;
        `uvm_component_utils(its_random_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_random_sequence seq;
            phase.raise_objection(this);
            seq = its_random_sequence::type_id::create("seq");
            if (!seq.randomize())
                `uvm_fatal("ITS_RAND", "sequence randomization failed")
            seq.pre_randomized = 1'b1;
            seq.print();
            seq.start(env.seqr);
            wait_for_tus(seq.n_tu, 600_000);
            `uvm_info("ITS_RAND",
                      $sformatf("random run done tus=%0d of %0d",
                                env.sb.tus_completed, seq.n_tu), UVM_LOW)
            phase.drop_objection(this);
        endtask
    endclass

    // Virtual sequence test: two agents, two sequencers, one coordinator.
    class its_vseq_test extends its_base_test;
        `uvm_component_utils(its_vseq_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_vseq_stress vseq;
            int unsigned    n;
            n = 12;
            void'($value$plusargs("VSEQ_TUS=%d", n));
            phase.raise_objection(this);
            vseq = its_vseq_stress::type_id::create("vseq");
            vseq.tu_count = n;
            vseq.start(env.vseqr);
            wait_for_tus(n, 900_000);
            `uvm_info("ITS_VSEQ",
                      $sformatf("vseq complete tus=%0d beats=%0d overlap=%0d",
                                env.sb.tus_completed, env.sb.beats_seen,
                                env.sb.overlap_admissions), UVM_LOW)
            phase.drop_objection(this);
        endtask
    endclass

    class its_vseq_tail_test extends its_base_test;
        `uvm_component_utils(its_vseq_tail_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_vseq_tail_stress seq;
            int unsigned stall;
            stall = 600;
            void'($value$plusargs("TAIL_STALL=%d", stall));
            phase.raise_objection(this);
            seq = its_vseq_tail_stress::type_id::create("seq");
            seq.stall_cycles = stall;
            seq.start(env.vseqr);
            wait_cycles(6_000);
            phase.drop_objection(this);
        endtask
    endclass

    class its_zero_data_test extends its_base_test;
        `uvm_component_utils(its_zero_data_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_zero_data_sequence seq;
            int unsigned mode;
            mode = 2;
            void'($value$plusargs("SPARSE_MODE=%d", mode));
            phase.raise_objection(this);
            seq = its_zero_data_sequence::type_id::create("seq");
            seq.mode = mode;
            seq.start(env.seqr);
            wait_cycles(8_000);
            phase.drop_objection(this);
        endtask
    endclass

    class its_desc_flood_test extends its_base_test;
        `uvm_component_utils(its_desc_flood_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_desc_flood_sequence seq;
            phase.raise_objection(this);
            seq = its_desc_flood_sequence::type_id::create("seq");
            seq.start(env.seqr);
            wait_cycles(8_000);
            phase.drop_objection(this);
        endtask
    endclass

    // Same queue ownership, but the end has to be parked instead of handed over
    // on the bind edge.
    //
    // The head TU closes its end inside the scrub window, so the slot retires as
    // zero-data while still holding scrub_active.  At that moment the queued TU
    // is the only owner left, and bind_event is blocked by the active scrub, so
    // the end cannot be popped straight into a slot: the wrapper has to store it
    // in end_seen_desc[] (end_to_queue_store).  The second TU then binds later
    // and inherits the stored end.
    class its_queued_end_store_sequence extends uvm_sequence #(its_tu_item);
        `uvm_object_utils(its_queued_end_store_sequence)

        int unsigned pick = 0;

        function new(string name = "its_queued_end_store_sequence");
            super.new(name);
        endfunction

        task body();
            its_tu_item req;
            its_tu_item tail;
            int unsigned cand;

            if (its_case_db::items.size() == 0)
                `uvm_fatal("ITS_SEQ", "case database is empty")

            cand = pick;
            if (cand >= its_case_db::items.size()) cand = 0;

            req = its_tu_item::new("queued_end_store");
            req.copy(its_case_db::items[cand]);
            req.tag         = "queued_end_store";
            req.input_count = 0;
            req.desc_burst  = 2;
            req.sparse_mode = 2;      // end inside the scrub window
            req.zero_golden = 1'b1;   // such a TU retires with zero data
            start_item(req);
            finish_item(req);

            tail = its_tu_item::new("queued_end_store_tail");
            tail.copy(its_case_db::items[cand]);
            tail.tag             = "queued_end_store_tail";
            tail.input_count     = 0;
            tail.desc_burst      = 1;
            tail.end_only_queued = 1'b1;
            start_item(tail);
            finish_item(tail);
        endtask
    endclass

    class its_queued_end_test extends its_base_test;
        `uvm_component_utils(its_queued_end_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_queued_end_sequence seq;
            phase.raise_objection(this);
            seq = its_queued_end_sequence::type_id::create("seq");
            seq.start(env.seqr);
            wait_cycles(8_000);
            phase.drop_objection(this);
        endtask
    endclass

    class its_queued_end_store_test extends its_base_test;
        `uvm_component_utils(its_queued_end_store_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            its_queued_end_store_sequence seq;
            phase.raise_objection(this);
            seq = its_queued_end_store_sequence::type_id::create("seq");
            seq.start(env.seqr);
            wait_cycles(8_000);
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