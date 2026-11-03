param([Parameter(Mandatory=$true)][string]$WorkRoot)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if(Test-Path -LiteralPath $WorkRoot){throw 'Use a new performance directory'}
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$WorkRoot=(Resolve-Path -LiteralPath $WorkRoot).Path
$env:PYTHONDONTWRITEBYTECODE='1';$env:PYTHONIOENCODING='utf-8'
$env:LM_LICENSE_FILE='D:\software\Modelsim\LICENSE.TXT';$env:MGLS_LICENSE_FILE=$env:LM_LICENSE_FILE
$sim='D:\software\Modelsim\win64'
& python (Join-Path $PSScriptRoot 'generate_full_spatial_performance_vectors.py') --output-dir $WorkRoot *> (Join-Path $WorkRoot 'generation.log')
if($LASTEXITCODE -ne 0){throw 'Performance vectors failed'}
New-Item -ItemType Directory -Path (Join-Path $WorkRoot '03_verification/sim') -Force | Out-Null
foreach($name in @('rom_coeffs.hex','lfnst_coeffs.hex','lfnst_packed_coeffs.hex')){Copy-Item -LiteralPath (Join-Path $repo "02_rtl/rtl/$name") -Destination (Join-Path $WorkRoot '03_verification/sim')}
$sources=@('its_simple_ram.sv','its_input_cache_bank.sv','unified_p4_kernel.sv','bounded_lfnst_engine.sv','unified_its_wrapper.sv','its_unified_submission_top.sv') | ForEach-Object {Join-Path $repo "02_rtl/rtl/$_"}
$sources+=@('its_full_spatial_performance_tb','its_full_spatial_stream_performance_tb') | ForEach-Object {Join-Path $repo "03_verification/tb/$_.sv"}
Push-Location $WorkRoot
try {
    & (Join-Path $sim 'vlib.exe') work *> vlib.log
    & (Join-Path $sim 'vlog.exe') -sv @sources -l compile.log *> compile_console.log
    if($LASTEXITCODE -ne 0){throw 'Performance compile failed'}
    foreach($test in @('its_full_spatial_performance_tb','its_full_spatial_stream_performance_tb')){
        & (Join-Path $sim 'vsim.exe') -c "work.$test" -l "$test.log" -do 'run -all; quit -f' *> "$test.console.log"
        $txt=Get-Content -LiteralPath "$test.log" -Raw
        $marker=if($test -eq 'its_full_spatial_performance_tb'){'PROBE_COMPLETED cases=36'}else{'STREAM_COMPLETED'}
        if($LASTEXITCODE -ne 0 -or -not $txt.Contains($marker) -or $txt -match 'Errors:\s*[1-9]|\*\* (Fatal|Error)'){throw "Performance execution failed: $test"}
    }
    $single=@(Import-Csv probe_metrics.csv)
    if($single.Count -ne 36 -or @($single | Where-Object {[int]$_.legacy_mismatch_beats -ne 0 -or [int]$_.full_mismatch_beats -ne 0 -or [int]$_.output_gaps -ne 0}).Count){throw 'Performance numeric/output cadence check failed'}
    $stream=@(Import-Csv stream_metrics.csv)
    if($stream.Count -ne 4 -or @($stream | Where-Object {[int]$_.full_spatial_mismatch_beats -ne 0}).Count){throw 'Stream numeric check failed'}
    foreach($row in $stream){$row | Add-Member -NotePropertyName Msamples_per_second_at_500MHz -NotePropertyValue ([int]$row.n*[int]$row.n*500/[double]$row.steady_mean_interval)}
    @{status='PASS_CORRECT_FULL_SPATIAL_PERFORMANCE';clock_period_ns=2;single_tu_cases=$single;stream=$stream;conditions='No output backpressure, single sparse DC and dense numerical cases; eight queued DC TUs per stream shape; cycle counts from RTL simulation.'} | ConvertTo-Json -Depth 6 | Set-Content PERFORMANCE.json -Encoding utf8
    $stream | Select-Object n,first_done_latency,steady_mean_interval,Msamples_per_second_at_500MHz | ConvertTo-Json
} finally {Pop-Location}
