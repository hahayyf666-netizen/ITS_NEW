param([Parameter(Mandatory=$true)][string]$EvidenceDir,
      [string]$NativeExe='',
      [string]$Compiler='D:\AMDDesignTools\2025.2\tps\mingw\10.0.0\win64.o\nt\bin\g++.exe')
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if(Test-Path -LiteralPath $EvidenceDir){throw 'Use a new qualification directory'}
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$EvidenceDir=(Resolve-Path -LiteralPath $EvidenceDir).Path
$env:PYTHONDONTWRITEBYTECODE='1';$env:PYTHONIOENCODING='utf-8'
$profile='contest_engineering_vtm10_sat10_v2'
$stages=@()
foreach($job in @(
    @('01_profile','validate_sat10_profile.py','SAT10_PROFILE_VALIDATION.json','PASS_SAT10_PROFILE_INHERITS_V1_ARITHMETIC'),
    @('02_profile_inheritance','validate_gate_a.py','GATE_A_VALIDATION.json','PASS_GATE_A_PROFILE_INHERITANCE'),
    @('03_python_oracle','run_vtm_engineering_oracle.py','VTM_PROFILE_ORACLE_RESULTS.json','PASS_INDEPENDENT_VTM_PROFILE_ORACLE_AND_IMPACT_AUDIT'),
    @('04_python_2d','validate_gate_c_model.py','GATE_C_MODEL_VALIDATION.json','PASS_ENGINEERING_PROFILE_2D_PROTOCOL_MODEL'))){
    $dir=Join-Path $EvidenceDir $job[0];New-Item -ItemType Directory -Path $dir | Out-Null
    & python (Join-Path $PSScriptRoot $job[1]) --profile $profile --evidence-dir $dir *> (Join-Path $dir 'command.log')
    if($LASTEXITCODE -ne 0){throw "Model qualification failed: $($job[0])"}
    $data=Get-Content -LiteralPath (Join-Path $dir $job[2]) -Raw | ConvertFrom-Json
    if($data.status -cne $job[3]){throw "Missing model status: $($job[0])"}
    $stages+=@{stage=$job[0];status=$data.status;exit_code=0}
}
& (Join-Path $PSScriptRoot 'run_step12f_coverage_modelsim.ps1') -WorkRoot (Join-Path $EvidenceDir '05_existing/sim') -EvidenceDir (Join-Path $EvidenceDir '05_existing/evidence') *> (Join-Path $EvidenceDir '05_existing.log')
if(-not $?){throw 'Existing regression qualification failed'}
$existing=Get-Content -LiteralPath (Join-Path $EvidenceDir '05_existing/evidence/STEP12F_COVERAGE_MODELSIM_RUN.json') -Raw | ConvertFrom-Json
if($existing.status -ne 'PASS' -or $existing.command_records.Count -ne 36){throw 'Existing regression missing records'}
& (Join-Path $PSScriptRoot 'run_full_spatial_regression.ps1') -WorkRoot (Join-Path $EvidenceDir '06_full_spatial') -NativeExe $NativeExe -Compiler $Compiler *> (Join-Path $EvidenceDir '06_full_spatial.log')
if(-not $?){throw 'Full spatial qualification failed'}
$full=Get-Content -LiteralPath (Join-Path $EvidenceDir '06_full_spatial/FULL_SPATIAL_REGRESSION.json') -Raw | ConvertFrom-Json
if($full.status -ne 'PASS_FULL_SPATIAL_REPAIR_REGRESSION' -or $full.baseline_negative_control -ne 'EXPECTED_FAIL_DETECTED' -or $full.simulations -ne 6){throw 'Full spatial qualification incomplete'}
& (Join-Path $PSScriptRoot 'run_full_spatial_performance.ps1') -WorkRoot (Join-Path $EvidenceDir '07_performance') *> (Join-Path $EvidenceDir '07_performance.log')
if(-not $?){throw 'Performance qualification failed'}
$result=@{status='PASS_FULL_SPATIAL_REPAIR_FUNCTIONAL_QUALIFICATION';source_commit=(git -C $repo rev-parse HEAD).Trim();
    python_stages=$stages;existing_simulations=36;new_simulations=6;total_positive_simulations=42;
    negative_control='EXPECTED_FAIL_DETECTED';native_reference_cases=($full.reference_standard_cases+$full.reference_extra_cases);
    native_reference_values=$full.reference_scalar_values;official_equivalence='NOT_PROVEN';
    physical='REQUIRES_SEPARATE_FRESH_IMPLEMENTATION_EVIDENCE';
    source_files=@(git -C $repo ls-files | ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $repo $_)).Hash}})
}
$result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $EvidenceDir 'REPAIR_FUNCTIONAL_QUALIFICATION.json') -Encoding utf8
Write-Output 'REPAIR_FUNCTIONAL_PASS positive_simulations=42 negative_control=EXPECTED_FAIL_DETECTED'
