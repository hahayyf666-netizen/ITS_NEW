param(
    [Parameter(Mandatory=$true)][string]$WorkRoot,
    [string]$NativeExe='',
    [string]$Compiler='D:\AMDDesignTools\2025.2\tps\mingw\10.0.0\win64.o\nt\bin\g++.exe',
    [string]$BaselineRoot=''
)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if(-not $BaselineRoot){$BaselineRoot=Join-Path $repo '03_verification/regression_baseline/081efa6'}
if(-not (Test-Path -LiteralPath (Join-Path $BaselineRoot '02_rtl/rtl/unified_its_wrapper.sv'))){throw 'Frozen negative-control fixture unavailable'}
if(Test-Path -LiteralPath (Join-Path $BaselineRoot 'BASELINE_MANIFEST.json')){
    $baselineManifest=Get-Content -LiteralPath (Join-Path $BaselineRoot 'BASELINE_MANIFEST.json') -Raw | ConvertFrom-Json
    foreach($file in $baselineManifest.files){
        if((Get-FileHash -LiteralPath (Join-Path $BaselineRoot $file.path)).Hash.ToLowerInvariant() -cne $file.sha256){throw "Negative fixture mutation: $($file.path)"}
    }
}
if(Test-Path -LiteralPath $WorkRoot){throw 'Use a new work/evidence directory'}
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
$WorkRoot=(Resolve-Path -LiteralPath $WorkRoot).Path
$env:PYTHONDONTWRITEBYTECODE='1'
$env:PYTHONIOENCODING='utf-8'
$modelsim='D:\software\Modelsim\win64'
$env:LM_LICENSE_FILE='D:\software\Modelsim\LICENSE.TXT'
$env:MGLS_LICENSE_FILE=$env:LM_LICENSE_FILE
if(-not $NativeExe){
    $NativeExe=Join-Path $WorkRoot 'vtm_full_spatial_oracle.exe'
    $vtm=Join-Path $repo '04_reference/VTM/source/Lib/CommonLib'
    $env:PATH=(Split-Path $Compiler)+';'+$env:PATH
    & $Compiler -std=c++17 -O2 -static -I $vtm (Join-Path $PSScriptRoot 'vtm_full_spatial_oracle.cpp') `
        (Join-Path $vtm 'TrQuant_EMT.cpp') (Join-Path $vtm 'RomTr.cpp') -o $NativeExe *> (Join-Path $WorkRoot 'native_compile.log')
    if($LASTEXITCODE -ne 0){throw 'Native VTM compile failed'}
}
$nativeEvidence=Join-Path $WorkRoot 'reference'
& python (Join-Path $PSScriptRoot 'verify_full_spatial_reference.py') --native-exe $NativeExe --evidence-dir $nativeEvidence *> (Join-Path $WorkRoot 'reference.log')
if($LASTEXITCODE -ne 0){throw 'Native VTM cross-check failed'}
$ref=Get-Content -LiteralPath (Join-Path $nativeEvidence 'FULL_SPATIAL_REFERENCE.json') -Raw | ConvertFrom-Json
if($ref.status -ne 'PASS_NATIVE_VTM_FULL_SPATIAL_REFERENCE'){throw 'Reference proof incomplete'}
# Ensure the separately directed credit test also uses the native expectations.
$primaryText=Get-Content -LiteralPath (Join-Path $repo '03_verification/tb/unified_its_primary_v_return_tb.sv') -Raw
$constants=@([regex]::Matches($primaryText,"expected_beat = 40'h([0-9a-f]{10})") | ForEach-Object {$_.Groups[1].Value})
$nativeConstants=@(Get-Content -LiteralPath (Join-Path $nativeEvidence 'primary_return_expected.hex'))
if(($constants -join ',') -cne ($nativeConstants -join ',')){throw 'Primary-V static expectations differ from native VTM'}
$rtlNames=@('its_simple_ram.sv','its_input_cache_bank.sv','unified_p4_kernel.sv','bounded_lfnst_engine.sv','unified_its_wrapper.sv','its_unified_submission_top.sv')
$tbs=@(
    @('its_unified_submission_top_dc_full_tb','FULL_SPATIAL_DC_PASS cases=5'),
    @('its_unified_submission_top_full_spatial_tb',"FULL_SPATIAL_NUMERIC_PASS cases=$($ref.extra_cases)"),
    @('its_unified_submission_top_full_spatial_contract_tb','FULL_SPATIAL_CONTRACT_PASS mixed_tus=8 boundary_stalls=8 final_stalls=8 reset_cases=4')
)
function Stage-Roms([string]$dir,[string]$source){
    New-Item -ItemType Directory -Force -Path (Join-Path $dir '03_verification/sim') | Out-Null
    foreach($name in @('rom_coeffs.hex','lfnst_coeffs.hex','lfnst_packed_coeffs.hex')){
        Copy-Item -LiteralPath (Join-Path $source "02_rtl/rtl/$name") -Destination (Join-Path $dir '03_verification/sim')
    }
}
$records=@()
foreach($mode in @('normal','synthesis')){
    $dir=Join-Path $WorkRoot $mode;Stage-Roms $dir $repo
    Copy-Item -LiteralPath (Join-Path $nativeEvidence 'full_spatial_vectors.txt') -Destination $dir
    Push-Location $dir
    try {
        & (Join-Path $modelsim 'vlib.exe') work *> vlib.log
        if($LASTEXITCODE -ne 0){throw 'vlib failed'}
        $defs=@();if($mode -eq 'synthesis'){$defs=@('+define+SYNTHESIS')}
        $sources=@($rtlNames | ForEach-Object {Join-Path $repo "02_rtl/rtl/$_"})
        $sources+=@($tbs | ForEach-Object {Join-Path $repo "03_verification/tb/$($_[0]).sv"})
        & (Join-Path $modelsim 'vlog.exe') -sv @defs @sources -l compile.log *> compile_console.log
        if($LASTEXITCODE -ne 0){throw "Compile failed: $mode"}
        if((Get-Content compile.log -Raw) -match '(Errors|Warnings):\s*[1-9]'){throw 'Compile diagnostic present'}
        foreach($test in $tbs){
            $log="$($test[0]).log"
            & (Join-Path $modelsim 'vsim.exe') -c "work.$($test[0])" -l $log -do 'run -all; quit -f' *> "$($test[0])_console.log"
            $code=$LASTEXITCODE;$txt=Get-Content -LiteralPath $log -Raw
            if($code -ne 0 -or -not $txt.Contains($test[1]) -or $txt -match 'Errors:\s*[1-9]|\*\* (Fatal|Error)'){
                throw "Full-spatial test failed: $mode/$($test[0])"
            }
            $records+=@{mode=$mode;test=$test[0];exit_code=$code;pass_marker=$test[1];log_sha256=(Get-FileHash $log).Hash}
        }
    } finally {Pop-Location}
}
$negative='NOT_RUN'
if($BaselineRoot){
    $dir=Join-Path $WorkRoot 'baseline_negative_control';Stage-Roms $dir $BaselineRoot
    Push-Location $dir
    try {
        & (Join-Path $modelsim 'vlib.exe') work *> vlib.log
        $old=@($rtlNames | ForEach-Object {Join-Path $BaselineRoot "02_rtl/rtl/$_"})
        & (Join-Path $modelsim 'vlog.exe') -sv @old (Join-Path $repo '03_verification/tb/its_unified_submission_top_dc_full_tb.sv') -l compile.log *> compile_console.log
        if($LASTEXITCODE -ne 0){throw 'Negative control did not compile'}
        & (Join-Path $modelsim 'vsim.exe') -c work.its_unified_submission_top_dc_full_tb -l negative.log -do 'run -all; quit -f' *> negative_console.log
        $txt=Get-Content negative.log -Raw
        if(-not $txt.Contains('full spatial DC mismatch samples=') -or $txt.Contains('FULL_SPATIAL_DC_PASS')){throw 'Negative control was not detected'}
        $negative='EXPECTED_FAIL_DETECTED'
    } finally {Pop-Location}
}
$result=[ordered]@{
    status='PASS_FULL_SPATIAL_REPAIR_REGRESSION';reference=$ref.status;reference_standard_cases=$ref.standard_cases;
    reference_extra_cases=$ref.extra_cases;reference_scalar_values=$ref.scalar_values;
    simulations=$records.Count;records=$records;baseline_negative_control=$negative;
    official_equivalence='NOT_PROVEN';source_commit=(git -C $repo rev-parse HEAD).Trim();
    source_files=@($rtlNames | ForEach-Object {@{path="02_rtl/rtl/$_";sha256=(Get-FileHash (Join-Path $repo "02_rtl/rtl/$_")).Hash}})
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $WorkRoot 'FULL_SPATIAL_REGRESSION.json') -Encoding utf8
Write-Output "FULL_SPATIAL_REPAIR_PASS simulations=$($records.Count) negative=$negative"
