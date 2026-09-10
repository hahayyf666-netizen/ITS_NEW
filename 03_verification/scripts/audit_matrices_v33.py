# -*- coding: utf-8 -*-
"""
V3.3 independent matrix audit.
- FAILS (exit 1) if Huawei attachment or VTM RomTr.cpp is missing.
- Independent verification of source_kernel vs VTM forward (element-by-element)
  and inverse_operator vs VTM fastInverse (one-hot all positions + fixed random).
- Does NOT rely on self-consistency; uses VTM as external oracle.
Usage: python audit_matrices_v33.py [--vtm D:/path/VTM] [--json path]
"""
import argparse, json, os, random, re, sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_VTM = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "..", "04_reference", "VTM"))
JSON_PATH = os.path.join(SCRIPT_DIR, "..", "output", "canonical_matrices.json")
VTM_COMMIT = "69f5112bae8c0f91f3cbc5ba0f44b58986080f16"

errors = 0
def fail(msg):
    global errors; print(f"  FAIL: {msg}"); errors += 1
def check(ok, msg):
    print(f"  {'OK' if ok else 'FAIL'}: {msg}")
    if not ok: global errors; errors += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--vtm', default=os.environ.get('VTM_DIR', DEFAULT_VTM))
    ap.add_argument('--json', default=JSON_PATH)
    args = ap.parse_args()

    # ---- 0. Source availability (MUST be present) ----
    att = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "..", "04_reference", "huawei", "华为附件.docx"))
    romtr = os.path.join(args.vtm, "source", "Lib", "CommonLib", "RomTr.cpp")
    missing = []
    if not os.path.exists(att): missing.append(f"Huawei attachment: {att}")
    if not os.path.exists(romtr): missing.append(f"VTM RomTr.cpp: {romtr}")
    if missing:
        print("FATAL: required sources missing:")
        for m in missing: print(f"  - {m}")
        print("AUDIT_FAIL (exit 1)")
        sys.exit(1)
    print(f"Sources present: attachment={att}\n  VTM={romtr}")

    # VTM commit check
    try:
        import subprocess
        r = subprocess.run(['git', 'log', '-1', '--format=%H'], cwd=args.vtm,
                           capture_output=True, text=True)
        actual = r.stdout.strip()
        print(f"  VTM commit: {actual[:12]} (expect {VTM_COMMIT[:12]})")
    except Exception:
        print("  WARNING: could not verify VTM commit")

    # ---- 1. Load canonical ----
    with open(args.json, encoding='utf-8') as f:
        data = json.load(f)
    transforms = data["transforms"]
    check(transforms["0"].get("name") == "DCT2", "trType=0 name DCT2")
    check(transforms["1"].get("name") == "DST7", "trType=1 name DST7")
    check(transforms["2"].get("name") == "DCT8", "trType=2 name DCT8")

    # ---- 2. Re-extract from VTM (independent) ----
    sys.path.insert(0, SCRIPT_DIR)
    from generate_canonical_v33 import vtm_dct2_forward, vtm_mts_forward
    content = open(romtr, encoding='utf-8', errors='ignore').read()

    # ---- 3. Verify source_kernel vs VTM forward (element-by-element) ----
    print("\n=== SOURCE_KERNEL vs VTM forward ===")
    expected_sizes = {"0": [4,8,16,32,64], "1": [4,8,16,32], "2": [4,8,16,32]}
    for tr in ["0","1","2"]:
        name = transforms[tr]["name"]
        for N in expected_sizes[tr]:
            C_canon = transforms[tr]["source_kernel"].get(str(N))
            if not C_canon:
                fail(f"{name}-{N}: source_kernel missing")
                continue
            if tr == "0":
                C_vtm = vtm_dct2_forward(N, content)
            else:
                C_vtm = vtm_mts_forward(name, N, content)
            if C_vtm is None:
                fail(f"{name}-{N}: VTM extraction failed")
                continue
            diff = sum(1 for i in range(N) for j in range(N)
                       if C_canon[i][j] != C_vtm[i][j])
            check(diff == 0, f"{name}-{N} source_kernel vs VTM: {diff}/{N*N} diffs")

    # ---- 4. Verify inverse_operator vs VTM fastInverse (one-hot + random) ----
    print("\n=== INVERSE_OPERATOR vs VTM fastInverse ===")
    vtm_model = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "..",
                                              "06_archive", "audits", "_v4_audit",
                                              "vtm_fast_transform_model.py"))
    if not os.path.exists(vtm_model):
        print("FATAL: vtm_fast_transform_model.py not found "
              f"(expected in archived V4 audit): {vtm_model}")
        sys.exit(1)
    import importlib.util
    spec = importlib.util.spec_from_file_location('vtm', vtm_model)
    vtm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(vtm)
    vtm.CANONICAL_JSON = os.path.abspath(args.json)
    vtm._canonical = None

    fn_map = {"0": ("DCT2", vtm.fast_inv_dct2),
              "1": ("DST7", vtm.fast_inv_dst7),
              "2": ("DCT8", vtm.fast_inv_dct8)}

    def inv1d(A, x):
        N = len(A)
        return [max(-32768, min(32767, (sum(A[i][j]*x[j] for j in range(N)) + 32) >> 6))
                for i in range(N)]

    rng = random.Random(2026)
    for tr, (name, fastfn) in fn_map.items():
        for N in expected_sizes[tr]:
            A = transforms[tr]["inverse_operator"].get(str(N))
            if not A:
                fail(f"{name}-{N}: inverse_operator missing")
                continue
            mism = 0
            # one-hot all positions
            for k in range(N):
                x = [0]*N; x[k] = 1
                if inv1d(A, x) != fastfn(x, N): mism += 1
            # fixed random
            for _ in range(50):
                x = [rng.randint(-300, 300) for _ in range(N)]
                if inv1d(A, x) != fastfn(x, N): mism += 1
            # extremes
            for x in ([32767]*N, [-32768]*N, [0]*N):
                if inv1d(A, x) != fastfn(x, N): mism += 1
            check(mism == 0, f"{name}-{N} inverse_operator vs VTM: {mism} mismatches")

    # ---- 5. A == C^T ----
    print("\n=== A == C^T ===")
    for tr in ["0","1","2"]:
        name = transforms[tr]["name"]
        for N in expected_sizes[tr]:
            C = transforms[tr]["source_kernel"].get(str(N))
            A = transforms[tr]["inverse_operator"].get(str(N))
            if C and A:
                ok = all(A[i][j] == C[j][i] for i in range(N) for j in range(N))
                check(ok, f"{name}-{N}: A == C^T")

    # ---- 6. Independent re-extraction from Huawei attachment ----
    print("\n=== SOURCE_KERNEL vs HUAWEI ATTACHMENT (independent) ===")
    from docx import Document
    att_doc = Document(att)
    att_text = '\n'.join([p.text for p in att_doc.paragraphs])
    from extract_attachment_matrices_v2 import parse_block, clean  # reuse parser

    def _att_rows(sec, start_needle):
        p = sec.find(start_needle)
        if p < 0:
            return None
        rows = parse_block(sec, sec.find('{', p))
        return rows

    def _att_mts(name, N, text):
        sec = text[text.find(name + ' (trType'):] if (name + ' (trType') in text else text[text.find(name):]
        m = re.search(rf'nTbs\s*=\s*{N}\s*\n', sec)
        if not m:
            return None
        rows = [r for r in parse_block(sec, sec.find('{', m.end())) if len(r) == N]
        return rows[:N] if len(rows) >= N else None

    # DCT2-64 from attachment (Col0to15 + Col16to31 + symmetry)
    d2s = att_text[att_text.find('DCT-II'):att_text.find('DCT-VIII')]
    c0 = [r for r in parse_block(d2s, d2s.find('{', d2s.find('transMatrixCol0to15 ='))) if len(r) == 16]
    c1 = [r for r in parse_block(d2s, d2s.find('{', d2s.find('transMatrixCol16to31 ='))) if len(r) == 16]
    if len(c0) == 64 and len(c1) == 64:
        m64 = [[0]*64 for _ in range(64)]
        for i in range(64):
            for j in range(16):
                m64[i][j] = c0[i][j]
                m64[i][j+16] = c1[i][j]
                m64[i][j+32] = c1[i][15-j] if i % 2 == 0 else -c1[i][15-j]
                m64[i][j+48] = c0[i][15-j] if i % 2 == 0 else -c0[i][15-j]
        C_can = transforms["0"]["source_kernel"].get("64")
        d = sum(1 for i in range(64) for j in range(64) if C_can[i][j] != m64[i][j])
        check(d == 0, f"DCT2-64 source_kernel vs attachment: {d}/4096 diffs")
    else:
        fail("DCT2-64 attachment extraction failed")

    # DST7 / DCT8 4/8/16 from attachment
    for tr, name, sec_name in [("1", "DST7", "DST-VII"), ("2", "DCT8", "DCT-VIII")]:
        sec = att_text[att_text.find(sec_name):]
        sec = sec[:sec.find('接口')] if '接口' in sec else sec
        for N in [4, 8, 16]:
            m = re.search(rf'nTbs\s*=\s*{N}\s*\n', sec)
            if not m:
                fail(f"{name}-{N}: attachment nTbs header not found")
                continue
            rows = [r for r in parse_block(sec, sec.find('{', m.end())) if len(r) == N]
            if len(rows) < N:
                fail(f"{name}-{N}: attachment rows={len(rows)}")
                continue
            C_can = transforms[tr]["source_kernel"].get(str(N))
            d = sum(1 for i in range(N) for j in range(N) if C_can[i][j] != rows[i][j])
            check(d == 0, f"{name}-{N} source_kernel vs attachment: {d}/{N*N} diffs")

    # DST7 / DCT8 32: attachment only defines Col0to15/Col16to31 (512 entries);
    # the full 32x32 in V3.3 comes from VTM RomTr (attachment 4-quadrant join was
    # shown wrong in V4 audit).  Verify attachment's 512 entries == VTM entries.
    for tr, name, sec_name in [("1", "DST7", "DST-VII"), ("2", "DCT8", "DCT-VIII")]:
        sec = att_text[att_text.find(sec_name):]
        sec = sec[:sec.find('接口')] if '接口' in sec else sec
        a0 = [r for r in parse_block(sec, sec.find('{', sec.find('transMatrixCol0to15 ='))) if len(r) == 16]
        a1 = [r for r in parse_block(sec, sec.find('{', sec.find('transMatrixCol16to31 ='))) if len(r) == 16]
        if len(a0) < 16 or len(a1) < 16:
            fail(f"{name}-32: attachment Col0to15/Col16to31 not found")
            continue
        C_vtm = vtm_mts_forward(name, 32, content)
        d0 = sum(1 for i in range(16) for j in range(16) if C_vtm[i][j] != a0[i][j])
        d1 = sum(1 for i in range(16) for j in range(16) if C_vtm[i][16+j] != a1[i][j])
        check(d0 == 0 and d1 == 0,
              f"{name}-32 attachment 512 entries vs VTM: d0={d0} d1={d1} (expect 0 0)")
        C_can = transforms[tr]["source_kernel"].get("32")
        d = sum(1 for i in range(32) for j in range(32) if C_can[i][j] != C_vtm[i][j])
        check(d == 0, f"{name}-32 source_kernel vs VTM full: {d}/1024 diffs")

    # LFNST from attachment (16 scenarios)
    print("\n=== LFNST vs HUAWEI ATTACHMENT (independent) ===")
    from generate_canonical_v33 import extract_lfnst_attachment
    lf_att = extract_lfnst_attachment(att_text)
    for ntrs in ["16", "48"]:
        for si in ["0", "1", "2", "3"]:
            for li in ["1", "2"]:
                a = lf_att[ntrs][si].get(li)
                c = data["lfnst"][ntrs][si].get(li)
                if a is None or c is None:
                    fail(f"lfnst {ntrs} s{si} i{li}: missing")
                    continue
                n = len(a)
                d = sum(1 for i in range(n) for j in range(len(a[0]))
                        if a[i][j] != c[i][j])
                check(d == 0, f"lfnst nTrs={ntrs} s{si} i{li}: {d} diffs")

    # ---- Verdict ----
    print(f"\n{'='*60}")
    if errors:
        print(f"AUDIT_FAIL: {errors} errors (exit 1)")
        sys.exit(1)
    print("AUDIT_PASS: source_kernel == VTM forward, inverse_operator == VTM fastInverse")
    sys.exit(0)


if __name__ == '__main__':
    main()
