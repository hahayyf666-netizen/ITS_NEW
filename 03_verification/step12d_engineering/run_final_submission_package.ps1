param([Parameter(Mandatory=$true)][string]$PackageManifest,
      [Parameter(Mandatory=$true)][string]$EvidenceDir)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$meta=Get-Content -LiteralPath $PackageManifest -Raw | ConvertFrom-Json
# A downloaded archive has no .git directory. Source identity is the frozen
# file inventory and authoritative commit, not the incidental local snapshot.
foreach($f in $meta.files){if((Get-FileHash -LiteralPath (Join-Path $repo $f.path)).Hash -cne $f.sha256){throw "Package mutation: $($f.path)"}}
if(-not (Test-Path -LiteralPath (Join-Path $repo '.git'))){
 & git -C $repo init -q
 & git -C $repo add -- .
 & git -C $repo -c user.name=PackageSnapshot -c user.email=package@local commit -qm 'Immutable package snapshot'
 if($LASTEXITCODE -ne 0){throw 'Downloaded package snapshot initialization failed'}
}
$snapshotCommit=(git -C $repo rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0){throw 'Package snapshot unavailable'}
if(Test-Path -LiteralPath $EvidenceDir){throw 'Evidence directory must be new'}
New-Item -ItemType Directory -Path $EvidenceDir | Out-Null
function Assert-Frozen {
 foreach($f in $meta.files){if((Get-FileHash -LiteralPath (Join-Path $repo $f.path)).Hash -cne $f.sha256){throw "Package mutation: $($f.path)"}}
 if((git -C $repo rev-parse HEAD).Trim() -cne $snapshotCommit){throw 'Package snapshot changed'}
}
$stages=@()
try {
 Assert-Frozen
 $profile='contest_engineering_vtm10_sat10_v2'
 $jobs=@(
  @('01_profile','validate_sat10_profile.py','SAT10_PROFILE_VALIDATION.json','PASS_SAT10_PROFILE_INHERITS_V1_ARITHMETIC'),
  @('02_gate_a','validate_gate_a.py','GATE_A_VALIDATION.json','PASS_GATE_A_PROFILE_INHERITANCE'),
  @('03_oracle','run_vtm_engineering_oracle.py','VTM_PROFILE_ORACLE_RESULTS.json','PASS_INDEPENDENT_VTM_PROFILE_ORACLE_AND_IMPACT_AUDIT'),
  @('04_gate_c','validate_gate_c_model.py','GATE_C_MODEL_VALIDATION.json','PASS_ENGINEERING_PROFILE_2D_PROTOCOL_MODEL'))
 foreach($job in $jobs){
  $dir=Join-Path $EvidenceDir $job[0]; New-Item -ItemType Directory -Path $dir | Out-Null
  $args=@((Join-Path $PSScriptRoot $job[1]),'--profile',$profile,'--evidence-dir',$dir)
  & python @args *> (Join-Path $dir 'command.log'); $code=$LASTEXITCODE
  if($code -ne 0){throw "Python stage failed: $($job[0])"}
  $result=Get-Content (Join-Path $dir $job[2]) -Raw | ConvertFrom-Json
  if($result.status -cne $job[3] -or $result.profile_sha256 -cne 'FEA3ACB18C5C35EB0FD8A8DBF533C3A6BE7536BCC8EF5FDB87135DF512643746'){throw "Stage contract mismatch: $($job[0])"}
  $stages+=@{stage=$job[0];command="python $($args -join ' ')";exit_code=$code}
  Assert-Frozen
 }
 $dir=Join-Path $EvidenceDir '05_modelsims'; New-Item -ItemType Directory -Path $dir | Out-Null
 $runner=Join-Path $PSScriptRoot 'run_step12f_coverage_modelsim.ps1'
 $work=Join-Path $env:TEMP ('final_submission_sim_'+[guid]::NewGuid().ToString('N'))
 $shell=(Get-Process -Id $PID).Path
 $args=@('-NoProfile','-File',$runner,'-WorkRoot',$work,'-EvidenceDir',$dir,'-ProfileName',$profile)
 & $shell @args *> (Join-Path $dir 'command.log'); $code=$LASTEXITCODE
 if($code -ne 0){throw 'Full ModelSim qualification failed'}
 $result=Get-Content (Join-Path $dir 'STEP12F_COVERAGE_MODELSIM_RUN.json') -Raw | ConvertFrom-Json
 if($result.status -ne 'PASS' -or $result.runs.Count -ne 2){throw 'ModelSim summary invalid'}
 foreach($run in $result.runs){
  if($run.submission_top_full_gate_c -ne 'PASS_369_CASES_45636_BEATS' -or
     $run.submission_top_lfnst_specialty -ne 'PASS_388_CASES_6724_BEATS' -or
     $run.submission_top_protocol -ne 'PASS_END_MARKERS_RESET_INPUT_GAPS_ILLEGAL_STICKY'){throw 'Submission-top gates missing'}
 }
 $stages+=@{stage='05_modelsims';command="$shell $($args -join ' ')";exit_code=$code}
 Assert-Frozen
 $out=[ordered]@{status='SUBMISSION_FUNCTIONAL_FREEZE_READY';tested_source_commit=$meta.tested_source_commit;
  package_snapshot_commit=$snapshotCommit;builder_snapshot_commit=$meta.package_snapshot_commit;package_sha256=$meta.archive_sha256;
  profile=$result.profile;stages=$stages;DUT_modified=$false;official_equivalence='NOT_PROVEN';
  physical='INHERITED_TWO_RUN_REGISTERED_NEIGHBOR_PASS_NO_NEW_IMPLEMENTATION';
  artifacts=@(Get-ChildItem $EvidenceDir -File -Recurse | Sort-Object FullName | ForEach-Object {
    @{path=[IO.Path]::GetRelativePath($EvidenceDir,$_.FullName).Replace('\','/');sha256=(Get-FileHash $_.FullName).Hash}
  })}
 $out | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $EvidenceDir 'FINAL_SUBMISSION_MANIFEST.json') -Encoding utf8
 Write-Output "FINAL_SUBMISSION_PASS source=$($meta.tested_source_commit)"
} catch {
 @{status='FAIL_STOP';tested_source_commit=$meta.tested_source_commit;failure=$_.Exception.Message;stages=$stages} |
  ConvertTo-Json -Depth 8 | Set-Content (Join-Path $EvidenceDir 'FINAL_SUBMISSION_MANIFEST.json') -Encoding utf8
 throw
}

