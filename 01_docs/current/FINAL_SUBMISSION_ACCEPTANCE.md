# Final submission acceptance

Baseline db8dbedac12ca337f5ae351841f5574363f91174; DUT source 9b33d9f62de49f022765cd594704353edeaa352c.
Profile SAT10 v2; official equivalence NOT_PROVEN.

| Requirement | Evidence gate |
|---|---|
| DCT2/DST7/DCT8, rectangles | Gate-B156; actual submission top Gate-C369/45636 |
| LFNST layout/nonZeroSize | engine1088; actual top388/6724; scatter/tail-poison/layout |
| sparse input/end-marker | empty end, end overlapping commit, final-data+end |
| signed10 output/40-bit packing | exhaustive65536; positive/negative top overflow |
| backpressure/order/ownership/done | real pending stall, two TU, numerical scoreboard |
| reset reuse | inflight reset followed by fresh zero TU; existing kernel reset suite |
| invalid descriptor | sticky error and illegal descriptor rejection |
| throughput | 13 modes, group II=1, vector II=N/4 |
| nominal500MHz | audits99/100, two independent registered-neighbor passes |

External output cadence and kernel II are distinct. Exact adapter boundaries are exhaustive; exact end-to-end intermediate reachability is not claimed for every boundary. Invalid-descriptor testing does not claim exhaustive malformed sparse-input coverage.

Build from clean committed sources:

```powershell
pwsh -File 03_verification/step12d_engineering/build_final_submission_package.ps1 -ExpectedSourceCommit <source-sha> -Destination <new-package-directory>
```

Run from extracted package source:

```powershell
pwsh -File 03_verification/step12d_engineering/run_final_submission_package.ps1 -PackageManifest <package-directory>/PACKAGE_MANIFEST.json -EvidenceDir <new-evidence-directory>
```

Prerequisites: PowerShell7, Git, Python3, ModelSim SE-64 2020.4 at D:/software/Modelsim with installed license. License is not packaged. Fresh runtime simulation directories receive only package files and newly generated vectors.

The archive contains RTL, coefficients, canonical matrices, historical contract inputs, frozen profile, TBs and runners. The extracted directory has its own Git snapshot; its SHA differs from authoritative tested_source_commit and is explicitly recorded. No existing vectors or simulator libraries are required.

The driver runs profile validation, Gate-A inheritance, independent Oracle, Python Gate-C and full normal/SYNTHESIS ModelSim. Inventory hashes are checked before/after stages. Process failures, missing required markers and source mutations stop qualification. Reports record archive hash, source/snapshot commit, commands, exits and artifact hashes.

Physical evidence is inherited only while DUT, ROM, harness, constraints and implementation sources match. This step changes verification/documentation only. Package-level I/O timing is not evaluated; nominal setup margin is1ps. SAT10, main-transform fixed-point rules and exact official LFNST-off pair subset retain their explicit engineering-contract scope.

Final public report identifies source and evidence commits separately. Main merge/tag require independent review.
