param([string]$KernelSource = "", [string]$EvidenceDir = "")
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $KernelSource) { $KernelSource = Join-Path $PSScriptRoot 'unified_p4_kernel.sv' }
$KernelSource = (Resolve-Path -LiteralPath $KernelSource).Path
if (-not $EvidenceDir) { $EvidenceDir = Join-Path $RepoRoot '05_audit\current\31\coeff_layout' }
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$EvidenceDir = (Resolve-Path -LiteralPath $EvidenceDir).Path
$env:LM_LICENSE_FILE = 'D:\software\Modelsim\LICENSE.TXT'
$env:MGLS_LICENSE_FILE = $env:LM_LICENSE_FILE
$ModelSimBin = 'D:\software\Modelsim\win64'
$Tb = Join-Path $RepoRoot '03_verification\tb\unified_p4_coeff_layout_tb.sv'
foreach ($Mode in @('normal', 'synthesis')) {
    $ModeDir = Join-Path $EvidenceDir $Mode
    $RomDir = Join-Path $ModeDir '03_verification\sim'
    New-Item -ItemType Directory -Force -Path $RomDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot '02_rtl\rtl\rom_coeffs.hex') -Destination $RomDir
    Push-Location $ModeDir
    try {
        & (Join-Path $ModelSimBin 'vlib.exe') work
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
        $Defines = @()
        if ($Mode -eq 'synthesis') { $Defines = @('+define+SYNTHESIS') }
        & (Join-Path $ModelSimBin 'vlog.exe') -sv @Defines $KernelSource $Tb -l compile.log
        if ($LASTEXITCODE -ne 0) { throw 'vlog failed' }
        & (Join-Path $ModelSimBin 'vsim.exe') -c work.unified_p4_coeff_layout_tb -l layout.log -do 'run -all; quit -f'
        if ($LASTEXITCODE -ne 0) { throw 'vsim failed' }
        $Transcript = Get-Content layout.log -Raw
        if (($Transcript -notmatch 'P4_COEFF_LAYOUT_PASS canonical=8176 padding=7440 bundles=61') -or
            ($Transcript -match 'Errors:\s*[1-9]')) { throw 'Coefficient layout verification failed' }
    } finally { Pop-Location }
}
Write-Output 'COEFF_LAYOUT_BOTH_MODES_PASS'
