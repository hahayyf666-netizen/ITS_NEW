# -*- coding: utf-8 -*-
"""
V3.3 canonical matrix generator (consolidated, single entry).
- Extracts from VTM RomTr.cpp (source of truth) + Huawei attachment.
- Does NOT read any existing canonical_matrices.json.
- Builds source_kernel (forward C) + inverse_operator (A = C^T).
- VTM path from VTM_DIR env or --vtm arg; defaults to ../../VTM relative to repo.

Usage: python generate_canonical_v33.py [--vtm D:/path/VTM] [--out out.json]
"""
import json, os, re, sys, hashlib, argparse

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_ROOT = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
DEFAULT_VTM = os.path.join(PROJ_ROOT, "VTM")  # ITS_STUDY/VTM
ROMTR_REL = os.path.join("source", "Lib", "CommonLib", "RomTr.cpp")
ATTACHMENT_REL = os.path.join("..", "..", "华为附件.docx")
VTM_COMMIT = "69f5112bae8c0f91f3cbc5ba0f44b58986080f16"


# ---------------------------------------------------------------
# VTM RomTr parsing
# ---------------------------------------------------------------
def _parse_params(name, N, content, call_idx):
    macro = f'DEFINE_{name}_P{N}_MATRIX'
    calls = re.findall(rf'{macro}\s*\(\s*([0-9,\s-]+)\)', content)
    if call_idx >= len(calls):
        return None
    return [int(x.strip()) for x in calls[call_idx].split(',') if x.strip()]


def _expand_macro_rows(name, N, content, call_idx, pnames):
    """Expand DEFINE_{name}_P{N}_MATRIX with params from call_idx invocation."""
    macro = f'DEFINE_{name}_P{N}_MATRIX'
    d = content.find(f'#define {macro}')
    if d < 0:
        return None
    be = content.find('\n\n', d)
    if be < 0:
        return None
    define = content[d:be]
    vals = _parse_params(name, N, content, call_idx)
    if vals is None:
        return None
    pmap = {c: i for i, c in enumerate(pnames)}
    rows = []
    for rm in re.finditer(r'\{([^{}]+)\}', define):
        entries = [e.strip() for e in rm.group(1).split(',') if e.strip()]
        row = []
        for e in entries:
            sign = 1
            if e.startswith('-'):
                sign = -1
                e = e[1:]
            if e in pmap and pmap[e] < len(vals):
                row.append(sign * vals[pmap[e]])
            elif e.lstrip('-').isdigit():
                row.append(sign * int(e))
            else:
                row.append(0)
        if len(row) == N:
            rows.append(row)
    return rows[:N] if len(rows) >= N else None


DCT2_PNAMES = {
    4: ['a', 'b', 'c'],
    8: ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
    16: ['a','b','c','d','e','f','g','h','i','j','k','l','m','n','o'],
    32: ['a','b','c','d','e','f','g','h','i','j','k','l','m','n','o',
         'p','q','r','s','t','u','v','w','x','y','z','A','B','C','D','E'],
    64: ['aa','ab','ac','ad','ae','af','ag','ah','ai','aj','ak','al','am','an','ao','ap',
         'aq','ar','as','at','au','av','aw','ax','ay','az',
         'ba','bb','bc','bd','be','bf','bg','bh','bi','bj','bk','bl','bm','bn','bo','bp',
         'bq','br','bs','bt','bu','bv','bw','bx','by','bz',
         'ca','cb','cc','cd','ce','cf','cg','ch','ci','cj','ck'],
}
MTS_PNAMES = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'


def vtm_dct2_forward(N, content):
    """64-scale forward DCT2-N. VTM DCT2-64 call1 (64-scale) IS the attachment
    C64 forward kernel (verified: attachment C64 == VTM DCT2-64 inverse set).
    Per Huawei rule: A_N[i][j] = C64[j*(64/N)][i], so source C_N[i][j]=C64[i*scale][j]."""
    C64 = _expand_macro_rows('DCT2', 64, content, 1, DCT2_PNAMES[64])
    if C64 is None or len(C64) != 64:
        return None
    scale = 64 // N
    return [[C64[i * scale][j] for j in range(N)] for i in range(N)]


def vtm_mts_forward(name, N, content):
    """Forward kernel for DST7/DCT8-N. VTM stores the 64-scale matrices;
    call 1 holds the matrix whose transpose is the inverse operator used by
    fastInverse (A = C^T). So source_kernel C = call1 matrix directly."""
    C = _expand_macro_rows(name, N, content, 1, MTS_PNAMES)
    if C is None or len(C) != N:
        return None
    return C


def transpose(M):
    N = len(M)
    return [[M[j][i] for j in range(N)] for i in range(N)]


# ---------------------------------------------------------------
# LFNST extraction from Huawei attachment
# ---------------------------------------------------------------
def parse_matrix_block(text, start_pos):
    depth, end = 0, -1
    for i in range(start_pos, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0: end = i; break
    if end == -1: return []
    block = text[start_pos:end + 1]
    rows = []
    for m in re.finditer(r'\{([^{}]+)\}', block):
        try:
            vals = [int(x.strip().replace('−', '-')) for x in m.group(1).split()]
            if vals: rows.append(vals)
        except (ValueError, IndexError):
            pass
    return rows


def extract_lfnst_attachment(att_text):
    lsec = att_text[att_text.find('nTrs ='):att_text.find('DCT-II')]
    all_lf = list(re.finditer(
        r'nTrs\s*=\s*(\d+)\D+?lfnstTrSetIdx\s*=\s*(\d+)\D+?lfnst_idx\s*=\s*(\d+)', lsec))
    result = {"16": {"0": {}, "1": {}, "2": {}, "3": {}},
              "48": {"0": {}, "1": {}, "2": {}, "3": {}}}
    for idx, m in enumerate(all_lf):
        ntrs = int(m.group(1)); si = str(m.group(2)); li = str(m.group(3))
        se = lsec[m.end():all_lf[idx+1].start()] if idx+1 < len(all_lf) else lsec[m.end():]
        if ntrs == 16:
            rows = parse_matrix_block(se, se.find('{'))
            if rows and len(rows) == 16:
                result["16"][si][li] = rows
        else:
            blocks = []
            for bn in ['Col0to15', 'Col16to31', 'Col32to47']:
                p = se.find(f'lowFreqTransMatrix{bn} =')
                if p < 0: break
                bb = parse_matrix_block(se, se.find('{', p))
                bb = [r for r in bb if len(r) == 16]
                if len(bb) == 16: blocks.append(bb)
            if len(blocks) == 3:
                result["48"][si][li] = blocks[0] + blocks[1] + blocks[2]
    return result


# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--vtm', default=os.environ.get('VTM_DIR', DEFAULT_VTM))
    ap.add_argument('--out', default=os.path.join(SCRIPT_DIR, "..", "output", "canonical_matrices.json"))
    args = ap.parse_args()

    romtr = os.path.join(args.vtm, ROMTR_REL)
    if not os.path.exists(romtr):
        print(f"FATAL: VTM RomTr.cpp not found at {romtr}")
        sys.exit(1)
    content = open(romtr, encoding='utf-8', errors='ignore').read()

    # Verify VTM commit
    try:
        import subprocess
        r = subprocess.run(['git', 'log', '-1', '--format=%H'], cwd=args.vtm,
                           capture_output=True, text=True)
        actual = r.stdout.strip()
        if actual and actual != VTM_COMMIT:
            print(f"WARNING: VTM commit {actual[:12]} != expected {VTM_COMMIT[:12]}")
    except Exception:
        print("WARNING: could not verify VTM commit (check manually)")

    transforms = {
        "0": {"name": "DCT2", "source_kernel": {}, "inverse_operator": {}},
        "1": {"name": "DST7", "source_kernel": {}, "inverse_operator": {}},
        "2": {"name": "DCT8", "source_kernel": {}, "inverse_operator": {}},
    }

    # DCT2
    for N in [4, 8, 16, 32, 64]:
        C = vtm_dct2_forward(N, content)
        if C is None:
            print(f"FATAL: DCT2-{N} extraction failed"); sys.exit(1)
        transforms["0"]["source_kernel"][str(N)] = C
        transforms["0"]["inverse_operator"][str(N)] = transpose(C)

    # DST7 / DCT8
    for tr, name in [("1", "DST7"), ("2", "DCT8")]:
        for N in [4, 8, 16, 32]:
            C = vtm_mts_forward(name, N, content)
            if C is None:
                print(f"FATAL: {name}-{N} extraction failed"); sys.exit(1)
            transforms[tr]["source_kernel"][str(N)] = C
            transforms[tr]["inverse_operator"][str(N)] = transpose(C)

    # Attachment LFNST extraction (required)
    att_path = os.path.join(SCRIPT_DIR, "..", "..", "华为附件.docx")
    if not os.path.exists(att_path):
        print(f"FATAL: Huawei attachment not found at {att_path}")
        sys.exit(1)
    from docx import Document
    att_doc = Document(att_path)
    att_text = '\n'.join([p.text for p in att_doc.paragraphs])
    lfnst = extract_lfnst_attachment(att_text)
    # Verify 16 scenarios
    lf_count = sum(1 for n in ["16","48"] for si in ["0","1","2","3"]
                   for li in ["1","2"] if lfnst[n][si].get(li))
    if lf_count != 16:
        print(f"FATAL: LFNST extraction incomplete ({lf_count}/16)")
        sys.exit(1)
    print(f"LFNST: {lf_count}/16 scenarios extracted")

    output = {
        "metadata": {
            "schema_version": 2,
            "generator": "generate_canonical_v33.py",
            "orientation": "inverse_operator = transpose(source_kernel)",
            "dct2_rule": "A_N[i][j] = C64[j*(64/N)][i]",
            "source_kernel": "forward C from VTM RomTr (64-scale)",
            "inverse_operator": "A = C^T (RTL executes this)",
            "vtm_commit": VTM_COMMIT,
            "vtm_romtr": romtr,
        },
        "transforms": transforms,
        "lfnst": lfnst,
    }

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
    with open(args.out, 'rb') as f:
        h = hashlib.sha256(f.read()).hexdigest()
    print(f"V3.3 canonical written: {args.out}")
    print(f"SHA-256: {h}")
    # one-hot sanity
    A4 = transforms["0"]["inverse_operator"]["4"]
    ok = all(A4[i][0] == 64 for i in range(4))
    print(f"DCT2-4 e0 one-hot [64,64,64,64]: {'PASS' if ok else 'FAIL'}")


if __name__ == '__main__':
    main()
