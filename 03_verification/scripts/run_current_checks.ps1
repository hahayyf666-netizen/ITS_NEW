$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$bundledPython = "C:\Users\Fine\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
$python = if (Test-Path -LiteralPath $bundledPython) { $bundledPython } else { "python" }

function Run-Check([string]$script) {
    & $python (Join-Path $root $script)
    if ($LASTEXITCODE -ne 0) {
        throw "Current check failed: $script (exit $LASTEXITCODE)"
    }
}

Run-Check "03_verification\scripts\step12ar2_executable_model.py"
Run-Check "03_verification\scripts\audit_matrices.py"
Run-Check "03_verification\scripts\p2f\run_p2f_equivalence.py"
Run-Check "03_verification\scripts\p2f\run_p2f_a2_kernel_regate.py"

Write-Output "V35_16_CURRENT_CHECKS_PASS"
