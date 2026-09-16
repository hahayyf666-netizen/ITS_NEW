param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$VivadoExe
)

$ErrorActionPreference = 'Continue'
$rootPath = (Resolve-Path -LiteralPath $Root).Path
$generic = (Resolve-Path -LiteralPath '03_verification/vivado/report_p9_a_routed_qualification.tcl').Path
$hread = (Resolve-Path -LiteralPath '03_verification/vivado/report_p9_r5_hread_address_validity.tcl').Path
$runs = @('R4_REPLAY','R5_REPLAY','R5_NETDELAY','R5_EXTRATIMING','R5_POSTROUTE_PHYSOPT','R5_INCREMENTAL')
$transcript = Join-Path $rootPath 'QUALIFICATION_TRANSCRIPT.txt'
Set-Content -LiteralPath $transcript -Value "vivado=$VivadoExe`r`nvivado_version=2025.2`r`nserial=true`r`n" -Encoding utf8

foreach ($run in $runs) {
    $dcp = Join-Path (Join-Path $rootPath $run) 'final.dcp'
    if (!(Test-Path -LiteralPath $dcp)) {
        Add-Content -LiteralPath $transcript -Value "SKIP $run missing=$dcp"
        continue
    }
    $out = Join-Path (Join-Path $rootPath $run) 'qualification'
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $env:XILINX_LOCAL_USER_DATA = Join-Path $out 'vivado_user'
    Add-Content -LiteralPath $transcript -Value "START generic $run dcp=$dcp out=$out"
    & $VivadoExe -log (Join-Path $out 'vivado_generic.log') -journal (Join-Path $out 'vivado_generic.jou') -mode batch -source $generic -tclargs $dcp $out *> (Join-Path $out 'console_generic.txt')
    Add-Content -LiteralPath $transcript -Value "DONE generic $run exit=$LASTEXITCODE"
    if ($run -ne 'R4_REPLAY') {
        Add-Content -LiteralPath $transcript -Value "START hread $run dcp=$dcp out=$out"
        & $VivadoExe -log (Join-Path $out 'vivado_hread.log') -journal (Join-Path $out 'vivado_hread.jou') -mode batch -source $hread -tclargs $dcp $out *> (Join-Path $out 'console_hread.txt')
        Add-Content -LiteralPath $transcript -Value "DONE hread $run exit=$LASTEXITCODE"
    }
}
Add-Content -LiteralPath $transcript -Value 'QUALIFICATION_BATCH_DONE'

