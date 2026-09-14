param(
    [string]$WorkRoot = (Join-Path $env:TEMP ("step12d_gate_bc_" + (Get-Date -Format "yyyyMMdd_HHmmss"))),
    [string]$EvidenceDir = ""
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
    # Resolve before Push-Location changes the process working directory;
    # otherwise a relative evidence path is accidentally nested under the
    # temporary ModelSim work tree.
    $EvidenceDir = (Resolve-Path -LiteralPath $EvidenceDir).Path
}

$Kernel = Join-Path $RepoRoot "02_rtl\rtl\unified_p4_kernel.sv"
$SimpleRam = Join-Path $RepoRoot "02_rtl\rtl\its_simple_ram.sv"
$InputBank = Join-Path $RepoRoot "02_rtl\rtl\its_input_cache_bank.sv"
$LfnstEngine = Join-Path $RepoRoot "02_rtl\rtl\bounded_lfnst_engine.sv"
$Wrapper = Join-Path $RepoRoot "02_rtl\rtl\unified_its_wrapper.sv"
$KernelTb = Join-Path $RepoRoot "03_verification\tb\unified_p4_kernel_numeric_tb.sv"
$ThroughputTb = Join-Path $RepoRoot "03_verification\tb\unified_p4_kernel_throughput_tb.sv"
$SmokeTb = Join-Path $RepoRoot "03_verification\tb\unified_its_wrapper_tb.sv"
$NumericTb = Join-Path $RepoRoot "03_verification\tb\unified_its_wrapper_numeric_tb.sv"
$GateBGenerator = Join-Path $RepoRoot "03_verification\step12d_engineering\generate_gate_b_hdl_vectors.py"
$GateCGenerator = Join-Path $RepoRoot "03_verification\step12d_engineering\generate_gate_c_hdl_vectors.py"

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
    & python $GateBGenerator (Join-Path $dir "unified_gate_b_vectors.txt")
    if ($LASTEXITCODE -ne 0) { throw "Gate-B vector generation failed" }
    & python $GateCGenerator (Join-Path $dir "unified_gate_c_vectors.txt")
    if ($LASTEXITCODE -ne 0) { throw "Gate-C vector generation failed" }

    Push-Location $dir
    try {
        & $Vlib work | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "vlib failed for $mode" }
        $define = @()
        if ($mode -eq "synthesis") { $define = @("+define+SYNTHESIS") }
        $compileLog = Join-Path $dir "compile.log"
        & $Vlog -sv @define $SimpleRam $InputBank $Kernel $LfnstEngine $Wrapper $KernelTb $ThroughputTb $SmokeTb $NumericTb -l $compileLog
        if ($LASTEXITCODE -ne 0) { throw "vlog failed for $mode" }

        $kernelLog = Join-Path $dir "gate_b_kernel_numeric.log"
        & $Vsim -c work.unified_p4_kernel_numeric_tb -l $kernelLog -do "run -all; quit -f"
        Assert-TranscriptPass $kernelLog "GATE_B_NUMERIC_TB_PASS cases=156"

        $throughputLog = Join-Path $dir "gate_b_vector_ii.log"
        & $Vsim -c work.unified_p4_kernel_throughput_tb -l $throughputLog -do "run -all; quit -f"
        Assert-TranscriptPass $throughputLog "GATE_B_VECTOR_II_TB_PASS modes=7"

        $smokeLog = Join-Path $dir "gate_c_wrapper_smoke.log"
        & $Vsim -c work.unified_its_wrapper_tb -l $smokeLog -do "run -all; quit -f"
        Assert-TranscriptPass $smokeLog "GATE_C_WRAPPER_TB_PASS beats=16/16 done=1/1"

        $numericLog = Join-Path $dir "gate_c_wrapper_numeric.log"
        & $Vsim -c work.unified_its_wrapper_numeric_tb -l $numericLog -do "run -all; quit -f"
        Assert-TranscriptPass $numericLog "GATE_C_NUMERIC_TB_PASS cases=19"

        $modeLogs = @($compileLog, $kernelLog, $throughputLog, $smokeLog, $numericLog)
        if ($EvidenceDir) {
            foreach ($log in $modeLogs) {
                Copy-Item -LiteralPath $log -Destination (Join-Path $EvidenceDir ($mode + "_" + (Split-Path $log -Leaf)))
            }
        }
        $runs += [ordered]@{
            mode = $mode
            compile = "PASS"
            gate_b_kernel_numeric = "PASS_156_CASES"
            gate_b_vector_ii = "PASS_7_MODES"
            gate_c_wrapper_smoke = "PASS"
            gate_c_wrapper_numeric = "PASS_19_CASES"
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
    schema = "step12d_engineering.modelsim_gate_bc_run.v1"
    status = "PASS"
    simulator = "ModelSim SE-64 2020.4"
    simulator_path = $Vsim
    license_path = $License
    work_root = $WorkRoot
    source_hashes = [ordered]@{
        its_simple_ram = (Get-FileHash -Algorithm SHA256 -LiteralPath $SimpleRam).Hash
        its_input_cache_bank = (Get-FileHash -Algorithm SHA256 -LiteralPath $InputBank).Hash
        unified_p4_kernel = (Get-FileHash -Algorithm SHA256 -LiteralPath $Kernel).Hash
        unified_its_wrapper = (Get-FileHash -Algorithm SHA256 -LiteralPath $Wrapper).Hash
        gate_b_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $KernelTb).Hash
        gate_b_throughput_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $ThroughputTb).Hash
        gate_c_smoke_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $SmokeTb).Hash
        gate_c_numeric_tb = (Get-FileHash -Algorithm SHA256 -LiteralPath $NumericTb).Hash
    }
    vector_sets = [ordered]@{
        gate_b = [ordered]@{
            cases = 156
            one_d_modes = 13
            stages = 2
            patterns_per_stage = 6
            throughput_modes = 7
        }
        gate_c = [ordered]@{
            cases = 19
            beats = 2368
            includes_lfnst = $true
            includes_rectangles = $true
            includes_backpressure = $true
        }
    }
    runs = $runs
}
$summaryJson = $summary | ConvertTo-Json -Depth 8
if ($EvidenceDir) {
    $summaryJson | Set-Content -LiteralPath (Join-Path $EvidenceDir "GATE_B_C_MODELSIM_RUN.json") -Encoding utf8
}
$summaryJson
