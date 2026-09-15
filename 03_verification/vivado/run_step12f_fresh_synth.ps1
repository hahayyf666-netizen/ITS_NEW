param([string]$EvidenceDir = '')
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Vivado = 'D:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat'
if (-not (Test-Path -LiteralPath $Vivado)) { throw "Vivado unavailable: $Vivado" }
if (-not $EvidenceDir) {
    $EvidenceDir = Join-Path $RepoRoot ('05_audit\current\31\fresh_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
if (Test-Path -LiteralPath $EvidenceDir) {
    if (Get-ChildItem -LiteralPath $EvidenceDir -Force | Select-Object -First 1) {
        throw 'Use a new evidence directory; historical results must not be overwritten.'
    }
}
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$EvidenceDir = (Resolve-Path -LiteralPath $EvidenceDir).Path
$env:XILINX_LOCAL_USER_DATA = Join-Path $env:TEMP 'step12f_vivado_user'
New-Item -ItemType Directory -Force -Path $env:XILINX_LOCAL_USER_DATA | Out-Null
$env:STEP12F_REPORT_DIR = $EvidenceDir
$env:STEP12F_RUN_DIR = Join-Path $EvidenceDir 'run'
$env:STEP12F_MAX_THREADS = '4'
$env:STEP12F_RUN_IMPL = '0'
Push-Location $RepoRoot
try {
    & $Vivado -mode batch -source (Join-Path $PSScriptRoot 'run_step12f_unified_wrapper.tcl') `
        -log (Join-Path $EvidenceDir 'vivado.log') -journal (Join-Path $EvidenceDir 'vivado.jou')
    if ($LASTEXITCODE -ne 0) { throw "Vivado exited with code $LASTEXITCODE" }
    foreach ($Name in @('step12f_unified_wrapper_postsynth.dcp', 'report_utilization_postsynth.rpt',
                         'report_timing_summary_postsynth.rpt', 'report_check_timing_postsynth.rpt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $EvidenceDir $Name))) { throw "Missing evidence: $Name" }
    }
    $Log = Get-Content -LiteralPath (Join-Path $EvidenceDir 'vivado.log') -Raw
    if (-not $Log.Contains('STEP12F_DONE')) { throw 'Synthesis/report flow did not finish' }
    Write-Output "SYNTHESIS_COMPLETED (timing signoff is separate): $EvidenceDir"
} finally { Pop-Location }
