param(
    [string]$WorkRoot = (Join-Path $env:TEMP ("step12f_coverage_" + (Get-Date -Format "yyyyMMdd_HHmmss"))),
    [string]$EvidenceDir = "",
    [string]$KernelSource = "",
    [string]$ProfileName = "contest_engineering_vtm10_sat10_v2"
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$ExpectedProfileName = "contest_engineering_vtm10_sat10_v2"
$ExpectedProfileSha256 = "FEA3ACB18C5C35EB0FD8A8DBF533C3A6BE7536BCC8EF5FDB87135DF512643746"
if ($ProfileName -cne $ExpectedProfileName) {
    throw "SAT10 release runner only accepts $ExpectedProfileName (got $ProfileName)"
}
$ProfilePath = Join-Path $PSScriptRoot ("profiles\" + $ProfileName + ".json")
if (-not (Test-Path -LiteralPath $ProfilePath)) { throw "Engineering profile not found: $ProfileName" }
$Profile = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json
if ($Profile.schema -ne "step12d_engineering.vtm_profile.v2") { throw "Unsupported engineering profile schema" }
if ($Profile.profile_name -cne $ExpectedProfileName) { throw "Profile name does not match SAT10 release identity" }
if ($Profile.final10.default -cne "SAT10") { throw "SAT10 release requires final10.default=SAT10" }
if (($Profile.final10.range.Count -ne 2) -or
    ($Profile.final10.range[0] -ne -512) -or ($Profile.final10.range[1] -ne 511)) {
    throw "SAT10 release requires final10.range=[-512,511]"
}
$ProfileCanonicalText = ([IO.File]::ReadAllText($ProfilePath)).Replace(([string][char]13 + [string][char]10), [string][char]10)
$ProfileCanonicalBytes = [Text.UTF8Encoding]::new($false).GetBytes($ProfileCanonicalText)
$ProfileSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($ProfileCanonicalBytes))
if ($ProfileSha256 -cne $ExpectedProfileSha256) {
    throw "SAT10 release profile hash mismatch: expected $ExpectedProfileSha256 got $ProfileSha256"
}
$ModelSim = "D:\software\Modelsim\win64"
$Vlib = Join-Path $ModelSim "vlib.exe"
$Vlog = Join-Path $ModelSim "vlog.exe"
$Vsim = Join-Path $ModelSim "vsim.exe"
$License = "D:\software\Modelsim\LICENSE.TXT"

foreach ($tool in @($Vlib, $Vlog, $Vsim, $License)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "Required ModelSim component not found: $tool"
    }
}
$env:LM_LICENSE_FILE = $License
$env:MGLS_LICENSE_FILE = $License

New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
if ($EvidenceDir) {
    New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
    # Resolve before changing directory so a relative evidence path does not
    # accidentally become nested below the temporary ModelSim work tree.
    $EvidenceDir = (Resolve-Path -LiteralPath $EvidenceDir).Path
}

$Kernel = Join-Path $RepoRoot "02_rtl\rtl\unified_p4_kernel.sv"
if ($KernelSource) {
    $requestedKernel = (Resolve-Path -LiteralPath $KernelSource).Path
    if ($requestedKernel -cne (Resolve-Path -LiteralPath $Kernel).Path) {
        throw "SAT10 release qualification forbids a kernel source override"
    }
}
$SimpleRam = Join-Path $RepoRoot "02_rtl\rtl\its_simple_ram.sv"
$InputBank = Join-Path $RepoRoot "02_rtl\rtl\its_input_cache_bank.sv"
$LfnstEngine = Join-Path $RepoRoot "02_rtl\rtl\bounded_lfnst_engine.sv"
$Wrapper = Join-Path $RepoRoot "02_rtl\rtl\unified_its_wrapper.sv"
$SubmissionTop = Join-Path $RepoRoot "02_rtl\rtl\its_unified_submission_top.sv"
$KernelTb = Join-Path $RepoRoot "03_verification\tb\unified_p4_kernel_numeric_tb.sv"
$ThroughputTb = Join-Path $RepoRoot "03_verification\tb\unified_p4_kernel_throughput_tb.sv"
$ThroughputFullTb = Join-Path $RepoRoot "03_verification\tb\unified_p4_kernel_throughput_full_tb.sv"
$SmokeTb = Join-Path $RepoRoot "03_verification\tb\unified_its_wrapper_tb.sv"
$P3Tb = Join-Path $RepoRoot "03_verification\tb\unified_its_wrapper_p3_tb.sv"
$P4Tb = Join-Path $RepoRoot "03_verification\tb\unified_p4_kernel_p4_tb.sv"
$FifoResetTb = Join-Path $RepoRoot "03_verification\tb\unified_p4_fifo_payload_reset_tb.sv"
$NumericTb = Join-Path $RepoRoot "03_verification\tb\unified_its_wrapper_numeric_tb.sv"
$AdapterTb = Join-Path $RepoRoot "03_verification\tb\unified_its_final_adapter_tb.sv"
$SatWrapperTb = Join-Path $RepoRoot "03_verification\tb\unified_its_sat10_wrapper_tb.sv"
$HReadRawCaptureTb = Join-Path $RepoRoot "03_verification\tb\unified_its_hread_raw_capture_tb.sv"
$PrimaryVReturnTb = Join-Path $RepoRoot "03_verification\tb\unified_its_primary_v_return_tb.sv"
$SubmissionTopTb = Join-Path $RepoRoot "03_verification\tb\its_unified_submission_top_sat10_tb.sv"
$SubmissionNumericTb = Join-Path $RepoRoot "03_verification\tb\its_unified_submission_top_numeric_tb.sv"
$SubmissionProtocolTb = Join-Path $RepoRoot "03_verification\tb\its_unified_submission_top_protocol_tb.sv"
$GateBGenerator = Join-Path $RepoRoot "03_verification\step12d_engineering\generate_gate_b_hdl_vectors.py"
$GateCGenerator = Join-Path $RepoRoot "03_verification\step12d_engineering\generate_gate_c_hdl_vectors.py"
$LfnstVectorGenerator = Join-Path $RepoRoot "03_verification\step12d_engineering\generate_lfnst_engine_vectors.py"
$LfnstTb = Join-Path $RepoRoot "03_verification\tb\bounded_lfnst_engine_tb.sv"
$LfnstWrapperVectorGenerator = Join-Path $RepoRoot "03_verification\step12d_engineering\generate_lfnst_wrapper_vectors.py"
$LfnstLayoutTest = Join-Path $RepoRoot "03_verification\step12d_engineering\test_lfnst_layout_contract.py"

$layoutTestOutput = (& python $LfnstLayoutTest | Out-String)
if ($LASTEXITCODE -ne 0 -or
    -not $layoutTestOutput.Contains("PASS_LFNST_LAYOUT_CONTRACT")) {
    throw "LFNST layout contract test failed"
}
if ($EvidenceDir) {
    $layoutTestOutput | Set-Content -LiteralPath (Join-Path $EvidenceDir "lfnst_layout_contract.log") -Encoding utf8
}

$LfnstVector = Join-Path $WorkRoot "lfnst_engine_vectors.txt"
$lfnstVectorOutput = (& python $LfnstVectorGenerator $LfnstVector | Out-String)
if ($LASTEXITCODE -ne 0) { throw "LFNST specialty vector generation failed" }
$lfnstVectorManifest = $lfnstVectorOutput | ConvertFrom-Json
if (($lfnstVectorManifest.cases -ne 1088) -or
    ($lfnstVectorManifest.basis_cases -ne 1024)) {
    throw "unexpected LFNST specialty vector set"
}
if ($EvidenceDir) {
    Copy-Item -LiteralPath $LfnstVector -Destination (Join-Path $EvidenceDir "lfnst_engine_vectors.txt")
    $lfnstVectorOutput | Set-Content -LiteralPath (Join-Path $EvidenceDir "LFNST_ENGINE_VECTOR_MANIFEST.json") -Encoding utf8
}
$LfnstWrapperVector = Join-Path $WorkRoot "lfnst_wrapper_vectors.txt"
$lfnstWrapperVectorOutput = (& python $LfnstWrapperVectorGenerator --profile $ProfileName $LfnstWrapperVector | Out-String)
if ($LASTEXITCODE -ne 0) { throw "LFNST wrapper specialty vector generation failed" }
$lfnstWrapperVectorManifest = $lfnstWrapperVectorOutput | ConvertFrom-Json
if (($lfnstWrapperVectorManifest.cases -ne 388) -or
    ($lfnstWrapperVectorManifest.all_gather_terms -ne $true)) {
    throw "unexpected LFNST wrapper specialty vector set"
}
if ($EvidenceDir) {
    Copy-Item -LiteralPath $LfnstWrapperVector -Destination (Join-Path $EvidenceDir "lfnst_wrapper_vectors.txt")
    $lfnstWrapperVectorOutput | Set-Content -LiteralPath (Join-Path $EvidenceDir "LFNST_WRAPPER_VECTOR_MANIFEST.json") -Encoding utf8
}

function Assert-TranscriptPass([string]$Path, [string]$Marker) {
    $text = Get-Content -LiteralPath $Path -Raw
    if (-not $text.Contains($Marker)) {
        throw "PASS marker missing from ${Path}: $Marker"
    }
    if ($text -match "Errors:\s*[1-9]") {
        throw "ModelSim errors reported in $Path"
    }
}

$runs = @()
$testRuns = @()
$compileRuns = @()

function Invoke-VsimTest([string]$Mode, [string]$Design, [string]$LogPath,
                         [string]$PassMarker, [string[]]$ExtraArgs = @()) {
    $arguments = @("-c", "work.$Design") + $ExtraArgs + @("-l", $LogPath, "-do", "run -all; quit -f")
    $command = '"{0}" {1}' -f $Vsim, (($arguments | ForEach-Object {
        if ($_ -match '\s') { '"' + $_.Replace('"', '\"') + '"' } else { $_ }
    }) -join ' ')
    & $Vsim @arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "vsim failed ($exitCode): $Design ($Mode)" }
    Assert-TranscriptPass $LogPath $PassMarker
    $script:testRuns += [ordered]@{
        mode = $Mode
        design = $Design
        command = $command
        exit_code = $exitCode
        log = (Split-Path $LogPath -Leaf)
        log_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $LogPath).Hash
        pass_marker = $PassMarker
    }
}

foreach ($mode in @("normal", "synthesis")) {
    $dir = Join-Path $WorkRoot $mode
    $romDir = Join-Path $dir "03_verification\sim"
    New-Item -ItemType Directory -Force -Path $romDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot "02_rtl\rtl\rom_coeffs.hex") -Destination $romDir
    Copy-Item -LiteralPath (Join-Path $RepoRoot "02_rtl\rtl\lfnst_coeffs.hex") -Destination $romDir
    Copy-Item -LiteralPath (Join-Path $RepoRoot "02_rtl\rtl\lfnst_packed_coeffs.hex") -Destination $romDir
    Copy-Item -LiteralPath $LfnstVector -Destination (Join-Path $dir "lfnst_engine_vectors.txt")
    Copy-Item -LiteralPath $LfnstWrapperVector -Destination (Join-Path $dir "lfnst_wrapper_vectors.txt")

    $gateBVector = Join-Path $dir "unified_gate_b_vectors.txt"
    $gateCVector = Join-Path $dir "unified_gate_c_vectors.txt"
    $gateBGeneratorOutput = (& python $GateBGenerator $gateBVector | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Gate-B vector generation failed for $mode" }
    $gateCGeneratorOutput = (& python $GateCGenerator --profile $ProfileName --full $gateCVector | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "full Gate-C vector generation failed for $mode" }
    $gateBManifest = $gateBGeneratorOutput | ConvertFrom-Json
    $gateCManifest = $gateCGeneratorOutput | ConvertFrom-Json
    if (($gateCManifest.cases -ne 369) -or ($gateCManifest.beats -ne 45636)) {
        throw "unexpected full Gate-C vector set for $mode"
    }
    if ($EvidenceDir) {
        Copy-Item -LiteralPath $gateBVector -Destination (Join-Path $EvidenceDir ($mode + "_GATE_B_VECTORS.txt"))
        Copy-Item -LiteralPath $gateCVector -Destination (Join-Path $EvidenceDir ($mode + "_GATE_C_VECTORS.txt"))
        $gateBManifest | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath (Join-Path $EvidenceDir ($mode + "_GATE_B_VECTOR_MANIFEST.json")) -Encoding utf8
        $gateCManifest | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath (Join-Path $EvidenceDir ($mode + "_FULL_GATE_C_VECTOR_MANIFEST.json")) -Encoding utf8
    }

    Push-Location $dir
    try {
        & $Vlib work | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "vlib failed for $mode" }
        $define = @()
        if ($mode -eq "synthesis") { $define = @("+define+SYNTHESIS") }
        $compileLog = Join-Path $dir "compile.log"
        $compileSources = @($SimpleRam, $InputBank, $Kernel, $LfnstEngine, $Wrapper, $SubmissionTop,
                            $KernelTb, $ThroughputTb, $ThroughputFullTb, $SmokeTb, $P3Tb, $P4Tb, $FifoResetTb,
                            $NumericTb, $AdapterTb, $SatWrapperTb, $HReadRawCaptureTb, $PrimaryVReturnTb,
                            $SubmissionTopTb, $SubmissionNumericTb, $SubmissionProtocolTb, $LfnstTb)
        $compileArguments = @("-sv") + $define + $compileSources + @("-l", $compileLog)
        $compileCommand = '"{0}" {1}' -f $Vlog, (($compileArguments | ForEach-Object {
            if ($_ -match '\s') { '"' + $_.Replace('"', '\"') + '"' } else { $_ }
        }) -join ' ')
        & $Vlog @compileArguments
        $compileExitCode = $LASTEXITCODE
        if ($compileExitCode -ne 0) { throw "vlog failed for $mode (exit=$compileExitCode)" }
        $compileText = Get-Content -LiteralPath $compileLog -Raw
        if ($compileText -match "Warnings:\s*[1-9]") {
            throw "ModelSim compile warnings present for $mode; interface drift must be resolved"
        }
        $compileRuns += [ordered]@{
            mode = $mode
            command = $compileCommand
            exit_code = $compileExitCode
            log = Split-Path $compileLog -Leaf
            log_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $compileLog).Hash
        }

        $kernelLog = Join-Path $dir "gate_b_kernel_numeric.log"
        Invoke-VsimTest $mode "unified_p4_kernel_numeric_tb" $kernelLog "GATE_B_NUMERIC_TB_PASS cases=156"

        $throughputLog = Join-Path $dir "gate_b_vector_ii.log"
        Invoke-VsimTest $mode "unified_p4_kernel_throughput_tb" $throughputLog "GATE_B_VECTOR_II_TB_PASS modes=7"

        $throughputFullLog = Join-Path $dir "gate_f_vector_ii.log"
        Invoke-VsimTest $mode "unified_p4_kernel_throughput_full_tb" $throughputFullLog "GATE_F_VECTOR_II_TB_PASS modes=13"

        $smokeLog = Join-Path $dir "gate_c_wrapper_smoke.log"
        Invoke-VsimTest $mode "unified_its_wrapper_tb" $smokeLog "GATE_C_WRAPPER_TB_PASS beats=16/16 done=1/1"

        $p3Log = Join-Path $dir "p3_vwrite_contract.log"
        Invoke-VsimTest $mode "unified_its_wrapper_p3_tb" $p3Log "P3_VWRITE_TB_PASS"

        $p4Log = Join-Path $dir "p4_stage0_issue_contract.log"
        Invoke-VsimTest $mode "unified_p4_kernel_p4_tb" $p4Log "GATE_F_P4_STAGE0_TB_PASS vectors=16 descriptors=16 captures=16 releases=16"

        $fifoResetLog = Join-Path $dir "p4_fifo_payload_reset.log"
        Invoke-VsimTest $mode "unified_p4_fifo_payload_reset_tb" $fifoResetLog "P4_FIFO_PAYLOAD_RESET_PASS inflight_reset=1 queued_nonzero_reset=1 stale_outputs=0"

        $numericLog = Join-Path $dir "gate_c_wrapper_numeric.log"
        Invoke-VsimTest $mode "unified_its_wrapper_numeric_tb" $numericLog "GATE_C_NUMERIC_TB_PASS cases=369"

        $adapterLog = Join-Path $dir "sat10_adapter_exhaustive.log"
        Invoke-VsimTest $mode "unified_its_final_adapter_tb" $adapterLog "SAT10_ADAPTER_EXHAUSTIVE_PASS values=65536"
        Assert-TranscriptPass $adapterLog "SAT10_ADAPTER_BOUNDARY_PASS values=-513,-512,-511,510,511,512"

        $satWrapperLog = Join-Path $dir "sat10_wrapper_boundary.log"
        Invoke-VsimTest $mode "unified_its_sat10_wrapper_tb" $satWrapperLog "SAT10_WRAPPER_BOUNDARY_PASS cases=5 beats=24 grid_init=2 stale_payload=1"

        $hreadRawLog = Join-Path $dir "hread_raw_capture.log"
        Invoke-VsimTest $mode "unified_its_hread_raw_capture_tb" $hreadRawLog `
            "H_READ_RAW_CAPTURE_PASS"

        $primaryVReturnLog = Join-Path $dir "primary_v_return_credit.log"
        Invoke-VsimTest $mode "unified_its_primary_v_return_tb" $primaryVReturnLog `
            "PRIMARY_V_RETURN_PASS outstanding_depth=4 real_stall_cycles=8 beats=64 done=1 request_ii_pairs=3"

        $topLog = Join-Path $dir "sat10_submission_top.log"
        Invoke-VsimTest $mode "its_unified_submission_top_sat10_tb" $topLog "SAT10_SUBMISSION_TOP_PASS tus=2 beats=8 done=2"

        $topNumericLog = Join-Path $dir "submission_top_full_gate_c.log"
        Invoke-VsimTest $mode "its_unified_submission_top_numeric_tb" $topNumericLog "SUBMISSION_TOP_NUMERIC_PASS cases=369 beats=45636"
        $topLfnstLog = Join-Path $dir "submission_top_lfnst_specialty.log"
        Invoke-VsimTest $mode "its_unified_submission_top_numeric_tb" $topLfnstLog "SUBMISSION_TOP_NUMERIC_PASS cases=388 beats=6724" @("-gVECTOR_FILE=lfnst_wrapper_vectors.txt")
        $topProtocolLog = Join-Path $dir "submission_top_protocol.log"
        Invoke-VsimTest $mode "its_unified_submission_top_protocol_tb" $topProtocolLog "SUBMISSION_TOP_PROTOCOL_PASS end_empty=1 end_commit=1 final_same_edge=1 reset_inflight=1 input_gaps=1 illegal_sticky=1"

        $lfnstLog = Join-Path $dir "lfnst_engine_specialty.log"
        Invoke-VsimTest $mode "bounded_lfnst_engine_tb" $lfnstLog "LFNST_ENGINE_TB_PASS cases=1088"

        $lfnstWrapperLog = Join-Path $dir "lfnst_wrapper_specialty.log"
        Invoke-VsimTest $mode "unified_its_wrapper_numeric_tb" $lfnstWrapperLog "GATE_C_NUMERIC_TB_PASS cases=388" @("-gVECTOR_FILE=lfnst_wrapper_vectors.txt")

        $modeLogs = @($compileLog, $kernelLog, $throughputLog, $throughputFullLog,
                      $smokeLog, $p3Log, $p4Log, $fifoResetLog, $numericLog, $adapterLog, $satWrapperLog,
                      $hreadRawLog, $primaryVReturnLog, $topLog, $topNumericLog, $topLfnstLog, $topProtocolLog, $lfnstLog, $lfnstWrapperLog)
        if ($EvidenceDir) {
            foreach ($log in $modeLogs) {
                Copy-Item -LiteralPath $log -Destination (Join-Path $EvidenceDir ($mode + "_" + (Split-Path $log -Leaf)))
            }
        }
        $runs += [ordered]@{
            mode = $mode
            compile = "PASS"
            gate_b_kernel_numeric = "PASS_156_CASES"
            gate_b_vector_ii_legacy = "PASS_7_MODES"
            gate_f_vector_ii = "PASS_13_MODES"
            gate_c_wrapper_smoke = "PASS"
            p3_vwrite_contract = "PASS"
            p4_stage0_issue_contract = "PASS_16_N4_VECTORS_SLOT_RELEASE"
            p4_fifo_payload_reset = "PASS_INFLIGHT_AND_QUEUED_RESET_NO_STALE_OUTPUT"
            gate_c_wrapper_numeric = "PASS_369_CASES"
            sat10_adapter_exhaustive = "PASS_65536_VALUES"
            sat10_wrapper_boundary = "PASS_5_CASES_24_BEATS_LFNST_GRID_REINIT"
            hread_raw_capture = "PASS_ORDERED_PAYLOAD_METADATA_AND_REAL_STALL"
            primary_v_return_credit = "PASS_DEPTH_4_REAL_STALL_ORDERED_64_BEATS_REQUEST_II1"
            sat10_submission_top = "PASS_2_TUS_8_BEATS_MIN_8_REAL_PENDING_STALL_CYCLES"
            submission_top_full_gate_c = "PASS_369_CASES_45636_BEATS"
            submission_top_lfnst_specialty = "PASS_388_CASES_6724_BEATS"
            submission_top_protocol = "PASS_END_MARKERS_RESET_INPUT_GAPS_ILLEGAL_STICKY"
            lfnst_engine_specialty = "PASS_1088_CASES"
            lfnst_wrapper_specialty = "PASS_388_CASES"
            gate_c_beats = 45636
            logs = @($modeLogs | ForEach-Object {
                [ordered]@{
                    name = Split-Path $_ -Leaf
                    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash
                }
            })
        }
    } finally {
        Pop-Location
    }
}

$summary = [ordered]@{
    schema = "step12f.coverage.modelsim_run.v1"
    status = "PASS"
    simulator = "ModelSim SE-64 2020.4"
    simulator_path = $Vsim
    license_path = $License
    work_root = $WorkRoot
    source_hashes = [ordered]@{
        its_simple_ram = (Get-FileHash -Algorithm SHA256 -LiteralPath $SimpleRam).Hash
        its_input_cache_bank = (Get-FileHash -Algorithm SHA256 -LiteralPath $InputBank).Hash
        unified_p4_kernel = (Get-FileHash -Algorithm SHA256 -LiteralPath $Kernel).Hash
        bounded_lfnst_engine = (Get-FileHash -Algorithm SHA256 -LiteralPath $LfnstEngine).Hash
        bounded_lfnst_engine_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $LfnstTb).Hash
        lfnst_vector_generator = (Get-FileHash -Algorithm SHA256 -LiteralPath $LfnstVectorGenerator).Hash
        lfnst_wrapper_vector_generator = (Get-FileHash -Algorithm SHA256 -LiteralPath $LfnstWrapperVectorGenerator).Hash
        unified_its_wrapper = (Get-FileHash -Algorithm SHA256 -LiteralPath $Wrapper).Hash
        its_unified_submission_top = (Get-FileHash -Algorithm SHA256 -LiteralPath $SubmissionTop).Hash
        gate_b_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $KernelTb).Hash
        gate_b_throughput_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $ThroughputTb).Hash
        gate_f_throughput_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $ThroughputFullTb).Hash
        gate_c_smoke_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $SmokeTb).Hash
        p3_vwrite_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $P3Tb).Hash
        p4_stage0_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $P4Tb).Hash
        p4_fifo_payload_reset_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $FifoResetTb).Hash
        gate_c_numeric_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $NumericTb).Hash
        sat10_adapter_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $AdapterTb).Hash
        sat10_wrapper_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $SatWrapperTb).Hash
        hread_raw_capture_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $HReadRawCaptureTb).Hash
        primary_v_return_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $PrimaryVReturnTb).Hash
        sat10_submission_top_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $SubmissionTopTb).Hash
        submission_top_numeric_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $SubmissionNumericTb).Hash
        submission_top_protocol_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $SubmissionProtocolTb).Hash
    }
    vector_sets = [ordered]@{
        gate_b = [ordered]@{
            cases = 156
            one_d_modes = 13
            stages = 2
            patterns_per_stage = 6
            throughput_modes_legacy = 7
            throughput_modes_full = 13
        }
        gate_c = [ordered]@{
            cases = 369
            beats = 45636
            tuple_source = "05_audit/current/27/step12d_engineering/LEGAL_TRANSFORM_MATRIX.json"
            includes_lfnst = $true
            includes_rectangles = $true
            sparse_inputs = $true
            output_adapter = $Profile.final10.default
            backpressure = $true
        }
        lfnst_specialty = [ordered]@{
            engine_cases = 1088
            engine_basis_cases = 1024
            wrapper_cases = 388
            wrapper_beats = 6724
            all_gather_terms = $true
            all_set_index = $true
        }
    }
    runs = $runs
    profile = [ordered]@{
        name = $Profile.profile_name
        adapter = $Profile.final10.default
        decision_class = $Profile.decision_class
        official_equivalence = $Profile.official_equivalence
        source = $ProfilePath
        sha256 = $ProfileSha256
    }
    tested_source_commit = (git -C $RepoRoot rev-parse HEAD).Trim()
    compile_records = $compileRuns
    command_records = $testRuns
}
$summaryJson = $summary | ConvertTo-Json -Depth 10
if ($EvidenceDir) {
    $summaryJson | Set-Content -LiteralPath (Join-Path $EvidenceDir "STEP12F_COVERAGE_MODELSIM_RUN.json") -Encoding utf8
}
$summaryJson

