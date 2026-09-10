"""
Regenerate all golden files for its_core_500_tb using the updated vertical-first ref model.
Parses test cases directly from the TB Verilog file and regenerates goldens.
"""

import os
import sys
import re

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ref_model import its_inverse_transform, flatten_raster

TV_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tb', 'test_vectors')
TB_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tb', 'its_core_500_tb.v')

def to_hex(val, bits):
    if val < 0:
        val = val + (1 << bits)
    return format(val & ((1 << bits) - 1), f'0{bits // 4}X')

def parse_tb_test_cases(tb_path):
    """Extract all run_test() calls from the TB file."""
    cases = []
    with open(tb_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Match run_test calls with literal hex paths
    pattern = r'run_test\("([^"]+)",\s*7\'d(\d+),\s*7\'d(\d+),\s*2\'d(\d+),\s*2\'d(\d+),\s*2\'d(\d+),\s*2\'d(\d+),\s*"([^"]+_input\.hex)",\s*"([^"]+_golden\.hex)"\);'
    for m in re.finditer(pattern, content):
        cases.append({
            'name': m.group(1),
            'width': int(m.group(2)),
            'height': int(m.group(3)),
            'tr_hor': int(m.group(4)),
            'tr_ver': int(m.group(5)),
            'set_idx': int(m.group(6)),
            'lfnst_idx': int(m.group(7)),
            'input_file': os.path.join(TV_DIR, os.path.basename(m.group(8))),
            'golden_file': os.path.join(TV_DIR, os.path.basename(m.group(9))),
        })
    return cases

def read_input_hex(input_path, width, height):
    """Read input hex file and reconstruct 2D coefficient matrix."""
    coeff = [[0] * width for _ in range(height)]
    if not os.path.exists(input_path):
        print(f"  WARNING: input file not found: {input_path}")
        return coeff
    with open(input_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            val = int(line, 16)
            addr = (val >> 16) & 0xFFF
            data = val & 0xFFFF
            if data & 0x8000:  # sign extend
                data = data - 0x10000
            r = addr // width
            c = addr % width
            if r < height and c < width:
                coeff[r][c] = data
    return coeff

def write_golden_hex(output_data, golden_path):
    """Write golden output hex file with 10-bit truncation matching RTL."""
    flat = flatten_raster(output_data)
    with open(golden_path, 'w') as f:
        for val in flat:
            # RTL writes col_out_data[9:0] — truncate to 10 bits (2's complement)
            val_10signed = val - ((val >> 9) & 1) * 1024
            val_10signed = (val_10signed + 512) % 1024 - 512  # wrap to [-512, 511]
            f.write(f"{to_hex(val_10signed, 10)}\n")

def main():
    cases = parse_tb_test_cases(TB_FILE)
    print(f"Found {len(cases)} test cases in TB file")

    regenerated = 0
    for case in cases:
        print(f"  {case['name']} (w={case['width']} h={case['height']} "
              f"tr_h={case['tr_hor']} tr_v={case['tr_ver']} "
              f"sidx={case['set_idx']} lfnst={case['lfnst_idx']})")

        coeff = read_input_hex(case['input_file'], case['width'], case['height'])
        non_zero = sum(1 for row in coeff for v in row if v != 0)
        print(f"    non-zero coeffs: {non_zero}")

        output = its_inverse_transform(
            coeff, case['width'], case['height'],
            case['tr_hor'], case['tr_ver'],
            case['set_idx'], case['lfnst_idx']
        )

        write_golden_hex(output, case['golden_file'])
        regenerated += 1

    print(f"\nRegenerated {regenerated} golden files")

if __name__ == '__main__':
    main()
