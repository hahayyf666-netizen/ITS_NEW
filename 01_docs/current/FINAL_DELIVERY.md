# Frozen SAT10 engineering delivery

The submission entry is **its_unified_submission_top**, from
`02_rtl/rtl/its_unified_submission_top.sv`. It explicitly selects
`FINAL_SATURATE=1`. The separate `its_top.v` is the legacy V3.4 entry and is
excluded from the submission source list.

## Source and coefficient files

Compile these six SystemVerilog files:

```text
02_rtl/rtl/its_simple_ram.sv
02_rtl/rtl/its_input_cache_bank.sv
02_rtl/rtl/unified_p4_kernel.sv
02_rtl/rtl/bounded_lfnst_engine.sv
02_rtl/rtl/unified_its_wrapper.sv
02_rtl/rtl/its_unified_submission_top.sv
```

The interface uses `it_info[21:0]`, signed `it_data_in[15:0]`,
`it_data_addr[11:0]`, and `it_data_out[39:0]`. One accepted output beat carries
four complete signed10 samples, lane0 in bits9:0 through lane3 in bits39:30.
The signed10 adapter clamps each signed16 result to [-512,511]. A TU has input,
compute and output phases; the four-point output cadence applies while output
is active and accepted. P4 group II=1 and vector II=N/4 have separate evidence.

The coefficient assets are `rom_coeffs.hex`, `lfnst_coeffs.hex` and
`lfnst_packed_coeffs.hex` in `02_rtl/rtl`. The wrapper's frozen parameter
defaults read them relative to the tool working directory, under
`03_verification/sim`. The ModelSim runner stages these automatically. For a
manual compile/synthesis or a fresh physical run from an extracted package,
run from the source root and stage them first:

```powershell
New-Item -ItemType Directory -Force 03_verification/sim | Out-Null
Copy-Item 02_rtl/rtl/rom_coeffs.hex 03_verification/sim/
Copy-Item 02_rtl/rtl/lfnst_coeffs.hex 03_verification/sim/
Copy-Item 02_rtl/rtl/lfnst_packed_coeffs.hex 03_verification/sim/
```

## Frozen identities and reproduction

- Tested submission source: `cb65bbf1cc2dc9e5e649b2fe8b8affc67435c5a7`.
- Functional/package evidence: `70153eb14d62801531386af35075c770e1bf51f4`.
- DUT arithmetic/control source: `9b33d9f62de49f022765cd594704353edeaa352c`.
- Two-run physical replay evidence: `db8dbedac12ca337f5ae351841f5574363f91174`.
- Profile: `contest_engineering_vtm10_sat10_v2`.
- Canonical profile SHA256: `FEA3ACB18C5C35EB0FD8A8DBF533C3A6BE7536BCC8EF5FDB87135DF512643746`.
- Tested `source.zip` SHA256: `46C55BFFA62A67CDD664FC9C68E210E3FCA1FC3B80093A4A81CEE0C9A19B461F`.

Download `source.zip` and `PACKAGE_MANIFEST.json` from
`05_audit/current/101_final_submission_20261006/package`. The exact tested
archive is preserved; subsequent review and merge commits contain delivery
documentation/evidence and preserved history, without changes to DUT or
verification sources. The archive's own README predates this release note.

Extract into an empty directory, then run:

```powershell
pwsh -File <source>/03_verification/step12d_engineering/run_final_submission_package.ps1 -PackageManifest <package>/PACKAGE_MANIFEST.json -EvidenceDir <new-evidence-directory>
```

PowerShell7, Git, Python3 and licensed ModelSim SE-64 2020.4 are required.
The driver checks all packaged files and generates new vectors and simulator
libraries. The final-source archive contains 3,286 files, including unused
historical TB assets; the explicit compile list selects the qualified tests.

## Acceptance and implementation evidence

Normal and SYNTHESIS regressions passed, including actual submission-top
Gate-C369/45,636 beats, LFNST388/6,724 beats, overflow, real pending-output
stall, two TU, sparse end markers, inflight reset and exactly-once done.
SAT10 exhaustive65,536, Gate-B156, Gate-F13 and LFNST engine1088 passed.

The frozen DUT passed two independent fresh registered-neighbor implementations
at 2.000ns: setup WNS+0.001ns/TNS0, hold WHS+0.011ns/THS0, zero failing
endpoints. Both are Fully Routed with zero routing/DRC errors and no
unconstrained internal endpoints or valid timing exceptions.

Physical top: `step12f_registered_neighbor_harness`; part
`xcku5p-ffvb676-2-e`; Vivado2025.2 build6299465; threads4; user clock
uncertainty0.000ns with tool-derived jitter retained. The frozen flow is
Default synthesis/opt, ExtraNetDelay_high place, AggressiveExplore phys-opt,
NoTimingRelaxation route. The package carries the harness and its own XDC;
the old wrapper OOC XDC is excluded from that flow.

Reference resources: LUT26,272, LUTRAM5,706, FF21,369, DSP320, BRAM/URAM0.
Power1.419W is a vectorless estimate, not measured workload power.

Raw functional evidence is in audit101; first/replay physical reports are in
audit99/100; the final source/archive/log review is in audit102. Large physical
DCPs remain local and have recorded SHA256 identities.

## Accepted scope

`FUNCTIONAL_FREEZE_READY=YES` under the frozen SAT10 engineering contract.
`CORE_TIMING_500MHZ=PASS` under the nominal registered-neighbor contract.
The remaining setup margin is1ps. Package I/O timing, external reset arrival
and additional system clock margin are not qualified.

`official_equivalence=NOT_PROVEN`: SAT10, main-transform scaling and the exact
official LFNST-off H/V subset retain their engineering-contract status.
Malformed sparse-address coverage is not claimed by the invalid-descriptor
test. Historical LOW10 audits and `v3.5-18` are preserved.
