"""
Generate exhaustive regression test vectors for ITS VVC inverse transform.
Covers all competition-required combinations:
  DCT2 (25 sizes) × 9 LFNST configs = 225
  MTS  (16 sizes) × 8 MTS combos × 9 LFNST configs = 1152
  Total: 1377 test cases

Also generates Verilog include files (.vh) for the testbench.
"""

import os
import sys
import random
import argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ref_model import its_inverse_transform, flatten_raster, LFNST_INPUT_SCAN_4x4 as LFNST_SCAN_4x4


# ============================================================
# Constants
# ============================================================

TV_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tb', 'test_vectors')
BASE_PATH = "../tb/test_vectors"

# DCT2: all 25 valid VVC block sizes
DCT2_SIZES = [
    (4,4),(4,8),(4,16),(4,32),(4,64),
    (8,4),(16,4),(32,4),(64,4),
    (8,8),(8,16),(8,32),(8,64),
    (16,8),(32,8),(64,8),
    (16,16),(16,32),(16,64),
    (32,16),(32,32),(32,64),
    (64,16),(64,32),(64,64),
]

# MTS: 16 sizes that support non-DCT2 transforms (max 32 for MTS)
MTS_SIZES = [
    (4,4),(4,8),(4,16),(4,32),
    (8,4),(16,4),(32,4),
    (8,8),(8,16),(8,32),
    (16,8),(32,8),
    (16,16),(16,32),(32,16),(32,32),
]

# 8 MTS transform combos (excluding DCT2xDCT2)
# tr_type encoding: 0=DCT2, 1=DST7, 2=DCT8
MTS_COMBOS = [
    (1, 2),  # DST7 x DCT8
    (2, 1),  # DCT8 x DST7
    (2, 2),  # DCT8 x DCT8
    (1, 1),  # DST7 x DST7
    (0, 2),  # DCT2 x DCT8
    (2, 0),  # DCT8 x DCT2
    (0, 1),  # DCT2 x DST7
    (1, 0),  # DST7 x DCT2
]

# LFNST configs: 9 per (size, transform) combination
# (lfnst_idx, set_idx, pattern_name)
LFNST_CONFIGS = [
    (0, 0, "random_sparse"),       # lfnst off
    (1, 0, "low_freq"),            # lfnst1 set0
    (1, 1, "low_freq"),            # lfnst1 set1
    (1, 2, "low_freq"),            # lfnst1 set2
    (1, 3, "low_freq"),            # lfnst1 set3
    (2, 0, "extreme_low_freq"),    # lfnst2 set0
    (2, 1, "extreme_low_freq"),    # lfnst2 set1
    (2, 2, "extreme_low_freq"),    # lfnst2 set2
    (2, 3, "extreme_low_freq"),    # lfnst2 set3
]


# ============================================================
# Input pattern generators
# ============================================================

def make_random_sparse(width, height, case_id, max_nz=16):
    """Random sparse input with deterministic seed."""
    rng = random.Random(20260617 + case_id)
    data = [[0] * width for _ in range(height)]
    num = rng.randint(1, min(max_nz, width * height))
    for _ in range(num):
        r = rng.randint(0, height - 1)
        c = rng.randint(0, width - 1)
        data[r][c] = rng.randint(-256, 256)
    return data


def make_low_freq(width, height):
    """Low-frequency diagonal pattern for LFNST testing.

    Places values in LFNST_SCAN_4x4 order so that the 16-element input
    vector (after diagonal scanning) has deterministic test values.
    """
    data = [[0] * width for _ in range(height)]
    vals = [100, -80, 60, -40, 50, -30, 20, -10,
            75, -55, 35, -15, 25, -5, 12, -3]
    for idx, (r, c) in enumerate(LFNST_SCAN_4x4):
        if idx < len(vals) and r < height and c < width:
            data[r][c] = vals[idx]
    return data


def make_extreme_low_freq(width, height):
    """Extreme low-frequency pattern with max/min values.

    Places values in LFNST_SCAN_4x4 order so that the 16-element input
    vector (after diagonal scanning) has deterministic extreme test values.
    """
    data = [[0] * width for _ in range(height)]
    vals = [32767, -32768, 32767, -32768, 32767, -32768, 32767, -32768,
            -32768, 32767, -32768, 32767, -32768, 32767, -32768, 32767]
    for idx, (r, c) in enumerate(LFNST_SCAN_4x4):
        if idx < len(vals) and r < height and c < width:
            data[r][c] = vals[idx]
    return data


# ============================================================
# Hex file writers
# ============================================================

def to_hex(val, bits):
    if val < 0:
        val = val + (1 << bits)
    return format(val & ((1 << bits) - 1), f'0{bits // 4}X')


def write_hex_files(desc, width, height, tr_hor, tr_ver, set_idx, lfnst, input_data):
    """Generate input and golden hex files. Returns (n_input, n_output)."""
    output = its_inverse_transform(input_data, width, height, tr_hor, tr_ver, set_idx, lfnst)
    flat_out = flatten_raster(output)
    flat_in = flatten_raster(input_data)

    input_path = os.path.join(TV_DIR, f"{desc}_input.hex")
    with open(input_path, 'w') as f:
        for idx, val in enumerate(flat_in):
            if val != 0:
                combined = (idx << 16) | (val & 0xFFFF)
                f.write(f"{combined:07X}\n")

    golden_path = os.path.join(TV_DIR, f"{desc}_golden.hex")
    with open(golden_path, 'w') as f:
        for val in flat_out:
            f.write(f"{to_hex(val, 10)}\n")

    n_in = sum(1 for v in flat_in if v != 0)
    return n_in, len(flat_out)


# ============================================================
# Verilog include file generators
# ============================================================

def tr_name(tr_type):
    return {0: "DCT2", 1: "DST7", 2: "DCT8"}[tr_type]


def gen_run_test_line(case_id, name, w, h, tr_h, tr_v, sidx, lfnst_idx):
    """Generate one run_test() call line for the .vh file."""
    desc = f"case_{case_id:04d}"
    return (
        f'    run_test("{case_id:04d}:{name}", '
        f"7'd{w}, 7'd{h}, 2'd{tr_h}, 2'd{tr_v}, 2'd{sidx}, 2'd{lfnst_idx},\n"
        f'             "{BASE_PATH}/{desc}_input.hex",\n'
        f'             "{BASE_PATH}/{desc}_golden.hex");\n'
    )


def gen_bp_test_line(case_id, name, w, h, tr_h, tr_v, sidx, lfnst_idx):
    """Generate one run_test_backpressure() call line."""
    desc = f"case_{case_id:04d}"
    return (
        f'    run_test_backpressure("{case_id:04d}:{name}", '
        f"7'd{w}, 7'd{h}, 2'd{tr_h}, 2'd{tr_v}, 2'd{sidx}, 2'd{lfnst_idx},\n"
        f'             "{BASE_PATH}/{desc}_input.hex",\n'
        f'             "{BASE_PATH}/{desc}_golden.hex");\n'
    )


def gen_end_same_cycle_line(case_id, name, w, h, tr_h, tr_v, sidx, lfnst_idx):
    """Generate one run_test_end_same_cycle() call line."""
    desc = f"case_{case_id:04d}"
    return (
        f'    run_test_end_same_cycle("{case_id:04d}:{name}", '
        f"7'd{w}, 7'd{h}, 2'd{tr_h}, 2'd{tr_v}, 2'd{sidx}, 2'd{lfnst_idx},\n"
        f'             "{BASE_PATH}/{desc}_input.hex",\n'
        f'             "{BASE_PATH}/{desc}_golden.hex");\n'
    )


def gen_continuous_line(case_id, name, w, h, tr_h, tr_v, sidx, lfnst_idx):
    """Generate one run_test_continuous() call line."""
    desc = f"case_{case_id:04d}"
    return (
        f'    run_test_continuous("{case_id:04d}:{name}", '
        f"7'd{w}, 7'd{h}, 2'd{tr_h}, 2'd{tr_v}, 2'd{sidx}, 2'd{lfnst_idx},\n"
        f'             "{BASE_PATH}/{desc}_input.hex",\n'
        f'             "{BASE_PATH}/{desc}_golden.hex");\n'
    )


# ============================================================
# Main
# ============================================================

def main(argv=None):
    global TV_DIR, BASE_PATH
    parser = argparse.ArgumentParser(
        description="Generate the canonical 1377-case regression vectors")
    parser.add_argument(
        "--output-dir", default=TV_DIR,
        help="directory for generated vectors (default: %(default)s)")
    parser.add_argument(
        "--base-path", default=BASE_PATH,
        help="path embedded in generated Verilog include files")
    args = parser.parse_args(argv)
    TV_DIR = os.path.abspath(args.output_dir)
    BASE_PATH = args.base_path

    os.makedirs(TV_DIR, exist_ok=True)
    from ref_model import _load_canonical_matrices
    _load_canonical_matrices()

    case_id = 0
    cases = []  # (case_id, name, w, h, tr_h, tr_v, sidx, lfnst_idx)

    # --- DCT2: 25 sizes × 9 LFNST = 225 ---
    print(f"=== DCT2: {len(DCT2_SIZES)} sizes × 9 LFNST = {len(DCT2_SIZES)*9} ===")
    for w, h in DCT2_SIZES:
        for lfnst_idx, sidx, pattern in LFNST_CONFIGS:
            name = f"{w}x{h}_DCT2xDCT2_lfnst{lfnst_idx}_s{sidx}"
            cases.append((case_id, name, w, h, 0, 0, sidx, lfnst_idx))
            case_id += 1

    # --- MTS: 16 sizes × 8 combos × 9 LFNST = 1152 ---
    print(f"=== MTS: {len(MTS_SIZES)} sizes × {len(MTS_COMBOS)} combos × 9 LFNST = {len(MTS_SIZES)*len(MTS_COMBOS)*9} ===")
    for w, h in MTS_SIZES:
        for tr_h, tr_v in MTS_COMBOS:
            for lfnst_idx, sidx, pattern in LFNST_CONFIGS:
                name = f"{w}x{h}_{tr_name(tr_h)}x{tr_name(tr_v)}_lfnst{lfnst_idx}_s{sidx}"
                cases.append((case_id, name, w, h, tr_h, tr_v, sidx, lfnst_idx))
                case_id += 1

    total = len(cases)
    print(f"\nTotal test cases: {total}")

    # Generate hex files
    print("\nGenerating hex files...")
    for cid, name, w, h, tr_h, tr_v, sidx, lfnst_idx in cases:
        # Determine pattern from LFNST config
        # LFNST_CONFIGS index: 0=lfnst0, 1-4=lfnst1_s0..s3, 5-8=lfnst2_s0..s3
        cfg_idx = 0 if lfnst_idx == 0 else (sidx + 1 if lfnst_idx == 1 else sidx + 5)
        _, _, pattern = LFNST_CONFIGS[cfg_idx]

        max_nz = 16 if w * h <= 256 else 8
        if pattern == "random_sparse":
            data = make_random_sparse(w, h, cid, max_nz)
        elif pattern == "low_freq":
            data = make_low_freq(w, h)
        else:  # extreme_low_freq
            data = make_extreme_low_freq(w, h)

        n_in, n_out = write_hex_files(f"case_{cid:04d}", w, h, tr_h, tr_v, sidx, lfnst_idx, data)
        if cid % 100 == 0:
            print(f"  [{cid:4d}/{total}] {name}: {n_in} in -> {n_out} out")

    print(f"  [{total-1:4d}/{total}] {cases[-1][1]}: done")

    # --- Generate regression_tests.vh ---
    print("\nGenerating regression_tests.vh...")
    with open(os.path.join(TV_DIR, "regression_tests.vh"), 'w') as f:
        f.write("// Auto-generated by gen_test_vectors.py — DO NOT EDIT\n")
        f.write(f"// {total} regression test cases\n\n")
        for cid, name, w, h, tr_h, tr_v, sidx, lfnst_idx in cases:
            f.write(gen_run_test_line(cid, name, w, h, tr_h, tr_v, sidx, lfnst_idx))

    # --- Generate backpressure_tests.vh ---
    # Select 37 cases: first 5 + every 50th + last 5
    bp_indices = list(range(5)) + list(range(50, total, 50)) + list(range(total - 5, total))
    bp_indices = sorted(set(bp_indices))
    print(f"\nGenerating backpressure_tests.vh ({len(bp_indices)} cases)...")
    with open(os.path.join(TV_DIR, "backpressure_tests.vh"), 'w') as f:
        f.write("// Auto-generated by gen_test_vectors.py — DO NOT EDIT\n")
        f.write(f"// {len(bp_indices)} backpressure tests (3on/2off toggle pattern)\n\n")
        for idx in bp_indices:
            cid, name, w, h, tr_h, tr_v, sidx, lfnst_idx = cases[idx]
            f.write(gen_bp_test_line(cid, name, w, h, tr_h, tr_v, sidx, lfnst_idx))

    # --- Generate end_same_cycle_tests.vh ---
    # Select 10 cases for end-same-cycle protocol test
    esc_indices = [0, 50, 100, 225, 400, 600, 800, 1000, 1200, total - 1]
    esc_indices = [i for i in esc_indices if i < total]
    print(f"\nGenerating end_same_cycle_tests.vh ({len(esc_indices)} cases)...")
    with open(os.path.join(TV_DIR, "end_same_cycle_tests.vh"), 'w') as f:
        f.write("// Auto-generated by gen_test_vectors.py — DO NOT EDIT\n")
        f.write(f"// {len(esc_indices)} end-same-cycle protocol tests\n\n")
        for idx in esc_indices:
            cid, name, w, h, tr_h, tr_v, sidx, lfnst_idx = cases[idx]
            f.write(gen_end_same_cycle_line(cid, name, w, h, tr_h, tr_v, sidx, lfnst_idx))

    # --- Generate continuous_tests.vh ---
    # Select 10 pairs (20 cases) for continuous TU testing
    cont_indices = [0, 1, 100, 101, 225, 226, 500, 501, 700, 701,
                    900, 901, 1000, 1001, 1100, 1101, 1300, 1301, total-2, total-1]
    cont_indices = [i for i in cont_indices if i < total]
    print(f"\nGenerating continuous_tests.vh ({len(cont_indices)} cases)...")
    with open(os.path.join(TV_DIR, "continuous_tests.vh"), 'w') as f:
        f.write("// Auto-generated by gen_test_vectors.py — DO NOT EDIT\n")
        f.write(f"// {len(cont_indices)} continuous TU tests (no reset between pairs)\n\n")
        for idx in cont_indices:
            cid, name, w, h, tr_h, tr_v, sidx, lfnst_idx = cases[idx]
            f.write(gen_continuous_line(cid, name, w, h, tr_h, tr_v, sidx, lfnst_idx))

    # --- Generate regression_index.txt ---
    print("\nGenerating regression_index.txt...")
    with open(os.path.join(TV_DIR, "regression_index.txt"), 'w') as f:
        for cid, name, w, h, tr_h, tr_v, sidx, lfnst_idx in cases:
            f.write(f"{cid:04d} {name} {w} {h} {tr_h} {tr_v} {sidx} {lfnst_idx}\n")

    # Summary
    print(f"\n{'='*60}")
    print(f"Generated {total} regression test cases")
    print(f"  Backpressure: {len(bp_indices)}")
    print(f"  End-same-cycle: {len(esc_indices)}")
    print(f"  Continuous: {len(cont_indices)}")
    print(f"  Total test invocations: {total + len(bp_indices) + len(esc_indices) + len(cont_indices)}")
    print(f"{'='*60}")
    print("Done!")


if __name__ == "__main__":
    main()
