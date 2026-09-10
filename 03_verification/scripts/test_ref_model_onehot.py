"""
Golden one-hot tests.
Verifies: trType mapping, index correctness, compute pipeline.
Matrix value correctness is verified by audit_matrices.py (cross-source comparison).
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ref_model import (its_inverse_transform, inverse_transform_1d,
                       get_canonical_transform_matrix,
                       LFNST_INPUT_SCAN_4x4, LFNST_OUTPUT_SCAN_16, LFNST_OUTPUT_SCAN_48)

pass_count = 0
fail_count = 0
src_labels = {0: {4: "VTM", 8: "VTM", 16: "VTM", 32: "VTM", 64: "ATTACHMENT+VTM"},
              1: "ATTACHMENT", 2: "ATTACHMENT"}


def check(name, condition, detail=""):
    global pass_count, fail_count
    if condition:
        pass_count += 1
    else:
        fail_count += 1
        print(f"  FAIL: {name}  {detail}")


# ============================================================
# 1. Main transform one-hot (element-by-element)
# ============================================================
print("=" * 60)
print("1. MAIN TRANSFORM ONE-HOT (element-by-element)")
print("=" * 60)

for tr_type, tr_name in [(0, "DCT2"), (1, "DST7"), (2, "DCT8")]:
    all_sizes = [4, 8, 16, 32, 64] if tr_type == 0 else [4, 8, 16, 32]
    tr_ok = True
    for N in all_sizes:
        try:
            T = get_canonical_transform_matrix(tr_type, N)
        except Exception as e:
            check(f"{tr_name} N={N}: load matrix", False, str(e))
            tr_ok = False
            continue

        src = src_labels[tr_type] if isinstance(src_labels[tr_type], str) else src_labels[tr_type][N]
        for k in range(min(N, 4)):
            x = [0] * N;
            x[k] = 1
            out = inverse_transform_1d(x, tr_type, N)
            row_ok = True
            for i in range(N):
                expected = (T[i][k] + 32) >> 6
                if out[i] != expected:
                    check(f"{tr_name} N={N} [{src}] onehot[{k}][{i}]: {out[i]} != {expected}", False)
                    row_ok = False
                    break
            if row_ok:
                pass_count += 1  # silently count per onehot position

    if tr_ok:
        check(f"{tr_name} all sizes: onehot PASS", True)

# ============================================================
# 2. LFNST input scan
# ============================================================
print()
print("=" * 60)
print("2. LFNST INPUT SCAN")
print("=" * 60)

coeff = [[r * 4 + c + 1 for c in range(4)] for r in range(4)]
input_vec = [coeff[r][c] for (r, c) in LFNST_INPUT_SCAN_4x4]
expected = [1, 5, 2, 9, 6, 3, 13, 10, 7, 4, 14, 11, 8, 15, 12, 16]
check("LFNST input scan: 4x4[1..16] -> diagonal vector",
      input_vec == expected, f"got {input_vec}")

# ============================================================
# 3. LFNST output write-back nTrs=16
# ============================================================
print()
print("=" * 60)
print("3. LFNST OUTPUT WRITE-BACK nTrs=16")
print("=" * 60)

expected_16 = [(0, 0), (0, 1), (0, 2), (0, 3), (1, 0), (1, 1), (1, 2), (1, 3),
               (2, 0), (2, 1), (2, 2), (2, 3), (3, 0), (3, 1), (3, 2), (3, 3)]
check("LFNST_OUTPUT_SCAN_16: row-major", LFNST_OUTPUT_SCAN_16 == expected_16)

# ============================================================
# 4. LFNST output write-back nTrs=48
# ============================================================
print()
print("=" * 60)
print("4. LFNST OUTPUT WRITE-BACK nTrs=48")
print("=" * 60)

check("LFNST_OUTPUT_SCAN_48: 48 positions", len(LFNST_OUTPUT_SCAN_48) == 48)
check("LFNST_OUTPUT_SCAN_48[0:32]: rows 0-3, cols 0-7",
      all(r < 4 and c < 8 for (r, c) in LFNST_OUTPUT_SCAN_48[:32]))
check("LFNST_OUTPUT_SCAN_48[32:48]: rows 4-7, cols 0-3",
      all(4 <= r < 8 and c < 4 for (r, c) in LFNST_OUTPUT_SCAN_48[32:]))

# ============================================================
# 5. Full LFNST integration
# ============================================================
print()
print("=" * 60)
print("5. FULL LFNST INTEGRATION (4x4)")
print("=" * 60)

data = [[0] * 4 for _ in range(4)]
for idx, (r, c) in enumerate(LFNST_INPUT_SCAN_4x4):
    data[r][c] = idx + 1

result = its_inverse_transform(data, 4, 4, 0, 0, 0, 1)
check("LFNST 4x4: produces non-zero output", any(v != 0 for row in result for v in row))
check("LFNST 4x4: output is 4x4", len(result) == 4 and len(result[0]) == 4)

# ============================================================
# 6. trType mapping verification
# ============================================================
print()
print("=" * 60)
print("6. trType MAPPING VERIFICATION")
print("=" * 60)

d2 = inverse_transform_1d([1] + [0] * 3, 0, 4)
d7 = inverse_transform_1d([1] + [0] * 3, 1, 4)
d8 = inverse_transform_1d([1] + [0] * 3, 2, 4)
check("trType=0 vs 1: different", d2 != d7)
check("trType=1 vs 2: different", d7 != d8)
check("trType=0 vs 2: different", d2 != d8)

# ============================================================
# Summary
# ============================================================
print(f"\n{'=' * 60}")
print(f"RESULTS: {pass_count} PASS, {fail_count} FAIL")
if fail_count == 0:
    print("GOLDEN ONE-HOT TEST: ALL PASSED")
else:
    print("GOLDEN ONE-HOT TEST: FAILURES DETECTED")
    sys.exit(1)
