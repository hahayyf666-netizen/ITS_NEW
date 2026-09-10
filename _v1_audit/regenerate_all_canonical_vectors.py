"""
Regenerate ALL test vectors from canonical reference model with deterministic seeds.
Output: specified TV_DIR. Two runs produce bit-identical results.
"""
import hashlib, json, os, random, sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_DIR = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, os.path.join(PROJ_DIR, '03_verification', 'scripts'))
from ref_model import its_inverse_transform, flatten_raster

# ---- config ----
TV_DIR = os.path.join(PROJ_DIR, '03_verification', 'tb', 'test_vectors')
_errors = 0


def fail(msg):
    global _errors;
    print(f"  FAIL: {msg}");
    _errors += 1


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
    return nz


def write_golden_hex(path, output):
    flat = flatten_raster(output)
    with open(path, 'w') as f:
        for val in flat:
            f.write(f"{to_hex(val, 10)}\n")
    return flat


def generate_case(w, h, tr_h, tr_v, sidx, lfnst, desc_base, input_data=None):
    if input_data is None:
        input_data = [[0] * w for _ in range(h)]
        rng = random.Random(make_seed(desc_base))
        for _ in range(min(8, w * h)):
            r = rng.randint(0, h - 1);
            c = rng.randint(0, w - 1)
            input_data[r][c] = rng.randint(-128, 127)

    output = its_inverse_transform(input_data, w, h, tr_h, tr_v, sidx, lfnst)
    nz = write_input_hex(os.path.join(TV_DIR, f"{desc_base}_input.hex"), input_data)
    golden = write_golden_hex(os.path.join(TV_DIR, f"{desc_base}_golden.hex"), output)
    return nz, golden


# ============================================================
def main():
    global _errors
    os.makedirs(TV_DIR, exist_ok=True)

    # ---- Boundary tests ----
    print("=== Boundary tests ===")
    nz, g = generate_case(4, 4, 0, 0, 0, 0, "boundary_dc_4x4",
                          [[64] * 4] * 4)
    nz, g = generate_case(4, 4, 0, 0, 0, 0, "boundary_maxval_4x4",
                          [[32767] * 4] * 4)
    nz, g = generate_case(4, 4, 0, 0, 0, 0, "boundary_minval_4x4",
                          [[-32768] * 4] * 4)

    # boundary_sparse_8x8: exactly two non-zero values
    data = [[0] * 8 for _ in range(8)]
    data[0][0] = 100
    data[0][7] = -50
    nz, g = generate_case(8, 8, 0, 0, 0, 0, "boundary_sparse_8x8", data)
    assert nz == 2, f"boundary_sparse_8x8: expected 2 non-zero inputs, got {nz}"
    assert any(v != 0 for v in g), "boundary_sparse_8x8: golden must not be all zeros"

    nz, g = generate_case(4, 4, 0, 0, 0, 0, "boundary_zero_4x4",
                          [[0] * 4] * 4)

    # ---- Manual directed tests ----
    print("\n=== Manual directed tests ===")
    dct2_sizes = [(4, 4), (4, 8), (4, 16), (4, 32), (4, 64),
                  (8, 4), (16, 4), (32, 4), (64, 4),
                  (8, 8), (8, 16), (8, 32), (8, 64),
                  (16, 8), (32, 8), (64, 8),
                  (16, 16), (16, 32), (16, 64),
                  (32, 16), (32, 32), (32, 64),
                  (64, 16), (64, 32), (64, 64)]

    for w, h in dct2_sizes:
        generate_case(w, h, 0, 0, 0, 0, f"dct2_{w}x{h}")

    lfnst_sizes = [(4, 4), (8, 8), (16, 16), (4, 64), (8, 64),
                   (16, 8), (16, 32), (32, 16), (32, 32), (64, 4), (64, 8),
                   (8, 16), (8, 4), (16, 4), (32, 4), (4, 8), (4, 16), (4, 32)]
    for lw, lh in lfnst_sizes:
        for li in [1, 2]:
            for si in [0, 1, 2, 3]:
                generate_case(lw, lh, 0, 0, si, li,
                              f"dct2_{lw}x{lh}_lfnst{li}_s{si}")

    dct8_sizes = [(4, 4), (4, 8), (4, 16), (4, 32), (8, 4), (16, 4), (32, 4),
                  (8, 8), (8, 16), (8, 32), (16, 8), (32, 8),
                  (16, 16), (16, 32), (32, 16), (32, 32)]
    for w, h in dct8_sizes:
        generate_case(w, h, 2, 2, 0, 0, f"dct8_{w}x{h}")

    dst7_sizes = [(4, 4), (4, 8), (4, 16), (4, 32), (8, 4), (16, 4), (32, 4),
                  (8, 8), (8, 16), (8, 32), (16, 8), (32, 8),
                  (16, 16), (16, 32), (32, 16), (32, 32)]
    for w, h in dst7_sizes:
        generate_case(w, h, 1, 1, 0, 0, f"dst7_{w}x{h}")

    for si in range(4):
        for li in [1, 2]:
            generate_case(4, 4, 0, 0, si, li, f"lfnst16_s{si}_i{li}")
            generate_case(8, 8, 0, 0, si, li, f"lfnst48_s{si}_i{li}")

    generate_case(4, 4, 0, 0, 0, 0, "dct2_4x4_dc", [[64] * 4] * 4)
    generate_case(8, 8, 0, 0, 0, 0, "dct2_8x8_dc", [[64] * 8] * 8)

    # ---- Main regression (1377 cases) ----
    print("\n=== Main regression (1377 cases) ===")
    import gen_test_vectors
    gen_test_vectors.TV_DIR = TV_DIR
    gen_test_vectors.BASE_PATH = "../tb/test_vectors"
    gen_test_vectors.main()

    # ---- Count ----
    files = sorted(os.listdir(TV_DIR))
    print(f"\nTotal: {len(files)} files")
    if _errors:
        print(f"VECTOR AUDIT: FAIL ({_errors} errors)")
        sys.exit(1)
    else:
        print("VECTOR AUDIT: PASS")


if __name__ == '__main__':
    main()
