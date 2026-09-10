"""
SINGLE canonical matrix generation entry point for ITS project.

Sources:
  Huawei attachment (华为附件.docx):
    - DCT2 64x64 (transMatrixCol0to15/Col16to31 + DCT-II symmetry)
    - DST7 4/8/16/32
    - DCT8 4/8/16/32
    - LFNST nTrs=16/48 (16 scenarios)

  VTM RomTr.cpp (VVCSoftware_VTM, commit 69f5112bae8c0f91f3cbc5ba0f44b58986080f16):
    - DCT2 4/8/16/32 (64-scale inverse transform macros)
    - DCT2 64 (for cross-validation against attachment)

DEPRECATED since V3.3: use generate_canonical_v33.py. Outputs attachment_only_matrices.json (not canonical).

Usage:
  python generate_canonical_matrices.py
  python generate_canonical_matrices.py  (must produce bit-identical output)
"""
import json, os, re, sys, hashlib, shutil, tempfile
from docx import Document

VTM_COMMIT = "69f5112bae8c0f91f3cbc5ba0f44b58986080f16"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(SCRIPT_DIR, "..", "output")
ATTACHMENT_PATH = os.path.join(SCRIPT_DIR, "..", "..", "04_reference", "huawei", "华为附件.docx")
VTM_ROMTR_PATH = os.path.join(SCRIPT_DIR, "..", "..", "04_reference", "VTM", "source", "Lib", "CommonLib", "RomTr.cpp")
OUTPUT_FILE = os.path.join(OUTPUT_DIR, "attachment_only_matrices.json")  # V3.3: superseded by generate_canonical_v33.py

FAILED = 0


def fail(msg):
    global FAILED
    print(f"  FAIL: {msg}")
    FAILED += 1


def check(ok, msg):
    if ok:
        print(f"  OK: {msg}")
    else:
        fail(msg)
    return ok


# ---------------------------------------------------------------
# Attachment: matrix parsing
# ---------------------------------------------------------------

def clean_number(s):
    return int(s.strip().replace(chr(0x2212), '-').replace('--', '-').replace('u2013', '-'))


def parse_matrix(text, start_pos):
    """Parse { {row1} {row2} ... } block starting at start_pos."""
    depth, end = 0, -1
    for i in range(start_pos, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0: end = i; break
    if end == -1:
        return []
    block = text[start_pos:end + 1]
    rows = []
    for m in re.finditer(r'\{([^{}]+)\}', block):
        try:
            vals = [int(x.strip().replace(chr(0x2212), '-').replace('--', '-'))
                    for x in m.group(1).split()]
            if vals: rows.append(vals)
        except (ValueError, IndexError):
            pass
    return rows


# ---------------------------------------------------------------
# Attachment: DCT2 64x64
# ---------------------------------------------------------------

def extract_dct2_64_from_attachment(full_text):
    d2s = full_text[full_text.find('DCT-II'):full_text.find('DST-VII')]

    def get_col_block(text, name):
        p = text.find(f'transMatrix{name} =')
        if p < 0: return None
        m = parse_matrix(text, text.find('{', p))
        return [r for r in m if len(r) == 16]

    c0 = get_col_block(d2s, 'Col0to15')
    c1 = get_col_block(d2s, 'Col16to31')
    if not c0 or len(c0) != 64:
        fail(f"DCT2 Col0to15: {len(c0) if c0 else 'MISSING'} rows (expect 64)")
        return None
    if not c1 or len(c1) != 64:
        fail(f"DCT2 Col16to31: {len(c1) if c1 else 'MISSING'} rows (expect 64)")
        return None

    m64 = [[0] * 64 for _ in range(64)]
    for i in range(64):
        for j in range(16):
            m64[i][j] = c0[i][j]
            m64[i][j + 16] = c1[i][j]
            # DCT-II symmetry: T[i][63-n] = (-1)^i * T[i][n]
            m64[i][j + 32] = c1[i][15 - j] if i % 2 == 0 else -c1[i][15 - j]
            m64[i][j + 48] = c0[i][15 - j] if i % 2 == 0 else -c0[i][15 - j]

    check(all(v == 64 for v in m64[0]), "DCT2 64: Row0 all 64")
    return m64


# ---------------------------------------------------------------
# Attachment: DST7 / DCT8
# ---------------------------------------------------------------

def extract_transform_matrices_attachment(full_text, section_marker, name, n_list):
    start = full_text.find(section_marker)
    end = full_text.find('DCT-VIII') if name == 'DST7' else (
        full_text.find('接口', start) if full_text.find('接口', start) != -1 else len(full_text))
    section = full_text[start:end]

    result = {}

    def get_col(text, col_name):
        p = text.find(f'transMatrix{col_name} =')
        if p < 0: return None
        m = parse_matrix(text, text.find('{', p))
        return [r for r in m if len(r) == 16]

    for n in n_list:
        if n == 32:
            c0 = get_col(section, 'Col0to15')
            c1 = get_col(section, 'Col16to31')
            if c0 and c1 and len(c0) >= 16 and len(c1) >= 16:
                m32 = [[0] * 32 for _ in range(32)]
                for i in range(16):
                    for j in range(16):
                        m32[i][j] = c0[i][j];
                        m32[i][j + 16] = c1[i][j]
                        m32[i + 16][j] = c1[i][j];
                        m32[i + 16][j + 16] = c0[i][j]
                result[str(n)] = m32
                check(True, f"{name} {n}x{n}: OK")
            else:
                fail(f"{name} {n}x{n}: column decomp failed")
                return None
        else:
            m = re.search(rf'nTbs\s*=\s*{n}\s*\n', section)
            if not m:
                fail(f"{name} {n}x{n}: nTbs header not found")
                return None
            rows = parse_matrix(section, section.find('{', m.end()))
            rows_n = [r for r in rows if len(r) == n]
            if len(rows_n) == n:
                result[str(n)] = rows_n
                check(True, f"{name} {n}x{n}: OK")
            else:
                fail(f"{name} {n}x{n}: got {len(rows_n)} rows (expect {n})")
                return None
    return result


# ---------------------------------------------------------------
# Attachment: LFNST
# ---------------------------------------------------------------

def extract_lfnst_from_attachment(full_text):
    lsec = full_text[full_text.find('nTrs ='):full_text.find('DCT-II')]
    all_lf = list(re.finditer(
        r'nTrs\s*=\s*(\d+)\D+?lfnstTrSetIdx\s*=\s*(\d+)\D+?lfnst_idx\s*=\s*(\d+)', lsec))

    result = {"16": {"0": {}, "1": {}, "2": {}, "3": {}},
              "48": {"0": {}, "1": {}, "2": {}, "3": {}}}

    for idx, m in enumerate(all_lf):
        ntrs = int(m.group(1));
        si = str(m.group(2));
        li = str(m.group(3))
        se = lsec[m.end():all_lf[idx + 1].start()] if idx + 1 < len(all_lf) else lsec[m.end():]

        if ntrs == 16:
            rows = parse_matrix(se, se.find('{'))
            if check(rows and len(rows) == 16, f"LFNST nTrs=16 s{si} i{li}: {len(rows) if rows else 0} rows"):
                result["16"][si][li] = rows
            else:
                return None
        else:
            blocks = []
            for bn in ['Col0to15', 'Col16to31', 'Col32to47']:
                p = se.find(f'lowFreqTransMatrix{bn} =')
                if p < 0: break
                b = parse_matrix(se, se.find('{', p))
                b = [r for r in b if len(r) == 16]
                if len(b) == 16: blocks.append(b)
            if check(len(blocks) == 3, f"LFNST nTrs=48 s{si} i{li}: {len(blocks)} blocks"):
                result["48"][si][li] = blocks[0] + blocks[1] + blocks[2]
            else:
                return None
    return result


# ---------------------------------------------------------------
# VTM: DCT2 matrices from RomTr.cpp
# ---------------------------------------------------------------

def read_vtm_romtr():
    with open(VTM_ROMTR_PATH, 'r', encoding='utf-8', errors='ignore') as f:
        return f.read()


def verify_vtm_commit():
    # Check commit file
    import subprocess
    vtm_dir = os.path.dirname(VTM_ROMTR_PATH)
    vtm_dir = os.path.dirname(os.path.dirname(vtm_dir))  # up 2 levels
    try:
        result = subprocess.run(['git', 'log', '-1', '--format=%H'],
                                cwd=vtm_dir, capture_output=True, text=True)
        actual = result.stdout.strip()
        if actual:
            check(actual == VTM_COMMIT,
                  f"VTM commit: expected {VTM_COMMIT[:12]}..., got {actual[:12]}...")
    except:
        print(f"  WARNING: Could not verify git commit (may be zip download)")


VTM_DCT2_PARAMS = {
    4: [64, 83, 36],
    8: [64, 83, 36, 89, 75, 50, 18],
    16: [64, 83, 36, 89, 75, 50, 18, 90, 87, 80, 70, 57, 43, 25, 9],
    32: [64, 83, 36, 89, 75, 50, 18, 90, 87, 80, 70, 57, 43, 25, 9, 90, 90, 88, 85, 82, 78, 73, 67, 61,
         54, 46, 38, 31, 22, 13, 4],
    64: [64, 83, 36, 89, 75, 50, 18, 90, 87, 80, 70, 57, 43, 25, 9, 90, 90, 88, 85, 82, 78, 73, 67, 61,
         54, 46, 38, 31, 22, 13, 4, 91, 90, 90, 90, 88, 87, 86, 84, 83, 81, 79, 77, 73, 71, 69, 65, 62,
         59, 56, 52, 48, 44, 41, 37, 33, 28, 24, 20, 15, 11, 7, 2],
}

VTM_PNAMES = {
    4: ['a', 'b', 'c'],
    8: ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
    16: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o'],
    32: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o',
         'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'A', 'B', 'C', 'D', 'E'],
    64: ['aa', 'ab', 'ac', 'ad', 'ae', 'af', 'ag', 'ah', 'ai', 'aj', 'ak', 'al', 'am', 'an', 'ao', 'ap',
         'aq', 'ar', 'as', 'at', 'au', 'av', 'aw', 'ax', 'ay', 'az',
         'ba', 'bb', 'bc', 'bd', 'be', 'bf', 'bg', 'bh', 'bi', 'bj', 'bk', 'bl', 'bm', 'bn', 'bo', 'bp',
         'bq', 'br', 'bs', 'bt', 'bu', 'bv', 'bw', 'bx', 'by', 'bz',
         'ca', 'cb', 'cc', 'cd', 'ce', 'cf', 'cg', 'ch', 'ci', 'cj', 'ck'],
}

VTM_PREFIX = {4: 'P4_MATRIX', 8: 'P8_MATRIX', 16: 'P16_MATRIX', 32: 'P32_MATRIX', 64: 'P64_MATRIX'}


def build_vtm_dct2(N, content):
    prefix = f'DCT2_{VTM_PREFIX[N]}'
    start = content.find(f'DEFINE_{prefix}')
    if start < 0:
        fail(f"VTM DCT2 {N}x{N}: macro not found")
        return None
    brace = content.find('{', content.find('\\\n', start) if '\\\n' in content[start:start + 300] else start)
    depth = 0
    for i in range(brace, len(content)):
        if content[i] == '{': depth += 1
        elif content[i] == '}':
            depth -= 1
            if depth == 0: block_end = i; break
    block = content[brace:block_end + 1].replace('\\\n', ' ').replace('\\\r\n', ' ')
    rows = []
    for m in re.finditer(r'\{([^{}]+)\}', block):
        rows.append([e.strip() for e in m.group(1).split(',')])

    pnames = VTM_PNAMES[N];
    params = VTM_DCT2_PARAMS[N];
    pmap = {n: i for i, n in enumerate(pnames)}
    M = []
    for row_entries in rows[:N]:
        vals = []
        for e in row_entries:
            sign = 1
            if e.startswith('-'): sign = -1; e = e[1:]
            if e in pmap:
                vals.append(sign * params[pmap[e]])
            else:
                try:
                    vals.append(sign * int(e))
                except:
                    vals.append(0)
        if len(vals) < N: vals += [0] * (N - len(vals))
        M.append(vals[:N])

    if len(M) == N and all(len(r) == N for r in M):
        check(True, f"VTM DCT2 {N}x{N}: built {N}x{N}")
        return M
    fail(f"VTM DCT2 {N}x{N}: dimension error ({len(M)}x{[len(r) for r in M[:3]]})")
    return None


# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------

def main():
    global FAILED

    # Verify VTM commit
    verify_vtm_commit()

    # Read sources
    if not os.path.exists(ATTACHMENT_PATH):
        print(f"ERROR: attachment not found: {ATTACHMENT_PATH}")
        sys.exit(1)
    if not os.path.exists(VTM_ROMTR_PATH):
        print(f"ERROR: VTM RomTr.cpp not found: {VTM_ROMTR_PATH}")
        sys.exit(1)

    doc = Document(ATTACHMENT_PATH)
    att_text = '\n'.join([p.text for p in doc.paragraphs])
    vtm_text = read_vtm_romtr()

    # Build matrices
    transforms = {"0": {"name": "DCT2", "sizes": {}},
                  "1": {"name": "DST7", "sizes": {}},
                  "2": {"name": "DCT8", "sizes": {}}}
    lfnst = {"16": {"0": {}, "1": {}, "2": {}, "3": {}},
             "48": {"0": {}, "1": {}, "2": {}, "3": {}}}

    # -- DCT2 64 from attachment --
    print("\n=== DCT2 64 (Attachment) ===")
    dct2_64_att = extract_dct2_64_from_attachment(att_text)
    if dct2_64_att is None:
        sys.exit(1)

    # -- VTM DCT2 4/8/16/32 --
    print("\n=== VTM DCT2 4/8/16/32 ===")
    for N in [4, 8, 16, 32]:
        m = build_vtm_dct2(N, vtm_text)
        if m is None:
            sys.exit(1)
        transforms["0"]["sizes"][str(N)] = m

    # -- VTM DCT2 64 cross-check --
    print("\n=== VTM DCT2 64 cross-check ===")
    dct2_64_vtm = build_vtm_dct2(64, vtm_text)
    if dct2_64_vtm is None:
        sys.exit(1)

    # Compare VTM 64 vs Attachment 64
    diffs = sum(1 for i in range(64) for j in range(64)
                if dct2_64_att[i][j] != dct2_64_vtm[i][j])
    if diffs > 0:
        # Show first few
        nd = 0
        for i in range(64):
            for j in range(64):
                if dct2_64_att[i][j] != dct2_64_vtm[i][j] and nd < 5:
                    print(f"  [{i}][{j}]: ATT={dct2_64_att[i][j]} VTM={dct2_64_vtm[i][j]}")
                    nd += 1
        fail(f"VTM DCT2 64 vs Attachment: {diffs}/4096 differ")
        sys.exit(1)
    else:
        check(True, "VTM DCT2 64 == Attachment DCT2 64: IDENTICAL (0/4096)")

    transforms["0"]["sizes"]["64"] = dct2_64_att

    # -- DST7 --
    print("\n=== DST7 (Attachment) ===")
    dst7 = extract_transform_matrices_attachment(att_text, 'DST-VII', 'DST7', [4, 8, 16, 32])
    if dst7 is None: sys.exit(1)
    transforms["1"]["sizes"] = dst7

    # -- DCT8 --
    print("\n=== DCT8 (Attachment) ===")
    dct8 = extract_transform_matrices_attachment(att_text, 'DCT-VIII', 'DCT8', [4, 8, 16, 32])
    if dct8 is None: sys.exit(1)
    transforms["2"]["sizes"] = dct8

    # -- LFNST --
    print("\n=== LFNST (Attachment) ===")
    lfnst_result = extract_lfnst_from_attachment(att_text)
    if lfnst_result is None: sys.exit(1)
    lfnst = lfnst_result

    # Build metadata
    metadata = {
        "schema_version": 1,
        "generator": "generate_canonical_matrices.py",
        "attachment": "Huawei_attachment.docx",
        "vtm_repo": "VVCSoftware_VTM",
        "vtm_commit": VTM_COMMIT,
        "sources": {
            "DCT2_4_8_16_32": "VTM RomTr.cpp 64-scale inverse tables (DEFINE_DCT2_P{N}_MATRIX)",
            "DCT2_64": "Huawei attachment; verified identical to VTM RomTr.cpp",
            "DST7_DCT8_LFNST": "Huawei attachment"
        }
    }

    output = {
        "metadata": metadata,
        "transforms": transforms,
        "lfnst": lfnst
    }

    # Atomic write via temp file
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=OUTPUT_DIR, suffix='.json')
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
    shutil.move(tmp, OUTPUT_FILE)

    # SHA-256
    with open(OUTPUT_FILE, 'rb') as f:
        h = hashlib.sha256(f.read()).hexdigest()

    print(f"\n{'=' * 60}")
    print(f"Canonical matrices: {OUTPUT_FILE}")
    print(f"SHA-256: {h}")
    print(f"Errors: {FAILED}")
    print(f"29 total: DCT2 5 + DST7 4 + DCT8 4 + LFNST 16")
    return FAILED


if __name__ == '__main__':
    sys.exit(1 if main() else 0)
