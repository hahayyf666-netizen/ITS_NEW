[CmdletBinding()]
param(
    [string]$EvidenceDir = '05_audit/current/56/p9_r5b_implementation_convergence_20260917'
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$vivado = 'D:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat'
$generic = (Resolve-Path (Join-Path $PSScriptRoot 'report_p9_a_routed_qualification.tcl')).Path
$hread = (Resolve-Path (Join-Path $PSScriptRoot 'report_p9_r5_hread_address_validity.tcl')).Path
$ev = (Resolve-Path (Join-Path $repo $EvidenceDir)).Path
$transcript = Join-Path $ev 'R5B_TARGETED_QUALIFICATION_TRANSCRIPT.txt'
Set-Content -LiteralPath $transcript -Value "P9-R5B targeted qualification`r`nvivado=$vivado`r`nvivado_version=2025.2`r`nmaxThreads=4`r`n" -Encoding utf8

$runs = @('B0_NETDELAY_REPLAY','B1_SETUP_OPT','B2_HOLD_FIX','B4_AGGRESSIVE_HOLD')
foreach ($name in $runs) {
    $runDir = Join-Path $ev $name
    $dcp = Join-Path $runDir 'final.dcp'
    if (-not (Test-Path -LiteralPath $dcp)) { throw "Missing $dcp" }
    $out = Join-Path $runDir 'targeted_qualification'
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $userData = Join-Path $out 'vivado_user'
    New-Item -ItemType Directory -Force -Path $userData | Out-Null
    $old = $env:XILINX_LOCAL_USER_DATA
    $env:XILINX_LOCAL_USER_DATA = $userData
    try {
        $genericLog = Join-Path $out 'vivado_generic.log'
        $genericJournal = Join-Path $out 'vivado_generic.jou'
        $genericConsole = Join-Path $out 'console_generic.txt'
        Add-Content -LiteralPath $transcript -Value "RUN_START $name generic" -Encoding utf8
        & $vivado -log $genericLog -journal $genericJournal -mode batch -source $generic -tclargs $dcp $out *> $genericConsole
        $rc = $LASTEXITCODE
        Add-Content -LiteralPath $transcript -Value "RUN_END $name generic exit_code=$rc" -Encoding utf8
        if ($rc -ne 0) { throw "Generic qualification failed for $name" }
        $hreadLog = Join-Path $out 'vivado_hread.log'
        $hreadJournal = Join-Path $out 'vivado_hread.jou'
        $hreadConsole = Join-Path $out 'console_hread.txt'
        Add-Content -LiteralPath $transcript -Value "RUN_START $name hread" -Encoding utf8
        & $vivado -log $hreadLog -journal $hreadJournal -mode batch -source $hread -tclargs $dcp $out *> $hreadConsole
        $rc = $LASTEXITCODE
        Add-Content -LiteralPath $transcript -Value "RUN_END $name hread exit_code=$rc" -Encoding utf8
        if ($rc -ne 0) { throw "H-read qualification failed for $name" }
    } finally {
        $env:XILINX_LOCAL_USER_DATA = $old
    }
}
Add-Content -LiteralPath $transcript -Value 'P9_R5B_TARGETED_QUALIFICATION_DONE' -Encoding utf8

