# Full spatial reconstruction repair delivery

Production compilation uses six SystemVerilog files in 02_rtl/rtl: its_simple_ram.sv, its_input_cache_bank.sv, unified_p4_kernel.sv, bounded_lfnst_engine.sv, unified_its_wrapper.sv and its_unified_submission_top.sv.

The three coefficient files in that directory are rom_coeffs.hex, lfnst_coeffs.hex and lfnst_packed_coeffs.hex. Stage copies under 03_verification/sim for a manual physical run. Functional runners create their own simulator work directories and coefficient copies.

03_verification/regression_baseline/081efa6 is a byte-identified expected-failure fixture, excluded from production compilation. Historical archive manifests describe historical source and must not be used as the repair inventory.

    pwsh -File 03_verification/step12d_engineering/qualify_full_spatial_repair.ps1 -EvidenceDir <new-directory>

The individual run_full_spatial_regression.ps1 accepts -Compiler and -NativeExe. Its native adapter calls the included unmodified VTM inverse functions after applying the declared frequency-input mask. Fast primitives assume out-of-support coefficients are already zero. Both corrected Python models are compared with full native spatial outputs. LFNST preprocessing uses the source-checked layout model.

    New-Item -ItemType Directory -Force 03_verification/sim | Out-Null
    Copy-Item 02_rtl/rtl/rom_coeffs.hex 03_verification/sim/
    Copy-Item 02_rtl/rtl/lfnst_coeffs.hex 03_verification/sim/
    Copy-Item 02_rtl/rtl/lfnst_packed_coeffs.hex 03_verification/sim/
    pwsh -File 03_verification/vivado/run_step12f_registered_neighbor.ps1 -EvidenceDir <new-directory>

Physical top: step12f_registered_neighbor_harness; part xcku5p-ffvb676-2-e; period2ns; user uncertainty0ns with tool jitter. The new implementation must supply setup/hold, routing, resource and power evidence. official_equivalence=NOT_PROVEN; official SAT10/scaling/profile and package-level timing ambiguities remain separate.

Published execution evidence: [05_audit/current/103_full_spatial_repair_20261029](../../05_audit/current/103_full_spatial_repair_20261029/README.md). Local snapshot IDs are mapped by the audit SOURCE_EQUIVALENCE.json.
