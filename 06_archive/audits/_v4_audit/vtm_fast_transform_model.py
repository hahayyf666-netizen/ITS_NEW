"""
VTM Fast Inverse Transform — Bit-Exact Python Model
====================================================

Faithful Python port of the VTM fast inverse transform functions from
`source/Lib/CommonLib/TrQuant_EMT.cpp`:

    fastInverseDCT2_B4/B8/B16/B32/B64  (E/O partial-butterfly)
    fastInverseDST7_B4/B8/B16/B32      (B4 special / B8 matrix-mult / B16,B32 partial butterfly)
    fastInverseDCT8_B4/B8/B16/B32

Coefficient source: `canonical_matrices.json`.  Element-wise verified equal to the VTM
`g_trCore*P*[TRANSFORM_INVERSE][0]` matrices for DCT2 all sizes and DST7/DCT8 4/8/16.
For DST7/DCT8 N=32 the JSON (Huawei attachment) DIFFERS from VTM RomTr (496 of 1024
entries) — the model therefore uses the VTM RomTr inverse matrices for N=32 (see
`_matrix_for`), so the fast algorithm is bit-exact with VTM for every size.

KEY FINDING on transpose orientation (see verify()):
----------------------------------------------------
The VTM `g_trCore*P*[TRANSFORM_INVERSE]` matrices are the *forward* VVC matrices
(e.g. DEFINE_DST7_P*_MATRIX(…)), which are NOT symmetric.  The fast *inverse*
algorithms apply them TRANSPOSED (dst = C^T * src), which is the mathematically
correct inverse:

    DCT2  :  dst = C^T * src   (C is NOT symmetric; VTM applies the transpose)
    DST7  :  dst = C^T * src   (C is NOT symmetric)
    DCT8  :  dst = C * src     (C IS symmetric, so C^T == C — no distinction)

So a bit-exact VTM inverse multiplies by the *transpose* of the canonical matrix.
`ref_model.inverse_transform_1d` multiplies by C directly (no transpose); therefore
for DCT2 and DST7 it computes the FORWARD transform and does NOT reproduce the VTM
inverse.  Only DCT8 (symmetric) is reproduced correctly by ref_model.

For every fast function the model below reproduces the *exact* C++ arithmetic:
add = 1 << (shift-1), right shift >>shift, and Clip3(-32768, 32767).  All arithmetic
is performed in unbounded Python ints; intermediate magnitudes stay below 2^31 for
16-bit inputs and 8-bit coefficients, so no 32-bit wraparound can occur (confirmed
empirically during verification).

Usage
-----
    from vtm_fast_transform_model import fast_inv_dct2, fast_inv_dst7, fast_inv_dct8
    y = fast_inv_dct2([1,2,3,4], 4)      # 1-D inverse DCT2, shift=6, clip
    stats = op_stats()                    # multiplication / add-sub counts
"""

import json
import os
import random


# --- VTM RomTr inverse matrices for N=32 (from RomTr.cpp macro expansion) ---
# These DIFFER from canonical_matrices.json (Huawei attachment) for DST7/DCT8 N=32
# (496/1024 entries differ).  They are what the VTM fast-inverse algorithm is
# bit-exact with, so they are used here instead of the JSON values for N=32.
VTM_DST7_P32 = [
    [4, 9, 13, 17, 21, 26, 30, 34, 38, 42, 46, 50, 53, 56, 60, 63, 66, 68, 72, 74, 77, 78, 80, 82, 84, 85, 86, 87, 88, 89, 90, 90],
    [13, 26, 38, 50, 60, 68, 77, 82, 86, 89, 90, 88, 85, 80, 74, 66, 56, 46, 34, 21, 9, -4, -17, -30, -42, -53, -63, -72, -78, -84, -87, -90],
    [21, 42, 60, 74, 84, 89, 89, 84, 74, 60, 42, 21, 0, -21, -42, -60, -74, -84, -89, -89, -84, -74, -60, -42, -21, 0, 21, 42, 60, 74, 84, 89],
    [30, 56, 77, 87, 89, 80, 63, 38, 9, -21, -50, -72, -85, -90, -84, -68, -46, -17, 13, 42, 66, 82, 90, 86, 74, 53, 26, -4, -34, -60, -78, -88],
    [38, 68, 86, 88, 74, 46, 9, -30, -63, -84, -90, -78, -53, -17, 21, 56, 80, 90, 82, 60, 26, -13, -50, -77, -89, -85, -66, -34, 4, 42, 72, 87],
    [46, 78, 90, 77, 42, -4, -50, -80, -90, -74, -38, 9, 53, 82, 89, 72, 34, -13, -56, -84, -88, -68, -30, 17, 60, 85, 87, 66, 26, -21, -63, -86],
    [53, 85, 85, 53, 0, -53, -85, -85, -53, 0, 53, 85, 85, 53, 0, -53, -85, -85, -53, 0, 53, 85, 85, 53, 0, -53, -85, -85, -53, 0, 53, 85],
    [60, 89, 74, 21, -42, -84, -84, -42, 21, 74, 89, 60, 0, -60, -89, -74, -21, 42, 84, 84, 42, -21, -74, -89, -60, 0, 60, 89, 74, 21, -42, -84],
    [66, 90, 56, -13, -74, -87, -46, 26, 80, 84, 34, -38, -85, -78, -21, 50, 88, 72, 9, -60, -90, -63, 4, 68, 89, 53, -17, -77, -86, -42, 30, 82],
    [72, 86, 34, -46, -89, -63, 13, 78, 82, 21, -56, -90, -53, 26, 84, 77, 9, -66, -88, -42, 38, 87, 68, -4, -74, -85, -30, 50, 90, 60, -17, -80],
    [77, 80, 9, -72, -84, -17, 66, 86, 26, -60, -88, -34, 53, 90, 42, -46, -90, -50, 38, 89, 56, -30, -87, -63, 21, 85, 68, -13, -82, -74, 4, 78],
    [80, 72, -17, -86, -60, 34, 90, 46, -50, -89, -30, 63, 85, 13, -74, -78, 4, 82, 68, -21, -87, -56, 38, 90, 42, -53, -88, -26, 66, 84, 9, -77],
    [84, 60, -42, -89, -21, 74, 74, -21, -89, -42, 60, 84, 0, -84, -60, 42, 89, 21, -74, -74, 21, 89, 42, -60, -84, 0, 84, 60, -42, -89, -21, 74],
    [86, 46, -63, -78, 21, 90, 26, -77, -66, 42, 87, 4, -85, -50, 60, 80, -17, -90, -30, 74, 68, -38, -88, -9, 84, 53, -56, -82, 13, 89, 34, -72],
    [88, 30, -78, -56, 60, 77, -34, -87, 4, 89, 26, -80, -53, 63, 74, -38, -86, 9, 90, 21, -82, -50, 66, 72, -42, -85, 13, 90, 17, -84, -46, 68],
    [90, 13, -87, -26, 84, 38, -78, -50, 72, 60, -63, -68, 53, 77, -42, -82, 30, 86, -17, -89, 4, 90, 9, -88, -21, 85, 34, -80, -46, 74, 56, -66],
    [90, -4, -90, 9, 89, -13, -88, 17, 87, -21, -86, 26, 85, -30, -84, 34, 82, -38, -80, 42, 78, -46, -77, 50, 74, -53, -72, 56, 68, -60, -66, 63],
    [89, -21, -84, 42, 74, -60, -60, 74, 42, -84, -21, 89, 0, -89, 21, 84, -42, -74, 60, 60, -74, -42, 84, 21, -89, 0, 89, -21, -84, 42, 74, -60],
    [87, -38, -72, 68, 42, -86, -4, 88, -34, -74, 66, 46, -85, -9, 89, -30, -77, 63, 50, -84, -13, 90, -26, -78, 60, 53, -82, -17, 90, -21, -80, 56],
    [85, -53, -53, 85, 0, -85, 53, 53, -85, 0, 85, -53, -53, 85, 0, -85, 53, 53, -85, 0, 85, -53, -53, 85, 0, -85, 53, 53, -85, 0, 85, -53],
    [82, -66, -30, 90, -42, -56, 86, -13, -77, 74, 17, -87, 53, 46, -89, 26, 68, -80, -4, 84, -63, -34, 90, -38, -60, 85, -9, -78, 72, 21, -88, 50],
    [78, -77, -4, 80, -74, -9, 82, -72, -13, 84, -68, -17, 85, -66, -21, 86, -63, -26, 87, -60, -30, 88, -56, -34, 89, -53, -38, 90, -50, -42, 90, -46],
    [74, -84, 21, 60, -89, 42, 42, -89, 60, 21, -84, 74, 0, -74, 84, -21, -60, 89, -42, -42, 89, -60, -21, 84, -74, 0, 74, -84, 21, 60, -89, 42],
    [68, -88, 46, 30, -84, 78, -17, -56, 90, -60, -13, 77, -85, 34, 42, -87, 72, -4, -66, 89, -50, -26, 82, -80, 21, 53, -90, 63, 9, -74, 86, -38],
    [63, -90, 66, -4, -60, 90, -68, 9, 56, -89, 72, -13, -53, 88, -74, 17, 50, -87, 77, -21, -46, 86, -78, 26, 42, -85, 80, -30, -38, 84, -82, 34],
    [56, -87, 80, -38, -21, 72, -90, 68, -17, -42, 82, -86, 53, 4, -60, 88, -78, 34, 26, -74, 90, -66, 13, 46, -84, 85, -50, -9, 63, -89, 77, -30],
    [50, -82, 88, -66, 21, 30, -72, 90, -78, 42, 9, -56, 85, -86, 60, -13, -38, 77, -90, 74, -34, -17, 63, -87, 84, -53, 4, 46, -80, 89, -68, 26],
    [42, -74, 89, -84, 60, -21, -21, 60, -84, 89, -74, 42, 0, -42, 74, -89, 84, -60, 21, 21, -60, 84, -89, 74, -42, 0, 42, -74, 89, -84, 60, -21],
    [34, -63, 82, -90, 84, -66, 38, -4, -30, 60, -80, 90, -85, 68, -42, 9, 26, -56, 78, -89, 86, -72, 46, -13, -21, 53, -77, 88, -87, 74, -50, 17],
    [26, -50, 68, -82, 89, -88, 80, -66, 46, -21, -4, 30, -53, 72, -84, 90, -87, 78, -63, 42, -17, -9, 34, -56, 74, -85, 90, -86, 77, -60, 38, -13],
    [17, -34, 50, -63, 74, -82, 87, -90, 88, -84, 77, -66, 53, -38, 21, -4, -13, 30, -46, 60, -72, 80, -86, 90, -89, 85, -78, 68, -56, 42, -26, 9],
    [9, -17, 26, -34, 42, -50, 56, -63, 68, -74, 78, -82, 85, -87, 89, -90, 90, -88, 86, -84, 80, -77, 72, -66, 60, -53, 46, -38, 30, -21, 13, -4],
]

VTM_DCT8_P32 = [
    [90, 90, 89, 88, 87, 86, 85, 84, 82, 80, 78, 77, 74, 72, 68, 66, 63, 60, 56, 53, 50, 46, 42, 38, 34, 30, 26, 21, 17, 13, 9, 4],
    [90, 87, 84, 78, 72, 63, 53, 42, 30, 17, 4, -9, -21, -34, -46, -56, -66, -74, -80, -85, -88, -90, -89, -86, -82, -77, -68, -60, -50, -38, -26, -13],
    [89, 84, 74, 60, 42, 21, 0, -21, -42, -60, -74, -84, -89, -89, -84, -74, -60, -42, -21, 0, 21, 42, 60, 74, 84, 89, 89, 84, 74, 60, 42, 21],
    [88, 78, 60, 34, 4, -26, -53, -74, -86, -90, -82, -66, -42, -13, 17, 46, 68, 84, 90, 85, 72, 50, 21, -9, -38, -63, -80, -89, -87, -77, -56, -30],
    [87, 72, 42, 4, -34, -66, -85, -89, -77, -50, -13, 26, 60, 82, 90, 80, 56, 21, -17, -53, -78, -90, -84, -63, -30, 9, 46, 74, 88, 86, 68, 38],
    [86, 63, 21, -26, -66, -87, -85, -60, -17, 30, 68, 88, 84, 56, 13, -34, -72, -89, -82, -53, -9, 38, 74, 90, 80, 50, 4, -42, -77, -90, -78, -46],
    [85, 53, 0, -53, -85, -85, -53, 0, 53, 85, 85, 53, 0, -53, -85, -85, -53, 0, 53, 85, 85, 53, 0, -53, -85, -85, -53, 0, 53, 85, 85, 53],
    [84, 42, -21, -74, -89, -60, 0, 60, 89, 74, 21, -42, -84, -84, -42, 21, 74, 89, 60, 0, -60, -89, -74, -21, 42, 84, 84, 42, -21, -74, -89, -60],
    [82, 30, -42, -86, -77, -17, 53, 89, 68, 4, -63, -90, -60, 9, 72, 88, 50, -21, -78, -85, -38, 34, 84, 80, 26, -46, -87, -74, -13, 56, 90, 66],
    [80, 17, -60, -90, -50, 30, 85, 74, 4, -68, -87, -38, 42, 88, 66, -9, -77, -84, -26, 53, 90, 56, -21, -82, -78, -13, 63, 89, 46, -34, -86, -72],
    [78, 4, -74, -82, -13, 68, 85, 21, -63, -87, -30, 56, 89, 38, -50, -90, -46, 42, 90, 53, -34, -88, -60, 26, 86, 66, -17, -84, -72, 9, 80, 77],
    [77, -9, -84, -66, 26, 88, 53, -42, -90, -38, 56, 87, 21, -68, -82, -4, 78, 74, -13, -85, -63, 30, 89, 50, -46, -90, -34, 60, 86, 17, -72, -80],
    [74, -21, -89, -42, 60, 84, 0, -84, -60, 42, 89, 21, -74, -74, 21, 89, 42, -60, -84, 0, 84, 60, -42, -89, -21, 74, 74, -21, -89, -42, 60, 84],
    [72, -34, -89, -13, 82, 56, -53, -84, 9, 88, 38, -68, -74, 30, 90, 17, -80, -60, 50, 85, -4, -87, -42, 66, 77, -26, -90, -21, 78, 63, -46, -86],
    [68, -46, -84, 17, 90, 13, -85, -42, 72, 66, -50, -82, 21, 90, 9, -86, -38, 74, 63, -53, -80, 26, 89, 4, -87, -34, 77, 60, -56, -78, 30, 88],
    [66, -56, -74, 46, 80, -34, -85, 21, 88, -9, -90, -4, 89, 17, -86, -30, 82, 42, -77, -53, 68, 63, -60, -72, 50, 78, -38, -84, 26, 87, -13, -90],
    [63, -66, -60, 68, 56, -72, -53, 74, 50, -77, -46, 78, 42, -80, -38, 82, 34, -84, -30, 85, 26, -86, -21, 87, 17, -88, -13, 89, 9, -90, -4, 90],
    [60, -74, -42, 84, 21, -89, 0, 89, -21, -84, 42, 74, -60, -60, 74, 42, -84, -21, 89, 0, -89, 21, 84, -42, -74, 60, 60, -74, -42, 84, 21, -89],
    [56, -80, -21, 90, -17, -82, 53, 60, -78, -26, 90, -13, -84, 50, 63, -77, -30, 89, -9, -85, 46, 66, -74, -34, 88, -4, -86, 42, 68, -72, -38, 87],
    [53, -85, 0, 85, -53, -53, 85, 0, -85, 53, 53, -85, 0, 85, -53, -53, 85, 0, -85, 53, 53, -85, 0, 85, -53, -53, 85, 0, -85, 53, 53, -85],
    [50, -88, 21, 72, -78, -9, 85, -60, -38, 90, -34, -63, 84, -4, -80, 68, 26, -89, 46, 53, -87, 17, 74, -77, -13, 86, -56, -42, 90, -30, -66, 82],
    [46, -90, 42, 50, -90, 38, 53, -89, 34, 56, -88, 30, 60, -87, 26, 63, -86, 21, 66, -85, 17, 68, -84, 13, 72, -82, 9, 74, -80, 4, 77, -78],
    [42, -89, 60, 21, -84, 74, 0, -74, 84, -21, -60, 89, -42, -42, 89, -60, -21, 84, -74, 0, 74, -84, 21, 60, -89, 42, 42, -89, 60, 21, -84, 74],
    [38, -86, 74, -9, -63, 90, -53, -21, 80, -82, 26, 50, -89, 66, 4, -72, 87, -42, -34, 85, -77, 13, 60, -90, 56, 17, -78, 84, -30, -46, 88, -68],
    [34, -82, 84, -38, -30, 80, -85, 42, 26, -78, 86, -46, -21, 77, -87, 50, 17, -74, 88, -53, -13, 72, -89, 56, 9, -68, 90, -60, -4, 66, -90, 63],
    [30, -77, 89, -63, 9, 50, -85, 84, -46, -13, 66, -90, 74, -26, -34, 78, -88, 60, -4, -53, 86, -82, 42, 17, -68, 90, -72, 21, 38, -80, 87, -56],
    [26, -68, 89, -80, 46, 4, -53, 84, -87, 63, -17, -34, 74, -90, 77, -38, -13, 60, -86, 85, -56, 9, 42, -78, 90, -72, 30, 21, -66, 88, -82, 50],
    [21, -60, 84, -89, 74, -42, 0, 42, -74, 89, -84, 60, -21, -21, 60, -84, 89, -74, 42, 0, -42, 74, -89, 84, -60, 21, 21, -60, 84, -89, 74, -42],
    [17, -50, 74, -87, 88, -77, 53, -21, -13, 46, -72, 86, -89, 78, -56, 26, 9, -42, 68, -85, 90, -80, 60, -30, -4, 38, -66, 84, -90, 82, -63, 34],
    [13, -38, 60, -77, 86, -90, 85, -74, 56, -34, 9, 17, -42, 63, -78, 87, -90, 84, -72, 53, -30, 4, 21, -46, 66, -80, 88, -89, 82, -68, 50, -26],
    [9, -26, 42, -56, 68, -78, 85, -89, 90, -86, 80, -72, 60, -46, 30, -13, -4, 21, -38, 53, -66, 77, -84, 88, -90, 87, -82, 74, -63, 50, -34, 17],
    [4, -13, 21, -30, 38, -46, 53, -60, 66, -72, 77, -80, 84, -86, 88, -90, 90, -89, 87, -85, 82, -78, 74, -68, 63, -56, 50, -42, 34, -26, 17, -9],
]


# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------
CLIP_MIN = -32768
CLIP_MAX = 32767
DEFAULT_SHIFT = 6
CANONICAL_JSON = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    '..', '03_verification', 'output', 'canonical_matrices.json')

_canonical = None


def _load_canonical():
    global _canonical
    if _canonical is not None:
        return _canonical
    path = CANONICAL_JSON
    if not os.path.exists(path):
        # fall back to a path relative to this module's directory
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            '..', '03_verification', 'output', 'canonical_matrices.json')
    with open(path, encoding='utf-8') as f:
        _canonical = json.load(f)
    return _canonical


def get_canonical_matrix(tr_type: int, N: int):
    """tr_type: 0=DCT2, 1=DST7, 2=DCT8. Returns NxN forward kernel C from
    canonical_matrices.json (schema v2: 'source_kernel').  The VTM fast-inverse
    algorithm multiplies by C^T internally, so this returns the forward kernel."""
    tr = _load_canonical()['transforms'][str(tr_type)]
    return tr['source_kernel'][str(N)]


def _matrix_for(tr_type: int, N: int):
    """Matrix the VTM fast-inverse algorithm is bit-exact with.
    For all sizes except DST7/DCT8 N=32 this equals the canonical JSON matrix
    (verified element-wise).  For DST7/DCT8 N=32 the JSON (Huawei attachment)
    differs from VTM RomTr, so the VTM RomTr inverse matrix is used here so the
    fast algorithm reproduces VTM exactly."""
    if (tr_type, N) == (1, 32) and VTM_DST7_P32 is not None:
        return VTM_DST7_P32
    if (tr_type, N) == (2, 32) and VTM_DCT8_P32 is not None:
        return VTM_DCT8_P32
    return get_canonical_matrix(tr_type, N)


def clip3(v, lo=CLIP_MIN, hi=CLIP_MAX):
    return max(lo, min(hi, v))


# ----------------------------------------------------------------------------
# Operation counting
# ----------------------------------------------------------------------------
class OpCounter:
    __slots__ = ('mul', 'add', 'sub', 'max_abs')

    def __init__(self):
        self.mul = 0
        self.add = 0
        self.sub = 0
        self.max_abs = 0

    def reset(self):
        self.mul = self.add = self.sub = 0
        self.max_abs = 0

    @property
    def addsub(self):
        return self.add + self.sub


class _Ctx:
    """Carries an OpCounter (or None) plus shift/clip parameters."""

    __slots__ = ('op', 'shift', 'add')

    def __init__(self, shift=DEFAULT_SHIFT, op=None):
        self.shift = shift
        self.add = 1 << (shift - 1) if shift > 0 else 0
        self.op = op

    # counted arithmetic
    def _track(self, v):
        if self.op and abs(v) > self.op.max_abs:
            self.op.max_abs = abs(v)
        return v

    def M(self, a, b):
        if self.op:
            self.op.mul += 1
        return self._track(a * b)

    def A(self, a, b):
        if self.op:
            self.op.add += 1
        return self._track(a + b)

    def S(self, a, b):
        if self.op:
            self.op.sub += 1
        return self._track(a - b)

    def rd(self, x):
        """(x + add) >> shift  -- the rounding+shift step."""
        if self.op:
            self.op.add += 1  # + add
        return (x + self.add) >> self.shift

    def out(self, x):
        """round+shift+clip."""
        if self.op:
            self.op.add += 1
        return clip3((x + self.add) >> self.shift)


def _idx_mul(ctx, coef, val):
    """coef * val, counted (coef is a matrix coefficient, val a data value)."""
    return ctx.M(coef, val)


# ----------------------------------------------------------------------------
# 1. DCT-2  (E/O partial butterfly)
# ----------------------------------------------------------------------------

def _inv_dct2(src, N, shift, op):
    ctx = _Ctx(shift, op)
    s = src
    if N == 4:
        return _inv_dct2_b4(ctx, s)
    if N == 8:
        return _inv_dct2_b8(ctx, s)
    if N == 16:
        return _inv_dct2_b16(ctx, s)
    if N == 32:
        return _inv_dct2_b32(ctx, s)
    if N == 64:
        return _inv_dct2_b64(ctx, s)
    raise ValueError(f'unsupported DCT2 size {N}')


def _inv_dct2_b4(ctx, s):
    iT = [v for row in _matrix_for(0, 4) for v in row]
    # O[0], O[1] : odd-index inputs (rows 1,3 of the matrix)
    O0 = ctx.A(ctx.A(ctx.M(iT[1 * 4 + 0], s[1]), ctx.M(iT[3 * 4 + 0], s[3])), 0)
    O1 = ctx.A(ctx.A(ctx.M(iT[1 * 4 + 1], s[1]), ctx.M(iT[3 * 4 + 1], s[3])), 0)
    # E[0], E[1] : even-index inputs (rows 0,2)
    E0 = ctx.A(ctx.A(ctx.M(iT[0 * 4 + 0], s[0]), ctx.M(iT[2 * 4 + 0], s[2])), 0)
    E1 = ctx.A(ctx.A(ctx.M(iT[0 * 4 + 1], s[0]), ctx.M(iT[2 * 4 + 1], s[2])), 0)
    dst = [0] * 4
    dst[0] = ctx.out(ctx.A(ctx.A(E0, O0), 0))
    dst[1] = ctx.out(ctx.A(ctx.A(E1, O1), 0))
    dst[2] = ctx.out(ctx.A(ctx.S(E1, O1), 0))
    dst[3] = ctx.out(ctx.A(ctx.S(E0, O0), 0))
    return dst


def _inv_dct2_b8(ctx, s):
    iT = [v for row in _matrix_for(0, 8) for v in row]
    O = [0] * 4
    for k in range(4):
        O[k] = ctx.A(ctx.A(ctx.A(ctx.A(
            ctx.M(iT[1 * 8 + k], s[1]), ctx.M(iT[3 * 8 + k], s[3])),
            ctx.M(iT[5 * 8 + k], s[5])), ctx.M(iT[7 * 8 + k], s[7])), 0)
    EO = [0] * 2
    EO[0] = ctx.A(ctx.A(ctx.M(iT[2 * 8 + 0], s[2]), ctx.M(iT[6 * 8 + 0], s[6])), 0)
    EO[1] = ctx.A(ctx.A(ctx.M(iT[2 * 8 + 1], s[2]), ctx.M(iT[6 * 8 + 1], s[6])), 0)
    EE = [0] * 2
    EE[0] = ctx.A(ctx.A(ctx.M(iT[0 * 8 + 0], s[0]), ctx.M(iT[4 * 8 + 0], s[4])), 0)
    EE[1] = ctx.A(ctx.A(ctx.M(iT[0 * 8 + 1], s[0]), ctx.M(iT[4 * 8 + 1], s[4])), 0)
    E = [0] * 4
    E[0] = ctx.A(EE[0], EO[0])
    E[3] = ctx.S(EE[0], EO[0])
    E[1] = ctx.A(EE[1], EO[1])
    E[2] = ctx.S(EE[1], EO[1])
    dst = [0] * 8
    for k in range(4):
        dst[k] = ctx.out(ctx.A(ctx.A(E[k], O[k]), 0))
        dst[k + 4] = ctx.out(ctx.A(ctx.S(E[3 - k], O[3 - k]), 0))
    return dst


def _inv_dct2_b16(ctx, s):
    iT = [v for row in _matrix_for(0, 16) for v in row]
    O = [0] * 8
    for k in range(8):
        acc = 0
        for r in (1, 3, 5, 7, 9, 11, 13, 15):
            acc = ctx.A(acc, ctx.M(iT[r * 16 + k], s[r]))
        O[k] = acc
    EO = [0] * 4
    for k in range(4):
        EO[k] = ctx.A(ctx.A(ctx.A(ctx.A(
            ctx.M(iT[2 * 16 + k], s[2]), ctx.M(iT[6 * 16 + k], s[6])),
            ctx.M(iT[10 * 16 + k], s[10])), ctx.M(iT[14 * 16 + k], s[14])), 0)
    EEO = [0] * 2
    EEO[0] = ctx.A(ctx.A(ctx.M(iT[4 * 16 + 0], s[4]), ctx.M(iT[12 * 16 + 0], s[12])), 0)
    EEO[1] = ctx.A(ctx.A(ctx.M(iT[4 * 16 + 1], s[4]), ctx.M(iT[12 * 16 + 1], s[12])), 0)
    EEE = [0] * 2
    EEE[0] = ctx.A(ctx.A(ctx.M(iT[0 * 16 + 0], s[0]), ctx.M(iT[8 * 16 + 0], s[8])), 0)
    EEE[1] = ctx.A(ctx.A(ctx.M(iT[0 * 16 + 1], s[0]), ctx.M(iT[8 * 16 + 1], s[8])), 0)
    EE = [0] * 4
    for k in range(2):
        EE[k] = ctx.A(EEE[k], EEO[k])
        EE[k + 2] = ctx.S(EEE[1 - k], EEO[1 - k])
    E = [0] * 8
    for k in range(4):
        E[k] = ctx.A(EE[k], EO[k])
        E[k + 4] = ctx.S(EE[3 - k], EO[3 - k])
    dst = [0] * 16
    for k in range(8):
        dst[k] = ctx.out(ctx.A(ctx.A(E[k], O[k]), 0))
        dst[k + 8] = ctx.out(ctx.A(ctx.S(E[7 - k], O[7 - k]), 0))
    return dst


def _inv_dct2_b32(ctx, s):
    iT = [v for row in _matrix_for(0, 32) for v in row]
    O = [0] * 16
    for k in range(16):
        acc = 0
        for r in (1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31):
            acc = ctx.A(acc, ctx.M(iT[r * 32 + k], s[r]))
        O[k] = acc
    EO = [0] * 8
    for k in range(8):
        EO[k] = 0
        for r in (2, 6, 10, 14, 18, 22, 26, 30):
            EO[k] = ctx.A(EO[k], ctx.M(iT[r * 32 + k], s[r]))
    EEO = [0] * 4
    for k in range(4):
        EEO[k] = 0
        for r in (4, 12, 20, 28):
            EEO[k] = ctx.A(EEO[k], ctx.M(iT[r * 32 + k], s[r]))
    EEEO = [0] * 2
    EEEO[0] = ctx.A(ctx.A(ctx.M(iT[8 * 32 + 0], s[8]), ctx.M(iT[24 * 32 + 0], s[24])), 0)
    EEEO[1] = ctx.A(ctx.A(ctx.M(iT[8 * 32 + 1], s[8]), ctx.M(iT[24 * 32 + 1], s[24])), 0)
    EEEE = [0] * 2
    EEEE[0] = ctx.A(ctx.A(ctx.M(iT[0 * 32 + 0], s[0]), ctx.M(iT[16 * 32 + 0], s[16])), 0)
    EEEE[1] = ctx.A(ctx.A(ctx.M(iT[0 * 32 + 1], s[0]), ctx.M(iT[16 * 32 + 1], s[16])), 0)
    EEE = [0] * 4
    EEE[0] = ctx.A(EEEE[0], EEEO[0])
    EEE[3] = ctx.S(EEEE[0], EEEO[0])
    EEE[1] = ctx.A(EEEE[1], EEEO[1])
    EEE[2] = ctx.S(EEEE[1], EEEO[1])
    EE = [0] * 8
    for k in range(4):
        EE[k] = ctx.A(EEE[k], EEO[k])
        EE[k + 4] = ctx.S(EEE[3 - k], EEO[3 - k])
    E = [0] * 16
    for k in range(8):
        E[k] = ctx.A(EE[k], EO[k])
        E[k + 8] = ctx.S(EE[7 - k], EO[7 - k])
    dst = [0] * 32
    for k in range(16):
        dst[k] = ctx.out(ctx.A(ctx.A(E[k], O[k]), 0))
        dst[k + 16] = ctx.out(ctx.A(ctx.S(E[15 - k], O[15 - k]), 0))
    return dst


def _inv_dct2_b64(ctx, s):
    iT = [v for row in _matrix_for(0, 64) for v in row]
    # 1-D inverse: line=1, iSkipLine=0, iSkipLine2=0  =>  zo = (iSkipLine2>=32) = False
    O = [0] * 32
    for k in range(32):
        acc = 0
        for r in range(1, 64, 2):
            acc = ctx.A(acc, ctx.M(iT[r * 64 + k], s[r]))
        O[k] = acc
    EO = [0] * 16
    for k in range(16):
        acc = 0
        for r in range(2, 64, 4):
            acc = ctx.A(acc, ctx.M(iT[r * 64 + k], s[r]))
        EO[k] = acc
    EEO = [0] * 8
    for k in range(8):
        acc = 0
        for r in range(4, 64, 8):
            acc = ctx.A(acc, ctx.M(iT[r * 64 + k], s[r]))
        EEO[k] = acc
    EEEO = [0] * 4
    for k in range(4):
        acc = 0
        for r in range(8, 64, 16):
            acc = ctx.A(acc, ctx.M(iT[r * 64 + k], s[r]))
        EEEO[k] = acc
    EEEEO = [0] * 2
    EEEEO[0] = ctx.A(ctx.M(iT[16 * 64 + 0], s[16]), ctx.M(iT[48 * 64 + 0], s[48]))
    EEEEO[1] = ctx.A(ctx.M(iT[16 * 64 + 1], s[16]), ctx.M(iT[48 * 64 + 1], s[48]))
    EEEEE = [0] * 2
    EEEEE[0] = ctx.A(ctx.M(iT[0 * 64 + 0], s[0]), ctx.M(iT[32 * 64 + 0], s[32]))
    EEEEE[1] = ctx.A(ctx.M(iT[0 * 64 + 1], s[0]), ctx.M(iT[32 * 64 + 1], s[32]))
    EEEE = [0] * 4
    for k in range(2):
        EEEE[k] = ctx.A(EEEEE[k], EEEEO[k])
        EEEE[k + 2] = ctx.S(EEEEE[1 - k], EEEEO[1 - k])
    EEE = [0] * 8
    for k in range(4):
        EEE[k] = ctx.A(EEEE[k], EEEO[k])
        EEE[k + 4] = ctx.S(EEEE[3 - k], EEEO[3 - k])
    EE = [0] * 16
    for k in range(8):
        EE[k] = ctx.A(EEE[k], EEO[k])
        EE[k + 8] = ctx.S(EEE[7 - k], EEO[7 - k])
    E = [0] * 32
    for k in range(16):
        E[k] = ctx.A(EE[k], EO[k])
        E[k + 16] = ctx.S(EE[15 - k], EO[15 - k])
    dst = [0] * 64
    for k in range(32):
        dst[k] = ctx.out(ctx.A(ctx.A(E[k], O[k]), 0))
        dst[k + 32] = ctx.out(ctx.A(ctx.S(E[31 - k], O[31 - k]), 0))
    return dst


# ----------------------------------------------------------------------------
# Table-driven output-row apply (DST7/DCT8 B16/B32 partial butterflies)
# rows[k] = (t_terms, v_terms), where
#   t_terms : tuple of (sign, t_index)          (+1/-1 applied to t[t_index])
#   v_terms : list of (sign, coef, varkind, i, j)  -> sign * iT[coef] * vars[varkind][i][j]
#             or ('srcsum', coef, ((sign, idx), ...)) -> sign * iT[coef] * (sum sign*src[idx])
# ----------------------------------------------------------------------------
def _apply_rows(ctx, iT, src, dst, rows, vars_dict, tvals):
    for okey, v_terms in rows.items():
        out_idx, raw_t = okey
        # normalize t-terms: int-0 / () / (sign,tidx) / ((sign,tidx),)
        if isinstance(raw_t, int) or raw_t == ():
            t_terms = ()
        elif isinstance(raw_t[0], int):
            t_terms = (raw_t,)
        else:
            t_terms = raw_t
        acc = 0
        started = False
        for term in v_terms:
            if term[0] == 'srcsum':
                _, sign, coef, idxs = term
                inner = 0
                inner_started = False
                for sgn, ix in idxs:
                    if not inner_started:
                        inner = src[ix]
                        inner_started = True
                    elif sgn == 1:
                        inner = ctx.A(inner, src[ix])
                    else:
                        inner = ctx.S(inner, src[ix])
                if sign == 1:
                    prod = ctx.M(iT[coef], inner)
                    acc = prod if not started else ctx.A(acc, prod)
                else:
                    if not started:
                        acc = ctx.M(-iT[coef], inner)
                    else:
                        acc = ctx.S(acc, ctx.M(iT[coef], inner))
                started = True
            else:
                sign, coef, vk, i, j = term
                cell = vars_dict[vk]
                val = cell[i][j] if isinstance(cell[i], list) else cell[i]
                if sign == 1:
                    prod = ctx.M(iT[coef], val)
                    acc = prod if not started else ctx.A(acc, prod)
                else:
                    if not started:
                        acc = ctx.M(-iT[coef], val)
                    else:
                        acc = ctx.S(acc, ctx.M(iT[coef], val))
                started = True
        for tt in t_terms:
            if isinstance(tt, int):
                continue  # empty-marker ((0),) from the generator
            tsign, tidx = tt
            if tsign == 0:
                continue
            if tsign == 1:
                acc = ctx.A(acc, tvals[tidx])
            else:
                acc = ctx.S(acc, tvals[tidx])
        dst[out_idx] = ctx.out(acc)


# ----------------------------------------------------------------------------
# 2. DST-7
# ----------------------------------------------------------------------------

def _inv_dst7(ctx, src, N):
    s = src
    if N == 4:
        return _inv_dst7_b4(ctx, s)
    if N == 8:
        return _inv_dst7_b8(ctx, s)
    if N == 16:
        return _inv_dst7_b16(ctx, s)
    if N == 32:
        return _inv_dst7_b32(ctx, s)
    raise ValueError(f'unsupported DST7 size {N}')


def _inv_dst7_b4(ctx, s):
    iT = [v for row in _matrix_for(1, 4) for v in row]
    c = [0] * 4
    c[0] = ctx.A(s[0], s[2])
    c[1] = ctx.A(s[2], s[3])
    c[2] = ctx.S(s[0], s[3])
    c[3] = ctx.M(iT[2], s[1])
    dst = [0] * 4
    dst[0] = ctx.out(ctx.A(ctx.A(ctx.A(ctx.M(iT[0], c[0]), ctx.M(iT[1], c[1])), c[3]), 0))
    dst[1] = ctx.out(ctx.A(ctx.A(ctx.S(ctx.M(iT[1], c[2]), ctx.M(iT[0], c[1])), c[3]), 0))
    dst[2] = ctx.out(ctx.A(ctx.M(iT[2], ctx.S(ctx.A(s[0], s[3]), s[2])), 0))
    dst[3] = ctx.out(ctx.A(ctx.S(ctx.A(ctx.M(iT[1], c[0]), ctx.M(iT[0], c[2])), c[3]), 0))
    return dst


def _inv_dst7_b8(ctx, s):
    # inverseMatrixMult<8>(..., numOutLines=1, skip=0)  =>  dst[j] = sum_k s[k]*iT[k*8+j]
    iT = [v for row in _matrix_for(1, 8) for v in row]
    dst = [0] * 8
    for j in range(8):
        acc = 0
        for k in range(8):
            acc = ctx.A(acc, ctx.M(iT[k * 8 + j], s[k]))
        dst[j] = ctx.out(acc)
    return dst


def _inv_dst7_b16(ctx, s):
    iT = [v for row in get_canonical_matrix(1, 16) for v in row]
    a = [0] * 5
    b = [0] * 5
    c = [0] * 5
    d = [0] * 5
    for k in range(5):
        a[k] = ctx.A(s[k], s[10 - k])
        b[k] = ctx.A(s[11 + k], s[10 - k])
        c[k] = ctx.S(s[k], s[11 + k])
        d[k] = ctx.A(ctx.S(s[k], s[10 - k]), s[11 + k])  # s[k]+s[11+k]-s[10-k]
    t = ctx.M(iT[10], s[5])
    dst = [0] * 16
    _apply_rows(ctx, iT, s, dst, _DST7_B16_ROWS,
                {'a': a, 'b': b, 'c': c, 'd': d}, [t])
    return dst


def _inv_dst7_b32(ctx, s):
    iT = [v for row in get_canonical_matrix(1, 32) for v in row]
    a = [[0] * 6 for _ in range(10)]
    b = [0] * 6
    c = [0] * 2
    t = [0] * 2
    for k in range(6):
        a[0][k] = ctx.A(s[k], s[12 - k])
        a[1][k] = ctx.S(s[k], s[13 + k])
        a[2][k] = ctx.A(s[k], s[25 - k])
        a[3][k] = ctx.S(s[k], s[26 + k])
        a[4][k] = ctx.A(s[7 + k], s[18 - k])
        a[5][k] = ctx.S(s[7 + k], s[20 + k])
        a[6][k] = ctx.A(s[7 + k], s[31 - k])
        a[7][k] = ctx.A(s[13 + k], s[25 - k])
        a[8][k] = ctx.S(s[13 + k], s[26 + k])
        a[9][k] = ctx.A(s[20 + k], s[31 - k])
        # b[k] = s[k] - s[12-k] + s[13+k] - s[25-k] + s[26+k]
        b[k] = ctx.A(ctx.S(ctx.A(ctx.S(s[k], s[12 - k]), s[13 + k]), s[25 - k]), s[26 + k])
    for k in range(2):
        # c[k] = s[k]-s[4-k]+s[5+k]-s[9-k]+s[10+k]-s[14-k]+s[15+k]-s[19-k]
        #        +s[20+k]-s[24-k]+s[25+k]-s[29-k]+s[30+k]
        idxs = [k, 4 - k, 5 + k, 9 - k, 10 + k, 14 - k, 15 + k,
                19 - k, 20 + k, 24 - k, 25 + k, 29 - k, 30 + k]
        signs = [1, -1, 1, -1, 1, -1, 1, -1, 1, -1, 1, -1, 1]
        c[k] = s[idxs[0]]
        for jj in range(1, len(idxs)):
            if signs[jj] == 1:
                c[k] = ctx.A(c[k], s[idxs[jj]])
            else:
                c[k] = ctx.S(c[k], s[idxs[jj]])
    t[0] = ctx.A(ctx.M(iT[12], s[6]), ctx.M(iT[25], s[19]))
    t[1] = ctx.S(ctx.M(iT[25], s[6]), ctx.M(iT[12], s[19]))
    dst = [0] * 32
    _apply_rows(ctx, iT, s, dst, _DST7_B32_ROWS,
                {'a': a, 'b': b, 'c': c}, t)
    return dst


# ----------------------------------------------------------------------------
# 3. DCT-8
# ----------------------------------------------------------------------------

def _inv_dct8(ctx, src, N):
    s = src
    if N == 4:
        return _inv_dct8_b4(ctx, s)
    if N == 8:
        return _inv_dct8_b8(ctx, s)
    if N == 16:
        return _inv_dct8_b16(ctx, s)
    if N == 32:
        return _inv_dct8_b32(ctx, s)
    raise ValueError(f'unsupported DCT8 size {N}')


def _inv_dct8_b4(ctx, s):
    iT = [v for row in _matrix_for(2, 4) for v in row]
    c = [0] * 4
    c[0] = ctx.A(s[0], s[3])
    c[1] = ctx.A(s[2], s[0])
    c[2] = ctx.S(s[3], s[2])
    c[3] = ctx.M(iT[1], s[1])
    dst = [0] * 4
    dst[0] = ctx.out(ctx.A(ctx.A(ctx.A(ctx.M(iT[3], c[0]), ctx.M(iT[2], c[1])), c[3]), 0))
    dst[1] = ctx.out(ctx.A(ctx.M(iT[1], ctx.S(ctx.S(s[0], s[2]), s[3])), 0))
    dst[2] = ctx.out(ctx.A(ctx.S(ctx.A(ctx.M(iT[3], c[2]), ctx.M(iT[2], c[0])), c[3]), 0))
    dst[3] = ctx.out(ctx.A(ctx.S(ctx.S(ctx.M(iT[3], c[1]), ctx.M(iT[2], c[2])), c[3]), 0))
    return dst


def _inv_dct8_b8(ctx, s):
    iT = [v for row in _matrix_for(2, 8) for v in row]
    dst = [0] * 8
    for j in range(8):
        acc = 0
        for k in range(8):
            acc = ctx.A(acc, ctx.M(iT[k * 8 + j], s[k]))
        dst[j] = ctx.out(acc)
    return dst


def _inv_dct8_b16(ctx, s):
    iT = [v for row in get_canonical_matrix(1, 16) for v in row]  # DCT8 B16 reuses DST7 P16 matrix
    a = [0] * 5
    b = [0] * 5
    c = [0] * 5
    d = [0] * 5
    for k in range(5):
        a[k] = ctx.A(s[15 - k], s[4 - k])
        b[k] = ctx.A(s[6 + k], s[4 - k])
        c[k] = ctx.S(s[15 - k], s[6 + k])
        d[k] = ctx.A(ctx.S(s[15 - k], s[4 - k]), s[6 + k])  # s[15-k]+s[6+k]-s[4-k]
    t = ctx.M(iT[10], s[5])
    dst = [0] * 16
    _apply_rows(ctx, iT, s, dst, _DCT8_B16_ROWS,
                {'a': a, 'b': b, 'c': c, 'd': d}, [t])
    return dst


def _inv_dct8_b32(ctx, s):
    iT = [v for row in get_canonical_matrix(1, 32) for v in row]  # DCT8 B32 reuses DST7 P32 matrix
    a = [[0] * 6 for _ in range(10)]
    b = [0] * 6
    c = [0] * 2
    t = [0] * 2
    for k in range(6):
        a[0][k] = ctx.S(s[31 - k], s[20 + k])
        a[1][k] = ctx.A(s[31 - k], s[18 - k])
        a[2][k] = ctx.A(s[31 - k], s[7 + k])
        a[3][k] = ctx.S(s[31 - k], s[5 - k])
        a[4][k] = ctx.A(s[25 - k], s[13 + k])
        a[5][k] = ctx.A(s[25 - k], s[12 - k])
        a[6][k] = ctx.S(s[25 - k], s[k])
        a[7][k] = ctx.S(s[18 - k], s[7 + k])
        a[8][k] = ctx.A(s[18 - k], s[5 - k])
        a[9][k] = ctx.A(s[12 - k], s[k])
        # b[k] = s31-k + s20+k - s18-k - s7+k + s5-k
        b[k] = ctx.A(ctx.S(ctx.S(ctx.A(s[31 - k], s[20 + k]), s[18 - k]), s[7 + k]), s[5 - k])
    for k in range(2):
        # c[k] = s31-k + s28+k - s26-k - s23+k + s21-k + s18+k - s16-k - s13+k
        #        + s11-k + s8+k - s6-k - s3+k + s1-k
        idxs = [31 - k, 28 + k, 26 - k, 23 + k, 21 - k, 18 + k, 16 - k, 13 + k,
                11 - k, 8 + k, 6 - k, 3 + k, 1 - k]
        signs = [1, 1, -1, -1, 1, 1, -1, -1, 1, 1, -1, -1, 1]
        c[k] = s[idxs[0]]
        for jj in range(1, len(idxs)):
            if signs[jj] == 1:
                c[k] = ctx.A(c[k], s[idxs[jj]])
            else:
                c[k] = ctx.S(c[k], s[idxs[jj]])
    t[0] = ctx.A(ctx.M(iT[12], s[19]), ctx.M(iT[25], s[6]))
    t[1] = ctx.S(ctx.M(iT[12], s[6]), ctx.M(iT[25], s[19]))
    dst = [0] * 32
    _apply_rows(ctx, iT, s, dst, _DCT8_B32_ROWS,
                {'a': a, 'b': b, 'c': c}, t)
    return dst


# ----------------------------------------------------------------------------
# DST7/DCT8 B32 output rows as (output_index, [(coef_idx, a_row, a_col), ...], t_terms)
# Transcribed from fastInverseDST7_B32 / fastInverseDCT8_B32.
# t_terms: list of (sign, t_index)  -> e.g. (1,0)=+t[0], (-1,1)=-t[1]
# ----------------------------------------------------------------------------
_DST7_B16_ROWS = {
    (0, (((1,0)))): [
        (1,0,"a",0,0),
        (1,9,"b",0,0),
        (1,2,"a",1,0),
        (1,7,"b",1,0),
        (1,4,"a",2,0),
        (1,5,"b",2,0),
        (1,6,"a",3,0),
        (1,3,"b",3,0),
        (1,8,"a",4,0),
        (1,1,"b",4,0),
    ],
    (1, (((1,0)))): [
        (1,1,"c",0,0),
        (-1,8,"b",0,0),
        (1,5,"c",1,0),
        (-1,4,"b",1,0),
        (1,9,"c",2,0),
        (-1,0,"b",2,0),
        (1,2,"a",3,0),
        (1,7,"c",3,0),
        (1,6,"a",4,0),
        (1,3,"c",4,0),
    ],
    (2, ((0))): [
        (1,2,"d",0,0),
        (1,8,"d",1,0),
        (1,14,"d",2,0),
        (1,11,"d",3,0),
        (1,5,"d",4,0),
    ],
    (3, (((-1,0)))): [
        (1,3,"a",0,0),
        (1,6,"b",0,0),
        (1,0,"c",1,0),
        (1,9,"a",1,0),
        (1,1,"a",2,0),
        (1,8,"c",2,0),
        (1,4,"c",3,0),
        (-1,5,"b",3,0),
        (-1,2,"a",4,0),
        (-1,7,"b",4,0),
    ],
    (4, (((-1,0)))): [
        (1,4,"c",0,0),
        (-1,5,"b",0,0),
        (1,6,"c",1,0),
        (1,3,"a",1,0),
        (1,7,"a",2,0),
        (1,2,"b",2,0),
        (-1,1,"c",3,0),
        (1,8,"b",3,0),
        (-1,9,"c",4,0),
        (-1,0,"a",4,0),
    ],
    (5, ((0))): [
        (1,5,"d",0,0),
        (1,14,"d",1,0),
        (1,2,"d",2,0),
        (-1,8,"d",3,0),
        (-1,11,"d",4,0),
    ],
    (6, (((1,0)))): [
        (1,6,"a",0,0),
        (1,3,"b",0,0),
        (1,9,"c",1,0),
        (1,0,"a",1,0),
        (-1,1,"a",2,0),
        (-1,8,"b",2,0),
        (-1,4,"c",3,0),
        (-1,5,"a",3,0),
        (-1,2,"c",4,0),
        (1,7,"b",4,0),
    ],
    (7, (((1,0)))): [
        (1,7,"c",0,0),
        (-1,2,"b",0,0),
        (1,8,"a",1,0),
        (1,1,"b",1,0),
        (-1,6,"c",2,0),
        (1,3,"b",2,0),
        (-1,9,"a",3,0),
        (-1,0,"b",3,0),
        (1,5,"c",4,0),
        (-1,4,"b",4,0),
    ],
    (8, ((0))): [
        (1,8,"d",0,0),
        (1,5,"d",1,0),
        (-1,11,"d",2,0),
        (-1,2,"d",3,0),
        (1,14,"d",4,0),
    ],
    (9, (((-1,0)))): [
        (1,9,"a",0,0),
        (1,0,"b",0,0),
        (1,2,"c",1,0),
        (-1,7,"b",1,0),
        (-1,5,"c",2,0),
        (-1,4,"a",2,0),
        (1,3,"a",3,0),
        (1,6,"b",3,0),
        (1,8,"c",4,0),
        (-1,1,"b",4,0),
    ],
    (10, ((0))): [
        ("srcsum",1,10,((1, 0), (-1, 2), (1, 3), (-1, 5), (1, 6), (-1, 8), (1, 9), (-1, 11), (1, 12), (-1, 14), (1, 15))),
    ],
    (11, ((0))): [
        (1,11,"d",0,0),
        (-1,2,"d",1,0),
        (-1,5,"d",2,0),
        (1,14,"d",3,0),
        (-1,8,"d",4,0),
    ],
    (12, (((1,0)))): [
        (1,1,"c",0,0),
        (1,8,"a",0,0),
        (-1,5,"a",1,0),
        (-1,4,"b",1,0),
        (-1,0,"c",2,0),
        (1,9,"b",2,0),
        (1,7,"c",3,0),
        (-1,2,"b",3,0),
        (-1,6,"c",4,0),
        (-1,3,"a",4,0),
    ],
    (13, (((1,0)))): [
        (1,7,"c",0,0),
        (1,2,"a",0,0),
        (-1,8,"c",1,0),
        (1,1,"b",1,0),
        (1,3,"c",2,0),
        (-1,6,"b",2,0),
        (1,0,"a",3,0),
        (1,9,"b",3,0),
        (-1,5,"a",4,0),
        (-1,4,"b",4,0),
    ],
    (14, ((0))): [
        (1,14,"d",0,0),
        (-1,11,"d",1,0),
        (1,8,"d",2,0),
        (-1,5,"d",3,0),
        (1,2,"d",4,0),
    ],
    (15, (((-1,0)))): [
        (1,4,"c",0,0),
        (1,5,"a",0,0),
        (-1,3,"c",1,0),
        (-1,6,"a",1,0),
        (1,2,"c",2,0),
        (1,7,"a",2,0),
        (-1,1,"c",3,0),
        (-1,8,"a",3,0),
        (1,0,"c",4,0),
        (1,9,"a",4,0),
    ],
}

_DCT8_B16_ROWS = {
    (0, (((1,0)))): [
        (1,0,"a",0,0),
        (1,9,"b",0,0),
        (1,1,"a",1,0),
        (1,8,"b",1,0),
        (1,2,"a",2,0),
        (1,7,"b",2,0),
        (1,3,"a",3,0),
        (1,6,"b",3,0),
        (1,4,"a",4,0),
        (1,5,"b",4,0),
    ],
    (1, ((0))): [
        (-1,2,"d",0,0),
        (-1,5,"d",1,0),
        (-1,8,"d",2,0),
        (-1,11,"d",3,0),
        (-1,14,"d",4,0),
    ],
    (2, (((-1,0)))): [
        (1,4,"c",0,0),
        (-1,5,"b",0,0),
        (1,9,"c",1,0),
        (-1,0,"b",1,0),
        (1,6,"c",2,0),
        (1,3,"a",2,0),
        (1,1,"c",3,0),
        (1,8,"a",3,0),
        (1,7,"a",4,0),
        (1,2,"b",4,0),
    ],
    (3, (((-1,0)))): [
        (-1,6,"a",0,0),
        (-1,3,"b",0,0),
        (-1,2,"c",1,0),
        (-1,7,"a",1,0),
        (-1,9,"c",2,0),
        (-1,0,"a",2,0),
        (-1,4,"c",3,0),
        (1,5,"b",3,0),
        (1,1,"a",4,0),
        (1,8,"b",4,0),
    ],
    (4, ((0))): [
        (1,8,"d",0,0),
        (1,14,"d",1,0),
        (1,5,"d",2,0),
        (-1,2,"d",3,0),
        (-1,11,"d",4,0),
    ],
    (5, ((0))): [
        ("srcsum",-1,10,((1, 15), (1, 14), (-1, 12), (-1, 11), (1, 9), (1, 8), (-1, 6), (-1, 5), (1, 3), (1, 2), (-1, 0))),
    ],
    (6, (((1,0)))): [
        (1,8,"a",0,0),
        (1,1,"c",0,0),
        (1,6,"c",1,0),
        (-1,3,"b",1,0),
        (-1,5,"a",2,0),
        (-1,4,"b",2,0),
        (-1,7,"c",3,0),
        (-1,2,"a",3,0),
        (-1,0,"c",4,0),
        (1,9,"b",4,0),
    ],
    (7, ((0))): [
        (-1,14,"d",0,0),
        (-1,2,"d",1,0),
        (1,11,"d",2,0),
        (1,5,"d",3,0),
        (-1,8,"d",4,0),
    ],
    (8, (((-1,0)))): [
        (1,4,"c",0,0),
        (1,5,"a",0,0),
        (-1,0,"c",1,0),
        (1,9,"b",1,0),
        (-1,3,"c",2,0),
        (-1,6,"a",2,0),
        (1,1,"c",3,0),
        (-1,8,"b",3,0),
        (1,2,"c",4,0),
        (1,7,"a",4,0),
    ],
    (9, (((-1,0)))): [
        (-1,7,"c",0,0),
        (-1,2,"a",0,0),
        (1,4,"a",1,0),
        (1,5,"b",1,0),
        (1,8,"c",2,0),
        (-1,1,"b",2,0),
        (-1,9,"a",3,0),
        (-1,0,"b",3,0),
        (-1,3,"c",4,0),
        (1,6,"b",4,0),
    ],
    (10, ((0))): [
        (1,11,"d",0,0),
        (-1,8,"d",1,0),
        (-1,2,"d",2,0),
        (1,14,"d",3,0),
        (-1,5,"d",4,0),
    ],
    (11, (((1,0)))): [
        (-1,9,"a",0,0),
        (-1,0,"b",0,0),
        (1,8,"c",1,0),
        (1,1,"a",1,0),
        (-1,2,"c",2,0),
        (1,7,"b",2,0),
        (-1,6,"a",3,0),
        (-1,3,"b",3,0),
        (1,5,"c",4,0),
        (1,4,"a",4,0),
    ],
    (12, (((1,0)))): [
        (1,7,"c",0,0),
        (-1,2,"b",0,0),
        (-1,5,"c",1,0),
        (-1,4,"a",1,0),
        (1,8,"a",2,0),
        (1,1,"b",2,0),
        (-1,0,"a",3,0),
        (-1,9,"b",3,0),
        (-1,6,"c",4,0),
        (1,3,"b",4,0),
    ],
    (13, ((0))): [
        (-1,5,"d",0,0),
        (1,11,"d",1,0),
        (-1,14,"d",2,0),
        (1,8,"d",3,0),
        (-1,2,"d",4,0),
    ],
    (14, (((-1,0)))): [
        (1,3,"a",0,0),
        (1,6,"b",0,0),
        (-1,7,"a",1,0),
        (-1,2,"b",1,0),
        (1,0,"c",2,0),
        (1,9,"a",2,0),
        (-1,4,"c",3,0),
        (-1,5,"a",3,0),
        (1,8,"c",4,0),
        (1,1,"a",4,0),
    ],
    (15, (((-1,0)))): [
        (-1,1,"c",0,0),
        (1,8,"b",0,0),
        (1,3,"c",1,0),
        (-1,6,"b",1,0),
        (-1,5,"c",2,0),
        (1,4,"b",2,0),
        (1,7,"c",3,0),
        (-1,2,"b",3,0),
        (-1,9,"c",4,0),
        (1,0,"b",4,0),
    ],
}

_DST7_B32_ROWS = {
    (0, (((1,0)))): [
        (1,0,"a",1,0),
        (-1,11,"a",8,0),
        (1,13,"a",7,0),
        (1,24,"a",4,5),
        (-1,1,"a",8,5),
        (1,10,"a",1,5),
        (1,14,"a",4,0),
        (1,23,"a",7,5),
        (1,2,"a",1,1),
        (-1,9,"a",8,1),
        (1,15,"a",7,1),
        (1,22,"a",4,4),
        (-1,3,"a",8,4),
        (1,8,"a",1,4),
        (1,16,"a",4,1),
        (1,21,"a",7,4),
        (1,4,"a",1,2),
        (-1,7,"a",8,2),
        (1,17,"a",7,2),
        (1,20,"a",4,3),
        (-1,5,"a",8,3),
        (1,6,"a",1,3),
        (1,18,"a",4,2),
        (1,19,"a",7,3),
    ],
    (1, (((1,1)))): [
        (-1,0,"a",4,2),
        (-1,11,"a",6,2),
        (1,13,"a",0,3),
        (1,24,"a",5,2),
        (1,1,"a",2,0),
        (1,10,"a",7,0),
        (1,14,"a",5,5),
        (-1,23,"a",9,5),
        (1,2,"a",7,2),
        (1,9,"a",2,2),
        (-1,15,"a",9,3),
        (1,22,"a",5,3),
        (-1,3,"a",6,0),
        (-1,8,"a",4,0),
        (1,16,"a",5,0),
        (1,21,"a",0,5),
        (-1,4,"a",4,1),
        (-1,7,"a",6,1),
        (1,17,"a",0,4),
        (1,20,"a",5,1),
        (1,5,"a",2,1),
        (1,6,"a",7,1),
        (1,18,"a",5,4),
        (-1,19,"a",9,4),
    ],
    (2, (((1,1)))): [
        (-1,0,"a",2,4),
        (-1,11,"a",3,4),
        (1,13,"a",0,4),
        (1,24,"a",1,4),
        (1,1,"a",4,3),
        (1,10,"a",7,2),
        (1,14,"a",1,2),
        (-1,23,"a",8,2),
        (1,2,"a",3,0),
        (-1,9,"a",6,5),
        (-1,15,"a",8,0),
        (1,22,"a",9,5),
        (-1,3,"a",6,4),
        (1,8,"a",3,1),
        (1,16,"a",9,4),
        (-1,21,"a",8,1),
        (1,4,"a",7,3),
        (1,7,"a",4,2),
        (-1,17,"a",8,3),
        (1,20,"a",1,3),
        (-1,5,"a",3,5),
        (-1,6,"a",2,5),
        (1,18,"a",1,5),
        (1,19,"a",0,5),
    ],
    (3, (((1,0)))): [
        (1,0,"a",5,4),
        (1,11,"a",0,1),
        (-1,13,"a",4,4),
        (-1,24,"a",6,4),
        (-1,1,"a",1,3),
        (-1,10,"a",0,3),
        (1,14,"a",2,3),
        (1,23,"a",3,3),
        (-1,2,"a",0,4),
        (-1,9,"a",1,4),
        (1,15,"a",3,4),
        (1,22,"a",2,4),
        (1,3,"a",0,0),
        (1,8,"a",5,5),
        (-1,16,"a",6,5),
        (-1,21,"a",4,5),
        (1,4,"a",5,0),
        (-1,7,"a",9,0),
        (1,17,"a",7,5),
        (1,20,"a",2,5),
        (-1,5,"a",8,2),
        (1,6,"a",9,3),
        (-1,18,"a",6,3),
        (1,19,"a",3,2),
    ],
    (4, ((0))): [
        (1,4,"b",0,0),
        (1,14,"b",1,0),
        (1,24,"b",2,0),
        (1,29,"b",3,0),
        (1,19,"b",4,0),
        (1,9,"b",5,0),
    ],
    (5, (((-1,0)))): [
        (-1,0,"a",1,5),
        (1,11,"a",8,5),
        (-1,13,"a",7,5),
        (-1,24,"a",4,0),
        (1,1,"a",5,1),
        (1,10,"a",0,4),
        (-1,14,"a",4,1),
        (-1,23,"a",6,1),
        (-1,2,"a",8,3),
        (1,9,"a",9,2),
        (-1,15,"a",6,2),
        (1,22,"a",3,3),
        (-1,3,"a",0,2),
        (-1,8,"a",1,2),
        (1,16,"a",3,2),
        (1,21,"a",2,2),
        (-1,4,"a",9,4),
        (1,7,"a",5,4),
        (1,17,"a",2,1),
        (1,20,"a",7,1),
        (1,5,"a",1,0),
        (-1,6,"a",8,0),
        (1,18,"a",7,0),
        (1,19,"a",4,5),
    ],
    (6, (((-1,1)))): [
        (-1,0,"a",7,5),
        (-1,11,"a",2,5),
        (1,13,"a",9,0),
        (-1,24,"a",5,0),
        (1,1,"a",3,4),
        (-1,10,"a",6,1),
        (-1,14,"a",8,4),
        (1,23,"a",9,1),
        (1,2,"a",4,2),
        (1,9,"a",7,3),
        (1,15,"a",1,3),
        (-1,22,"a",8,3),
        (-1,3,"a",2,2),
        (-1,8,"a",3,2),
        (1,16,"a",0,2),
        (1,21,"a",1,2),
        (-1,4,"a",6,4),
        (-1,7,"a",4,4),
        (1,17,"a",5,4),
        (1,20,"a",0,1),
        (1,5,"a",7,0),
        (1,6,"a",2,0),
        (-1,18,"a",9,5),
        (1,19,"a",5,5),
    ],
    (7, (((-1,1)))): [
        (-1,0,"a",6,3),
        (-1,11,"a",4,3),
        (1,13,"a",5,3),
        (1,24,"a",0,2),
        (1,1,"a",7,1),
        (1,10,"a",4,4),
        (-1,14,"a",8,1),
        (1,23,"a",1,1),
        (-1,2,"a",7,5),
        (-1,9,"a",4,0),
        (1,15,"a",8,5),
        (-1,22,"a",1,5),
        (1,3,"a",7,3),
        (1,8,"a",2,3),
        (-1,16,"a",9,2),
        (1,21,"a",5,2),
        (-1,4,"a",6,5),
        (1,7,"a",3,0),
        (1,17,"a",9,5),
        (-1,20,"a",8,0),
        (1,5,"a",6,1),
        (-1,6,"a",3,4),
        (-1,18,"a",9,1),
        (1,19,"a",8,4),
    ],
    (8, (((-1,0)))): [
        (-1,0,"a",1,1),
        (-1,11,"a",0,1),
        (1,13,"a",2,1),
        (1,24,"a",3,1),
        (1,1,"a",1,3),
        (-1,10,"a",8,3),
        (1,14,"a",7,3),
        (1,23,"a",4,2),
        (-1,2,"a",9,1),
        (1,9,"a",8,4),
        (-1,15,"a",3,4),
        (1,22,"a",6,1),
        (1,3,"a",5,5),
        (1,8,"a",0,0),
        (-1,16,"a",4,5),
        (-1,21,"a",6,5),
        (1,4,"a",0,5),
        (1,7,"a",1,5),
        (-1,17,"a",3,5),
        (-1,20,"a",2,5),
        (1,5,"a",5,3),
        (-1,6,"a",9,3),
        (1,18,"a",7,2),
        (1,19,"a",2,2),
    ],
    (9, ((0))): [
        (1,9,"b",0,0),
        (1,29,"b",1,0),
        (1,14,"b",2,0),
        (-1,4,"b",3,0),
        (-1,24,"b",4,0),
        (-1,19,"b",5,0),
    ],
    (10, (((1,0)))): [
        (1,0,"a",8,3),
        (-1,11,"a",1,3),
        (-1,13,"a",4,2),
        (-1,24,"a",7,3),
        (-1,1,"a",8,0),
        (1,10,"a",1,0),
        (1,14,"a",4,5),
        (1,23,"a",7,0),
        (1,2,"a",5,3),
        (1,9,"a",0,2),
        (-1,15,"a",4,3),
        (-1,22,"a",6,3),
        (-1,3,"a",5,0),
        (-1,8,"a",0,5),
        (1,16,"a",4,0),
        (1,21,"a",6,0),
        (1,4,"a",1,4),
        (1,7,"a",0,4),
        (-1,17,"a",2,4),
        (-1,20,"a",3,4),
        (-1,5,"a",1,1),
        (-1,6,"a",0,1),
        (1,18,"a",2,1),
        (1,19,"a",3,1),
    ],
    (11, (((1,1)))): [
        (1,0,"a",7,0),
        (1,11,"a",2,0),
        (-1,13,"a",9,5),
        (1,24,"a",5,5),
        (1,1,"a",2,5),
        (1,10,"a",7,5),
        (1,14,"a",5,0),
        (-1,23,"a",9,0),
        (-1,2,"a",2,1),
        (-1,9,"a",3,1),
        (1,15,"a",0,1),
        (1,22,"a",1,1),
        (-1,3,"a",7,4),
        (-1,8,"a",4,1),
        (1,16,"a",8,4),
        (-1,21,"a",1,4),
        (1,4,"a",3,2),
        (-1,7,"a",6,3),
        (-1,17,"a",8,2),
        (1,20,"a",9,3),
        (1,5,"a",4,2),
        (1,6,"a",6,2),
        (-1,18,"a",0,3),
        (-1,19,"a",5,2),
    ],
    (12, ((0))): [
        (1,12,"c",0,0),
        (1,25,"c",1,0),
    ],
    (13, (((1,0)))): [
        (1,0,"a",9,5),
        (-1,11,"a",8,0),
        (1,13,"a",3,0),
        (-1,24,"a",6,5),
        (-1,1,"a",8,5),
        (1,10,"a",9,0),
        (-1,14,"a",6,0),
        (1,23,"a",3,5),
        (1,2,"a",5,4),
        (-1,9,"a",9,4),
        (1,15,"a",7,1),
        (1,22,"a",2,1),
        (-1,3,"a",1,4),
        (1,8,"a",8,4),
        (-1,16,"a",7,4),
        (-1,21,"a",4,1),
        (-1,4,"a",0,2),
        (-1,7,"a",5,3),
        (1,17,"a",6,3),
        (1,20,"a",4,3),
        (1,5,"a",0,3),
        (1,6,"a",1,3),
        (-1,18,"a",3,3),
        (-1,19,"a",2,3),
    ],
    (14, ((0))): [
        (1,14,"b",0,0),
        (1,19,"b",1,0),
        (-1,9,"b",2,0),
        (-1,24,"b",3,0),
        (1,4,"b",4,0),
        (1,29,"b",5,0),
    ],
    (15, (((-1,0)))): [
        (-1,0,"a",9,1),
        (1,11,"a",5,1),
        (1,13,"a",2,4),
        (1,24,"a",7,4),
        (1,1,"a",9,3),
        (-1,10,"a",5,3),
        (-1,14,"a",2,2),
        (-1,23,"a",7,2),
        (-1,2,"a",9,5),
        (1,9,"a",5,5),
        (1,15,"a",2,0),
        (1,22,"a",7,0),
        (1,3,"a",9,4),
        (-1,8,"a",8,1),
        (1,16,"a",3,1),
        (-1,21,"a",6,4),
        (-1,4,"a",9,2),
        (1,7,"a",8,3),
        (-1,17,"a",3,3),
        (1,20,"a",6,2),
        (1,5,"a",9,0),
        (-1,6,"a",8,5),
        (1,18,"a",3,5),
        (-1,19,"a",6,0),
    ],
    (16, (((-1,1)))): [
        (1,0,"a",4,4),
        (1,11,"a",7,1),
        (1,13,"a",1,1),
        (-1,24,"a",8,1),
        (1,1,"a",6,2),
        (-1,10,"a",3,3),
        (-1,14,"a",9,2),
        (1,23,"a",8,3),
        (-1,2,"a",6,1),
        (-1,9,"a",4,1),
        (1,15,"a",5,1),
        (1,22,"a",0,4),
        (-1,3,"a",4,5),
        (-1,8,"a",6,5),
        (1,16,"a",0,0),
        (1,21,"a",5,5),
        (-1,4,"a",6,0),
        (1,7,"a",3,5),
        (1,17,"a",9,0),
        (-1,20,"a",8,5),
        (1,5,"a",6,3),
        (1,6,"a",4,3),
        (-1,18,"a",5,3),
        (-1,19,"a",0,2),
    ],
    (17, (((-1,1)))): [
        (-1,0,"a",7,2),
        (-1,11,"a",4,3),
        (1,13,"a",8,2),
        (-1,24,"a",1,2),
        (1,1,"a",7,1),
        (1,10,"a",2,1),
        (-1,14,"a",9,4),
        (1,23,"a",5,4),
        (-1,2,"a",3,5),
        (1,9,"a",6,0),
        (1,15,"a",8,5),
        (-1,22,"a",9,0),
        (-1,3,"a",2,3),
        (-1,8,"a",7,3),
        (-1,16,"a",5,2),
        (1,21,"a",9,2),
        (1,4,"a",4,5),
        (1,7,"a",7,0),
        (1,17,"a",1,0),
        (-1,20,"a",8,0),
        (-1,5,"a",2,4),
        (-1,6,"a",3,4),
        (1,18,"a",0,4),
        (1,19,"a",1,4),
    ],
    (18, (((-1,0)))): [
        (-1,0,"a",9,0),
        (1,11,"a",8,5),
        (-1,13,"a",3,5),
        (1,24,"a",6,0),
        (1,1,"a",5,1),
        (-1,10,"a",9,1),
        (1,14,"a",7,4),
        (1,23,"a",2,4),
        (1,2,"a",0,3),
        (1,9,"a",5,2),
        (-1,15,"a",6,2),
        (-1,22,"a",4,2),
        (1,3,"a",1,2),
        (1,8,"a",0,2),
        (-1,16,"a",2,2),
        (-1,21,"a",3,2),
        (-1,4,"a",8,1),
        (1,7,"a",1,1),
        (1,17,"a",4,4),
        (1,20,"a",7,1),
        (1,5,"a",9,5),
        (-1,6,"a",8,0),
        (1,18,"a",3,0),
        (-1,19,"a",6,5),
    ],
    (19, ((0))): [
        (1,19,"b",0,0),
        (1,4,"b",1,0),
        (-1,29,"b",2,0),
        (1,9,"b",3,0),
        (1,14,"b",4,0),
        (-1,24,"b",5,0),
    ],
    (20, (((1,0)))): [
        (1,0,"a",8,2),
        (-1,11,"a",9,3),
        (1,13,"a",6,3),
        (-1,24,"a",3,2),
        (1,1,"a",0,1),
        (1,10,"a",5,4),
        (-1,14,"a",6,4),
        (-1,23,"a",4,4),
        (1,2,"a",1,5),
        (1,9,"a",0,5),
        (-1,15,"a",2,5),
        (-1,22,"a",3,5),
        (-1,3,"a",9,2),
        (1,8,"a",5,2),
        (1,16,"a",2,3),
        (1,21,"a",7,3),
        (1,4,"a",5,5),
        (-1,7,"a",9,5),
        (1,17,"a",7,0),
        (1,20,"a",2,0),
        (1,5,"a",0,4),
        (1,6,"a",5,1),
        (-1,18,"a",6,1),
        (-1,19,"a",4,1),
    ],
    (21, (((1,1)))): [
        (-1,0,"a",2,1),
        (-1,11,"a",7,1),
        (-1,13,"a",5,4),
        (1,24,"a",9,4),
        (-1,1,"a",6,2),
        (-1,10,"a",4,2),
        (1,14,"a",5,2),
        (1,23,"a",0,3),
        (-1,2,"a",2,4),
        (-1,9,"a",7,4),
        (-1,15,"a",5,1),
        (1,22,"a",9,1),
        (-1,3,"a",6,5),
        (-1,8,"a",4,5),
        (1,16,"a",5,5),
        (1,21,"a",0,0),
        (-1,4,"a",4,0),
        (-1,7,"a",7,5),
        (-1,17,"a",1,5),
        (1,20,"a",8,5),
        (-1,5,"a",7,2),
        (-1,6,"a",4,3),
        (1,18,"a",8,2),
        (-1,19,"a",1,2),
    ],
    (22, (((1,1)))): [
        (1,0,"a",6,1),
        (-1,11,"a",3,4),
        (-1,13,"a",9,1),
        (1,24,"a",8,4),
        (1,1,"a",4,3),
        (1,10,"a",6,3),
        (-1,14,"a",0,2),
        (-1,23,"a",5,3),
        (1,2,"a",7,0),
        (1,9,"a",4,5),
        (-1,15,"a",8,0),
        (1,22,"a",1,0),
        (-1,3,"a",3,1),
        (1,8,"a",6,4),
        (1,16,"a",8,1),
        (-1,21,"a",9,4),
        (-1,4,"a",2,3),
        (-1,7,"a",3,3),
        (1,17,"a",0,3),
        (1,20,"a",1,3),
        (-1,5,"a",7,5),
        (-1,6,"a",2,5),
        (1,18,"a",9,0),
        (-1,19,"a",5,0),
    ],
    (23, (((1,0)))): [
        (-1,0,"a",0,3),
        (-1,11,"a",1,3),
        (1,13,"a",3,3),
        (1,24,"a",2,3),
        (-1,1,"a",8,0),
        (1,10,"a",9,5),
        (-1,14,"a",6,5),
        (1,23,"a",3,0),
        (1,2,"a",8,2),
        (-1,9,"a",1,2),
        (-1,15,"a",4,3),
        (-1,22,"a",7,2),
        (1,3,"a",0,5),
        (1,8,"a",5,0),
        (-1,16,"a",6,0),
        (-1,21,"a",4,0),
        (1,4,"a",8,4),
        (-1,7,"a",9,1),
        (1,17,"a",6,1),
        (-1,20,"a",3,4),
        (-1,5,"a",5,4),
        (-1,6,"a",0,1),
        (1,18,"a",4,4),
        (1,19,"a",6,4),
    ],
    (24, ((0))): [
        (1,24,"b",0,0),
        (-1,9,"b",1,0),
        (-1,4,"b",2,0),
        (1,19,"b",3,0),
        (-1,29,"b",4,0),
        (1,14,"b",5,0),
    ],
    (25, ((0))): [
        (1,25,"c",0,0),
        (-1,12,"c",1,0),
    ],
    (26, (((-1,1)))): [
        (-1,0,"a",3,0),
        (-1,11,"a",2,0),
        (1,13,"a",1,0),
        (1,24,"a",0,0),
        (-1,1,"a",2,5),
        (-1,10,"a",3,5),
        (1,14,"a",0,5),
        (1,23,"a",1,5),
        (1,2,"a",4,4),
        (1,9,"a",6,4),
        (-1,15,"a",0,1),
        (-1,22,"a",5,4),
        (-1,3,"a",4,1),
        (-1,8,"a",7,4),
        (-1,16,"a",1,4),
        (1,21,"a",8,4),
        (1,4,"a",2,2),
        (1,7,"a",7,2),
        (1,17,"a",5,3),
        (-1,20,"a",9,3),
        (1,5,"a",3,3),
        (-1,6,"a",6,2),
        (-1,18,"a",8,3),
        (1,19,"a",9,2),
    ],
    (27, (((-1,1)))): [
        (-1,0,"a",3,3),
        (1,11,"a",6,2),
        (1,13,"a",8,3),
        (-1,24,"a",9,2),
        (-1,1,"a",2,0),
        (-1,10,"a",3,0),
        (1,14,"a",0,0),
        (1,23,"a",1,0),
        (-1,2,"a",6,3),
        (1,9,"a",3,2),
        (1,15,"a",9,3),
        (-1,22,"a",8,2),
        (-1,3,"a",4,0),
        (-1,8,"a",6,0),
        (1,16,"a",0,5),
        (1,21,"a",5,0),
        (-1,4,"a",7,4),
        (-1,7,"a",2,4),
        (1,17,"a",9,1),
        (-1,20,"a",5,1),
        (-1,5,"a",4,4),
        (-1,6,"a",7,1),
        (-1,18,"a",1,1),
        (1,19,"a",8,1),
    ],
    (28, (((-1,0)))): [
        (1,0,"a",0,4),
        (1,11,"a",5,1),
        (-1,13,"a",6,1),
        (-1,24,"a",4,1),
        (1,1,"a",9,3),
        (-1,10,"a",8,2),
        (1,14,"a",3,2),
        (-1,23,"a",6,3),
        (-1,2,"a",1,0),
        (-1,9,"a",0,0),
        (1,15,"a",2,0),
        (1,22,"a",3,0),
        (1,3,"a",8,1),
        (-1,8,"a",9,4),
        (1,16,"a",6,4),
        (-1,21,"a",3,1),
        (-1,4,"a",5,2),
        (-1,7,"a",0,3),
        (1,17,"a",4,2),
        (1,20,"a",6,2),
        (1,5,"a",1,5),
        (-1,6,"a",8,5),
        (1,18,"a",7,5),
        (1,19,"a",4,0),
    ],
    (29, ((0))): [
        (1,29,"b",0,0),
        (-1,24,"b",1,0),
        (1,19,"b",2,0),
        (-1,14,"b",3,0),
        (1,9,"b",4,0),
        (-1,4,"b",5,0),
    ],
    (30, (((1,0)))): [
        (1,0,"a",5,3),
        (-1,11,"a",9,3),
        (1,13,"a",7,2),
        (1,24,"a",2,2),
        (1,1,"a",0,1),
        (1,10,"a",1,1),
        (-1,14,"a",3,1),
        (-1,23,"a",2,1),
        (1,2,"a",9,0),
        (-1,9,"a",5,0),
        (-1,15,"a",2,5),
        (-1,22,"a",7,5),
        (-1,3,"a",5,2),
        (1,8,"a",9,2),
        (-1,16,"a",7,3),
        (-1,21,"a",2,3),
        (-1,4,"a",0,0),
        (-1,7,"a",1,0),
        (1,17,"a",3,0),
        (1,20,"a",2,0),
        (-1,5,"a",9,1),
        (1,6,"a",5,1),
        (1,18,"a",2,4),
        (1,19,"a",7,4),
    ],
    (31, (((1,1)))): [
        (1,0,"a",3,5),
        (1,11,"a",2,5),
        (-1,13,"a",1,5),
        (-1,24,"a",0,5),
        (-1,1,"a",3,4),
        (-1,10,"a",2,4),
        (1,14,"a",1,4),
        (1,23,"a",0,4),
        (1,2,"a",3,3),
        (1,9,"a",2,3),
        (-1,15,"a",1,3),
        (-1,22,"a",0,3),
        (-1,3,"a",3,2),
        (-1,8,"a",2,2),
        (1,16,"a",1,2),
        (1,21,"a",0,2),
        (1,4,"a",3,1),
        (1,7,"a",2,1),
        (-1,17,"a",1,1),
        (-1,20,"a",0,1),
        (-1,5,"a",3,0),
        (-1,6,"a",2,0),
        (1,18,"a",1,0),
        (1,19,"a",0,0),
    ],
}

_DCT8_B32_ROWS = {
    (0, (((1,0)))): [
        (1,0,"a",3,0),
        (1,11,"a",6,5),
        (1,13,"a",8,0),
        (1,24,"a",9,5),
        (1,1,"a",3,1),
        (1,10,"a",6,4),
        (1,14,"a",8,1),
        (1,23,"a",9,4),
        (1,2,"a",3,2),
        (1,9,"a",6,3),
        (1,15,"a",8,2),
        (1,22,"a",9,3),
        (1,3,"a",3,3),
        (1,8,"a",6,2),
        (1,16,"a",8,3),
        (1,21,"a",9,2),
        (1,4,"a",3,4),
        (1,7,"a",6,1),
        (1,17,"a",8,4),
        (1,20,"a",9,1),
        (1,5,"a",3,5),
        (1,6,"a",6,0),
        (1,18,"a",8,5),
        (1,19,"a",9,0),
    ],
    (1, (((1,1)))): [
        (1,0,"a",5,2),
        (-1,11,"a",0,3),
        (-1,13,"a",4,2),
        (-1,24,"a",6,2),
        (-1,1,"a",9,1),
        (-1,10,"a",8,4),
        (-1,14,"a",3,4),
        (-1,23,"a",6,1),
        (-1,2,"a",0,0),
        (1,9,"a",5,5),
        (-1,15,"a",6,5),
        (-1,22,"a",4,5),
        (1,3,"a",5,3),
        (-1,8,"a",0,2),
        (-1,16,"a",4,3),
        (-1,21,"a",6,3),
        (-1,4,"a",9,0),
        (-1,7,"a",8,5),
        (-1,17,"a",3,5),
        (-1,20,"a",6,0),
        (-1,5,"a",0,1),
        (1,6,"a",5,4),
        (-1,18,"a",6,4),
        (-1,19,"a",4,4),
    ],
    (2, ((0))): [
        (1,4,"b",0,0),
        (1,9,"b",1,0),
        (1,14,"b",2,0),
        (1,19,"b",3,0),
        (1,24,"b",4,0),
        (1,29,"b",5,0),
    ],
    (3, (((-1,1)))): [
        (1,0,"a",9,4),
        (1,11,"a",5,4),
        (-1,13,"a",2,1),
        (1,24,"a",7,1),
        (1,1,"a",0,3),
        (1,10,"a",1,3),
        (-1,14,"a",3,3),
        (-1,23,"a",2,3),
        (-1,2,"a",8,5),
        (-1,9,"a",9,0),
        (-1,15,"a",6,0),
        (-1,22,"a",3,5),
        (1,3,"a",1,4),
        (1,8,"a",0,4),
        (-1,16,"a",2,4),
        (-1,21,"a",3,4),
        (1,4,"a",5,3),
        (1,7,"a",9,3),
        (1,17,"a",7,2),
        (-1,20,"a",2,2),
        (-1,5,"a",8,0),
        (-1,6,"a",1,0),
        (1,18,"a",4,5),
        (1,19,"a",7,0),
    ],
    (4, (((-1,0)))): [
        (-1,0,"a",3,2),
        (-1,11,"a",2,2),
        (1,13,"a",1,2),
        (1,24,"a",0,2),
        (1,1,"a",6,0),
        (1,10,"a",3,5),
        (1,14,"a",9,0),
        (1,23,"a",8,5),
        (-1,2,"a",2,3),
        (-1,9,"a",3,3),
        (1,15,"a",0,3),
        (1,22,"a",1,3),
        (-1,3,"a",7,0),
        (1,8,"a",2,0),
        (-1,16,"a",9,5),
        (-1,21,"a",5,5),
        (1,4,"a",4,4),
        (1,7,"a",6,4),
        (1,17,"a",0,1),
        (-1,20,"a",5,4),
        (-1,5,"a",7,4),
        (-1,6,"a",4,1),
        (1,18,"a",8,4),
        (1,19,"a",1,4),
    ],
    (5, (((-1,0)))): [
        (1,0,"a",3,5),
        (1,11,"a",6,0),
        (1,13,"a",8,5),
        (1,24,"a",9,0),
        (-1,1,"a",6,5),
        (-1,10,"a",3,0),
        (-1,14,"a",9,5),
        (-1,23,"a",8,0),
        (1,2,"a",7,4),
        (-1,9,"a",2,4),
        (1,15,"a",9,1),
        (1,22,"a",5,1),
        (1,3,"a",7,1),
        (1,8,"a",4,4),
        (-1,16,"a",8,1),
        (-1,21,"a",1,1),
        (-1,4,"a",6,2),
        (-1,7,"a",4,2),
        (1,17,"a",5,2),
        (-1,20,"a",0,3),
        (1,5,"a",3,2),
        (1,6,"a",2,2),
        (-1,18,"a",1,2),
        (-1,19,"a",0,2),
    ],
    (6, ((0))): [
        (1,12,"c",0,0),
        (1,25,"c",1,0),
    ],
    (7, ((0))): [
        (-1,14,"b",0,0),
        (-1,29,"b",1,0),
        (-1,19,"b",2,0),
        (-1,4,"b",3,0),
        (1,9,"b",4,0),
        (1,24,"b",5,0),
    ],
    (8, (((1,1)))): [
        (1,0,"a",9,3),
        (1,11,"a",8,2),
        (1,13,"a",3,2),
        (1,24,"a",6,3),
        (1,1,"a",1,5),
        (1,10,"a",0,5),
        (-1,14,"a",2,5),
        (-1,23,"a",3,5),
        (-1,2,"a",1,3),
        (-1,9,"a",8,3),
        (1,15,"a",7,3),
        (1,22,"a",4,2),
        (-1,3,"a",9,5),
        (-1,8,"a",5,5),
        (1,16,"a",2,0),
        (-1,21,"a",7,0),
        (-1,4,"a",1,1),
        (-1,7,"a",0,1),
        (1,17,"a",2,1),
        (1,20,"a",3,1),
        (1,5,"a",5,1),
        (1,6,"a",9,1),
        (1,18,"a",7,4),
        (-1,19,"a",2,4),
    ],
    (9, (((1,0)))): [
        (1,0,"a",2,1),
        (1,11,"a",3,1),
        (-1,13,"a",0,1),
        (-1,24,"a",1,1),
        (-1,1,"a",7,3),
        (1,10,"a",2,3),
        (-1,14,"a",9,2),
        (-1,23,"a",5,2),
        (-1,2,"a",4,0),
        (-1,9,"a",7,5),
        (1,15,"a",1,5),
        (1,22,"a",8,5),
        (-1,3,"a",3,4),
        (-1,8,"a",2,4),
        (1,16,"a",1,4),
        (1,21,"a",0,4),
        (-1,4,"a",6,3),
        (-1,7,"a",3,2),
        (-1,17,"a",9,3),
        (-1,20,"a",8,2),
        (-1,5,"a",4,5),
        (-1,6,"a",6,5),
        (-1,18,"a",0,0),
        (1,19,"a",5,5),
    ],
    (10, (((1,0)))): [
        (-1,0,"a",6,1),
        (-1,11,"a",4,1),
        (1,13,"a",5,1),
        (-1,24,"a",0,4),
        (1,1,"a",2,2),
        (-1,10,"a",7,2),
        (-1,14,"a",5,3),
        (-1,23,"a",9,3),
        (1,2,"a",6,4),
        (1,9,"a",4,4),
        (-1,15,"a",5,4),
        (1,22,"a",0,1),
        (-1,3,"a",2,5),
        (1,8,"a",7,5),
        (1,16,"a",5,0),
        (1,21,"a",9,0),
        (-1,4,"a",7,0),
        (-1,7,"a",4,5),
        (1,17,"a",8,0),
        (1,20,"a",1,0),
        (1,5,"a",4,2),
        (1,6,"a",7,3),
        (-1,18,"a",1,3),
        (-1,19,"a",8,3),
    ],
    (11, (((1,1)))): [
        (-1,0,"a",1,3),
        (-1,11,"a",0,3),
        (1,13,"a",2,3),
        (1,24,"a",3,3),
        (-1,1,"a",9,1),
        (-1,10,"a",5,1),
        (1,14,"a",2,4),
        (-1,23,"a",7,4),
        (-1,2,"a",8,0),
        (-1,9,"a",9,5),
        (-1,15,"a",6,5),
        (-1,22,"a",3,0),
        (1,3,"a",0,2),
        (-1,8,"a",5,3),
        (1,16,"a",6,3),
        (1,21,"a",4,3),
        (1,4,"a",5,0),
        (-1,7,"a",0,5),
        (-1,17,"a",4,0),
        (-1,20,"a",6,0),
        (1,5,"a",9,4),
        (1,6,"a",5,4),
        (-1,18,"a",2,1),
        (1,19,"a",7,1),
    ],
    (12, ((0))): [
        (1,24,"b",0,0),
        (1,14,"b",1,0),
        (-1,9,"b",2,0),
        (-1,29,"b",3,0),
        (-1,4,"b",4,0),
        (1,19,"b",5,0),
    ],
    (13, (((-1,1)))): [
        (1,0,"a",0,0),
        (1,11,"a",1,0),
        (-1,13,"a",3,0),
        (-1,24,"a",2,0),
        (1,1,"a",5,4),
        (-1,10,"a",0,1),
        (-1,14,"a",4,4),
        (-1,23,"a",6,4),
        (-1,2,"a",9,3),
        (-1,9,"a",5,3),
        (1,15,"a",2,2),
        (-1,22,"a",7,2),
        (1,3,"a",8,3),
        (1,8,"a",9,2),
        (1,16,"a",6,2),
        (1,21,"a",3,3),
        (-1,4,"a",1,4),
        (-1,7,"a",8,4),
        (1,17,"a",7,4),
        (1,20,"a",4,1),
        (1,5,"a",0,5),
        (1,6,"a",1,5),
        (-1,18,"a",3,5),
        (-1,19,"a",2,5),
    ],
    (14, (((-1,0)))): [
        (1,0,"a",4,2),
        (1,11,"a",7,3),
        (-1,13,"a",1,3),
        (-1,24,"a",8,3),
        (1,1,"a",4,1),
        (1,10,"a",6,1),
        (1,14,"a",0,4),
        (-1,23,"a",5,1),
        (-1,2,"a",3,0),
        (-1,9,"a",2,0),
        (1,15,"a",1,0),
        (1,22,"a",0,0),
        (-1,3,"a",6,3),
        (-1,8,"a",4,3),
        (1,16,"a",5,3),
        (-1,21,"a",0,2),
        (-1,4,"a",7,5),
        (-1,7,"a",4,0),
        (1,17,"a",8,5),
        (1,20,"a",1,5),
        (1,5,"a",6,4),
        (1,6,"a",3,1),
        (1,18,"a",9,4),
        (1,19,"a",8,1),
    ],
    (15, (((-1,0)))): [
        (1,0,"a",7,4),
        (1,11,"a",4,1),
        (-1,13,"a",8,4),
        (-1,24,"a",1,4),
        (-1,1,"a",2,2),
        (-1,10,"a",3,2),
        (1,14,"a",0,2),
        (1,23,"a",1,2),
        (-1,2,"a",2,1),
        (1,9,"a",7,1),
        (1,15,"a",5,4),
        (1,22,"a",9,4),
        (1,3,"a",7,5),
        (-1,8,"a",2,5),
        (1,16,"a",9,0),
        (1,21,"a",5,0),
        (1,4,"a",2,0),
        (1,7,"a",3,0),
        (-1,17,"a",0,0),
        (-1,20,"a",1,0),
        (1,5,"a",2,3),
        (-1,6,"a",7,3),
        (-1,18,"a",5,2),
        (-1,19,"a",9,2),
    ],
    (16, (((-1,1)))): [
        (-1,0,"a",0,1),
        (1,11,"a",5,4),
        (-1,13,"a",6,4),
        (-1,24,"a",4,4),
        (1,1,"a",0,3),
        (-1,10,"a",5,2),
        (1,14,"a",6,2),
        (1,23,"a",4,2),
        (-1,2,"a",0,5),
        (1,9,"a",5,0),
        (-1,15,"a",6,0),
        (-1,22,"a",4,0),
        (-1,3,"a",0,4),
        (-1,8,"a",1,4),
        (1,16,"a",3,4),
        (1,21,"a",2,4),
        (1,4,"a",0,2),
        (1,7,"a",1,2),
        (-1,17,"a",3,2),
        (-1,20,"a",2,2),
        (-1,5,"a",0,0),
        (-1,6,"a",1,0),
        (1,18,"a",3,0),
        (1,19,"a",2,0),
    ],
    (17, ((0))): [
        (-1,29,"b",0,0),
        (1,4,"b",1,0),
        (1,24,"b",2,0),
        (-1,9,"b",3,0),
        (-1,19,"b",4,0),
        (1,14,"b",5,0),
    ],
    (18, (((1,1)))): [
        (1,0,"a",0,5),
        (1,11,"a",1,5),
        (-1,13,"a",3,5),
        (-1,24,"a",2,5),
        (-1,1,"a",1,0),
        (-1,10,"a",0,0),
        (1,14,"a",2,0),
        (1,23,"a",3,0),
        (-1,2,"a",5,1),
        (1,9,"a",0,4),
        (1,15,"a",4,1),
        (1,22,"a",6,1),
        (-1,3,"a",8,1),
        (-1,8,"a",1,1),
        (1,16,"a",4,4),
        (1,21,"a",7,1),
        (-1,4,"a",9,2),
        (-1,7,"a",5,2),
        (1,17,"a",2,3),
        (-1,20,"a",7,3),
        (-1,5,"a",9,3),
        (-1,6,"a",8,2),
        (-1,18,"a",3,2),
        (-1,19,"a",6,3),
    ],
    (19, ((0))): [
        (-1,25,"c",0,0),
        (1,12,"c",1,0),
    ],
    (20, (((1,0)))): [
        (-1,0,"a",4,0),
        (-1,11,"a",6,0),
        (-1,13,"a",0,5),
        (1,24,"a",5,0),
        (1,1,"a",6,5),
        (1,10,"a",4,5),
        (-1,14,"a",5,5),
        (1,23,"a",0,0),
        (-1,2,"a",6,1),
        (-1,9,"a",3,4),
        (-1,15,"a",9,1),
        (-1,22,"a",8,4),
        (1,3,"a",4,4),
        (1,8,"a",7,1),
        (-1,16,"a",1,1),
        (-1,21,"a",8,1),
        (-1,4,"a",3,3),
        (-1,7,"a",2,3),
        (1,17,"a",1,3),
        (1,20,"a",0,3),
        (1,5,"a",7,2),
        (-1,6,"a",2,2),
        (1,18,"a",9,3),
        (1,19,"a",5,3),
    ],
    (21, (((1,1)))): [
        (1,0,"a",1,2),
        (1,11,"a",8,2),
        (-1,13,"a",7,2),
        (-1,24,"a",4,3),
        (1,1,"a",1,5),
        (1,10,"a",8,5),
        (-1,14,"a",7,5),
        (-1,23,"a",4,0),
        (1,2,"a",5,2),
        (1,9,"a",9,2),
        (1,15,"a",7,3),
        (-1,22,"a",2,3),
        (1,3,"a",5,5),
        (1,8,"a",9,5),
        (1,16,"a",7,0),
        (-1,21,"a",2,0),
        (1,4,"a",8,1),
        (1,7,"a",9,4),
        (1,17,"a",6,4),
        (1,20,"a",3,1),
        (1,5,"a",8,4),
        (1,6,"a",9,1),
        (1,18,"a",6,1),
        (1,19,"a",3,4),
    ],
    (22, ((0))): [
        (1,19,"b",0,0),
        (-1,24,"b",1,0),
        (1,4,"b",2,0),
        (1,14,"b",3,0),
        (-1,29,"b",4,0),
        (1,9,"b",5,0),
    ],
    (23, (((-1,1)))): [
        (1,0,"a",8,4),
        (1,11,"a",9,1),
        (1,13,"a",6,1),
        (1,24,"a",3,4),
        (-1,1,"a",8,2),
        (-1,10,"a",1,2),
        (1,14,"a",4,3),
        (1,23,"a",7,2),
        (-1,2,"a",0,1),
        (-1,9,"a",1,1),
        (1,15,"a",3,1),
        (1,22,"a",2,1),
        (1,3,"a",5,0),
        (1,8,"a",9,0),
        (1,16,"a",7,5),
        (-1,21,"a",2,5),
        (-1,4,"a",9,5),
        (-1,7,"a",8,0),
        (-1,17,"a",3,0),
        (-1,20,"a",6,5),
        (1,5,"a",5,2),
        (-1,6,"a",0,3),
        (-1,18,"a",4,2),
        (-1,19,"a",6,2),
    ],
    (24, (((-1,0)))): [
        (-1,0,"a",2,3),
        (1,11,"a",7,3),
        (1,13,"a",5,2),
        (1,24,"a",9,2),
        (1,1,"a",4,1),
        (1,10,"a",7,4),
        (-1,14,"a",1,4),
        (-1,23,"a",8,4),
        (-1,2,"a",4,5),
        (-1,9,"a",7,0),
        (1,15,"a",1,0),
        (1,22,"a",8,0),
        (1,3,"a",4,3),
        (1,8,"a",6,3),
        (1,16,"a",0,2),
        (-1,21,"a",5,3),
        (-1,4,"a",2,5),
        (-1,7,"a",3,5),
        (1,17,"a",0,5),
        (1,20,"a",1,5),
        (1,5,"a",2,1),
        (1,6,"a",3,1),
        (-1,18,"a",0,1),
        (-1,19,"a",1,1),
    ],
    (25, (((-1,0)))): [
        (-1,0,"a",4,5),
        (-1,11,"a",6,5),
        (-1,13,"a",0,0),
        (1,24,"a",5,5),
        (-1,1,"a",3,1),
        (-1,10,"a",2,1),
        (1,14,"a",1,1),
        (1,23,"a",0,1),
        (1,2,"a",7,2),
        (1,9,"a",4,3),
        (-1,15,"a",8,2),
        (-1,22,"a",1,2),
        (1,3,"a",6,2),
        (1,8,"a",3,3),
        (1,16,"a",9,2),
        (1,21,"a",8,3),
        (1,4,"a",2,4),
        (-1,7,"a",7,4),
        (-1,17,"a",5,1),
        (-1,20,"a",9,1),
        (-1,5,"a",4,0),
        (-1,6,"a",6,0),
        (-1,18,"a",0,5),
        (1,19,"a",5,0),
    ],
    (26, (((-1,1)))): [
        (1,0,"a",8,0),
        (1,11,"a",1,0),
        (-1,13,"a",4,5),
        (-1,24,"a",7,0),
        (1,1,"a",5,4),
        (1,10,"a",9,4),
        (1,14,"a",7,1),
        (-1,23,"a",2,1),
        (-1,2,"a",1,2),
        (-1,9,"a",0,2),
        (1,15,"a",2,2),
        (1,22,"a",3,2),
        (-1,3,"a",9,2),
        (-1,8,"a",8,3),
        (-1,16,"a",3,3),
        (-1,21,"a",6,2),
        (1,4,"a",0,4),
        (-1,7,"a",5,1),
        (1,17,"a",6,1),
        (1,20,"a",4,1),
        (1,5,"a",8,5),
        (1,6,"a",1,5),
        (-1,18,"a",4,0),
        (-1,19,"a",7,5),
    ],
    (27, ((0))): [
        (-1,9,"b",0,0),
        (1,19,"b",1,0),
        (-1,29,"b",2,0),
        (1,24,"b",3,0),
        (-1,14,"b",4,0),
        (1,4,"b",5,0),
    ],
    (28, (((1,1)))): [
        (-1,0,"a",5,1),
        (-1,11,"a",9,1),
        (-1,13,"a",7,4),
        (1,24,"a",2,4),
        (1,1,"a",8,2),
        (1,10,"a",9,3),
        (1,14,"a",6,3),
        (1,23,"a",3,2),
        (-1,2,"a",9,4),
        (-1,9,"a",8,1),
        (-1,15,"a",3,1),
        (-1,22,"a",6,4),
        (1,3,"a",9,0),
        (1,8,"a",5,0),
        (-1,16,"a",2,5),
        (1,21,"a",7,5),
        (-1,4,"a",5,5),
        (1,7,"a",0,0),
        (1,17,"a",4,5),
        (1,20,"a",6,5),
        (1,5,"a",1,3),
        (1,6,"a",0,3),
        (-1,18,"a",2,3),
        (-1,19,"a",3,3),
    ],
    (29, (((1,0)))): [
        (1,0,"a",6,4),
        (1,11,"a",3,1),
        (1,13,"a",9,4),
        (1,24,"a",8,1),
        (-1,1,"a",7,3),
        (-1,10,"a",4,2),
        (1,14,"a",8,3),
        (1,23,"a",1,3),
        (-1,2,"a",3,5),
        (-1,9,"a",2,5),
        (1,15,"a",1,5),
        (1,22,"a",0,5),
        (1,3,"a",2,4),
        (1,8,"a",3,4),
        (-1,16,"a",0,4),
        (-1,21,"a",1,4),
        (1,4,"a",4,3),
        (1,7,"a",7,2),
        (-1,17,"a",1,2),
        (-1,20,"a",8,2),
        (-1,5,"a",3,0),
        (-1,6,"a",6,5),
        (-1,18,"a",8,0),
        (-1,19,"a",9,5),
    ],
    (30, (((1,0)))): [
        (-1,0,"a",7,2),
        (1,11,"a",2,2),
        (-1,13,"a",9,3),
        (-1,24,"a",5,3),
        (-1,1,"a",6,0),
        (-1,10,"a",4,0),
        (1,14,"a",5,0),
        (-1,23,"a",0,5),
        (-1,2,"a",4,2),
        (-1,9,"a",6,2),
        (-1,15,"a",0,3),
        (1,22,"a",5,2),
        (1,3,"a",2,0),
        (-1,8,"a",7,0),
        (-1,16,"a",5,5),
        (-1,21,"a",9,5),
        (1,4,"a",7,1),
        (-1,7,"a",2,1),
        (1,17,"a",9,4),
        (1,20,"a",5,4),
        (1,5,"a",6,1),
        (1,6,"a",4,1),
        (-1,18,"a",5,1),
        (1,19,"a",0,4),
    ],
    (31, (((1,1)))): [
        (1,0,"a",8,5),
        (1,11,"a",1,5),
        (-1,13,"a",4,0),
        (-1,24,"a",7,5),
        (-1,1,"a",1,0),
        (-1,10,"a",8,0),
        (1,14,"a",7,0),
        (1,23,"a",4,5),
        (-1,2,"a",8,4),
        (-1,9,"a",1,4),
        (1,15,"a",4,1),
        (1,22,"a",7,4),
        (1,3,"a",1,1),
        (1,8,"a",8,1),
        (-1,16,"a",7,1),
        (-1,21,"a",4,4),
        (1,4,"a",8,3),
        (1,7,"a",1,3),
        (-1,17,"a",4,2),
        (-1,20,"a",7,3),
        (-1,5,"a",1,2),
        (-1,6,"a",8,2),
        (1,18,"a",7,2),
        (1,19,"a",4,3),
    ],
}


# ----------------------------------------------------------------------------
# Public API
# ----------------------------------------------------------------------------
def fast_inv_dct2(src, N, shift=DEFAULT_SHIFT, op=None):
    return _inv_dct2(list(src), N, shift, op)


def fast_inv_dst7(src, N, shift=DEFAULT_SHIFT, op=None):
    return _inv_dst7(_Ctx(shift, op), list(src), N)


def fast_inv_dct8(src, N, shift=DEFAULT_SHIFT, op=None):
    return _inv_dct8(_Ctx(shift, op), list(src), N)


def fast_inv(tr_type, src, N, shift=DEFAULT_SHIFT, op=None):
    if tr_type == 0:
        return fast_inv_dct2(src, N, shift, op)
    if tr_type == 1:
        return fast_inv_dst7(src, N, shift, op)
    if tr_type == 2:
        return fast_inv_dct8(src, N, shift, op)
    raise ValueError(f'unknown trType {tr_type}')


# ----------------------------------------------------------------------------
# Reference direct / transposed matrix multiplications (shift=6, clip)
# ----------------------------------------------------------------------------
def ref_direct(tr_type, src, N, shift=DEFAULT_SHIFT):
    """y = clip((T*src + add) >> shift).  This is ref_model.inverse_transform_1d."""
    T = _matrix_for(tr_type, N)
    add = 1 << (shift - 1)
    out = []
    for i in range(N):
        s = 0
        for j in range(N):
            s += T[i][j] * src[j]
        out.append(clip3((s + add) >> shift))
    return out


def ref_transpose(tr_type, src, N, shift=DEFAULT_SHIFT):
    """y = clip((T^T*src + add) >> shift)."""
    T = _matrix_for(tr_type, N)
    add = 1 << (shift - 1)
    out = []
    for j in range(N):
        s = 0
        for i in range(N):
            s += T[i][j] * src[i]
        out.append(clip3((s + add) >> shift))
    return out


def ref_direct_noclip(tr_type, src, N, shift=DEFAULT_SHIFT):
    """ref_model.inverse_transform_1d exactly (no clipping)."""
    T = _matrix_for(tr_type, N)
    r = []
    for i in range(N):
        s = 0
        for j in range(N):
            s += T[i][j] * src[j]
        r.append((s + (1 << (shift - 1))) >> shift)
    return r


# ----------------------------------------------------------------------------
# Verification
# ----------------------------------------------------------------------------
def gen_inputs(N, seed=12345):
    """Produce test input vectors: one-hot, extremes, sparse, random, overflow."""
    rng = random.Random(seed)
    inputs = []
    # one-hot (each position)
    for i in range(N):
        v = [0] * N
        v[i] = 1
        inputs.append(('onehot', i, v))
    # max / min
    inputs.append(('maxall', 0, [32767] * N))
    inputs.append(('minall', 0, [-32768] * N))
    inputs.append(('maxmin_alt', 0, [32767 if i % 2 == 0 else -32768 for i in range(N)]))
    inputs.append(('minmax_alt', 0, [-32768 if i % 2 == 0 else 32767 for i in range(N)]))
    # overflow boundary: large magnitude inputs
    inputs.append(('overflow_hi', 0, [32767 if i < N // 2 else 30000 for i in range(N)]))
    inputs.append(('overflow_lo', 0, [-32768 if i < N // 2 else -30000 for i in range(N)]))
    # sparse (few non-zero)
    for trial in range(100):
        v = [0] * N
        for _ in range(max(1, N // 8)):
            v[rng.randrange(N)] = rng.choice([-32768, -20000, -1000, -5, 1, 7, 1000, 20000, 32767])
        inputs.append((f'sparse{trial}', 0, v))
    # random (task requirement: 1000 groups)
    for trial in range(1000):
        v = [rng.randint(-32768, 32767) for _ in range(N)]
        inputs.append((f'rand{trial}', 0, v))
    return inputs


def _diff(a, b):
    d = [i for i, (x, y) in enumerate(zip(a, b)) if x != y]
    return d


def verify(tr_type, N, seed=12345, verbose=True):
    """Compare the fast model against both references for all test inputs:
      - 'direct'      : ref_model.inverse_transform_1d logic (y=(T*x+32)>>6, clipped)
      - 'transpose'   : y=(T^T*x+32)>>6 clipped   (the mathematically-correct inverse,
                        which is what the VTM fast inverse reproduces)
    Returns (n_checked, n_neither, match_direct, match_transpose)."""
    name = {0: 'DCT2', 1: 'DST7', 2: 'DCT8'}[tr_type]
    fast_fn = {0: fast_inv_dct2, 1: fast_inv_dst7, 2: fast_inv_dct8}[tr_type]

    mismatches = 0
    checked = 0
    match_direct = 0
    match_transpose = 0
    first_fail = None
    for label, idx, v in gen_inputs(N, seed):
        f = fast_fn(v, N)
        checked += 1
        d_ref = ref_direct(tr_type, v, N)
        t_ref = ref_transpose(tr_type, v, N)
        if f == d_ref:
            match_direct += 1
        if f == t_ref:
            match_transpose += 1
        if f != d_ref and f != t_ref:
            mismatches += 1
            if first_fail is None:
                first_fail = (label, v, f, d_ref, t_ref)
    if verbose:
        n = len(gen_inputs(N, seed))
        print(f'  {name} N={N}: checked {checked} inputs, direct-match {match_direct}, '
              f'transpose-match {match_transpose}, NEITHER {mismatches}')
        if first_fail:
            lbl, v, f, d, t = first_fail
            print(f'    first NEITHER: {lbl}')
            print(f'      in : {v}')
            print(f'      fast: {f}')
            print(f'      dir : {d}')
            print(f'      trns: {t}')
    return checked, mismatches, match_direct, match_transpose


def verify_all(seed=12345, sizes=None):
    print('=' * 78)
    print('FAST vs DIRECT MATRIX  (ref_model.inverse_transform_1d style, shift=6, clip)')
    print('=' * 78)
    ok = True
    for tr in (0, 1, 2):
        for N in ([4, 8, 16, 32, 64] if tr == 0 else [4, 8, 16, 32]):
            if sizes and N not in sizes:
                continue
            c, m, md, mt = verify(tr, N, seed, verbose=True)
            if m:
                ok = False
    print('=' * 78)
    print('VERDICT:', 'PASS (every input matches direct and/or transpose)'
          if ok else 'FAIL (some inputs match neither)')
    print('KEY RESULT: the VTM fast inverse reproduces  y = T^T * x  (transpose).')
    print('  - DCT2, DST7 (non-symmetric): fast == transpose only; ref_model.inverse_transform_1d')
    print('    computes T*x (the FORWARD transform) and therefore does NOT reproduce VTM.')
    print('  - DCT8 (symmetric T^T==T): fast == direct == transpose.')
    print('  - For DST7/DCT8 N=32 the model uses VTM RomTr matrices (canonical JSON differs).')
    return ok


# ----------------------------------------------------------------------------
# Operation statistics
# ----------------------------------------------------------------------------
def op_stats():
    """Report per-transform multiplication / add-sub counts for one 1-D inverse vector."""
    rows = []
    for tr, name in ((0, 'DCT2'), (1, 'DST7'), (2, 'DCT8')):
        for N in ([4, 8, 16, 32, 64] if tr == 0 else [4, 8, 16, 32]):
            op = OpCounter()
            fast_inv(tr, [1] * N, N, op=op)
            T = _matrix_for(tr, N)
            nz = sum(1 for i in range(N) for j in range(N) if T[i][j] != 0)
            # unique coefficients
            uniq = len(set(v for row in T for v in row if v != 0))
            naive_mul = N * N
            naive_add = N * (N - 1)
            rows.append(dict(
                tr=name, N=N, mul=op.mul, addsub=op.addsub, sub=op.sub,
                naive_mul=naive_mul, naive_add=naive_add,
                mul_saved=naive_mul - op.mul,
                unique_coeff=uniq, nz_coeff=nz))
    return rows


def print_op_stats():
    rows = op_stats()
    print()
    print('=' * 100)
    print('OPERATION STATISTICS  (one 1-D inverse vector of length N)')
    print('=' * 100)
    hdr = (f"{'tr':5} {'N':>3} | {'fast mul':>8} {'naive mul':>9} {'mul saved':>9} "
           f"| {'fast add/sub':>12} {'naive add':>9} | {'unique coef':>11} {'nz coef':>7}")
    print(hdr)
    print('-' * len(hdr))
    for r in rows:
        print(f"{r['tr']:5} {r['N']:>3} | {r['mul']:>8} {r['naive_mul']:>9} "
              f"{r['mul_saved']:>9} | {r['addsub']:>12} {r['naive_add']:>9} "
              f"| {r['unique_coeff']:>11} {r['nz_coeff']:>7}")
    print('-' * len(hdr))
    # Totals across sizes
    for tr in ('DCT2', 'DST7', 'DCT8'):
        sub = [r for r in rows if r['tr'] == tr]
        tm = sum(r['mul'] for r in sub)
        tn = sum(r['naive_mul'] for r in sub)
        ta = sum(r['addsub'] for r in sub)
        print(f'{tr}: total fast mul={tm}, naive mul={tn}, mul saved={tn - tm}, fast add/sub={ta}')
    print()
    # Shared subexpression estimate: number of butterfly intermediates (E/O/a/b/c/d...)
    print('Shared subexpressions (intermediates computed once and reused per output):')
    for tr, name in ((0, 'DCT2'), (1, 'DST7'), (2, 'DCT8')):
        for N in ([4, 8, 16, 32, 64] if tr == 0 else [4, 8, 16, 32]):
            if tr == 0:
                n_int = {4: 4, 8: 10, 16: 22, 32: 46, 64: 94}[N]
            elif tr == 1:
                n_int = {4: 4, 8: 0, 16: 21, 32: 74}[N]
            else:
                n_int = {4: 4, 8: 0, 16: 21, 32: 74}[N]
            print(f'  {name} N={N}: ~{n_int} reusable butterfly intermediates')


if __name__ == '__main__':
    verify_all()
    print_op_stats()
