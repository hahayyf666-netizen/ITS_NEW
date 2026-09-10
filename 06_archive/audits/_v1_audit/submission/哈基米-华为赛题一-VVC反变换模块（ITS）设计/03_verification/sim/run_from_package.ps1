param(
    [ValidateSet("singleclk", "core", "top", "synthesis", "all")]
    [string]$Mode = "singleclk"
)

$ErrorActionPreference = "Stop"

$sourceRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$stageRoot = "C:\tmp\its_vvc_modelsim_run"
$stageRtl = Join-Path $stageRoot "rtl"
$stageTb = Join-Path $stageRoot "tb"
$stageSim = Join-Path $stageRoot "sim"

if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stageRtl, $stageTb, $stageSim | Out-Null

Copy-Item -Path (Join-Path $sourceRoot "02_rtl\rtl\*") -Destination $stageRtl -Recurse -Force
Copy-Item -Path (Join-Path $sourceRoot "03_verification\tb\*") -Destination $stageTb -Recurse -Force
Copy-Item -Path (Join-Path $sourceRoot "03_verification\sim\*.do") -Destination $stageSim -Force

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
Get-ChildItem -LiteralPath $stageSim -Filter "*.do" -File | ForEach-Object {
    $doText = [System.IO.File]::ReadAllText($_.FullName)
    $doText = $doText.Replace("../../02_rtl/rtl/", "../rtl/")
    $doText = $doText.Replace("../../02_rtl\rtl\", "../rtl/")
    [System.IO.File]::WriteAllText($_.FullName, $doText, $utf8NoBom)
}

if (-not $env:LM_LICENSE_FILE -and (Test-Path "C:\App\ModelSim\LICENSE.TXT")) {
    $env:LM_LICENSE_FILE = "C:\App\ModelSim\LICENSE.TXT"
}
if (-not $env:MGLS_LICENSE_FILE -and (Test-Path "C:\App\ModelSim\LICENSE.TXT")) {
    $env:MGLS_LICENSE_FILE = "C:\App\ModelSim\LICENSE.TXT"
}

$doList = switch ($Mode) {
    "singleclk" { @("run_500_singleclk.do") }
    "core" { @("run_core_500.do") }
    "top" { @("run.do") }
    "synthesis" { @("run_500_singleclk_synthesis_define.do") }
    "all" { @("run_core_500.do", "run_500_singleclk_synthesis_define.do", "run_500_singleclk.do", "run.do") }
}

Set-Location $stageSim
foreach ($doFile in $doList) {
    Write-Host "==== Running $doFile in $stageSim ===="
    & vsim -c -do "do $doFile"
    if ($LASTEXITCODE -ne 0) {
        throw "ModelSim failed on $doFile with exit code $LASTEXITCODE"
    }
}