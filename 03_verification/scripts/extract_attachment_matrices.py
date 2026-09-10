"""
DEPRECATED: Attachment-only matrix extraction tool.
Output: attachment_only_matrices.json (NOT canonical — lacks VTM DCT2 4/8/16/32)
For canonical matrices use: generate_canonical_matrices.py
"""
import json, os, re, sys, hashlib
from docx import Document

def clean(s):
    return int(s.strip().replace('−','-').replace('–','-'))

def parse_matrix(text, start_pos):
    """Parse matrix from outermost { } starting at start_pos.
    Returns list of rows (each row is list of ints)."""
    depth, end = 0, -1
    for i in range(start_pos, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0: end = i; break
    if end == -1: return []
    block = text[start_pos:end+1]
    rows = []
    for m in re.finditer(r'\{([^{}]+)\}', block):
        try:
            vals = [clean(x) for x in m.group(1).split()]
            if vals: rows.append(vals)
        except: pass
    return rows


def main():
    failed = 0
    def check(ok, msg):
        nonlocal failed
        if ok: print(f"  OK: {msg}")
        else: print(f"  FAIL: {msg}"); failed += 1
        return ok

    _att = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                          "..", "..", "04_reference", "huawei", "华为附件.docx"))
    if not os.path.exists(_att):
        print(f"FATAL: Huawei attachment not found at {_att}")
        sys.exit(1)
    doc = Document(_att)
    full = '\n'.join([p.text for p in doc.paragraphs])

    result = {
        "transforms": {
            "0": {"name": "DCT2", "sizes": {}},
            "1": {"name": "DST7", "sizes": {}},
            "2": {"name": "DCT8", "sizes": {}}
        },
        "lfnst": {
            "16": {"0": {}, "1": {}, "2": {}, "3": {}},
            "48": {"0": {}, "1": {}, "2": {}, "3": {}}
        }
    }

    # ================================================================
    # DCT2: trType=0, ONLY nTbs=64
    # ================================================================
    print("=== DCT2 (trType=0) ===")
    d2s = full[full.find('DCT-II'):full.find('DST-VII')]

    def get_col_block(text, name):
        p = text.find(f'transMatrix{name} =')
        if p < 0: return None
        m = parse_matrix(text, text.find('{', p))
        return [r for r in m if len(r) == 16]

    c0 = get_col_block(d2s, 'Col0to15')
    c1 = get_col_block(d2s, 'Col16to31')

    if check(c0 and len(c0) == 64, f'Col0to15: {len(c0) if c0 else 0} rows (expect 64)'):
        if check(c1 and len(c1) == 64, f'Col16to31: {len(c1) if c1 else 0} rows (expect 64)'):
            m64 = [[0]*64 for _ in range(64)]
            for i in range(64):
                for j in range(16):
                    m64[i][j] = c0[i][j]
                    m64[i][j+16] = c1[i][j]
                    # DCT-II symmetry: T[i][63-n] = (-1)^i * T[i][n]
                    m64[i][j+32] = c1[i][15-j] if i % 2 == 0 else -c1[i][15-j]
                    m64[i][j+48] = c0[i][15-j] if i % 2 == 0 else -c0[i][15-j]
            result["transforms"]["0"]["sizes"]["64"] = m64
            check(all(v == 64 for v in m64[0]), f"Row0 all 64")
            check(m64[8][31] == m64[8][32], f"DCT-II even-row symmetry M[8][31]==M[8][32]")
    print("  DCT2 4/8/16/32: NOT provided in attachment (only 64-point)")
    print("  These sizes are EXCLUDED from attachment_matrices.json")

    # ================================================================
    # DST7: trType=1, nTbs=4/8/16/32
    # ================================================================
    print("\n=== DST7 (trType=1) ===")
    d7s = full[full.find('DST-VII'):full.find('DCT-VIII')]

    for n in [4, 8, 16]:
        m = re.search(rf'nTbs\s*=\s*{n}\s*\n', d7s)
        if not m:
            check(False, f"nTbs={n} header not found")
            continue
        rows = parse_matrix(d7s, d7s.find('{', m.end()))
        rows_n = [r for r in rows if len(r) == n]
        if check(len(rows_n) == n, f"N={n}: {len(rows_n)} rows"):
            result["transforms"]["1"]["sizes"][str(n)] = rows_n

    # nTbs=32: column decomposition
    c0d7 = get_col_block(d7s, 'Col0to15')
    c1d7 = get_col_block(d7s, 'Col16to31')
    if check(c0d7 and len(c0d7) >= 16, f'Col0to15: {len(c0d7) if c0d7 else 0} rows') and \
       check(c1d7 and len(c1d7) >= 16, f'Col16to31: {len(c1d7) if c1d7 else 0} rows'):
        m32 = [[0]*32 for _ in range(32)]
        for i in range(16):
            for j in range(16):
                m32[i][j] = c0d7[i][j]; m32[i][j+16] = c1d7[i][j]
                m32[i+16][j] = c1d7[i][j]; m32[i+16][j+16] = c0d7[i][j]
        result["transforms"]["1"]["sizes"]["32"] = m32
        check(True, "N=32: assembled")

    # ================================================================
    # DCT8: trType=2, nTbs=4/8/16/32
    # ================================================================
    print("\n=== DCT8 (trType=2) ===")
    ifc = full.find('接口')
    d8s = full[full.find('DCT-VIII'):ifc] if ifc > 0 else full[full.find('DCT-VIII'):]

    for n in [4, 8, 16]:
        m = re.search(rf'nTbs\s*=\s*{n}\s*\n', d8s)
        if not m:
            check(False, f"nTbs={n} header not found")
            continue
        rows = parse_matrix(d8s, d8s.find('{', m.end()))
        rows_n = [r for r in rows if len(r) == n]
        if check(len(rows_n) == n, f"N={n}: {len(rows_n)} rows"):
            result["transforms"]["2"]["sizes"][str(n)] = rows_n

    c0d8 = get_col_block(d8s, 'Col0to15')
    c1d8 = get_col_block(d8s, 'Col16to31')
    if check(c0d8 and len(c0d8) >= 16, f'Col0to15: {len(c0d8) if c0d8 else 0} rows') and \
       check(c1d8 and len(c1d8) >= 16, f'Col16to31: {len(c1d8) if c1d8 else 0} rows'):
        m32 = [[0]*32 for _ in range(32)]
        for i in range(16):
            for j in range(16):
                m32[i][j] = c0d8[i][j]; m32[i][j+16] = c1d8[i][j]
                m32[i+16][j] = c1d8[i][j]; m32[i+16][j+16] = c0d8[i][j]
        result["transforms"]["2"]["sizes"]["32"] = m32
        check(True, "N=32: assembled")

    # ================================================================
    # LFNST: 16 scenarios
    # ================================================================
    print("\n=== LFNST ===")
    lsec = full[full.find('nTrs ='):full.find('DCT-II')]
    all_lf = list(re.finditer(r'nTrs\s*=\s*(\d+)\D+?lfnstTrSetIdx\s*=\s*(\d+)\D+?lfnst_idx\s*=\s*(\d+)', lsec))

    for idx, m in enumerate(all_lf):
        ntrs, si, li = int(m.group(1)), str(m.group(2)), str(m.group(3))
        start = m.end()
        end = all_lf[idx+1].start() if idx+1 < len(all_lf) else len(lsec)
        se = lsec[start:end]

        if ntrs == 16:
            rows = parse_matrix(se, se.find('{'))
            ok = check(rows and len(rows) == 16, f"nTrs=16 s{si} i{li}: {len(rows) if rows else 0} rows")
            if ok: result["lfnst"]["16"][si][li] = rows
        else:  # nTrs=48
            blocks = []
            for bn in ['Col0to15', 'Col16to31', 'Col32to47']:
                p = se.find(f'lowFreqTransMatrix{bn} =')
                if p < 0:
                    break
                b = parse_matrix(se, se.find('{', p))
                b = [r for r in b if len(r) == 16]
                if len(b) == 16: blocks.append(b)
            if check(len(blocks) == 3, f"nTrs=48 s{si} i{li}: {len(blocks)} blocks (expect 3)"):
                result["lfnst"]["48"][si][li] = blocks[0] + blocks[1] + blocks[2]

    # ================================================================
    # Write output
    # ================================================================
    od = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'output')
    os.makedirs(od, exist_ok=True)
    op = os.path.join(od, 'attachment_only_matrices.json')
    with open(op, 'w', encoding='utf-8') as f:
        json.dump(result, f, indent=2, ensure_ascii=False)

    # Compute content hash
    with open(op, 'rb') as f:
        h = hashlib.md5(f.read()).hexdigest()

    print(f"\n{'='*60}")
    print(f"EXTRACTION {'PASSED' if failed == 0 else 'FAILED'}: {failed} errors")
    print(f"JSON: {op}")
    print(f"MD5:  {h}")
    return failed


if __name__ == '__main__':
    sys.exit(1 if main() else 0)
