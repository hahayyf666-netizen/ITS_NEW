param([switch]$SkipGate,[switch]$SkipP2,[switch]$SkipP4,[switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'closure_runner.py'
$runnerArgs = @($runner)
if ($SkipGate) { $runnerArgs += '--skip-gate' }
if ($SkipP2) { $runnerArgs += '--skip-p2' }
if ($SkipP4) { $runnerArgs += '--skip-p4' }
if ($SelfTest) { $runnerArgs += '--selftest' }
& python @runnerArgs
exit $LASTEXITCODE
