"""
Compare current project matrices against attachment_matrices.json.
Without modifying RTL, ROM, or hex.

Comparisons:
  1. Formula-generated (gen_rom_coeffs.py) vs attachment JSON
  2. Current rom_coeffs.hex vs attachment JSON
  3. Current lfnst_coeffs.hex vs attachment JSON
  4. trType mapping audit (current: 1=DCT8,2=DST7 vs attachment: 1=DST7,2=DCT8)
"""
import json
import math
import os
import sys


def gen_dct2_matrix(N):
    T = [[0]*N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            if i == 0: T[i][j] = 64
            else:
                angle = math.pi * i * (2*j + 1) / (2 * N)
                T[i][j] = round(89 * math.cos(angle))
    return T


def gen_dct8_matrix(N):
    T = [[0]*N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            angle = math.pi * (2*i + 1) * (2*j + 1) / (4 * N)
            T[i][j] = round(64 * math.cos(angle))
    return T


def gen_dst7_matrix(N):
    T = [[0]*N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            angle = math.pi * (i + 1) * (j + 1) / (N + 1)
            T[i][j] = round(64 * math.sin(angle))
    return T


def compare_matrices(name, mat_a, mat_b):
    """Compare two matrices, return diff summary."""
    if len(mat_a) != len(mat_b) or len(mat_a[0]) != len(mat_b[0]):
        return {
            "name": name,
            "size": f"{len(mat_a)}x{len(mat_a[0])} vs {len(mat_b)}x{len(mat_b[0])}",
            "element_count": -1,
            "diff_count": -1,
            "max_abs_diff": -1,
            "mismatches": [("SIZE MISMATCH",)],
        }

    total = len(mat_a) * len(mat_a[0])
    diffs = 0
    max_diff = 0
    mismatches = []
    for i in range(len(mat_a)):
        for j in range(len(mat_a[0])):
            if mat_a[i][j] != mat_b[i][j]:
                diffs += 1
                d = abs(mat_a[i][j] - mat_b[i][j])
                max_diff = max(max_diff, d)
                if len(mismatches) < 20:
                    mismatches.append((i, j, mat_a[i][j], mat_b[i][j], d))

    return {
        "name": name,
        "size": f"{len(mat_a)}x{len(mat_a[0])}",
        "element_count": total,
        "diff_count": diffs,
        "max_abs_diff": max_diff,
        "mismatches": mismatches,
    }


def main():
    # Load attachment matrices
    json_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             '..', 'output', 'attachment_matrices.json')
    with open(json_path, 'r', encoding='utf-8') as f:
        attachment = json.load(f)

    hex_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           '..', '..', '02_rtl', 'rtl')

    all_diffs = []

    # ============================================================
    # 1. Formula matrices vs attachment
    #    CURRENT mapping: 0=DCT2, 1=DCT8, 2=DST7
    #    ATTACHMENT:       0=DCT2, 1=DST7, 2=DCT8
    # ============================================================
    print("=" * 70)
    print("1. CURRENT FORMULA MATRICES vs ATTACHMENT JSON")
    print("   (Current: trType 1=DCT8, 2=DST7)")
    print("   (Attachment: trType 1=DST7, 2=DCT8)")
    print("=" * 70)

    # Current formula generators with CURRENT trType mapping
    current_generators = {
        "0": ("DCT2", gen_dct2_matrix),
        "1": ("DCT8", gen_dct8_matrix),  # current uses 1=DCT8
        "2": ("DST7", gen_dst7_matrix),  # current uses 2=DST7
    }

    for tr in ["0", "1", "2"]:
        name_cur, gen_fn = current_generators[tr]
        sizes_att = attachment["transforms"][tr]["sizes"]

        for size in sizes_att:
            N = int(size)
            formula_mat = gen_fn(N)
            att_mat = sizes_att[size]

            label = f"formula_cur_{name_cur}_vs_att_{attachment['transforms'][tr]['name']}_N{N}"
            result = compare_matrices(label, formula_mat, att_mat)
            all_diffs.append(result)

            if result["diff_count"] != 0:
                print(f"  {label}: {result['diff_count']}/{result['element_count']} DIFFER "
                      f"(max_diff={result['max_abs_diff']})")
                if result["mismatches"]:
                    for m in result["mismatches"][:3]:
                        print(f"    [{m[0]}][{m[1]}]: formula={m[2]} att={m[3]} (diff={m[4]})")
            else:
                print(f"  {label}: MATCH")

    # ============================================================
    # 2. rom_coeffs.hex vs attachment JSON
    # ============================================================
    print()
    print("=" * 70)
    print("2. CURRENT rom_coeffs.hex vs ATTACHMENT JSON")
    print("   (Current ROM order: DCT2 -> DCT8 -> DST7)")
    print("   (Attachment order: DCT2 -> DST7 -> DCT8)")
    print("=" * 70)

    hex_path = os.path.join(hex_dir, 'rom_coeffs.hex')
    if os.path.exists(hex_path):
        with open(hex_path, 'r') as f:
            hex_lines = [l.strip() for l in f if l.strip() and not l.startswith('//')]
        hex_vals = []
        for line in hex_lines:
            v = int(line, 16)
            if v > 32767: v -= 65536
            hex_vals.append(v)

        # Current ROM layout (from gen_rom_coeffs.py):
        # DCT2(4): 0..15, DCT2(8): 16..79, DCT2(16): 80..335,
        # DCT2(32): 336..1359, DCT2(64): 1360..5455,
        # DCT8(4): 5456..5471, DCT8(8): 5472..5535, DCT8(16): 5536..5791,
        # DCT8(32): 5792..6815,
        # DST7(4): 6816..6831, DST7(8): 6832..6895, DST7(16): 6896..7151,
        # DST7(32): 7152..8175

        current_rom_layout = {
            "0": {  # DCT2
                4: 0, 8: 16, 16: 80, 32: 336, 64: 1360,
            },
            "1": {  # DCT8 (current encoding)
                4: 5456, 8: 5472, 16: 5536, 32: 5792,
            },
            "2": {  # DST7 (current encoding)
                4: 6816, 8: 6832, 16: 6896, 32: 7152,
            },
        }

        # Compare: current ROM places DCT8 at trType=1 location, but attachment says
        # trType=1 should be DST7. So we need to compare:
        #   ROM[trType=1 region] vs attachment[trType=1]=DST7
        #   ROM[trType=2 region] vs attachment[trType=2]=DCT8
        for tr_cur, tr_att_name in [("1", "DST7"), ("2", "DCT8")]:
            att_tr = tr_cur  # same tr number in JSON
            att_name = attachment["transforms"][tr_cur]["name"]
            sizes = attachment["transforms"][tr_cur]["sizes"]

            for size in sorted(sizes.keys(), key=int):
                N = int(size)
                base = current_rom_layout[tr_cur][N]
                # Read from ROM
                rom_mat = []
                for i in range(N):
                    row = []
                    for j in range(N):
                        idx = base + i * N + j
                        row.append(hex_vals[idx] if idx < len(hex_vals) else 0)
                    rom_mat.append(row)

                att_mat = sizes[size]
                label = f"ROM_tr{tr_cur}_cur_{current_generators[tr_cur][0]}_vs_att_{att_name}_N{N}"
                result = compare_matrices(label, rom_mat, att_mat)
                all_diffs.append(result)

                swap_label = f"ROM_tr{tr_cur}_cur_vs_att_SWAPPED_TRTYPE_N{N}"
                # Also compare ROM[tr=1] with attachment[tr=1]=DST7
                # If current ROM stores DCT8 at tr=1 but attachment says DST7 should be there, they should differ
                print(f"  {label}: {result['diff_count']}/{result['element_count']} DIFFER "
                      f"(max_diff={result['max_abs_diff']})")
                if result["diff_count"] == 0:
                    print(f"    -> ROM tr{tr_cur} ({current_generators[tr_cur][0]}) MATCHES attachment {att_name} "
                          f"- mapping may NOT need swap!")
                elif result["mismatches"]:
                    for m in result["mismatches"][:3]:
                        print(f"    [{m[0]}][{m[1]}]: ROM={m[2]} att={m[3]} (diff={m[4]})")

        # Also verify DCT2 (trType=0 should be same)
        for size in [4, 8, 16, 32, 64]:
            N = size
            base = current_rom_layout["0"][N]
            rom_mat = [[hex_vals[base + i*N + j] for j in range(N)] for i in range(N)]
            att_mat = attachment["transforms"]["0"]["sizes"][str(N)]
            label = f"ROM_tr0_DCT2_N{N}"
            result = compare_matrices(label, rom_mat, att_mat)
            all_diffs.append(result)
            if result["diff_count"] == 0:
                print(f"  {label}: MATCH")
            else:
                print(f"  {label}: {result['diff_count']}/{result['element_count']} DIFFER "
                      f"(max_diff={result['max_abs_diff']})")
                for m in result["mismatches"][:3]:
                    print(f"    [{m[0]}][{m[1]}]: ROM={m[2]} att={m[3]} (diff={m[4]})")
    else:
        print(f"  rom_coeffs.hex not found at {hex_path}")

    # ============================================================
    # 3. lfnst_coeffs.hex vs attachment JSON
    # ============================================================
    print()
    print("=" * 70)
    print("3. CURRENT lfnst_coeffs.hex vs ATTACHMENT JSON")
    print("=" * 70)

    lfnst_hex_path = os.path.join(hex_dir, 'lfnst_coeffs.hex')
    if os.path.exists(lfnst_hex_path):
        with open(lfnst_hex_path, 'r') as f:
            lfnst_lines = [l.strip() for l in f if l.strip() and not l.startswith('//')]
        lfnst_vals = []
        for line in lfnst_lines:
            v = int(line, 16)
            if v > 32767: v -= 65536
            lfnst_vals.append(v)

        for ntrs in ["16", "48"]:
            for set_idx in ["0", "1", "2", "3"]:
                for idx in ["1", "2"]:
                    att_mat = attachment["lfnst"][ntrs][set_idx][idx]
                    nrows = len(att_mat)
                    ncols = len(att_mat[0])

                    # Current LFNST ROM layout:
                    if ntrs == "16":
                        base = int(set_idx) * 512 + (int(idx) - 1) * 256
                    else:
                        base = 2048 + (int(set_idx) * 2 + (int(idx) - 1)) * 768

                    rom_mat = []
                    for i in range(nrows):
                        row = []
                        for j in range(ncols):
                            addr = base + i * 16 + j
                            row.append(lfnst_vals[addr] if addr < len(lfnst_vals) else 0)
                        rom_mat.append(row)

                    label = f"LFNST_nTrs{ntrs}_s{set_idx}_i{idx}"
                    result = compare_matrices(label, rom_mat, att_mat)
                    all_diffs.append(result)
                    if result["diff_count"] == 0:
                        print(f"  {label}: MATCH")
                    else:
                        print(f"  {label}: {result['diff_count']}/{result['element_count']} DIFFER "
                              f"(max_diff={result['max_abs_diff']})")
                        for m in result["mismatches"][:3]:
                            print(f"    [{m[0]}][{m[1]}]: ROM={m[2]} att={m[3]} (diff={m[4]})")
    else:
        print(f"  lfnst_coeffs.hex not found at {lfnst_hex_path}")

    # ============================================================
    # Summary
    # ============================================================
    print()
    print("=" * 70)
    print("SUMMARY")
    print("=" * 70)
    matching = sum(1 for d in all_diffs if d["diff_count"] == 0)
    differing = sum(1 for d in all_diffs if d["diff_count"] != 0)
    print(f"  Matching: {matching}")
    print(f"  Differing: {differing}")

    # Key finding: trType swap
    print()
    print("KEY FINDINGS:")
    # Check if current trType=1 matches attachment trType=2 and vice versa
    for size in ["4", "8", "16", "32"]:
        N = int(size)
        # Current DCT8 formula (tr=1 current) vs attachment DST7 (tr=1)
        formula_cur_dct8 = gen_dct8_matrix(N)
        att_dst7 = attachment["transforms"]["1"]["sizes"][size]
        diff_dct8_vs_dst7 = compare_matrices("", formula_cur_dct8, att_dst7)

        # Current DCT8 formula vs attachment DCT8 (tr=2)
        formula_cur_dst7 = gen_dst7_matrix(N)
        att_dct8 = attachment["transforms"]["2"]["sizes"][size]
        diff_dst7_vs_dct8 = compare_matrices("", formula_cur_dst7, att_dct8)

        # Current DCT8 formula vs attachment DCT8 (tr=2) - does swapping fix it?
        diff_dct8_vs_dct8 = compare_matrices("", formula_cur_dct8, att_dct8)
        diff_dst7_vs_dst7 = compare_matrices("", formula_cur_dst7, att_dst7)

        if diff_dct8_vs_dct8["diff_count"] == 0:
            print(f"  N={N}: Current DCT8(tr=1) matches Attachment DCT8(tr=2) -> trType SWAP needed")
        if diff_dst7_vs_dst7["diff_count"] == 0:
            print(f"  N={N}: Current DST7(tr=2) matches Attachment DST7(tr=1) -> trType SWAP needed")


if __name__ == '__main__':
    main()
