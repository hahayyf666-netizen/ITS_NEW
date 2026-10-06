param([Parameter(Mandatory=$true)][string]$ExpectedSourceCommit,
      [Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$head=(git -C $repo rev-parse HEAD).Trim()
if($head -cne $ExpectedSourceCommit){throw 'Source commit mismatch'}
if((git -C $repo status --porcelain | Out-String).Trim()){throw 'Package requires clean committed sources'}
if(Test-Path -LiteralPath $Destination){throw 'Destination must be new'}
New-Item -ItemType Directory -Path $Destination | Out-Null
$paths=@('README.md','01_docs/current/FINAL_SUBMISSION_ACCEPTANCE.md',
 '03_verification/tb','03_verification/step12d_engineering',
 '03_verification/output/canonical_matrices.json')
$paths+=@('its_simple_ram.sv','its_input_cache_bank.sv','unified_p4_kernel.sv',
 'bounded_lfnst_engine.sv','unified_its_wrapper.sv','its_unified_submission_top.sv',
 'step12f_registered_neighbor_harness.sv','rom_coeffs.hex','lfnst_coeffs.hex','lfnst_packed_coeffs.hex') |
 ForEach-Object {'02_rtl/rtl/'+$_}
$paths+=@('run_step12f_registered_neighbor.ps1','run_step12f_registered_neighbor.tcl',
 'step12f_registered_neighbor_2ns.xdc','report_p9_primary_v_return_routed.tcl') |
 ForEach-Object {'03_verification/vivado/'+$_}
$paths+=@('ENGINEERING_PROFILE.json','LEGAL_TRANSFORM_MATRIX.json','LFNST_CASE_MATRIX.json',
 'P4_EXECUTION_PROOF.json','ARCHITECTURE_DECISION.json','CYCLE_RESOURCE_CONTRACT.json',
 'GATE_A_CHECKPOINT.json','OFFICIAL_EXPERT_QA_EVIDENCE.json','VTM_ZERO_OUT_RULES.json') |
 ForEach-Object {'05_audit/current/27/step12d_engineering/'+$_}
$archive=Join-Path $Destination 'source.zip'
& git -C $repo archive --format=zip "--output=$archive" $head -- @paths
if($LASTEXITCODE -ne 0){throw 'git archive failed'}
Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $Destination 'source')
$root=Join-Path $Destination 'source'
# A local Git snapshot permits existing read-only provenance queries. Its SHA
# is distinct from the authoritative tested source commit and recorded as such.
& git -C $root init -q
& git -C $root add -- .
& git -C $root -c user.name=PackageSnapshot -c user.email=package@local commit -qm 'Immutable package snapshot'
if($LASTEXITCODE -ne 0){throw 'Package snapshot initialization failed'}
$files=@(Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object {$_.FullName -notlike "$root\.git\*"} | Sort-Object FullName | ForEach-Object {
 [ordered]@{path=[IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/'); sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
})
$manifest=[ordered]@{tested_source_commit=$head;package_snapshot_commit=(git -C $root rev-parse HEAD).Trim();
 archive_sha256=(Get-FileHash -LiteralPath $archive).Hash;files=$files;top='its_unified_submission_top';
 profile='contest_engineering_vtm10_sat10_v2';official_equivalence='NOT_PROVEN'}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Destination 'PACKAGE_MANIFEST.json') -Encoding utf8
Write-Output "PACKAGE_BUILT source=$head files=$($files.Count) root=$root"
