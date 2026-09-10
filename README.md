# ITS_NEW

VVC inverse-transform FPGA study project. This repository is a source snapshot of:

```text
D:\Workspace\ITS_STUDY_V35_STEP12A_R2_1_DCT2_64_2D_PRE
```

Snapshot date: 2026-09-10.

## Current status

- Functional baseline: V3.4 main transform/LFNST fixes remain frozen.
- DCT2-64 standalone P4 kernel: four complete 1D results per cycle, vector interval 16 cycles.
- Standalone R4C kernel OOC timing: 500 MHz post-route closed.
- Current integration gate: V3.5 Step 12A-R2.1 executable 64x64 DCT2 two-dimensional pre-integration model.
- Step 12B wrapper RTL has not started and remains gated on independent review of the R2.1 evidence.

Current model entry points:

```text
python 03_verification/scripts/step12ar2_executable_model.py
python 03_verification/scripts/make_step12ar2_manifest.py
```

See `README_STEP12A_R2.md` and the reports under `03_verification/output/` for details.

## Snapshot exclusions

The original engineering directory is unchanged. This Git snapshot excludes only regenerated tool caches, nested Git metadata, and VTM example private keys. RTL, scripts, ROMs, canonical data, test vectors, reports, logs, and implementation evidence are retained.
