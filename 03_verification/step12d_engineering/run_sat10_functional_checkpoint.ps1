param(
    [Parameter(Mandatory = $true)]
    [string]$ExpectedSourceCommit,
    [string]$EvidenceParent = "",
    [string]$ProfileName = "contest_engineering_vtm10_sat10_v2"
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$ExpectedProfileName = "contest_engineering_vtm10_sat10_v2"
$ExpectedProfileSha256 = "FEA3ACB18C5C35EB0FD8A8DBF533C3A6BE7536BCC8EF5FDB87135DF512643746"
$Python = (Get-Command python -ErrorAction Stop).Source
$PowerShell = (Get-Process -Id $PID).Path
$ProfilePath = Join-Path $PSScriptRoot "profiles\contest_engineering_vtm10_sat10_v2.json"
$Runner = Join-Path $PSScriptRoot "run_step12f_coverage_modelsim.ps1"
$GateBCRunner = Join-Path $PSScriptRoot "run_gate_b_c_modelsim.ps1"

if ($ProfileName -cne $ExpectedProfileName) {
    throw "Checkpoint accepts only $ExpectedProfileName"
}
$profileText = [IO.File]::ReadAllText($ProfilePath)
$profileCanonical = $profileText.Replace(([string][char]13 + [string][char]10), [string][char]10)
$profileSha = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($profileCanonical))
)
if ($profileSha -cne $ExpectedProfileSha256) {
    throw "Frozen profile SHA256 mismatch: expected $ExpectedProfileSha256, got $profileSha"
}

$sourceCommit = (git -C $RepoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -cne $ExpectedSourceCommit) {
    throw "Tested source commit mismatch: expected $ExpectedSourceCommit, got $sourceCommit"
}
$worktreeStatus = (git -C $RepoRoot status --porcelain --untracked-files=all | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect source worktree status"
}
if ($worktreeStatus.Length -gt 0) {
    throw "Checkpoint must start from a clean source worktree"
}

if (-not $EvidenceParent) {
    $EvidenceParent = Join-Path $RepoRoot "05_audit\current\71_sat10_functional_checkpoint"
}
New-Item -ItemType Directory -Force -Path $EvidenceParent | Out-Null
$runId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ") + "_" + $sourceCommit.Substring(0, 12)
$EvidenceDir = Join-Path $EvidenceParent $runId
if (Test-Path -LiteralPath $EvidenceDir) {
    throw "Evidence directory already exists; refusing to overwrite: $EvidenceDir"
}
New-Item -ItemType Directory -Path $EvidenceDir -ErrorAction Stop | Out-Null

$StageRuns = @()
$Failure = $null

function Quote-CommandArgument([string]$Argument) {
    if ($Argument -match '[\s"]') { return '"' + $Argument.Replace('"', '\"') + '"' }
    return $Argument
}

function Invoke-LoggedStage([string]$Name, [string]$Executable, [string[]]$Arguments,
                            [string]$WorkingDirectory, [string]$StageDirectory) {
    New-Item -ItemType Directory -Path $StageDirectory -ErrorAction Stop | Out-Null
    $log = Join-Path $StageDirectory "command.log"
    $commandLine = (Quote-CommandArgument $Executable) + " " +
        (($Arguments | ForEach-Object { Quote-CommandArgument $_ }) -join " ")
    $previous = Get-Location
    try {
        Set-Location -LiteralPath $WorkingDirectory
        & $Executable @Arguments *> $log
        $exitCode = $LASTEXITCODE
    } finally {
        Set-Location $previous
    }
    if ($null -eq $exitCode) { $exitCode = 0 }
    $stage = [ordered]@{
        name = $Name
        command = $commandLine
        exit_code = $exitCode
        log = ($log.Substring($EvidenceDir.Length + 1) -replace '\\', '/')
        log_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $log).Hash
    }
    $script:StageRuns += $stage
    if ($exitCode -ne 0) { throw "Stage $Name failed with exit code $exitCode" }
}

function Assert-SourceFrozen {
    $headNow = (git -C $RepoRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $headNow -cne $sourceCommit) {
        throw "HEAD changed during functional checkpoint"
    }
    & git -C $RepoRoot diff --quiet $sourceCommit -- 02_rtl 03_verification
    if ($LASTEXITCODE -ne 0) { throw "02_rtl or 03_verification changed during checkpoint" }
}

try {
    $profileStage = Join-Path $EvidenceDir "01_profile_validation"
    Invoke-LoggedStage "sat10_profile_validation" $Python @(
        (Join-Path $PSScriptRoot "validate_sat10_profile.py"),
        "--profile", $ExpectedProfileName,
        "--evidence-dir", $profileStage
    ) $RepoRoot $profileStage
    $profileResult = Get-Content (Join-Path $profileStage "SAT10_PROFILE_VALIDATION.json") -Raw | ConvertFrom-Json
    if ($profileResult.status -ne "PASS_SAT10_PROFILE_INHERITS_V1_ARITHMETIC" -or
        $profileResult.profile_sha256 -cne $ExpectedProfileSha256 -or
        $profileResult.official_equivalence -cne "NOT_PROVEN") {
        throw "SAT10 profile validation evidence did not satisfy frozen contract"
    }

    Assert-SourceFrozen
    $gateAStage = Join-Path $EvidenceDir "02_gate_a_inheritance"
    Invoke-LoggedStage "gate_a_inheritance" $Python @(
        (Join-Path $PSScriptRoot "validate_gate_a.py"),
        "--profile", $ExpectedProfileName,
        "--evidence-dir", $gateAStage
    ) $RepoRoot $gateAStage
    $gateAResult = Get-Content (Join-Path $gateAStage "GATE_A_VALIDATION.json") -Raw | ConvertFrom-Json
    if ($gateAResult.status -ne "PASS_GATE_A_PROFILE_INHERITANCE" -or
        $gateAResult.profile_sha256 -cne $ExpectedProfileSha256) {
        throw "Gate-A inheritance evidence did not satisfy frozen contract"
    }

    Assert-SourceFrozen
    $oracleStage = Join-Path $EvidenceDir "03_independent_vtm_oracle"
    Invoke-LoggedStage "independent_vtm_oracle" $Python @(
        (Join-Path $PSScriptRoot "run_vtm_engineering_oracle.py"),
        "--profile", $ExpectedProfileName,
        "--evidence-dir", $oracleStage
    ) $RepoRoot $oracleStage
    $oracleResult = Get-Content (Join-Path $oracleStage "VTM_PROFILE_ORACLE_RESULTS.json") -Raw | ConvertFrom-Json
    if ($oracleResult.status -ne "PASS_INDEPENDENT_VTM_PROFILE_ORACLE_AND_IMPACT_AUDIT" -or
        $oracleResult.profile_sha256 -cne $ExpectedProfileSha256 -or
        $oracleResult.adapter_mode_used -ne "SAT10") {
        throw "Independent VTM Oracle evidence did not satisfy frozen SAT10 contract"
    }

    Assert-SourceFrozen
    $gateCStage = Join-Path $EvidenceDir "04_independent_python_gate_c"
    Invoke-LoggedStage "independent_python_gate_c" $Python @(
        (Join-Path $PSScriptRoot "validate_gate_c_model.py"),
        "--profile", $ExpectedProfileName,
        "--evidence-dir", $gateCStage
    ) $RepoRoot $gateCStage
    $gateCResult = Get-Content (Join-Path $gateCStage "GATE_C_MODEL_VALIDATION.json") -Raw | ConvertFrom-Json
    if ($gateCResult.status -ne "PASS_ENGINEERING_PROFILE_2D_PROTOCOL_MODEL" -or
        $gateCResult.profile_sha256 -cne $ExpectedProfileSha256 -or
        $gateCResult.adapter_mode_used -ne "SAT10" -or
        $gateCResult.aggregate.cases -ne 369 -or $gateCResult.aggregate.beats -ne 45636) {
        throw "Independent Python Gate-C evidence did not satisfy frozen SAT10 contract"
    }

    Assert-SourceFrozen
    $wrongProfileStage = Join-Path $EvidenceDir "05_fail_closed_negative_tests"
    New-Item -ItemType Directory -Path $wrongProfileStage -ErrorAction Stop | Out-Null
    foreach ($entry in @(
        @{name="full_modelsims"; script=$Runner},
        @{name="gate_bc_modelsim"; script=$GateBCRunner}
    )) {
        $log = Join-Path $wrongProfileStage ($entry.name + ".log")
        $args = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $entry.script,
                  "-ProfileName", "contest_engineering_vtm10_v1",
                  "-EvidenceDir", (Join-Path $wrongProfileStage ($entry.name + "_must_not_exist")))
        $commandLine = (Quote-CommandArgument $PowerShell) + " " +
            (($args | ForEach-Object { Quote-CommandArgument $_ }) -join " ")
        & $PowerShell @args *> $log
        $rejectExitCode = $LASTEXITCODE
        $rejectText = Get-Content $log -Raw
        if ($rejectExitCode -eq 0 -or
            $rejectText -notmatch "only accepts contest_engineering_vtm10_sat10_v2") {
            throw "Negative profile test failed to reject LOW10 before ModelSim: $($entry.name)"
        }
        if (Test-Path -LiteralPath (Join-Path $wrongProfileStage ($entry.name + "_must_not_exist"))) {
            throw "Negative profile test created evidence/work before rejecting: $($entry.name)"
        }
        $StageRuns += [ordered]@{
            name = "fail_closed_" + $entry.name
            command = $commandLine
            expected_exit_code = "NONZERO"
            actual_exit_code = $rejectExitCode
            log = ($log.Substring($EvidenceDir.Length + 1) -replace '\\', '/')
            log_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $log).Hash
            result = "PASS_REJECTED_BEFORE_MODELSIM"
        }
    }

    Assert-SourceFrozen
    $modelsimStage = Join-Path $EvidenceDir "06_full_modelsims"
    $modelsimWork = Join-Path $env:TEMP ("sat10_functional_" + $runId)
    if (Test-Path -LiteralPath $modelsimWork) {
        throw "ModelSim work root already exists; refusing to reuse or overwrite it"
    }
    $modelsimArgs = @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Runner,
        "-ProfileName", $ExpectedProfileName,
        "-WorkRoot", $modelsimWork,
        "-EvidenceDir", $modelsimStage
    )
    Invoke-LoggedStage "full_normal_and_synthesis_modelsim" $PowerShell $modelsimArgs $RepoRoot $modelsimStage
    $modelsimResult = Get-Content (Join-Path $modelsimStage "STEP12F_COVERAGE_MODELSIM_RUN.json") -Raw | ConvertFrom-Json
    if ($modelsimResult.status -ne "PASS" -or
        $modelsimResult.profile.name -cne $ExpectedProfileName -or
        $modelsimResult.profile.adapter -cne "SAT10" -or
        $modelsimResult.profile.sha256 -cne $ExpectedProfileSha256 -or
        $modelsimResult.runs.Count -ne 2 -or
        $modelsimResult.vector_sets.gate_c.cases -ne 369 -or
        $modelsimResult.vector_sets.gate_c.beats -ne 45636 -or
        $modelsimResult.vector_sets.lfnst_specialty.engine_cases -ne 1088 -or
        $modelsimResult.vector_sets.lfnst_specialty.wrapper_cases -ne 388) {
        throw "Full ModelSim qualification manifest failed required coverage checks"
    }
    foreach ($run in $modelsimResult.runs) {
        if ($run.mode -notin @("normal", "synthesis") -or
            $run.gate_b_kernel_numeric -ne "PASS_156_CASES" -or
            $run.gate_f_vector_ii -ne "PASS_13_MODES" -or
            $run.gate_c_wrapper_numeric -ne "PASS_369_CASES" -or
            $run.sat10_adapter_exhaustive -ne "PASS_65536_VALUES" -or
            $run.sat10_submission_top -ne "PASS_2_TUS_8_BEATS_MIN_8_REAL_PENDING_STALL_CYCLES" -or
            $run.hread_raw_capture -ne "PASS_ORDERED_PAYLOAD_METADATA_AND_REAL_STALL" -or
            $run.sat10_wrapper_boundary -ne "PASS_5_CASES_24_BEATS_LFNST_GRID_REINIT" -or
            $run.lfnst_engine_specialty -ne "PASS_1088_CASES" -or
            $run.lfnst_wrapper_specialty -ne "PASS_388_CASES") {
            throw "A normal/SYNTHESIS ModelSim mode is missing required SAT10 gates"
        }
    }
    Assert-SourceFrozen

    $sourcePaths = @(
        "02_rtl/rtl/its_simple_ram.sv",
        "02_rtl/rtl/its_input_cache_bank.sv",
        "02_rtl/rtl/unified_p4_kernel.sv",
        "02_rtl/rtl/bounded_lfnst_engine.sv",
        "02_rtl/rtl/unified_its_wrapper.sv",
        "02_rtl/rtl/its_unified_submission_top.sv",
        "02_rtl/rtl/rom_coeffs.hex",
        "02_rtl/rtl/lfnst_coeffs.hex",
        "02_rtl/rtl/lfnst_packed_coeffs.hex",
        "03_verification/tb/unified_p4_kernel_numeric_tb.sv",
        "03_verification/tb/unified_p4_kernel_throughput_tb.sv",
        "03_verification/tb/unified_p4_kernel_throughput_full_tb.sv",
        "03_verification/tb/unified_p4_kernel_p4_tb.sv",
        "03_verification/tb/unified_p4_fifo_payload_reset_tb.sv",
        "03_verification/tb/unified_p4_coeff_layout_tb.sv",
        "03_verification/tb/unified_its_wrapper_tb.sv",
        "03_verification/tb/unified_its_wrapper_p3_tb.sv",
        "03_verification/tb/unified_its_wrapper_numeric_tb.sv",
        "03_verification/tb/unified_its_final_adapter_tb.sv",
        "03_verification/tb/unified_its_sat10_wrapper_tb.sv",
        "03_verification/tb/unified_its_hread_raw_capture_tb.sv",
        "03_verification/tb/its_unified_submission_top_sat10_tb.sv",
        "03_verification/tb/bounded_lfnst_engine_tb.sv",
        "03_verification/step12d_engineering/profile_contract.py",
        "03_verification/step12d_engineering/validate_sat10_profile.py",
        "03_verification/step12d_engineering/validate_gate_a.py",
        "03_verification/step12d_engineering/run_vtm_engineering_oracle.py",
        "03_verification/step12d_engineering/validate_gate_c_model.py",
        "03_verification/step12d_engineering/generate_gate_b_hdl_vectors.py",
        "03_verification/step12d_engineering/generate_gate_c_hdl_vectors.py",
        "03_verification/step12d_engineering/generate_lfnst_engine_vectors.py",
        "03_verification/step12d_engineering/generate_lfnst_wrapper_vectors.py",
        "03_verification/step12d_engineering/test_lfnst_layout_contract.py",
        "03_verification/step12d_engineering/run_gate_b_c_modelsim.ps1",
        "03_verification/step12d_engineering/run_step12f_coverage_modelsim.ps1",
        "03_verification/step12d_engineering/run_sat10_functional_checkpoint.ps1",
        "03_verification/step12d_engineering/profiles/contest_engineering_vtm10_sat10_v2.json"
    )
    $sourceHashes = [ordered]@{}
    foreach ($relative in $sourcePaths) {
        $path = Join-Path $RepoRoot ($relative -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path)) { throw "Required frozen source missing: $relative" }
        $sourceHashes[$relative] = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    }

    $files = @(Get-ChildItem -LiteralPath $EvidenceDir -File -Recurse |
        Where-Object { $_.Name -ne "CHECKPOINT_MANIFEST.json" } |
        Sort-Object FullName | ForEach-Object {
            [ordered]@{
                path = ($_.FullName.Substring($EvidenceDir.Length + 1) -replace '\\', '/')
                bytes = $_.Length
                sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
            }
        })
    $manifest = [ordered]@{
        schema = "step12d_engineering.sat10_functional_checkpoint.v1"
        status = "FUNCTIONAL_PASS"
        tested_source_commit = $sourceCommit
        checkout_state = "DETACHED_AT_TESTED_SOURCE_COMMIT"
        remote_target_branch = "sat10-profile-v2"
        profile = [ordered]@{
            name = $ExpectedProfileName
            path = "03_verification/step12d_engineering/profiles/contest_engineering_vtm10_sat10_v2.json"
            canonical_sha256 = $ExpectedProfileSha256
            decision_class = $profileResult.decision_class
            official_equivalence = "NOT_PROVEN"
            final10 = "SAT10"
            range = @(-512, 511)
        }
        execution = [ordered]@{
            simulator = "ModelSim SE-64 2020.4"
            normal = "PASS"
            SYNTHESIS = "PASS"
            gate_b_cases = 156
            gate_f_modes = 13
            gate_c_cases = 369
            gate_c_beats_per_mode = 45636
            lfnst_engine_cases = 1088
            lfnst_wrapper_cases = 388
            sat10_exhaustive_signed16_values = 65536
            wrapper_end_to_end = "PASS_POSITIVE_AND_NEGATIVE_OVERFLOW_BACKPRESSURE_TWO_TU_DONE_4X10_PACKING"
            submission_top_end_to_end = "PASS_POSITIVE_AND_NEGATIVE_OVERFLOW_BACKPRESSURE_TWO_TU_DONE_4X10_PACKING"
            exact_intermediate_end_to_end_boundaries = "NOT_CLAIMED; exact [-513,-512,-511,510,511,512] values are covered by exhaustive adapter-function simulation; no canonical end-to-end input vectors were established for each exact intermediate"
            official_equivalence = "NOT_PROVEN"
            fresh_synthesis_place_route = "NOT_RUN"
        }
        stages = $StageRuns
        source_file_sha256 = $sourceHashes
        evidence_files = $files
        evidence_commit_expected_parent = $sourceCommit
        evidence_commit_sha_location = "Reported from the remote sat10-profile-v2 ref after the evidence commit; a Git commit cannot contain its own SHA in its tree."
        historical_low10_audit_modified = $false
        physical_timing = "NOT_RUN"
    }
    $manifest | ConvertTo-Json -Depth 12 |
        Set-Content -LiteralPath (Join-Path $EvidenceDir "CHECKPOINT_MANIFEST.json") -Encoding utf8
    Write-Output "SAT10_FUNCTIONAL_CHECKPOINT_PASS source=$sourceCommit evidence=$EvidenceDir"
} catch {
    $Failure = $_.Exception.Message
    $failureManifest = [ordered]@{
        schema = "step12d_engineering.sat10_functional_checkpoint.v1"
        status = "FAIL_STOP"
        tested_source_commit = $sourceCommit
        profile_name = $ExpectedProfileName
        profile_sha256 = $ExpectedProfileSha256
        official_equivalence = "NOT_PROVEN"
        failure = $Failure
        completed_stages = $StageRuns
        evidence_commit = "NOT_CREATED"
        physical_timing = "NOT_RUN"
    }
    $failureManifest | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $EvidenceDir "CHECKPOINT_MANIFEST.json") -Encoding utf8
    Write-Error "SAT10 checkpoint STOP: $Failure"
    exit 1
}
