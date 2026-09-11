$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$python = if (Get-Command python -ErrorAction SilentlyContinue) { "python" } else { throw "python not found" }
& $python (Join-Path $root "03_verification\scripts\step12b_cycle_model.py")
if ($LASTEXITCODE -ne 0) { throw "Step12B cycle model failed" }

$vs = "D:\software\Modelsim\win64"
if (-not (Test-Path (Join-Path $vs "vlog.exe"))) { throw "ModelSim vlog.exe not found at $vs" }
if (-not (Test-Path (Join-Path $root "work"))) { & (Join-Path $vs "vlib.exe") (Join-Path $root "work") }
Push-Location $root
try {
  & (Join-Path $vs "vlog.exe") -sv -work work "+incdir+02_rtl/rtl" `
    02_rtl/rtl/p2f_dct2_64_b1_step102.sv 02_rtl/rtl/step12b_dct2_64_wrapper.sv `
    03_verification/tb/step12b_dct2_64_wrapper_tb.sv | Tee-Object 03_verification/logs/step12b_wrapper_normal_compile.log
  if ($LASTEXITCODE -ne 0) { throw "normal vlog failed" }
  $normalSim = (& (Join-Path $vs "vsim.exe") -c work.step12b_dct2_64_wrapper_tb -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/step12b_wrapper_normal.log) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw "normal vsim failed" }
  if ($normalSim -notmatch "STEP12B_WRAPPER_PASS" -or $normalSim -notmatch "Errors: 0") {
    throw "normal simulation did not report a clean PASS"
  }
  & (Join-Path $vs "vlog.exe") -sv -work work "+define+SYNTHESIS" "+incdir+02_rtl/rtl" `
    02_rtl/rtl/p2f_dct2_64_b1_step102.sv 02_rtl/rtl/step12b_dct2_64_wrapper.sv `
    03_verification/tb/step12b_dct2_64_wrapper_tb.sv | Tee-Object 03_verification/logs/step12b_wrapper_synthesis_compile.log
  if ($LASTEXITCODE -ne 0) { throw "synthesis vlog failed" }
  $synthSim = (& (Join-Path $vs "vsim.exe") -c work.step12b_dct2_64_wrapper_tb -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/step12b_wrapper_synthesis.log) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw "synthesis vsim failed" }
  if ($synthSim -notmatch "STEP12B_WRAPPER_PASS" -or $synthSim -notmatch "Errors: 0") {
    throw "synthesis simulation did not report a clean PASS"
  }
} finally { Pop-Location }
Write-Output "V35_17_STEP12B_FUNCTIONAL_SMOKE_PASS"
