"""
Generate VVC ITS ROM coefficients for all transform types and sizes.
Outputs: rom_coeffs.hex (for $readmemh) and lfnst_coeffs.hex

Transform formulas (VVC standard, 64x scaling):
  DCT2: T(i,j) = 64 (i=0), round(89 * cos(pi*i*(2j+1)/(2N))) (i>0)
  DCT8: T(i,j) = round(64 * cos(pi*(2i+1)*(2j+1)/(4N)))
  DST7: T(i,j) = round(64 * sin(pi*(i+1)*(j+1)/(N+1)))

LFNST: 16 scenarios from official document
  nTrs=16 (tu_width<8 or tu_height<8): 16x16 matrix, 16 outputs
  nTrs=48 (tu_width>=8 and tu_height>=8): 16x16 matrix, 16 outputs rearranged into 3 blocks

Address mapping:
  addr = base_addr(tr_type, size) + row * size + col

  DCT2 (tr_type=0): sizes 4,8,16,32,64
  DCT8 (tr_type=1): sizes 4,8,16,32
  DST7 (tr_type=2): sizes 4,8,16,32
"""

import math
import os
import re
from typing import List, Tuple, Dict

# ============================================================
# Matrix generation
# ============================================================

def gen_dct2(N: int) -> List[List[int]]:
    """Generate N-point DCT2 matrix."""
    T = [[0] * N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            if i == 0:
                T[i][j] = 64
            else:
                angle = math.pi * i * (2 * j + 1) / (2 * N)
                T[i][j] = round(89 * math.cos(angle))
    return T


def gen_dct8(N: int) -> List[List[int]]:
    """Generate N-point DCT8 matrix."""
    T = [[0] * N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            angle = math.pi * (2 * i + 1) * (2 * j + 1) / (4 * N)
            T[i][j] = round(64 * math.cos(angle))
    return T


def gen_dst7(N: int) -> List[List[int]]:
    """Generate N-point DST7 matrix."""
    T = [[0] * N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            angle = math.pi * (i + 1) * (j + 1) / (N + 1)
            T[i][j] = round(64 * math.sin(angle))
    return T


# ============================================================
# LFNST matrix parsing from official document
# ============================================================

def parse_lfnst_matrix_rows(text: str) -> List[List[int]]:
    """Parse matrix rows from text like { 1 2 3 } { 4 5 6 } ..."""
    rows = []
    for match in re.finditer(r'\{([^{}]+)\}', text):
        row_str = match.group(1).strip()
        if row_str:
            # Replace Unicode minus variants with regular minus
            row_str = row_str.replace('−', '-')  # U+2212
            row_str = row_str.replace('–', '-')  # en-dash
            row_str = row_str.replace('—', '-')  # em-dash
            try:
                vals = [int(x) for x in row_str.split()]
                rows.append(vals)
            except ValueError:
                pass
    return rows


def parse_lfnst_from_document(doc_path: str) -> Dict[Tuple[int, int, int], List[List[int]]]:
    """Parse all 16 LFNST scenarios from the official document.

    Returns dict: (nTrs, lfnstTrSetIdx, lfnst_idx) -> Nx16 matrix
      nTrs=16: 16x16 matrix
      nTrs=48: 48x16 matrix (3 Col blocks of 16x16)
    """
    with open(doc_path, 'r', encoding='utf-8') as f:
        content = f.read()

    matrices = {}

    # Find all scenario headers
    pattern = r'nTrs\s*=\s*(\d+)\D+lfnstTrSetIdx\s*=\s*(\d+)\D+lfnst_idx\s*=\s*(\d+)'
    all_matches = list(re.finditer(pattern, content))

    for idx, m in enumerate(all_matches):
        ntrs = int(m.group(1))
        set_idx = int(m.group(2))
        lfnst_idx = int(m.group(3))

        # Limit search to this scenario's section
        section_end = all_matches[idx + 1].start() if idx + 1 < len(all_matches) else len(content)
        section = content[m.end():section_end]

        if ntrs == 16:
            # nTrs=16: single 16x16 matrix
            block_start = section.find('{')
            if block_start == -1:
                continue
            depth = 0
            end = -1
            for i in range(block_start, len(section)):
                if section[i] == '{':
                    depth += 1
                elif section[i] == '}':
                    depth -= 1
                    if depth == 0:
                        end = i
                        break
            if end == -1:
                continue
            block = section[block_start:end + 1]
            matrix = parse_lfnst_matrix_rows(block)
            if matrix:
                key = (ntrs, set_idx, lfnst_idx)
                matrices[key] = matrix
                print(f"  Parsed nTrs={ntrs}, lfnstTrSetIdx={set_idx}, "
                      f"lfnst_idx={lfnst_idx}: {len(matrix)}x{len(matrix[0])}")

        elif ntrs == 48:
            # nTrs=48: three 16x16 Col blocks -> 48x16 matrix
            # Find all { ... } matrix blocks in this section
            blocks = []
            pos = 0
            while pos < len(section):
                block_start = section.find('{', pos)
                if block_start == -1:
                    break
                # Check if this is a matrix row block (starts with "{  " or "{ -")
                # Skip lone "{" that are part of text like "lowFreqTransMatrixCol0to15 ="
                depth = 0
                end = -1
                for i in range(block_start, len(section)):
                    if section[i] == '{':
                        depth += 1
                    elif section[i] == '}':
                        depth -= 1
                        if depth == 0:
                            end = i
                            break
                if end == -1:
                    break
                block = section[block_start:end + 1]
                rows = parse_lfnst_matrix_rows(block)
                if rows and len(rows) >= 16 and len(rows[0]) >= 16:
                    blocks.append(rows)
                pos = end + 1

            if len(blocks) >= 3:
                # Combine 3 Col blocks into 48x16 matrix
                matrix = blocks[0][:16] + blocks[1][:16] + blocks[2][:16]
                key = (ntrs, set_idx, lfnst_idx)
                matrices[key] = matrix
                print(f"  Parsed nTrs={ntrs}, lfnstTrSetIdx={set_idx}, "
                      f"lfnst_idx={lfnst_idx}: {len(matrix)}x{len(matrix[0])}")
            else:
                print(f"  WARNING: nTrs={ntrs}, lfnstTrSetIdx={set_idx}, "
                      f"lfnst_idx={lfnst_idx}: found {len(blocks)} blocks, expected 3")

    return matrices


# ============================================================
# Address mapping
# ============================================================

TRANSFORM_SIZES = {
    0: [4, 8, 16, 32, 64],   # DCT2
    1: [4, 8, 16, 32],        # DCT8
    2: [4, 8, 16, 32],        # DST7
}

TRANSFORM_NAMES = {0: "DCT2", 1: "DCT8", 2: "DST7"}


def compute_base_addrs() -> Dict[Tuple[int, int], int]:
    """Compute base addresses for each (tr_type, size) pair."""
    base = 0
    addrs = {}
    for tr_type in range(3):
        for size in TRANSFORM_SIZES[tr_type]:
            addrs[(tr_type, size)] = base
            base += size * size
    return addrs, base


def to_signed_16bit(val: int) -> int:
    """Convert to 16-bit signed representation for hex output."""
    if val < 0:
        val = val + 65536
    return val & 0xFFFF


# ============================================================
# Generate ROM hex file
# ============================================================

def generate_rom_hex(filename: str):
    """Generate rom_coeffs.hex for all transform kernels."""
    base_addrs, total_size = compute_base_addrs()

    # Initialize all entries to 0
    coeffs = [0] * total_size

    # Fill in coefficients
    for tr_type in range(3):
        for size in TRANSFORM_SIZES[tr_type]:
            base = base_addrs[(tr_type, size)]

            if tr_type == 0:
                matrix = gen_dct2(size)
            elif tr_type == 1:
                matrix = gen_dct8(size)
            else:
                matrix = gen_dst7(size)

            for i in range(size):
                for j in range(size):
                    coeffs[base + i * size + j] = matrix[i][j]

    # Write hex file (16-bit values, one per line)
    with open(filename, 'w') as f:
        f.write(f"// VVC ITS ROM coefficients\n")
        f.write(f"// Total entries: {total_size}\n")
        f.write(f"// Format: one 16-bit hex value per line\n\n")

        # Address map comment
        f.write(f"// Address map:\n")
        for tr_type in range(3):
            for size in TRANSFORM_SIZES[tr_type]:
                base = base_addrs[(tr_type, size)]
                f.write(f"//   {TRANSFORM_NAMES[tr_type]}-{size}: addr {base}..{base + size*size - 1}\n")
        f.write(f"\n")

        for i, val in enumerate(coeffs):
            f.write(f"{to_signed_16bit(val):04X}\n")

    print(f"Generated {filename}: {total_size} entries ({total_size * 2} bytes)")

    # Print address map
    print("\nAddress map:")
    for tr_type in range(3):
        for size in TRANSFORM_SIZES[tr_type]:
            base = base_addrs[(tr_type, size)]
            print(f"  {TRANSFORM_NAMES[tr_type]}-{size:2d}: {base:5d} .. {base + size*size - 1:5d}")

    return base_addrs, total_size


# ============================================================
# Generate LFNST hex file
# ============================================================

def generate_lfnst_hex(filename: str, doc_path: str):
    """Generate lfnst_coeffs.hex for LFNST matrices from official document.

    ROM layout (8192 entries, 13-bit address):
      nTrs=16 [0..2047]:   4 setIdx x 2 idx x 16x16 = 8 x 256
      nTrs=48 [2048..8191]: 4 setIdx x 2 idx x 48x16 = 8 x 768

    Address formula (must match RTL in its_lfnst.v):
      nTrs=16: lfnstTrSetIdx * 512 + (lfnst_idx - 1) * 256 + row * 16 + col
      nTrs=48: 2048 + (lfnstTrSetIdx * 2 + (lfnst_idx - 1)) * 768 + row * 16 + col
    """
    print("\nParsing LFNST matrices from official document...")
    matrices = parse_lfnst_from_document(doc_path)

    # Verify all 16 scenarios present
    expected = []
    for ntrs in [16, 48]:
        for set_idx in range(4):
            for idx in [1, 2]:
                expected.append((ntrs, set_idx, idx))

    missing = [k for k in expected if k not in matrices]
    if missing:
        print(f"WARNING: Missing {len(missing)} scenarios: {missing}")
        return

    # Build ROM array (8192 entries)
    coeffs = [0] * 8192

    for (ntrs, set_idx, lfnst_idx), matrix in matrices.items():
        if ntrs == 16:
            base = set_idx * 512 + (lfnst_idx - 1) * 256
            num_rows = 16
        else:  # ntrs == 48
            base = 2048 + (set_idx * 2 + (lfnst_idx - 1)) * 768
            num_rows = 48

        for row in range(num_rows):
            for col in range(16):
                addr = base + row * 16 + col
                coeffs[addr] = matrix[row][col]

    # Write hex file
    with open(filename, 'w') as f:
        f.write(f"// VVC LFNST ROM coefficients (from official document)\n")
        f.write(f"// Total entries: 8192\n\n")
        f.write(f"// nTrs=16 region [0..2047] (8 scenarios x 256 entries):\n")
        for set_idx in range(4):
            for idx in [1, 2]:
                base = set_idx * 512 + (idx - 1) * 256
                f.write(f"//   lfnstTrSetIdx={set_idx}, lfnst_idx={idx}: "
                        f"addr {base}..{base + 255}\n")
        f.write(f"\n// nTrs=48 region [2048..8191] (8 scenarios x 768 entries):\n")
        for set_idx in range(4):
            for idx in [1, 2]:
                base = 2048 + (set_idx * 2 + (idx - 1)) * 768
                f.write(f"//   lfnstTrSetIdx={set_idx}, lfnst_idx={idx}: "
                        f"addr {base}..{base + 767}\n")
        f.write(f"\n")

        for val in coeffs:
            f.write(f"{to_signed_16bit(val):04X}\n")

    print(f"Generated {filename}: 8192 entries (16384 bytes)")

    # Verify address mapping matches RTL
    print("\nAddress map verification (must match RTL rom_base):")
    for set_idx in range(4):
        for idx in [1, 2]:
            base16 = set_idx * 512 + (idx - 1) * 256
            base48 = 2048 + (set_idx * 2 + (idx - 1)) * 768
            print(f"  setIdx={set_idx} idx={idx}: nTrs=16 base={base16}, nTrs=48 base={base48}")


# ============================================================
# Generate Verilog ROM module (alternative to hex file)
# ============================================================

def generate_rom_verilog(filename: str, base_addrs: Dict, total_size: int):
    """Generate Verilog ROM module with $readmemh."""
    code = """\
// ===================================================================
// ITS Transform Kernel ROM
// Auto-generated by gen_rom_coeffs.py
// Supports DCT2(4/8/16/32/64), DCT8(4/8/16/32), DST7(4/8/16/32)
// ===================================================================

module its_rom (
    input  wire        clk,
    input  wire [13:0] addr,      // Flat address
    output reg  [15:0] coeff      // Coefficient output (signed)
);

    // ROM storage
    reg [15:0] rom [0:{max_addr}];

    // Load coefficients from hex file
    initial begin
        $readmemh("rom_coeffs.hex", rom);
    end

    // Synchronous read (1 cycle latency)
    always @(posedge clk) begin
        coeff <= rom[addr];
    end

endmodule
""".format(max_addr=total_size - 1)

    with open(filename, 'w') as f:
        f.write(code)

    print(f"Generated {filename}")


def generate_lfnst_rom_verilog(filename: str):
    """Generate LFNST ROM module with $readmemh."""
    code = """\
// ===================================================================
// ITS LFNST Transform Kernel ROM
// Auto-generated by gen_rom_coeffs.py
// 8192 entries: nTrs=16 (8x256) + nTrs=48 (8x768)
// ===================================================================

module its_lfnst_rom (
    input  wire        clk,
    input  wire [12:0] addr,      // Address (0-8191)
    output reg  [15:0] coeff      // Coefficient output (signed)
);

    // ROM storage: 8192 entries
    reg [15:0] rom [0:8191];

    // Load coefficients from hex file
    initial begin
        $readmemh("lfnst_coeffs.hex", rom);
    end

    // Synchronous read (1 cycle latency)
    always @(posedge clk) begin
        coeff <= rom[addr];
    end

endmodule
"""

    with open(filename, 'w') as f:
        f.write(code)

    print(f"Generated {filename}")


# ============================================================
# Main
# ============================================================

if __name__ == "__main__":
    # Output directory (same as script directory, or rtl/)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)
    rtl_dir = os.path.join(project_dir, 'rtl')
    doc_path = os.path.join(project_dir, 'output', 'lfnst_doc.txt')

    print("=" * 60)
    print("VVC ITS ROM Coefficient Generator")
    print("=" * 60)

    # Generate transform kernel ROM
    print("\n--- Transform Kernel ROM ---")
    hex_path = os.path.join(rtl_dir, 'rom_coeffs.hex')
    base_addrs, total_size = generate_rom_hex(hex_path)

    # Generate LFNST ROM (from official document)
    print("\n--- LFNST ROM (from official document) ---")
    lfnst_hex_path = os.path.join(rtl_dir, 'lfnst_coeffs.hex')
    generate_lfnst_hex(lfnst_hex_path, doc_path)

    # Generate Verilog modules
    print("\n--- Verilog Modules ---")
    rom_v_path = os.path.join(rtl_dir, 'its_rom.v')
    generate_rom_verilog(rom_v_path, base_addrs, total_size)

    lfnst_rom_v_path = os.path.join(rtl_dir, 'its_lfnst_rom.v')
    generate_lfnst_rom_verilog(lfnst_rom_v_path)

    # Print some sample matrices for verification
    print("\n" + "=" * 60)
    print("Verification: Sample matrices")
    print("=" * 60)

    for name, gen_fn in [("DCT2-4", lambda: gen_dct2(4)),
                          ("DCT8-4", lambda: gen_dct8(4)),
                          ("DST7-4", lambda: gen_dst7(4))]:
        print(f"\n{name}:")
        for row in gen_fn():
            print(f"  {[f'{v:4d}' for v in row]}")

    print("\nDone!")
