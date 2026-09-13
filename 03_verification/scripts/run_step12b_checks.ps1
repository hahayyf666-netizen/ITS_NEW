$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$python = if (Get-Command python -ErrorAction SilentlyContinue) { "python" } else { throw "python not found" }
$auditDir = if ($env:STEP12B_AUDIT_DIR) { $env:STEP12B_AUDIT_DIR } else { "05_audit\current\20\m4" }
$modelDir = if ($env:STEP12B_MODEL_DIR) { $env:STEP12B_MODEL_DIR } else { "05_audit\current\20\m4_model" }
$auditAbs = Join-Path $root $auditDir
$modelAbs = Join-Path $root $modelDir
$null = New-Item -ItemType Directory -Force -Path $auditAbs
$null = New-Item -ItemType Directory -Force -Path $modelAbs
$env:STEP12B_AUDIT_OUT = $modelAbs
$env:STEP12B_MODEL_VERSION = if ($env:STEP12B_MODEL_VERSION) { $env:STEP12B_MODEL_VERSION } else { "V3.5-Step12C-M4" }
& $python (Join-Path $root "03_verification\scripts\step12b_cycle_model.py")
if ($LASTEXITCODE -ne 0) { throw "Step12B cycle model failed" }
& $python (Join-Path $root "03_verification\scripts\gen_step12b_rtl_random_vectors.py")
if ($LASTEXITCODE -ne 0) { throw "Step12B RTL random vector generation failed" }

$vs = "D:\software\Modelsim\win64"
if (-not (Test-Path (Join-Path $vs "vlog.exe"))) { throw "ModelSim vlog.exe not found at $vs" }
if (-not (Test-Path (Join-Path $root "work"))) { & (Join-Path $vs "vlib.exe") (Join-Path $root "work") }
Push-Location $root
try {
  & (Join-Path $vs "vlog.exe") -sv -work work "+incdir+02_rtl/rtl" `
    02_rtl/rtl/p2f_dct2_64_b1_step102.sv 02_rtl/rtl/step12b_dct2_64_wrapper.sv `
    03_verification/tb/step12b_dct2_64_wrapper_tb.sv `
    03_verification/tb/step12b_dct2_64_wrapper_two_tu_tb.sv `
    03_verification/tb/step12b_dct2_64_wrapper_descriptor_tb.sv `
    03_verification/tb/step12b_dct2_64_wrapper_epoch_tb.sv `
    03_verification/tb/step12b_dct2_64_wrapper_random_tb.sv `
    03_verification/tb/r4c_latency_contract_tb.sv | Tee-Object 03_verification/logs/step12b_wrapper_normal_compile.log
  if ($LASTEXITCODE -ne 0) { throw "normal vlog failed" }
  $normalSim = (& (Join-Path $vs "vsim.exe") -c work.step12b_dct2_64_wrapper_tb -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/step12b_wrapper_normal.log) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw "normal vsim failed" }
  if ($normalSim -notmatch "STEP12B_WRAPPER_PASS" -or $normalSim -notmatch "Errors: 0") {
    throw "normal simulation did not report a clean PASS"
  }
  $traceCheck = (& $python (Join-Path $root "03_verification\scripts\validate_step12b_rtl_trace.py") `
    --rtl-trace (Join-Path $auditAbs "step12b_rtl_event_trace_normal.csv") `
    --model-trace (Join-Path $modelAbs "step12b_cycle_trace.json") 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $traceCheck -notmatch "STEP12B_RTL_TRACE_PASS") {
    throw "RTL event trace validation failed: $traceCheck"
  }
  $internalCheck = (& $python (Join-Path $root "03_verification\scripts\validate_step12b_internal_trace.py") `
    --rtl-trace (Join-Path $auditAbs "step12b_rtl_event_trace_normal.csv") `
    --model-trace (Join-Path $modelAbs "step12b_cycle_trace.json") `
    --out (Join-Path $auditAbs "step12b_internal_trace_results.json") 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $internalCheck -notmatch "STEP12B_INTERNAL_TRACE_PASS") {
    throw "internal transaction trace audit failed: $internalCheck"
  }
  $traceMutations = (& $python (Join-Path $root "03_verification\scripts\run_step12b_trace_mutations.py") `
    --rtl-trace (Join-Path $auditAbs "step12b_rtl_event_trace_normal.csv") `
    --model-trace (Join-Path $modelAbs "step12b_cycle_trace.json") `
    --out (Join-Path $auditAbs "step12b_trace_mutation_results.json") 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $traceMutations -notmatch "STEP12B_TRACE_MUTATION_PASS") {
    throw "trace comparator mutation audit failed: $traceMutations"
  }
  $normalTwo = (& (Join-Path $vs "vsim.exe") -c work.step12b_dct2_64_wrapper_two_tu_tb -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/step12b_wrapper_two_tu_normal.log) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $normalTwo -notmatch "STEP12B_TWO_TU_PASS" -or $normalTwo -notmatch "Errors: 0") {
    throw "normal two-TU simulation did not report a clean PASS"
  }
  $normalDesc = (& (Join-Path $vs "vsim.exe") -c work.step12b_dct2_64_wrapper_descriptor_tb -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/step12b_wrapper_descriptor_normal.log) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $normalDesc -notmatch "STEP12B_DESCRIPTOR_SEMANTICS_PASS" -or $normalDesc -notmatch "STEP12B_DESCRIPTOR_OVERFLOW_PASS" -or $normalDesc -notmatch "Errors: 0") {
    throw "normal descriptor simulation did not report a clean PASS"
  }
  $normalEpoch = (& (Join-Path $vs "vsim.exe") -c work.step12b_dct2_64_wrapper_epoch_tb -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/step12b_wrapper_epoch_normal.log) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $normalEpoch -notmatch "STEP12B_EPOCH_WRAP_PASS" -or $normalEpoch -notmatch "Errors: 0") {
    throw "normal epoch simulation did not report a clean PASS"
  }
  $normalRandom = (& (Join-Path $vs "vsim.exe") -c work.step12b_dct2_64_wrapper_random_tb -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/step12b_wrapper_random_normal.log) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $normalRandom -notmatch "STEP12B_RANDOM_PASS" -or $normalRandom -notmatch "Errors: 0") {
    throw "normal random simulation did not report a clean PASS"
  }
  $normalLatency = (& (Join-Path $vs "vsim.exe") -c work.r4c_latency_contract_tb -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/r4c_latency_normal.log) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $normalLatency -notmatch "R4C_LATENCY_PASS" -or $normalLatency -notmatch "transaction_latency=23") {
    throw "normal R4C latency contract failed"
  }
  $normalExtreme = (& (Join-Path $vs "vsim.exe") -c work.step12b_dct2_64_wrapper_random_tb `
    "-gINPUT_FILE=03_verification/generated/step12b_extreme_input.mem" `
    "-gEXPECTED_FILE=03_verification/generated/step12b_extreme_expected.mem" `
    -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/step12b_wrapper_extreme_normal.log) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $normalExtreme -notmatch "STEP12B_RANDOM_PASS" -or $normalExtreme -notmatch "Errors: 0") {
    throw "normal extreme simulation did not report a clean PASS"
  }
  & (Join-Path $vs "vlog.exe") -sv -work work "+define+SYNTHESIS" "+incdir+02_rtl/rtl" `
    02_rtl/rtl/p2f_dct2_64_b1_step102.sv 02_rtl/rtl/step12b_dct2_64_wrapper.sv `
    03_verification/tb/step12b_dct2_64_wrapper_tb.sv `
    03_verification/tb/step12b_dct2_64_wrapper_two_tu_tb.sv `
    03_verification/tb/step12b_dct2_64_wrapper_descriptor_tb.sv `
    03_verification/tb/step12b_dct2_64_wrapper_epoch_tb.sv `
    03_verification/tb/step12b_dct2_64_wrapper_random_tb.sv `
    03_verification/tb/r4c_latency_contract_tb.sv | Tee-Object 03_verification/logs/step12b_wrapper_synthesis_compile.log
  if ($LASTEXITCODE -ne 0) { throw "synthesis vlog failed" }
  $synthSim = (& (Join-Path $vs "vsim.exe") -c work.step12b_dct2_64_wrapper_tb -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/step12b_wrapper_synthesis.log) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw "synthesis vsim failed" }
  if ($synthSim -notmatch "STEP12B_WRAPPER_PASS" -or $synthSim -notmatch "Errors: 0") {
    throw "synthesis simulation did not report a clean PASS"
  }
  $synthTraceCheck = (& $python (Join-Path $root "03_verification\scripts\validate_step12b_rtl_trace.py") `
    --rtl-trace (Join-Path $auditAbs "step12b_rtl_event_trace_synthesis.csv") `
    --model-trace (Join-Path $modelAbs "step12b_cycle_trace.json") 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $synthTraceCheck -notmatch "STEP12B_RTL_TRACE_PASS") {
    throw "SYNTHESIS RTL event trace comparison failed: $synthTraceCheck"
  }
  $synthInternalCheck = (& $python (Join-Path $root "03_verification\scripts\validate_step12b_internal_trace.py") `
    --rtl-trace (Join-Path $auditAbs "step12b_rtl_event_trace_synthesis.csv") `
    --model-trace (Join-Path $modelAbs "step12b_cycle_trace.json") `
    --out (Join-Path $auditAbs "step12b_internal_trace_synthesis_results.json") 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $synthInternalCheck -notmatch "STEP12B_INTERNAL_TRACE_PASS") {
    throw "SYNTHESIS internal transaction trace audit failed: $synthInternalCheck"
  }
  $synthTwo = (& (Join-Path $vs "vsim.exe") -c work.step12b_dct2_64_wrapper_two_tu_tb -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/step12b_wrapper_two_tu_synthesis.log) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $synthTwo -notmatch "STEP12B_TWO_TU_PASS" -or $synthTwo -notmatch "Errors: 0") {
    throw "synthesis two-TU simulation did not report a clean PASS"
  }
  $synthDesc = (& (Join-Path $vs "vsim.exe") -c work.step12b_dct2_64_wrapper_descriptor_tb -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/step12b_wrapper_descriptor_synthesis.log) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $synthDesc -notmatch "STEP12B_DESCRIPTOR_SEMANTICS_PASS" -or $synthDesc -notmatch "STEP12B_DESCRIPTOR_OVERFLOW_PASS" -or $synthDesc -notmatch "Errors: 0") {
    throw "synthesis descriptor simulation did not report a clean PASS"
  }
  $synthEpoch = (& (Join-Path $vs "vsim.exe") -c work.step12b_dct2_64_wrapper_epoch_tb -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/step12b_wrapper_epoch_synthesis.log) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $synthEpoch -notmatch "STEP12B_EPOCH_WRAP_PASS" -or $synthEpoch -notmatch "Errors: 0") {
    throw "synthesis epoch simulation did not report a clean PASS"
  }
  $synthRandom = (& (Join-Path $vs "vsim.exe") -c work.step12b_dct2_64_wrapper_random_tb -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/step12b_wrapper_random_synthesis.log) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $synthRandom -notmatch "STEP12B_RANDOM_PASS" -or $synthRandom -notmatch "Errors: 0") {
    throw "synthesis random simulation did not report a clean PASS"
  }
  $synthLatency = (& (Join-Path $vs "vsim.exe") -c work.r4c_latency_contract_tb -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/r4c_latency_synthesis.log) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $synthLatency -notmatch "R4C_LATENCY_PASS" -or $synthLatency -notmatch "transaction_latency=23") {
    throw "SYNTHESIS R4C latency contract failed"
  }
  $synthExtreme = (& (Join-Path $vs "vsim.exe") -c work.step12b_dct2_64_wrapper_random_tb `
    "-gINPUT_FILE=03_verification/generated/step12b_extreme_input.mem" `
    "-gEXPECTED_FILE=03_verification/generated/step12b_extreme_expected.mem" `
    -do "run -all; quit -f" 2>&1 |
    Tee-Object 03_verification/logs/step12b_wrapper_extreme_synthesis.log) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $synthExtreme -notmatch "STEP12B_RANDOM_PASS" -or $synthExtreme -notmatch "Errors: 0") {
    throw "synthesis extreme simulation did not report a clean PASS"
  }
} finally { Pop-Location }
Write-Output "V35_STEP12C_M4_FUNCTIONAL_REGRESSION_PASS"
