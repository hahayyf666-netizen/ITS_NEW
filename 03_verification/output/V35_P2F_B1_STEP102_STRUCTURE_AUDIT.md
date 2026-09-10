# V35 P2F-B1 Step 10.2 Structure Audit

Status: **PASS** (source-level only; Vivado NOT RUN)

## Mechanically checked structure
- Active RTL: `D:\Workspace\ITS_STUDY_V35_P2F_B2_R1\02_rtl\rtl\p2f_dct2_64_b1_step102.sv`
- Multiplier lanes: **128** (required 128)
- Generated operations: **1368** (required 1368)
- Shared reduction slots: stage0=64, stage1=32, stage2=16, stage3=8, stage4=4
- Butterfly physical capacities: N4/N8/N16/N32/N64 = **4/8/16/16/8**
- Generated reduction events: 1304; butterfly events: 124
- A/B vector buffers: **2** declarations, 2048 bits
- Dot context: 5120 bits; shared signal store: 4960 bits
- Final reorder storage: 6656 bits
- Raw/biased/shifted memories are under `ifndef SYNTHESIS` (simulation-only).

## Forbidden replicated structures
- term_mem / red_l / dot_acc_next: **absent**
- No per-bank reduction arrays; reduction arrays are single shared stage resources.

## R1 → R2 integrity
- Common files compared: 27735; changed files in R2: 1
- Extra files in R2: 108; missing files in R2: 0
- Full SHA-256 comparison: `D:\Workspace\ITS_STUDY_V35_P2F_B2_R1\_step102_audit\r1_r2_common_sha256.json`
- Expected changed common file (testbench binding): `['03_verification/tb/p2f_dct2_64_b1_tb.sv']`
- R1 is not modified by this step; R2 is the only work directory.

## Gate result
- Functional RTL simulation: see `V35_P2F_B1_STEP102_FUNCTIONAL_REPORT.md`
- Source structure: **PASS**
- Vivado/synthesis/place/route/power: **NOT RUN by instruction**
