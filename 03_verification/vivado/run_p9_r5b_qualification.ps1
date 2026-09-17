[CmdletBinding()]
param(
    [string]$EvidenceDir = '05_audit/current/56/p9_r5b_implementation_convergence_20260917',
    [switch]$SkipB0,
    [switch]$SkipB1,
    [switch]$SkipB2,
    [switch]$SkipConditional
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$vivado = 'D:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat'
$tcl = (Resolve-Path (Join-Path $PSScriptRoot 'run_p9_r5b_postroute.tcl')).Path
$evPath = Join-Path $repo $EvidenceDir
New-Item -ItemType Directory -Force -Path $evPath | Out-Null
$ev = (Resolve-Path $evPath).Path
$postsynth = (Resolve-Path (Join-Path $repo '05_audit/current/54/p9_round5_hread_addr_validity_20260916/step12f_unified_wrapper_postsynth.dcp')).Path
$netdelay = (Resolve-Path (Join-Path $repo '05_audit/current/55/p9_r5a_implementation_stability_20260916/R5_NETDELAY/final.dcp')).Path
$expectedPostSynth = '8156F568B1A22D14542E35186FECC3B1E9A1746B4B138738AB8D96FF42FDCC28'
$expectedNetDelay = '6BE317AFB579115AF7451F872CF2D0C107C296E76432E34D741240248C8E236F'
$part = 'xcku5p-ffvb676-2-e'

New-Item -ItemType Directory -Force -Path $ev | Out-Null
$transcript = Join-Path $ev 'R5B_ORCHESTRATOR_TRANSCRIPT.txt'
Set-Content -LiteralPath $transcript -Value "P9-R5B bounded implementation convergence`r`nrepo=$repo`r`nvivado=$vivado`r`ntcl=$tcl`r`nvivado_version=2025.2`r`nmaxThreads=4`r`npart=$part`r`n" -Encoding utf8

function Log([string]$text) {
    Add-Content -LiteralPath $transcript -Value $text -Encoding utf8
    Write-Host $text
}

function Assert-Hash([string]$Path, [string]$Expected, [string]$Label) {
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
    Log ("HASH_CHECK {0} expected={1} actual={2}" -f $Label,$Expected,$got)
    if ($got -ne $Expected) { throw "Hash mismatch for $Label" }
}

Assert-Hash $postsynth $expectedPostSynth 'R5_POSTSYNTH'
Assert-Hash $netdelay $expectedNetDelay 'R5_NETDELAY_ROUTED'

function Invoke-VivadoR5B([string]$Mode, [string]$InputDcp, [string]$RunName, [string]$Reference = '') {
    $out = Join-Path $ev $RunName
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $runRequest = [ordered]@{
        mode = $Mode
        input_dcp = $InputDcp
        reference_dcp_or_descriptor = $Reference
        vivado = $vivado
        vivado_version = '2025.2'
        maxThreads = 4
        part = $part
        tcl = $tcl
    }
    $runRequest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'RUN_REQUEST.json') -Encoding utf8
    $console = Join-Path $out 'console.txt'
    $userData = Join-Path $out 'vivado_user'
    New-Item -ItemType Directory -Force -Path $userData | Out-Null
    $oldUserData = $env:XILINX_LOCAL_USER_DATA
    $env:XILINX_LOCAL_USER_DATA = $userData
    try {
        $args = @('-mode','batch','-source',$tcl,'-tclargs',$Mode,$InputDcp,$out)
        if ($Reference -ne '') { $args += $Reference }
        Log ("RUN_START $RunName mode=$Mode input=$InputDcp reference=$Reference")
        & $vivado @args *> $console
        $exitCode = $LASTEXITCODE
        Log ("RUN_END $RunName exit_code=$exitCode")
        if ($exitCode -ne 0) { throw "Vivado failed for $RunName with exit code $exitCode" }
    } finally {
        $env:XILINX_LOCAL_USER_DATA = $oldUserData
    }
    $dcp = Join-Path $out 'final.dcp'
    if (-not (Test-Path -LiteralPath $dcp)) { throw "Missing final DCP for $RunName" }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $dcp).Hash.ToUpperInvariant()
    Log ("FINAL_DCP $RunName sha256=$hash")
    return $out
}

$runs = [ordered]@{}
if (-not $SkipB0) { $runs.B0_NETDELAY_REPLAY = Invoke-VivadoR5B 'b0_netdelay_replay' $postsynth 'B0_NETDELAY_REPLAY' }
if (-not $SkipB1) { $runs.B1_SETUP_OPT = Invoke-VivadoR5B 'b1_setup_opt' $netdelay 'B1_SETUP_OPT' }
if (-not $SkipB2) { $runs.B2_HOLD_FIX = Invoke-VivadoR5B 'b2_hold_fix' $netdelay 'B2_HOLD_FIX' }

function Read-Summary([string]$RunDir) {
    $setup = Join-Path $RunDir 'report_timing_summary_setup.rpt'
    $hold = Join-Path $RunDir 'report_timing_summary_hold.rpt'
    $setupLine = $null
    $holdLine = $null
    if (Test-Path -LiteralPath $setup) {
        $lines = @(Get-Content -LiteralPath $setup)
        for ($i=0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'WNS\(ns\).*TNS\(ns\)') {
                for ($j=$i+1; $j -lt [Math]::Min($i+5,$lines.Count); $j++) {
                    if ($lines[$j] -match '^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)') { $setupLine=$lines[$j]; break }
                }
                if ($setupLine) { break }
            }
        }
    }
    if (Test-Path -LiteralPath $hold) {
        $lines = @(Get-Content -LiteralPath $hold)
        for ($i=0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'WHS\(ns\).*THS\(ns\)') {
                for ($j=$i+1; $j -lt [Math]::Min($i+5,$lines.Count); $j++) {
                    if ($lines[$j] -match '^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)') { $holdLine=$lines[$j]; break }
                }
                if ($holdLine) { break }
            }
        }
    }
    $routeR = Join-Path $RunDir 'report_route_status.rpt'
    $routeLine = if (Test-Path -LiteralPath $routeR) { (Select-String -LiteralPath $routeR -Pattern 'Fully Routed|route status' | Select-Object -First 1).Line } else { $null }
    $wns = $null; $whs = $null
    if ($setupLine) { $m=[regex]::Match($setupLine,'^\s*(-?\d+\.\d+)'); if($m.Success){$wns=[double]$m.Groups[1].Value} }
    if ($holdLine) { $m=[regex]::Match($holdLine,'^\s*(-?\d+\.\d+)'); if($m.Success){$whs=[double]$m.Groups[1].Value} }
    [pscustomobject]@{ run_dir=$RunDir; wns_ns=$wns; whs_ns=$whs; setup_summary=$setupLine; hold_summary=$holdLine; route_summary=$routeLine }
}

$baseSummary = [pscustomobject]@{ wns_ns=-0.063; whs_ns=-0.080 }
$b0Summary = if ($runs.Contains('B0_NETDELAY_REPLAY')) { Read-Summary $runs.B0_NETDELAY_REPLAY } else { $baseSummary }
$b1Summary = if ($runs.Contains('B1_SETUP_OPT')) { Read-Summary $runs.B1_SETUP_OPT } else { $null }
$b2Summary = if ($runs.Contains('B2_HOLD_FIX')) { Read-Summary $runs.B2_HOLD_FIX } else { $null }

$conditional = [ordered]@{ b3_run=$false; b4_run=$false; reason=@() }
if (-not $SkipConditional -and $b1Summary -and $b2Summary) {
    $b1SetupImproves = ($null -ne $b1Summary.wns_ns -and $null -ne $b0Summary.wns_ns -and $b1Summary.wns_ns -gt $b0Summary.wns_ns)
    $b1HoldFails = ($null -eq $b1Summary.whs_ns -or $b1Summary.whs_ns -lt 0)
    if ($b1SetupImproves -and $b1HoldFails) {
        $runs.B3_COMBINED = Invoke-VivadoR5B 'b3_combined' (Join-Path $runs.B1_SETUP_OPT 'final.dcp') 'B3_COMBINED'
        $conditional.b3_run = $true
    } else {
        $conditional.reason += "B3 not run: B1 did not both improve setup over -0.063 ns and retain a hold violation"
    }
    $holdParent = if ($conditional.b3_run) { Join-Path $runs.B3_COMBINED 'final.dcp' } else { Join-Path $runs.B2_HOLD_FIX 'final.dcp' }
    $holdSummary = Read-Summary (Split-Path $holdParent -Parent)
    if ($holdSummary.whs_ns -eq $null -or $holdSummary.whs_ns -lt 0) {
        $runs.B4_AGGRESSIVE_HOLD = Invoke-VivadoR5B 'b4_aggressive_hold' $holdParent 'B4_AGGRESSIVE_HOLD'
        $conditional.b4_run = $true
    } else {
        $conditional.reason += 'B4 not run: ordinary hold fix passed'
    }
} elseif ($SkipConditional) {
    $conditional.reason += 'conditional runs skipped by request'
} else {
    $conditional.reason += 'B3/B4 not evaluated because B1 or B2 was skipped/failed'
}

$result = [ordered]@{
    schema = 'step12f.p9.r5b.execution.v1'
    generated_utc = (Get-Date).ToUniversalTime().ToString('o')
    baseline_commit = '64219104be0e3afd313c180f7d3b85f36e8694de'
    local_full_evidence_commit = 'e75e2abf52d197e0349bc2ce6399c45cbf09bad2'
    postsynth_sha256 = $expectedPostSynth
    netdelay_routed_sha256 = $expectedNetDelay
    modes = $runs.Keys
    conditional = $conditional
    summaries = @($runs.Keys | ForEach-Object { Read-Summary $runs[$_] })
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ev 'P9_R5B_EXECUTION.json') -Encoding utf8
Log 'P9_R5B_ORCHESTRATION_DONE'

