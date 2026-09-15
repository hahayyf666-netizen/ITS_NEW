param(
    [string]$WorkRoot = (Join-Path $env:TEMP ("step12f_coverage_" + (Get-Date -Format "yyyyMMdd_HHmmss"))),
    [string]$EvidenceDir = "",
    [string]$KernelSource = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
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
if ($KernelSource) { $Kernel = (Resolve-Path -LiteralPath $KernelSource).Path }
$SimpleRam = Join-Path $RepoRoot "02_rtl\rtl\its_simple_ram.sv"
$InputBank = Join-Path $RepoRoot "02_rtl\rtl\its_input_cache_bank.sv"
$LfnstEngine = Join-Path $RepoRoot "02_rtl\rtl\bounded_lfnst_engine.sv"
$Wrapper = Join-Path $RepoRoot "02_rtl\rtl\unified_its_wrapper.sv"
$KernelTb = Join-Path $RepoRoot "03_verification\tb\unified_p4_kernel_numeric_tb.sv"
$ThroughputTb = Join-Path $RepoRoot "03_verification\tb\unified_p4_kernel_throughput_tb.sv"
$ThroughputFullTb = Join-Path $RepoRoot "03_verification\tb\unified_p4_kernel_throughput_full_tb.sv"
$SmokeTb = Join-Path $RepoRoot "03_verification\tb\unified_its_wrapper_tb.sv"
$P3Tb = Join-Path $RepoRoot "03_verification\tb\unified_its_wrapper_p3_tb.sv"
$P4Tb = Join-Path $RepoRoot "03_verification\tb\unified_p4_kernel_p4_tb.sv"
$NumericTb = Join-Path $RepoRoot "03_verification\tb\unified_its_wrapper_numeric_tb.sv"
$GateBGenerator = Join-Path $RepoRoot "03_verification\step12d_engineering\generate_gate_b_hdl_vectors.py"
$GateCGenerator = Join-Path $RepoRoot "03_verification\step12d_engineering\generate_gate_c_hdl_vectors.py"
$LfnstVectorGenerator = Join-Path $RepoRoot "03_verification\step12d_engineering\generate_lfnst_engine_vectors.py"
$LfnstTb = Join-Path $RepoRoot "03_verification\tb\bounded_lfnst_engine_tb.sv"
$LfnstWrapperVectorGenerator = Join-Path $RepoRoot "03_verification\step12d_engineering\generate_lfnst_wrapper_vectors.py"

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
$lfnstWrapperVectorOutput = (& python $LfnstWrapperVectorGenerator $LfnstWrapperVector | Out-String)
if ($LASTEXITCODE -ne 0) { throw "LFNST wrapper specialty vector generation failed" }
$lfnstWrapperVectorManifest = $lfnstWrapperVectorOutput | ConvertFrom-Json
if (($lfnstWrapperVectorManifest.cases -ne 258) -or
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
    $gateCGeneratorOutput = (& python $GateCGenerator --full $gateCVector | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "full Gate-C vector generation failed for $mode" }
    $gateBManifest = $gateBGeneratorOutput | ConvertFrom-Json
    $gateCManifest = $gateCGeneratorOutput | ConvertFrom-Json
    if (($gateCManifest.cases -ne 369) -or ($gateCManifest.beats -ne 45636)) {
        throw "unexpected full Gate-C vector set for $mode"
    }
    if ($EvidenceDir) {
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
        & $Vlog -sv @define $SimpleRam $InputBank $Kernel $LfnstEngine $Wrapper $KernelTb $ThroughputTb $ThroughputFullTb $SmokeTb $P3Tb $P4Tb $NumericTb $LfnstTb -l $compileLog
        if ($LASTEXITCODE -ne 0) { throw "vlog failed for $mode" }

        $kernelLog = Join-Path $dir "gate_b_kernel_numeric.log"
        & $Vsim -c work.unified_p4_kernel_numeric_tb -l $kernelLog -do "run -all; quit -f"
        Assert-TranscriptPass $kernelLog "GATE_B_NUMERIC_TB_PASS cases=156"

        $throughputLog = Join-Path $dir "gate_b_vector_ii.log"
        & $Vsim -c work.unified_p4_kernel_throughput_tb -l $throughputLog -do "run -all; quit -f"
        Assert-TranscriptPass $throughputLog "GATE_B_VECTOR_II_TB_PASS modes=7"

        $throughputFullLog = Join-Path $dir "gate_f_vector_ii.log"
        & $Vsim -c work.unified_p4_kernel_throughput_full_tb -l $throughputFullLog -do "run -all; quit -f"
        Assert-TranscriptPass $throughputFullLog "GATE_F_VECTOR_II_TB_PASS modes=13"

        $smokeLog = Join-Path $dir "gate_c_wrapper_smoke.log"
        & $Vsim -c work.unified_its_wrapper_tb -l $smokeLog -do "run -all; quit -f"
        Assert-TranscriptPass $smokeLog "GATE_C_WRAPPER_TB_PASS beats=16/16 done=1/1"

        $p3Log = Join-Path $dir "p3_vwrite_contract.log"
        & $Vsim -c work.unified_its_wrapper_p3_tb -l $p3Log -do "run -all; quit -f"
        Assert-TranscriptPass $p3Log "P3_VWRITE_TB_PASS"

        $p4Log = Join-Path $dir "p4_stage0_issue_contract.log"
        & $Vsim -c work.unified_p4_kernel_p4_tb -l $p4Log -do "run -all; quit -f"
        Assert-TranscriptPass $p4Log "GATE_F_P4_STAGE0_TB_PASS vectors=16 descriptors=16 captures=16 releases=16"

        $numericLog = Join-Path $dir "gate_c_wrapper_numeric.log"
        & $Vsim -c work.unified_its_wrapper_numeric_tb -l $numericLog -do "run -all; quit -f"
        Assert-TranscriptPass $numericLog "GATE_C_NUMERIC_TB_PASS cases=369"

        $lfnstLog = Join-Path $dir "lfnst_engine_specialty.log"
        & $Vsim -c work.bounded_lfnst_engine_tb -l $lfnstLog -do "run -all; quit -f"
        Assert-TranscriptPass $lfnstLog "LFNST_ENGINE_TB_PASS cases=1088"

        $lfnstWrapperLog = Join-Path $dir "lfnst_wrapper_specialty.log"
        & $Vsim -c work.unified_its_wrapper_numeric_tb "-gVECTOR_FILE=lfnst_wrapper_vectors.txt" -l $lfnstWrapperLog -do "run -all; quit -f"
        Assert-TranscriptPass $lfnstWrapperLog "GATE_C_NUMERIC_TB_PASS cases=258"

        $modeLogs = @($compileLog, $kernelLog, $throughputLog, $throughputFullLog,
                      $smokeLog, $p3Log, $p4Log, $numericLog, $lfnstLog, $lfnstWrapperLog)
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
            gate_c_wrapper_numeric = "PASS_369_CASES"
            lfnst_engine_specialty = "PASS_1088_CASES"
            lfnst_wrapper_specialty = "PASS_258_CASES"
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
        gate_b_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $KernelTb).Hash
        gate_b_throughput_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $ThroughputTb).Hash
        gate_f_throughput_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $ThroughputFullTb).Hash
        gate_c_smoke_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $SmokeTb).Hash
        p3_vwrite_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $P3Tb).Hash
        p4_stage0_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $P4Tb).Hash
        gate_c_numeric_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $NumericTb).Hash
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
            output_adapter = "LOW10_TWOS_COMPLEMENT"
            backpressure = $true
        }
        lfnst_specialty = [ordered]@{
            engine_cases = 1088
            engine_basis_cases = 1024
            wrapper_cases = 258
            wrapper_beats = 4644
            all_gather_terms = $true
            all_set_index = $true
        }
    }
    runs = $runs
}
$summaryJson = $summary | ConvertTo-Json -Depth 10
if ($EvidenceDir) {
    $summaryJson | Set-Content -LiteralPath (Join-Path $EvidenceDir "STEP12F_COVERAGE_MODELSIM_RUN.json") -Encoding utf8
}
$summaryJson
