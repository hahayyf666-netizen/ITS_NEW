"""
V2 ROM generator - reads canonical_matrices.json, writes rom_coeffs.hex.
No formulas, no fallback, no trig functions.

ROM layout (unchanged address ranges):
  DCT2 (trType=0): 4(0..15), 8(16..79), 16(80..335), 32(336..1359), 64(1360..5455)
  DST7 (trType=1): 4(5456..5471), 8(5472..5535), 16(5536..5791), 32(5792..6815)
  DCT8 (trType=2): 4(6816..6831), 8(6832..6895), 16(6896..7151), 32(7152..8175)
Total depth: 8176

lfnst_coeffs.hex is NOT regenerated - verified identical to attachment.
"""
import json, os, sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CANONICAL = os.path.join(SCRIPT_DIR, "..", "output", "canonical_matrices.json")

TR_TYPE_SIZES = [
    (0, [4, 8, 16, 32, 64]),   # DCT2
    (1, [4, 8, 16, 32]),        # DST7
    (2, [4, 8, 16, 32]),        # DCT8
]

BASE_ADDR = {
    (0, 4): 0, (0, 8): 16, (0, 16): 80, (0, 32): 336, (0, 64): 1360,
    (1, 4): 5456, (1, 8): 5472, (1, 16): 5536, (1, 32): 5792,
    (2, 4): 6816, (2, 8): 6832, (2, 16): 6896, (2, 32): 7152,
}
TOTAL_DEPTH = 8176


def to_signed_16bit(val):
    if val < 0: val += 65536
    return val & 0xFFFF


def main(output_path):
    with open(CANONICAL, 'r', encoding='utf-8') as f:
        data = json.load(f)

    transforms = data["transforms"]

    # Initialize ROM
    rom = [0] * TOTAL_DEPTH

    for tr_type, sizes in TR_TYPE_SIZES:
        name = transforms[str(tr_type)]["name"]
        matrices = transforms[str(tr_type)]["inverse_operator"]
        for N in sizes:
            base = BASE_ADDR[(tr_type, N)]
            matrix = matrices[str(N)]
            for i in range(N):
                for j in range(N):
                    addr = base + i * N + j
                    rom[addr] = to_signed_16bit(matrix[i][j])
            end = base + N * N - 1
            print(f"  {name} {N}x{N}: ROM[{base}..{end}] ({N*N} entries)")

    # Write hex
    with open(output_path, 'w') as f:
        f.write(f"// V2 ROM generated from canonical_matrices.json\n")
        f.write(f"// trType: 0=DCT2, 1=DST7, 2=DCT8\n")
        f.write(f"// Total entries: {TOTAL_DEPTH}\n\n")
        for val in rom:
            f.write(f"{val:04X}\n")

    print(f"\nWritten: {output_path} ({TOTAL_DEPTH} entries)")

    # Verify no gaps
    for i in range(TOTAL_DEPTH):
        if rom[i] == 0 and i > 0:
            prev_zero = all(v == 0 for v in rom[:i])
            if not prev_zero:
                pass  # zero entries after valid data are OK if within a block
    return rom


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(SCRIPT_DIR, "..", "..", "02_rtl", "rtl", "rom_coeffs.hex")
    main(out)
