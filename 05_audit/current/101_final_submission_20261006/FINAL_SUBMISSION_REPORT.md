# Final submission functional qualification

SUBMISSION_FUNCTIONAL_FREEZE_READY = YES under the frozen SAT10 v2 engineering contract.

Tested source commit: cb65bbf1cc2dc9e5e649b2fe8b8affc67435c5a7.
DUT functional source: 9b33d9f62de49f022765cd594704353edeaa352c.
Baseline physical replay: db8dbedac12ca337f5ae351841f5574363f91174.
Archive SHA256: 46C55BFFA62A67CDD664FC9C68E210E3FCA1FC3B80093A4A81CEE0C9A19B461F; size2007090 bytes.
Execution snapshot: b2a61f9f48fe71e3d5ed588f7232486c33edd1be; builder snapshot: 5998e4c104d7b2a8c86f48ece8bca21725807241.
Snapshots are incidental local Git records for existing provenance queries. The authoritative source identity is tested_source_commit plus the frozen package-file inventory.

## Executed qualification

The final archive was extracted into a second empty directory, without the builder's .git metadata. The qualification driver successfully initialized its own local snapshot and regenerated all vectors there. No original-worktree files, prior simulator libraries or precomputed expected vectors were used.

Independent profile validation, Gate-A inheritance, VTM engineering Oracle and Python Gate-C passed. Full normal and SYNTHESIS ModelSim regression passed. All36 simulation command exit codes and transcript hashes were independently rechecked against copied logs; mismatches0.

Actual its_unified_submission_top:
- Gate-C369 cases /45636 beats per mode; real pending-output stall count is logged.
- LFNST specialty388 cases /6724 beats per mode, using unchanged independent vectors.
- Positive/negative overflow, 4x10-bit packing, two TU, stall and exact done pairing.
- Empty end-only TU; end-only overlapping prior write commit; final-data+end.
- Input gaps, inflight reset followed by fresh zero TU.
- Invalid descriptor: sticky protocol_error and rejected input admission (flag observed read-only).

Non-regression rerun: Gate-B156, Gate-F13, LFNST engine1088, SAT10 exhaustive65536, wrapper/P3/P4 suites, N4 stream16, FIFO reset, H-read raw capture and primary-V return credit.
The LOW10 profile negative invocation exited1 with the expected rejection before ModelSim/evidence initialization.

## Source/physical review

git diff from db8dbed confirms no changes to02_rtl,03_verification/vivado or historical05_audit/current/27.
The source delta consists of actual-top TBs, verification/package runners and current documentation.
The inherited two independent registered-neighbor runs pass nominal500MHz: setup+0.001ns/TNS0, hold+0.011ns/THS0, zero failing endpoints. No fresh implementation run is claimed for verification-only changes.

## Reproduction

Download package/source.zip and package/PACKAGE_MANIFEST.json. Extract ZIP into a new source directory and execute:

```powershell
pwsh -File <source>/03_verification/step12d_engineering/run_final_submission_package.ps1 -PackageManifest <package>/PACKAGE_MANIFEST.json -EvidenceDir <new-evidence-directory>
```

The driver initializes a local Git snapshot when absent, checks frozen file hashes before/after stages, enforces the frozen SAT10 profile and stops on failed processes, missing markers or source mutation. Tool prerequisites and build-from-commit commands are documented in01_docs/current/FINAL_SUBMISSION_ACCEPTANCE.md.
The archive includes unused historical TB assets, but the accepted vectors are newly generated and the compile list explicitly selects the current tests. No DCP/old execution log/simulator library is packaged.

## Boundaries

official_equivalence=NOT_PROVEN; SAT10 remains PROVISIONAL_ENGINEERING_DECISION.
Main-transform scaling and exact official LFNST-off H/V subset remain explicit engineering bindings.
Malformed sparse-address testing is not claimed by the invalid-descriptor test.
Exact signed16 adapter boundaries are exhaustive; exact intermediate end-to-end reachability is not claimed for every boundary.
Package-level timing/system clock margin are not evaluated; nominal setup margin is1ps.
Historical LOW10 audits are unchanged. Main merge/tag were not performed.

PUBLICATION_MANIFEST.json distinguishes working-tree byte SHA256 from LF-normalized published text SHA256/Git blob. Binary ZIP bytes are unchanged.
This is executor verification; the package and raw evidence are ready for independent review before main merge.

