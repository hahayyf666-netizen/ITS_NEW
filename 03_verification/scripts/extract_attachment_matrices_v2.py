"""
DEPRECATED: Attachment-only extraction (v2 prototype). Not the canonical entry point.
Use generate_canonical_matrices.py for the authoritative canonical_matrices.json.
This script writes attachment_only_v2_matrices.json (intermediate, no VTM matrices).
"""
import json, os, re, sys
from docx import Document

def clean(s):
    return int(s.strip().replace('−','-').replace('–','-'))

def parse_block(text, start_pos):
    """Parse matrix from outermost { } starting at start_pos."""
    depth, end = 0, -1
    for i in range(start_pos, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0: end = i; break
    if end == -1: return []
    block = text[start_pos:end+1]
    rows, all_rows = [], []
    for m in re.finditer(r'\{([^{}]+)\}', block):
        try:
            vals = [clean(x) for x in m.group(1).split()]
            if vals: all_rows.append(vals)
        except: pass
    return all_rows

def main():
    import sys
    failed = 0
    _att = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                          "..", "..", "04_reference", "huawei", "华为附件.docx"))
    if not os.path.exists(_att):
        print(f"FATAL: Huawei attachment not found at {_att}")
        sys.exit(1)
    doc = Document(_att)
    full = '\n'.join([p.text for p in doc.paragraphs])

    result = {
        "transforms": {"0":{"name":"DCT2","sizes":{}}, "1":{"name":"DST7","sizes":{}}, "2":{"name":"DCT8","sizes":{}}},
        "lfnst": {"16":{"0":{},"1":{},"2":{},"3":{}}, "48":{"0":{},"1":{},"2":{},"3":{}}}
    }

    # === DCT2 (trType=0, nTbs=64 only) ===
    d2s = full[full.find('DCT-II'):full.find('DCT-VIII')]
    c0 = parse_block(d2s, d2s.find('{', d2s.find('transMatrixCol0to15 =')))
    c1 = parse_block(d2s, d2s.find('{', d2s.find('transMatrixCol16to31 =')))
    c0 = [r for r in c0 if len(r)==16]
    c1 = [r for r in c1 if len(r)==16]
    if len(c0)==64 and len(c1)==64:
        m64 = [[0]*64 for _ in range(64)]
        for i in range(64):
            for j in range(16):
                m64[i][j] = c0[i][j]
                m64[i][j+16] = c1[i][j]
                # DCT-II symmetry: T[i][63-n] = (-1)^i * T[i][n]
                m64[i][j+32] = c1[i][15-j] if i%2==0 else -c1[i][15-j]
                m64[i][j+48] = c0[i][15-j] if i%2==0 else -c0[i][15-j]
        result["transforms"]["0"]["sizes"]["64"] = m64
        ok0 = all(v==64 for v in m64[0]); ok8 = m64[8][31]==m64[8][32]
        print(f"DCT2 64x64: Row0_ok={ok0} M8_31=32_ok={ok8}")
        # DCT2 4/8/16/32: NOT provided in attachment — do NOT put in JSON
        print(f"DCT2 4/8/16/32: NOT in attachment (only 64-point provided)")
    else:
        print(f"DCT2 FAIL: c0={len(c0)} c1={len(c1)}")

    # === DST7 (trType=1) ===
    d7s = full[full.find('DST-VII'):full.find('DCT-VIII')]
    for n in [4,8,16]:
        m = re.search(rf'nTbs\s*=\s*{n}\s*\n', d7s)
        if m:
            rows = parse_block(d7s, d7s.find('{', m.end()))
            rows_n = [r for r in rows if len(r)==n]
            if len(rows_n)==n:
                result["transforms"]["1"]["sizes"][str(n)] = rows_n
                print(f"DST7 {n}x{n}: OK")
            else: print(f"DST7 {n}x{n}: FAIL rows={len(rows_n)}")
        else: print(f"DST7 {n}x{n}: HEADER NOT FOUND")
    # nTbs=32 column decomp
    c0d7 = parse_block(d7s, d7s.find('{', d7s.find('transMatrixCol0to15 =')))
    c1d7 = parse_block(d7s, d7s.find('{', d7s.find('transMatrixCol16to31 =')))
    c0d7 = [r for r in c0d7 if len(r)==16]
    c1d7 = [r for r in c1d7 if len(r)==16]
    if len(c0d7)>=16 and len(c1d7)>=16:
        m32 = [[0]*32 for _ in range(32)]
        for i in range(16):
            for j in range(16):
                m32[i][j]=c0d7[i][j]; m32[i][j+16]=c1d7[i][j]
                m32[i+16][j]=c1d7[i][j]; m32[i+16][j+16]=c0d7[i][j]
        result["transforms"]["1"]["sizes"]["32"] = m32
        print(f"DST7 32x32: OK")
    else: print(f"DST7 32x32: FAIL")

    # === DCT8 (trType=2) ===
    d8s = full[full.find('DCT-VIII'):full.find('接口') if full.find('接口')>-1 else len(full)]
    for n in [4,8,16]:
        m = re.search(rf'nTbs\s*=\s*{n}\s*\n', d8s)
        if m:
            rows = parse_block(d8s, d8s.find('{', m.end()))
            rows_n = [r for r in rows if len(r)==n]
            if len(rows_n)==n:
                result["transforms"]["2"]["sizes"][str(n)] = rows_n
                print(f"DCT8 {n}x{n}: OK")
            else: print(f"DCT8 {n}x{n}: FAIL rows={len(rows_n)}")
        else: print(f"DCT8 {n}x{n}: HEADER NOT FOUND")
    c0d8 = parse_block(d8s, d8s.find('{', d8s.find('transMatrixCol0to15 =')))
    c1d8 = parse_block(d8s, d8s.find('{', d8s.find('transMatrixCol16to31 =')))
    c0d8 = [r for r in c0d8 if len(r)==16]
    c1d8 = [r for r in c1d8 if len(r)==16]
    if len(c0d8)>=16 and len(c1d8)>=16:
        m32 = [[0]*32 for _ in range(32)]
        for i in range(16):
            for j in range(16):
                m32[i][j]=c0d8[i][j]; m32[i][j+16]=c1d8[i][j]
                m32[i+16][j]=c1d8[i][j]; m32[i+16][j+16]=c0d8[i][j]
        result["transforms"]["2"]["sizes"]["32"] = m32
        print(f"DCT8 32x32: OK")
    else: print(f"DCT8 32x32: FAIL")

    # === LFNST ===
    lsec = full[full.find('nTrs ='):full.find('DCT-II')]
    all_lf = list(re.finditer(r'nTrs\s*=\s*(\d+)\D+?lfnstTrSetIdx\s*=\s*(\d+)\D+?lfnst_idx\s*=\s*(\d+)', lsec))
    for idx, m in enumerate(all_lf):
        ntrs, si, li = int(m.group(1)), str(m.group(2)), str(m.group(3))
        if idx+1 < len(all_lf):
            se = lsec[m.end():all_lf[idx+1].start()]
        else:
            se = lsec[m.end():]
        if ntrs==16:
            r = parse_block(se, se.find('{'))
            if r and len(r)==16: result["lfnst"]["16"][si][li]=r; print(f"LFNST nTrs=16 s{si} i{li}: OK")
            else: print(f"LFNST nTrs=16 s{si} i{li}: FAIL")
        else:
            blks = []
            for bn in ['Col0to15','Col16to31','Col32to47']:
                p = se.find(f'lowFreqTransMatrix{bn} =')
                if p<0: break
                b = parse_block(se, se.find('{', p))
                b = [r for r in b if len(r)==16]
                if len(b)==16: blks.append(b)
            if len(blks)==3:
                result["lfnst"]["48"][si][li] = blks[0]+blks[1]+blks[2]
                print(f"LFNST nTrs=48 s{si} i{li}: OK")
            else: print(f"LFNST nTrs=48 s{si} i{li}: FAIL ({len(blks)} blocks)")

    od = os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','output')
    os.makedirs(od, exist_ok=True)
    with open(os.path.join(od,'attachment_only_v2_matrices.json'),'w',encoding='utf-8') as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
    print("\nDone.")
    return failed

if __name__=='__main__':
    failed = main()
    sys.exit(1 if failed else 0)
