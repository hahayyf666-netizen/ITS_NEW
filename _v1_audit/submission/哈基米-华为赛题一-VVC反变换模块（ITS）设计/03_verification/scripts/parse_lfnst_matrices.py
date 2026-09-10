"""
Parse LFNST matrices from the competition attachment document
and generate lfnst_coeffs.hex for the ROM.

16 scenarios:
  nTrs=16: 4 lfnstTrSetIdx x 2 lfnst_idx = 8 scenarios, each 16x16 = 256 entries
  nTrs=48: 4 lfnstTrSetIdx x 2 lfnst_idx = 8 scenarios, each 48x16 = 768 entries
  Total: 8*256 + 8*768 = 8192 entries

ROM address layout:
  nTrs=16 region [0..2047]:
    base = lfnstTrSetIdx * 512 + (lfnst_idx - 1) * 256
    Each scenario: 16 rows x 16 cols = 256 entries
    Address = base + row * 16 + col

  nTrs=48 region [2048..8191]:
    base = 2048 + lfnstTrSetIdx * 2048 + (lfnst_idx - 1) * 1024
    Each scenario: 48 rows x 16 cols = 768 entries
    Address = base + row * 16 + col
"""

import re
import os


def parse_matrix_block(text):
    """Parse a matrix block like { { 1 2 3 } { 4 5 6 } } into 2D list."""
    rows = []
    # Find all row patterns: { val val val ... }
    for match in re.finditer(r'\{([^{}]+)\}', text):
        row_str = match.group(1).strip()
        if row_str:
            vals = [int(x) for x in row_str.split()]
            rows.append(vals)
    return rows


def parse_lfnst_doc(filename):
    """Parse the LFNST document and extract all 16 scenario matrices."""
    with open(filename, 'r', encoding='utf-8') as f:
        content = f.read()

    scenarios = {}

    # Split by scenario headers
    # Pattern: 场景N：nTrs = X，lfnstTrSetIdx = Y，lfnst_idx = Z
    scenario_pattern = re.compile(
        r'场景(\d+)：nTrs\s*=\s*(\d+)，lfnstTrSetIdx\s*=\s*(\d+)，lfnst_idx\s*=\s*(\d+)'
    )

    # Find all scenario positions
    matches = list(scenario_pattern.finditer(content))

    for idx, match in enumerate(matches):
        scene_num = int(match.group(1))
        ntrs = int(match.group(2))
        set_idx = int(match.group(3))
        lfnst_idx = int(match.group(4))

        # Extract text from this scenario to the next one
        start = match.end()
        end = matches[idx + 1].start() if idx + 1 < len(matches) else len(content)
        section = content[start:end]

        if ntrs == 16:
            # nTrs=16: single 16x16 matrix
            matrix = parse_matrix_block(section)
            if len(matrix) != 16 or any(len(r) != 16 for r in matrix):
                print(f"WARNING: Scenario {scene_num} (nTrs=16, set={set_idx}, idx={lfnst_idx}): "
                      f"expected 16x16, got {len(matrix)}x{len(matrix[0]) if matrix else 0}")
            scenarios[(ntrs, set_idx, lfnst_idx)] = matrix

        elif ntrs == 48:
            # nTrs=48: three sub-matrices (Col0to15, Col16to31, Col32to47)
            # Each is 16x16, combined into 48x16
            sub_matrices = []
            # Find all matrix blocks
            all_blocks = re.findall(
                r'lowFreqTransMatrix(?:Col\d+to\d+)?\s*=\s*\n?\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}',
                section
            )

            if len(all_blocks) == 3:
                for block in all_blocks:
                    sub_matrices.append(parse_matrix_block('{' + block + '}'))
            else:
                # Fallback: parse all matrix blocks in order
                blocks = list(re.finditer(r'\{(\s*\{[^{}]+\}\s*)+\}', section))
                for block in blocks:
                    m = parse_matrix_block(block.group(0))
                    if m and len(m) == 16 and len(m[0]) == 16:
                        sub_matrices.append(m)

            if len(sub_matrices) == 3:
                # Combine 3 x (16x16) into 48x16
                combined = sub_matrices[0] + sub_matrices[1] + sub_matrices[2]
                scenarios[(ntrs, set_idx, lfnst_idx)] = combined
            else:
                print(f"WARNING: Scenario {scene_num} (nTrs=48, set={set_idx}, idx={lfnst_idx}): "
                      f"found {len(sub_matrices)} sub-matrices, expected 3")

    return scenarios


def compute_rom_address(ntrs, set_idx, lfnst_idx, row, col):
    """Compute ROM address for a given scenario and position.

    ROM layout (8192 entries total):
      nTrs=16 [0..2047]:
        Each scenario: 16x16 = 256 entries
        4 setIdx x 2 lfnst_idx = 8 scenarios x 256 = 2048
        base = set_idx * 512 + (lfnst_idx - 1) * 256

      nTrs=48 [2048..8191]:
        Each scenario: 48x16 = 768 entries
        4 setIdx x 2 lfnst_idx = 8 scenarios x 768 = 6144
        base = 2048 + set_idx * 2048 + (lfnst_idx - 1) * 1024
        (set0: 2048..3071, set1: 4096..5119, set2: 6144..7167, set3: 8192..9215)
        Wait - that's wrong. Let me recalculate.
        Actually: 8 scenarios x 768 = 6144, stored contiguously.
        base = 2048 + scenario_index * 768
        scenario_index = set_idx * 2 + (lfnst_idx - 1)
    """
    if ntrs == 16:
        base = set_idx * 512 + (lfnst_idx - 1) * 256
    else:  # ntrs == 48
        scenario_index = set_idx * 2 + (lfnst_idx - 1)
        base = 2048 + scenario_index * 768
    return base + row * 16 + col


def to_signed_16bit(val):
    """Convert to 16-bit signed representation for hex output."""
    if val < 0:
        val = val + 65536
    return val & 0xFFFF


def generate_hex(scenarios, filename):
    """Generate the LFNST ROM hex file."""
    # Initialize all entries to 0
    rom = [0] * 8192

    for (ntrs, set_idx, lfnst_idx), matrix in scenarios.items():
        for row_idx, row in enumerate(matrix):
            for col_idx, val in enumerate(row):
                addr = compute_rom_address(ntrs, set_idx, lfnst_idx, row_idx, col_idx)
                rom[addr] = val

    # Write hex file
    with open(filename, 'w') as f:
        f.write("// VVC LFNST ROM coefficients (from competition attachment)\n")
        f.write(f"// Total entries: 8192\n")
        f.write(f"// nTrs=16: 4 setIdx x 2 lfnst_idx x 16x16 = 2048 entries [addr 0..2047]\n")
        f.write(f"// nTrs=48: 4 setIdx x 2 lfnst_idx x 48x16 = 6144 entries [addr 2048..8191]\n\n")

        # Address map
        f.write("// Address map:\n")
        for ntrs in [16, 48]:
            for set_idx in range(4):
                for lfnst_idx in [1, 2]:
                    base = compute_rom_address(ntrs, set_idx, lfnst_idx, 0, 0)
                    size = 256 if ntrs == 16 else 768
                    f.write(f"//   nTrs={ntrs}, set={set_idx}, idx={lfnst_idx}: "
                            f"addr {base}..{base + size - 1}\n")
        f.write("\n")

        for val in rom:
            f.write(f"{to_signed_16bit(val):04X}\n")

    # Count non-zero entries
    non_zero = sum(1 for v in rom if v != 0)
    print(f"Generated {filename}: 8192 entries, {non_zero} non-zero")

    return rom


def verify_rom(rom, scenarios):
    """Verify ROM contents against scenarios."""
    errors = 0
    for (ntrs, set_idx, lfnst_idx), matrix in scenarios.items():
        for row_idx, row in enumerate(matrix):
            for col_idx, expected in enumerate(row):
                addr = compute_rom_address(ntrs, set_idx, lfnst_idx, row_idx, col_idx)
                actual = rom[addr]
                if actual != expected:
                    print(f"MISMATCH at addr {addr}: expected {expected}, got {actual} "
                          f"(nTrs={ntrs}, set={set_idx}, idx={lfnst_idx}, "
                          f"row={row_idx}, col={col_idx})")
                    errors += 1
    return errors


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)
    doc_path = os.path.join(project_dir, 'output', 'lfnst_doc.txt')
    rtl_dir = os.path.join(project_dir, 'rtl')
    sim_dir = os.path.join(project_dir, 'sim')

    print("=" * 60)
    print("VVC LFNST ROM Generator (from competition attachment)")
    print("=" * 60)

    # Parse matrices
    print("\nParsing LFNST matrices...")
    scenarios = parse_lfnst_doc(doc_path)

    print(f"\nFound {len(scenarios)} scenarios:")
    for (ntrs, set_idx, lfnst_idx), matrix in sorted(scenarios.items()):
        rows = len(matrix)
        cols = len(matrix[0]) if matrix else 0
        print(f"  nTrs={ntrs}, set={set_idx}, idx={lfnst_idx}: {rows}x{cols}")

    # Generate hex files
    print("\nGenerating hex files...")
    hex_path = os.path.join(rtl_dir, 'lfnst_coeffs.hex')
    rom = generate_hex(scenarios, hex_path)

    # Copy to sim directory
    sim_hex_path = os.path.join(sim_dir, 'lfnst_coeffs.hex')
    import shutil
    shutil.copy2(hex_path, sim_hex_path)
    print(f"Copied to {sim_hex_path}")

    # Verify
    print("\nVerifying ROM contents...")
    errors = verify_rom(rom, scenarios)
    if errors == 0:
        print("VERIFICATION PASSED: All entries match.")
    else:
        print(f"VERIFICATION FAILED: {errors} mismatches.")

    # Print sample entries for spot check
    print("\nSpot check - first few entries of each nTrs=16 scenario:")
    for set_idx in range(4):
        for lfnst_idx in [1, 2]:
            base = compute_rom_address(16, set_idx, lfnst_idx, 0, 0)
            vals = [rom[base + i] for i in range(4)]
            signed_vals = [v if v < 32768 else v - 65536 for v in vals]
            print(f"  set={set_idx}, idx={lfnst_idx}: [{', '.join(str(v) for v in signed_vals)}] ...")

    print("\nDone!")


if __name__ == "__main__":
    main()
