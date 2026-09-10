"""Audit test_vectors directory: every file has content, correct dimensions, parseable hex."""
import os, sys

def fail(msg):
    print(f"  FAIL: {msg}")
    global _errors; _errors += 1

def main(tv_dir):
    global _errors; _errors = 0
    empties = []

    if not os.path.isdir(tv_dir):
        print(f"FATAL: {tv_dir} not found")
        sys.exit(1)

    # Check regression_index.txt
    idx_path = os.path.join(tv_dir, "regression_index.txt")
    if not os.path.exists(idx_path):
        fail(f"regression_index.txt missing")
        sys.exit(1)

    with open(idx_path) as f:
        idx_lines = [l.strip().split() for l in f if l.strip()]

    case_ids = []
    for parts in idx_lines:
        if len(parts) < 8: continue
        cid, name, w, h, tr_h, tr_v, sidx, lfnst = parts[0], parts[1], int(parts[2]), int(parts[3]), \
            int(parts[4]), int(parts[5]), int(parts[6]), int(parts[7])
        case_ids.append((cid, w, h))

    print(f"Regression index: {len(case_ids)} cases")
    check_count = len(case_ids)

    # Check all files in directory
    all_files = sorted(os.listdir(tv_dir))
    for f in all_files:
        fp = os.path.join(tv_dir, f)
        if not os.path.isfile(fp): continue
        sz = os.path.getsize(fp)

        if sz == 0:
            empties.append(f)
            # boundary_zero input is allowed to be empty
            if f != "boundary_zero_4x4_input.hex":
                fail(f"Empty file (not boundary_zero): {f}")
            continue

        if f.endswith("_golden.hex") or f.endswith("_input.hex"):
            with open(fp) as fh:
                lines = [l.strip() for l in fh if l.strip()]
            if not lines:
                fail(f"Empty after strip: {f}")
                continue

    # Check regression cases
    missing = []
    for cid, w, h in case_ids:
        for suffix in ["_input.hex", "_golden.hex"]:
            fn = f"case_{cid}{suffix}"
            fp = os.path.join(tv_dir, fn)
            if not os.path.exists(fp):
                missing.append(fn)
            elif os.path.getsize(fp) == 0:
                fail(f"Empty case file: {fn}")

    if missing:
        for m in missing[:10]:
            fail(f"Missing: {m}")
        if len(missing) > 10:
            fail(f"... and {len(missing)-10} more missing")

    # Check golden dimensions
    dim_errors = 0
    for cid, w, h in case_ids:
        fn = f"case_{cid}_golden.hex"
        fp = os.path.join(tv_dir, fn)
        if not os.path.exists(fp) or os.path.getsize(fp) == 0:
            continue
        with open(fp) as f:
            glines = [l.strip() for l in f if l.strip()]
        expected = w * h
        if len(glines) != expected:
            dim_errors += 1
            if dim_errors <= 3:
                fail(f"{fn}: {len(glines)} golden lines, expected {expected} (w={w} h={h})")
    if dim_errors > 3:
        fail(f"{dim_errors} cases have wrong golden dimensions")

    # Check hex parseability
    parse_errs = 0
    for f in sorted(all_files):
        if not (f.endswith("_golden.hex") or f.endswith("_input.hex")): continue
        fp = os.path.join(tv_dir, f)
        sz = os.path.getsize(fp)
        if sz == 0: continue
        if f == "boundary_zero_4x4_input.hex": continue
        with open(fp) as fh:
            for lineno, line in enumerate(fh, 1):
                line = line.strip()
                if not line: continue
                try:
                    int(line, 16)
                except ValueError:
                    parse_errs += 1
                    if parse_errs <= 3:
                        fail(f"{f}:{lineno} cannot parse hex: {line[:40]}")
    if parse_errs > 3:
        fail(f"{parse_errs} hex parse errors")

    print(f"\nEmpty files: {len(empties)} (boundary_zero allowed)")
    print(f"Dimension errors: {dim_errors}")
    print(f"Parse errors: {parse_errs}")

    if _errors:
        print(f"\nAUDIT FAIL: {_errors} errors")
        sys.exit(1)
    else:
        print(f"\nAUDIT PASS: {len(all_files)} files validated, {len(case_ids)} regression cases OK")
        sys.exit(0)

if __name__ == "__main__":
    import sys
    tv = sys.argv[1] if len(sys.argv) > 1 else "D:/Workspace/ITS_STUDY/03_verification/tb/test_vectors"
    main(tv)
