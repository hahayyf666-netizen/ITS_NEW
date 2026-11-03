# Unified VVC ITS — full spatial reconstruction repair

This branch fixes missing lower spatial rows when V has reduced frequency-input support. A 64x64 DCT2 TU with only DC=512 now reconstructs all4096 samples as16 under the selected scaling.

Production top: 02_rtl/rtl/its_unified_submission_top.sv. Profile: contest_engineering_vtm10_sat10_v2, shifts7/10, signed16 clipping, SAT10[-512,511]. official_equivalence=NOT_PROVEN.

Run functional qualification from the source root:

    pwsh -File 03_verification/step12d_engineering/qualify_full_spatial_repair.ps1 -EvidenceDir <new-directory>

The runner executes four profile/Python stages,36 existing simulations,6 new normal/SYNTHESIS simulations, a frozen-DUT expected-failure control, native VTM checks and cycle measurements. It compiles the included unmodified VTM subset using the configured C++17 MinGW compiler. ModelSim SE-64 2020.4, Python3, Git and PowerShell7 are required.

Fresh physical implementation is separate:

    pwsh -File 03_verification/vivado/run_step12f_registered_neighbor.ps1 -EvidenceDir <new-directory>

Stage the three coefficient hex files in 03_verification/sim first. Functional runners stage their own copies. The repair delivery manifest records new timing/PPA evidence; old implementation PASS records do not qualify changed RTL.

[Repair design](01_docs/current/FULL_SPATIAL_REPAIR.md), [delivery](01_docs/current/FINAL_DELIVERY.md), [acceptance](01_docs/current/FINAL_SUBMISSION_ACCEPTANCE.md).

Current repair evidence: [full spatial repair audit](05_audit/current/103_full_spatial_repair_20261029/README.md).
