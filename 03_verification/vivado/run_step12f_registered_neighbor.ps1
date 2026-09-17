param([string]$EvidenceDir = '')
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Vivado = 'D:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat'
if (-not (Test-Path -LiteralPath $Vivado)) { throw "Vivado unavailable: $Vivado" }
if (-not $EvidenceDir) {
    $EvidenceDir = Join-Path $RepoRoot ('05_audit\current\59\p9_r5e_registered_neighbor_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
if (Test-Path -LiteralPath $EvidenceDir) {
    if (Get-ChildItem -LiteralPath $EvidenceDir -Force | Select-Object -First 1) {
        throw 'Use a new evidence directory; historical results must not be overwritten.'
    }
}
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$EvidenceDir = (Resolve-Path -LiteralPath $EvidenceDir).Path
$env:XILINX_LOCAL_USER_DATA = Join-Path $env:TEMP 'step12f_r5e_vivado_user'
New-Item -ItemType Directory -Force -Path $env:XILINX_LOCAL_USER_DATA | Out-Null
$env:STEP12F_R5E_REPORT_DIR = $EvidenceDir
$env:STEP12F_MAX_THREADS = '4'
Push-Location $RepoRoot
try {
    & $Vivado -mode batch -source (Join-Path $PSScriptRoot 'run_step12f_registered_neighbor.tcl') `
        -log (Join-Path $EvidenceDir 'vivado.log') -journal (Join-Path $EvidenceDir 'vivado.jou')
    if ($LASTEXITCODE -ne 0) { throw "Vivado exited with code $LASTEXITCODE" }
    foreach ($Name in @('step12f_registered_neighbor_postsynth.dcp',
                         'step12f_registered_neighbor_postroute.dcp',
                         'report_timing_summary_postroute.rpt',
                         'report_timing_hold_summary_postroute.rpt',
                         'report_route_status_postroute.rpt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $EvidenceDir $Name))) { throw "Missing evidence: $Name" }
    }
    $Log = Get-Content -LiteralPath (Join-Path $EvidenceDir 'vivado.log') -Raw
    if (-not $Log.Contains('P9R5E_DONE')) { throw 'P9-R5E flow did not finish' }
    Write-Output "P9R5E_COMPLETED: $EvidenceDir"
} finally { Pop-Location }

