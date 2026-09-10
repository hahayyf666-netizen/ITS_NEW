"""Generate the B1 self-checking ModelSim testbench from the independent Oracle."""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "03_verification" / "scripts" / "p2f"))

from dct2_64_factorized import ExactDCT2Factorizer, wrap_signed_16  # noqa: E402
from run_p2f_equivalence import deterministic_cases  # noqa: E402

TB = ROOT / "03_verification" / "tb" / "p2f_dct2_64_b1_tb.sv"
MANIFEST = ROOT / "03_verification" / "output" / "p2f_b1_tb_manifest.json"
VECTOR_DIR = ROOT / "03_verification" / "tb" / "p2f_b1_vectors"


def pack(values: list[int], width: int) -> str:
    mask = (1 << width) - 1
    flat = 0
    for i, value in enumerate(values):
        flat |= (int(value) & mask) << (i * width)
    return f"{flat:0{(len(values) * width + 3) // 4}x}"


def fixed(raw: list[int]) -> dict[str, list[int]]:
    biased = [v + 32 for v in raw]
    shifted = [v >> 6 for v in biased]
    stage16 = [wrap_signed_16(v) for v in shifted]
    final10 = [v & 0x3FF for v in stage16]
    return {"raw": raw, "biased": biased, "shifted": shifted,
            "stage16": stage16, "final10": final10}


def choose_cases() -> list[tuple[str, list[int]]]:
    cases = deterministic_cases()
    by_name = {name: x for name, x in cases}
    names = [
        "zero",
        "all_positive_max",
        "all_negative_min",
        "alternating_positive_negative",
        "alternating_negative_positive",
        "single_max_0",
        "single_min_63",
        "sparse_first_last_opposite",
        "sparse_mixed_extreme",
        "one_hot_0",
        "one_hot_1",
        "one_hot_2",
        "one_hot_3",
        "one_hot_7",
        "one_hot_15",
        "one_hot_31",
        "one_hot_63",
    ]
    selected = [(name, by_name[name]) for name in names]
    for seed in (20260904, 20260905):
        rng = random.Random(seed)
        for idx in range(16):
            selected.append((f"random_{seed}_{idx}",
                             [rng.randint(-32768, 32767) for _ in range(64)]))
    return selected


def main() -> None:
    factorizer = ExactDCT2Factorizer()
    cases = choose_cases()
    init: list[str] = []
    wrap_pos = 0
    wrap_neg = 0
    for c, (_name, x) in enumerate(cases):
        init.append(f"    case_input[{c}] = 1024'h{pack(x, 16)};")
        raw = [sum(int(factorizer.inverse[64][i][j]) * int(x[j]) for j in range(64))
               for i in range(64)]
        vals = fixed(raw)
        wrap_pos += sum(v > 32767 for v in vals["shifted"])
        wrap_neg += sum(v < -32768 for v in vals["shifted"])
        for g in range(16):
            lo = 4 * g
            hi = lo + 4
            init.append(f"    exp_raw[{c}][{g}] = 160'h{pack(vals['raw'][lo:hi], 40)};")
            init.append(f"    exp_biased[{c}][{g}] = 160'h{pack(vals['biased'][lo:hi], 40)};")
            init.append(f"    exp_shifted[{c}][{g}] = 160'h{pack(vals['shifted'][lo:hi], 40)};")
            init.append(f"    exp_stage16[{c}][{g}] = 64'h{pack(vals['stage16'][lo:hi], 16)};")
            init.append(f"    exp_final10[{c}][{g}] = 40'h{pack(vals['final10'][lo:hi], 10)};")

    n = len(cases)
    tb = f"""`timescale 1ns/1ps
module p2f_dct2_64_b1_tb;
    localparam integer NUM_CASES = {n};
    reg clk;
    reg rst_n;
    reg vector_start;
    reg [15:0] vector_id_in;
    reg [1023:0] vector_data_flat;
    reg result_accept;
    wire result_valid;
    wire [4:0] result_group;
    wire [15:0] result_vector_id;
    wire result_first, result_last;
    wire [159:0] result_raw_flat, result_biased_flat, result_shifted_flat;
    wire [63:0] result_stage16_flat;
    wire [39:0] result_final10_flat;

    reg [1023:0] case_input [0:NUM_CASES-1];
    reg [159:0] exp_raw [0:NUM_CASES-1][0:15];
    reg [159:0] exp_biased [0:NUM_CASES-1][0:15];
    reg [159:0] exp_shifted [0:NUM_CASES-1][0:15];
    reg [63:0] exp_stage16 [0:NUM_CASES-1][0:15];
    reg [39:0] exp_final10 [0:NUM_CASES-1][0:15];
    integer seen_groups [0:NUM_CASES-1];
    integer launch_tick [0:NUM_CASES-1];
    integer first_fire_tick [0:NUM_CASES-1];
    integer last_fire_tick [0:NUM_CASES-1];
    integer tick;
    integer errors;
    integer total_fires;
    integer global_gap_count;
    integer previous_global_fire_tick;
    integer c, g, vid;

    p2f_dct2_64_b1 dut (
        .clk(clk), .rst_n(rst_n), .vector_start(vector_start),
        .vector_id_in(vector_id_in), .vector_data_flat(vector_data_flat),
        .result_accept(result_accept), .result_valid(result_valid),
        .result_group(result_group), .result_vector_id(result_vector_id),
        .result_first(result_first), .result_last(result_last),
        .result_raw_flat(result_raw_flat),
        .result_biased_flat(result_biased_flat),
        .result_shifted_flat(result_shifted_flat),
        .result_stage16_flat(result_stage16_flat),
        .result_final10_flat(result_final10_flat)
    );

    always #1 clk = ~clk;

    initial begin
{chr(10).join(init)}
    end

    // Sample once per stable output cycle.  This catches the last beat too,
    // unlike a post-NBA posedge-only monitor.
    always @(negedge clk) begin
        if (!rst_n) begin
            tick = 0;
        end else begin
            tick = tick + 1;
            if (result_valid) begin
                total_fires = total_fires + 1;
                vid = result_vector_id;
                g = result_group;
                if (vid < 0 || vid >= NUM_CASES) begin
                    errors = errors + 1;
                    $display("ERR invalid vector tag %0d", vid);
                end else begin
                    if (g !== seen_groups[vid]) begin
                        errors = errors + 1;
                        $display("ERR group order v%0d got %0d expected %0d", vid, g, seen_groups[vid]);
                    end
                    if (result_raw_flat !== exp_raw[vid][g]) begin
                        errors = errors + 1;
                        $display("ERR raw v%0d g%0d", vid, g);
                    end
                    if (result_biased_flat !== exp_biased[vid][g]) begin
                        errors = errors + 1;
                        $display("ERR biased v%0d g%0d", vid, g);
                    end
                    if (result_shifted_flat !== exp_shifted[vid][g]) begin
                        errors = errors + 1;
                        $display("ERR shifted v%0d g%0d", vid, g);
                    end
                    if (result_stage16_flat !== exp_stage16[vid][g]) begin
                        errors = errors + 1;
                        $display("ERR stage16 v%0d g%0d", vid, g);
                    end
                    if (result_final10_flat !== exp_final10[vid][g]) begin
                        errors = errors + 1;
                        $display("ERR final10 v%0d g%0d", vid, g);
                    end
                    if (result_first !== (g == 0) || result_last !== (g == 15)) begin
                        errors = errors + 1;
                        $display("ERR first/last v%0d g%0d", vid, g);
                    end
                    if (g == 0) begin
                        first_fire_tick[vid] = tick;
                    end else if (tick - last_fire_tick[vid] != 1) begin
                        errors = errors + 1;
                        $display("ERR group bubble v%0d g%0d interval=%0d expected 1", vid, g, tick - last_fire_tick[vid]);
                    end
                    if (previous_global_fire_tick >= 0 && tick - previous_global_fire_tick != 1)
                        global_gap_count = global_gap_count + 1;
                    previous_global_fire_tick = tick;
                    last_fire_tick[vid] = tick;
                    seen_groups[vid] = seen_groups[vid] + 1;
                    if ((g == 0) || (g == 15))
                        $display("B1_FIRE tick=%0d vector=%0d group=%0d first=%b last=%b", tick, vid, g, result_first, result_last);
                end
            end
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        vector_start = 1'b0;
        vector_id_in = 16'd0;
        vector_data_flat = 1024'd0;
        result_accept = 1'b1;
        tick = 0;
        errors = 0;
        total_fires = 0;
        global_gap_count = 0;
        previous_global_fire_tick = -1;
        for (c = 0; c < NUM_CASES; c = c + 1) begin
            seen_groups[c] = 0;
            launch_tick[c] = -1;
            first_fire_tick[c] = -1;
            last_fire_tick[c] = -1;
        end

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        for (c = 0; c < NUM_CASES; c = c + 1) begin
            @(negedge clk);
            #0.1;
            launch_tick[c] = tick;
            vector_id_in = c[15:0];
            vector_data_flat = case_input[c];
            vector_start = 1'b1;
            @(negedge clk);
            #0.1;
            vector_start = 1'b0;
            repeat (14) @(negedge clk);
        end
        repeat (120) @(negedge clk);

        for (c = 0; c < NUM_CASES; c = c + 1) begin
            if (seen_groups[c] != 16) begin
                errors = errors + 1;
                $display("ERR vector %0d received %0d groups, expected 16", c, seen_groups[c]);
            end
            if (first_fire_tick[c] >= 0 && last_fire_tick[c] - first_fire_tick[c] != 15) begin
                errors = errors + 1;
                $display("ERR vector %0d output span=%0d expected 15", c, last_fire_tick[c] - first_fire_tick[c]);
            end
            if (c > 0 && launch_tick[c] - launch_tick[c-1] != 16) begin
                errors = errors + 1;
                $display("ERR launch interval c%0d=%0d expected 16", c, launch_tick[c] - launch_tick[c-1]);
            end
        end
        if (total_fires != NUM_CASES * 16) begin
            errors = errors + 1;
            $display("ERR total fires=%0d expected %0d", total_fires, NUM_CASES * 16);
        end
        if (global_gap_count != 0) begin
            errors = errors + global_gap_count;
            $display("ERR global output gaps=%0d", global_gap_count);
        end
        if (errors == 0)
            $display("B1_PASS cases=%0d fires=%0d positive_wrap_outputs={wrap_pos} negative_wrap_outputs={wrap_neg}", NUM_CASES, total_fires);
        else
            $display("B1_FAIL cases=%0d fires=%0d errors=%0d", NUM_CASES, total_fires, errors);
        $finish;
    end
endmodule
"""
    TB.parent.mkdir(parents=True, exist_ok=True)
    TB.write_text(tb, encoding="utf-8")
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(json.dumps({
        "testbench": str(TB),
        "case_count": n,
        "case_names": [name for name, _ in cases],
        "random_seeds": [20260904, 20260905],
        "random_cases_per_seed": 16,
        "positive_wrap_outputs": wrap_pos,
        "negative_wrap_outputs": wrap_neg,
    }, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"generated {TB} ({n} cases)")


if __name__ == "__main__":
    main()
