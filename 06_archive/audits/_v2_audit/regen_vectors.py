"""Deterministic regeneration of ALL test vectors from canonical ref_model.
Usage: python regen_vectors.py <output_dir>
Two runs on the same output_dir produce bit-identical files.
"""
import hashlib, json, os, random, sys, shutil

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_DIR = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, os.path.join(PROJ_DIR, '03_verification', 'scripts'))

from ref_model import its_inverse_transform, flatten_raster


def make_seed(desc):
    return int.from_bytes(hashlib.sha256(desc.encode("ascii")).digest()[:8], "big")


def to_hex(val, bits):
    if val < 0: val += (1 << bits)
    return format(val & ((1 << bits) - 1), f'0{bits // 4}X')


def write_input_hex(path, data):
    flat = flatten_raster(data)
    nz = 0
    with open(path, 'w') as f:
        for idx, val in enumerate(flat):
            if val != 0:
                combined = (idx << 16) | (val & 0xFFFF)
                f.write(f"{combined:07X}\n")
                nz += 1
    # Verify
    if os.path.getsize(path) == 0:
        raise RuntimeError(f"Wrote empty input file: {path}")
    return nz


def write_golden_hex(path, output):
    flat = flatten_raster(output)
    with open(path, 'w') as f:
        for val in flat:
            f.write(f"{to_hex(val, 10)}\n")
    if os.path.getsize(path) == 0:
        raise RuntimeError(f"Wrote empty golden file: {path}")
    return flat


def generate_case(tv_dir, w, h, tr_h, tr_v, sidx, lfnst, desc_base, input_data=None):
    if input_data is None:
        input_data = [[0] * w for _ in range(h)]
        rng = random.Random(make_seed(desc_base))
        for _ in range(min(8, w * h)):
            r = rng.randint(0, h - 1);
            c = rng.randint(0, w - 1)
            input_data[r][c] = rng.randint(-128, 127)

    output = its_inverse_transform(input_data, w, h, tr_h, tr_v, sidx, lfnst)
    nz = write_input_hex(os.path.join(tv_dir, f"{desc_base}_input.hex"), input_data)
    write_golden_hex(os.path.join(tv_dir, f"{desc_base}_golden.hex"), output)
    return nz


def gen_directed(tv_dir):
    """Generate all boundary + manual test cases."""
    # Boundary tests
    generate_case(tv_dir, 4, 4, 0, 0, 0, 0, "boundary_dc_4x4", [[64] * 4] * 4)
    generate_case(tv_dir, 4, 4, 0, 0, 0, 0, "boundary_maxval_4x4", [[32767] * 4] * 4)
    generate_case(tv_dir, 4, 4, 0, 0, 0, 0, "boundary_minval_4x4", [[-32768] * 4] * 4)
    # boundary_sparse_8x8: exactly 2 non-zero
    data = [[0] * 8 for _ in range(8)]; data[0][0] = 100; data[0][7] = -50
    nz, golden = generate_case(tv_dir, 8, 8, 0, 0, 0, 0, "boundary_sparse_8x8", data), None
    # boundary_zero: allowed empty input
    out = its_inverse_transform([[0] * 4] * 4, 4, 4, 0, 0, 0, 0)
    # boundary_zero is the ONLY case where all-zero input is valid
    with open(os.path.join(tv_dir, "boundary_zero_4x4_input.hex"), 'w') as f:
        pass  # intentionally empty for all-zero sparse input
    write_golden_hex(os.path.join(tv_dir, "boundary_zero_4x4_golden.hex"), out)

    # DCT2 all sizes
    dct2_sizes = [(4, 4), (4, 8), (4, 16), (4, 32), (4, 64), (8, 4), (16, 4), (32, 4), (64, 4),
                  (8, 8), (8, 16), (8, 32), (8, 64), (16, 8), (32, 8), (64, 8),
                  (16, 16), (16, 32), (16, 64), (32, 16), (32, 32), (32, 64),
                  (64, 16), (64, 32), (64, 64)]
    for w, h in dct2_sizes:
        generate_case(tv_dir, w, h, 0, 0, 0, 0, f"dct2_{w}x{h}")

    # LFNST variants
    lfnst_sizes = [(4, 4), (8, 8), (16, 16), (4, 64), (8, 64), (8, 16), (8, 4),
                   (16, 8), (16, 32), (16, 4), (32, 16), (32, 32), (32, 4),
                   (64, 4), (64, 8), (4, 8), (4, 16), (4, 32)]
    for lw, lh in lfnst_sizes:
        for li in [1, 2]:
            for si in [0, 1, 2, 3]:
                generate_case(tv_dir, lw, lh, 0, 0, si, li, f"dct2_{lw}x{lh}_lfnst{li}_s{si}")

    # DCT8
    dct8_list = [(4, 4), (4, 8), (4, 16), (4, 32), (8, 4), (16, 4), (32, 4),
                 (8, 8), (8, 16), (8, 32), (16, 8), (32, 8),
                 (16, 16), (16, 32), (32, 16), (32, 32)]
    for w, h in dct8_list:
        generate_case(tv_dir, w, h, 2, 2, 0, 0, f"dct8_{w}x{h}")

    # DST7
    dst7_list = [(4, 4), (4, 8), (4, 16), (4, 32), (8, 4), (16, 4), (32, 4),
                 (8, 8), (8, 16), (8, 32), (16, 8), (32, 8),
                 (16, 16), (16, 32), (32, 16), (32, 32)]
    for w, h in dst7_list:
        generate_case(tv_dir, w, h, 1, 1, 0, 0, f"dst7_{w}x{h}")

    # LFNST pure
    for si in range(4):
        for li in [1, 2]:
            generate_case(tv_dir, 4, 4, 0, 0, si, li, f"lfnst16_s{si}_i{li}")
            generate_case(tv_dir, 8, 8, 0, 0, si, li, f"lfnst48_s{si}_i{li}")

    # DC
    generate_case(tv_dir, 4, 4, 0, 0, 0, 0, "dct2_4x4_dc", [[64] * 4] * 4)
    generate_case(tv_dir, 8, 8, 0, 0, 0, 0, "dct2_8x8_dc", [[64] * 8] * 8)


def main(tv_dir):
    os.makedirs(tv_dir, exist_ok=True)

    # 1. Directed/manual tests
    print("=== Directed/manual tests ===")
    gen_directed(tv_dir)
    n_files = len(os.listdir(tv_dir))
    print(f"Directed files: {n_files}")

    # 2. Regression via gen_test_vectors (1377 cases)
    print("\n=== Regression (1377 cases) ===")
    sys.path.insert(0, os.path.join(PROJ_DIR, '03_verification', 'scripts'))
    import gen_test_vectors
    # Override module-level TV_DIR BEFORE calling main()
    gen_test_vectors.TV_DIR = tv_dir
    gen_test_vectors.BASE_PATH = "../tb/test_vectors"
    gen_test_vectors.main()

    # 3. Verify
    all_files = sorted(os.listdir(tv_dir))
    empty_count = sum(1 for f in all_files if os.path.getsize(os.path.join(tv_dir, f)) == 0)
    print(f"\nTotal files: {len(all_files)}")
    print(f"Empty files: {empty_count} (only boundary_zero_4x4_input.hex expected)")

    # Verify every file is non-empty except boundary_zero
    for f in all_files:
        fp = os.path.join(tv_dir, f)
        if os.path.getsize(fp) == 0 and f != "boundary_zero_4x4_input.hex":
            print(f"  UNEXPECTED EMPTY: {f}")

    sys.exit(0)


if __name__ == "__main__":
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(PROJ_DIR, "03_verification", "tb", "test_vectors")
    main(out_dir)
