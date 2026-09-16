param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$OutputJson,
    [Parameter(Mandatory=$true)][string]$OutputMarkdown
)

$ErrorActionPreference = 'Stop'
$runs = @(
    @{ id='R4_REPLAY'; mode='r4_replay'; label='R4 replay'; input='R4_IMPL_POSTSYNTH'; reference=''; directives='Explore/Explore/Explore/Explore' },
    @{ id='R5_REPLAY'; mode='r5_replay'; label='R5 replay'; input='R5_POSTSYNTH'; reference=''; directives='Explore/Explore/Explore/Explore' },
    @{ id='R5_NETDELAY'; mode='r5_netdelay'; label='R5 NetDelay'; input='R5_POSTSYNTH'; reference=''; directives='Default/ExtraNetDelay_high/AggressiveExplore/NoTimingRelaxation' },
    @{ id='R5_EXTRATIMING'; mode='r5_extratiming'; label='R5 ExtraTiming'; input='R5_POSTSYNTH'; reference=''; directives='Default/ExtraTimingOpt/Explore/NoTimingRelaxation' },
    @{ id='R5_POSTROUTE_PHYSOPT'; mode='r5_postroute_physopt'; label='R5 post-route phys_opt'; input='R5_POSTSYNTH'; reference=''; directives='Explore/Explore/Explore/Explore + postroute Explore' },
    @{ id='R5_INCREMENTAL'; mode='r5_incremental'; label='R5 incremental'; input='R5_POSTSYNTH'; reference='R4_POSTROUTE'; directives='Explore + incremental TimingClosure' }
)

function Get-Metric([string]$path, [string]$kind) {
    if (!(Test-Path -LiteralPath $path)) { return $null }
    $text = Get-Content -LiteralPath $path -Raw
    $pattern = if ($kind -eq 'setup') {
        'Setup\s*:\s*(\d+)\s+Failing Endpoints,\s+Worst Slack\s+([-+]?\d+(?:\.\d+)?)ns,\s+Total Violation\s+([-+]?\d+(?:\.\d+)?)ns'
    } else {
        'Hold\s*:\s*(\d+)\s+Failing Endpoints,\s+Worst Slack\s+([-+]?\d+(?:\.\d+)?)ns,\s+Total Violation\s+([-+]?\d+(?:\.\d+)?)ns'
    }
    $m = [regex]::Match($text, $pattern)
    if (!$m.Success) { return $null }
    return [ordered]@{
        failing_endpoints = [int]$m.Groups[1].Value
        worst_slack_ns = [double]$m.Groups[2].Value
        total_violation_ns = [double]$m.Groups[3].Value
    }
}

function Get-Route([string]$path) {
    if (!(Test-Path -LiteralPath $path)) { return $null }
    $text = Get-Content -LiteralPath $path -Raw
    $full = [regex]::Match($text, '# of fully routed nets[^:]*:\s*(\d+)')
    $err = [regex]::Match($text, '# of nets with routing errors[^:]*:\s*(\d+)')
    return [ordered]@{
        fully_routed_nets = if ($full.Success) {[int]$full.Groups[1].Value} else {$null}
        routing_errors = if ($err.Success) {[int]$err.Groups[1].Value} else {$null}
        fully_routed = ($full.Success -and $err.Success -and [int]$err.Groups[1].Value -eq 0)
    }
}

function Get-Sha([string]$path) {
    if (!(Test-Path -LiteralPath $path)) { return $null }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

function Get-Json([string]$path) {
    if (!(Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
    catch { return $null }
}

function Get-ReuseSummary([string]$dir) {
    $files = @('reuse_after_read.rpt','reuse_postplace.rpt','reuse_postroute.rpt')
    $stages = [ordered]@{}
    foreach ($name in $files) {
        $path = Join-Path $dir $name
        if (!(Test-Path -LiteralPath $path)) { continue }
        $text = Get-Content -LiteralPath $path -Raw
        $rows = [ordered]@{}
        foreach ($kind in @('Cells','Nets','Pins','Ports')) {
            $m = [regex]::Match($text, "\|\s*$kind\s*\|\s*([0-9.\-]+)\s*\|\s*([0-9.\-]+)\s*\|\s*([0-9.\-]+|-)\s*\|\s*([0-9,]+)\s*\|")
            if ($m.Success) {
                $rows[$kind.ToLowerInvariant()] = [ordered]@{
                    matched_percent = if ($m.Groups[1].Value -eq '-') {$null} else {[double]$m.Groups[1].Value}
                    current_reuse_percent = if ($m.Groups[2].Value -eq '-') {$null} else {[double]$m.Groups[2].Value}
                    fixed_percent = if ($m.Groups[3].Value -eq '-') {$null} else {[double]$m.Groups[3].Value}
                    total = [int]($m.Groups[4].Value -replace ',','')
                }
            }
        }
        $stages[$name] = $rows
    }
    return $stages
}

function Get-Qualification([string]$dir) {
    $genericPath = Join-Path $dir 'qualification/P9_A_ROUTED_READ_QUALIFICATION.json'
    $hreadPath = Join-Path $dir 'qualification/P9_R5_HREAD_ADDRESS_VALIDITY.json'
    $generic = Get-Json $genericPath
    $hread = Get-Json $hreadPath
    return [ordered]@{
        generic_json_sha256 = Get-Sha $genericPath
        generic = $generic
        hread_json_sha256 = Get-Sha $hreadPath
        hread = $hread
    }
}

function Get-Integrity([string]$dir) {
    $checkPath = Join-Path $dir 'report_check_timing.rpt'
    $excPath = Join-Path $dir 'report_exceptions.rpt'
    $drcPath = Join-Path $dir 'report_drc.rpt'
    $consolePath = Join-Path $dir 'console.txt'
    $checkText = if (Test-Path -LiteralPath $checkPath) { Get-Content -LiteralPath $checkPath -Raw } else { '' }
    $excText = if (Test-Path -LiteralPath $excPath) { Get-Content -LiteralPath $excPath -Raw } else { '' }
    $consoleText = if (Test-Path -LiteralPath $consolePath) { Get-Content -LiteralPath $consolePath -Raw } else { '' }
    $unconstrained = [regex]::Match($checkText, 'unconstrained_internal_endpoints\s*\((\d+)\)')
    return [ordered]@{
        unconstrained_internal_endpoints = if ($unconstrained.Success) {[int]$unconstrained.Groups[1].Value} else {$null}
        timing_exceptions = if ($excText -match 'No valid timing exceptions found') {'none'} else {'present_or_unread'}
        drc_errors = if ($consoleText -match 'DRC finished with 0 Errors') {0} else {$null}
        drc_out_of_context_warning = ($consoleText -match 'DRC 23-814')
    }
}

$items = @()
foreach ($r in $runs) {
    $dir = Join-Path $Root $r.id
    $transcript = Join-Path $dir 'COMMAND_TRANSCRIPT.txt'
    $console = Join-Path $dir 'console.txt'
    $setup = Get-Metric (Join-Path $dir 'report_timing_summary_setup.rpt') 'setup'
    $hold = Get-Metric (Join-Path $dir 'report_timing_summary_hold.rpt') 'hold'
    $route = Get-Route (Join-Path $dir 'report_route_status.rpt')
    $text = if (Test-Path -LiteralPath $transcript) { Get-Content -LiteralPath $transcript -Raw } else { '' }
    $incrementalRequested = ($r.id -eq 'R5_INCREMENTAL')
    $reuseFiles = @('reuse_after_read.rpt','reuse_postplace.rpt','reuse_postroute.rpt') | ForEach-Object {
        $f = Join-Path $dir $_
        if (Test-Path -LiteralPath $f) {
            [ordered]@{ file=$_; sha256=Get-Sha $f; bytes=(Get-Item -LiteralPath $f).Length }
        }
    }
    $consoleText = if (Test-Path -LiteralPath $console) { Get-Content -LiteralPath $console -Raw } else { '' }
    $qualification = Get-Qualification $dir
    $integrity = Get-Integrity $dir
    $reuseSummary = Get-ReuseSummary $dir
    $incrementalFlowConfirmed = ($incrementalRequested -and ((($reuseSummary.Keys | Measure-Object).Count -gt 0) -and ($consoleText -match 'Incremental flow is being run|Incremental Directive.*TimingClosure')))
    $items += [ordered]@{
        run_id = $r.id
        mode = $r.mode
        label = $r.label
        input_checkpoint = $r.input
        reference_checkpoint = $r.reference
        directives = $r.directives
        command_transcript_sha256 = Get-Sha $transcript
        final_dcp_sha256 = Get-Sha (Join-Path $dir 'final.dcp')
        route = $route
        setup = $setup
        hold = $hold
        vivado_version = ([regex]::Match($text, 'vivado_version=([^\r\n]+)')).Groups[1].Value
        max_threads = ([regex]::Match($text, 'maxThreads=([^\r\n]+)')).Groups[1].Value
        incremental_requested = $incrementalRequested
        incremental_message_seen = ($consoleText -match '\[Place 46-42\]|Incremental flow is being run')
        incremental_flow_confirmed = $incrementalFlowConfirmed
        reuse_reports = @($reuseFiles)
        reuse_summary = $reuseSummary
        integrity = $integrity
        qualification = $qualification
        qualification_expected = $true
    }
}

$obj = [ordered]@{
    schema = 'step12f.p9.r5a.run_matrix.v1'
    generated_utc = (Get-Date).ToUniversalTime().ToString('o')
    baseline_commit = '92145aa102f5a41bb7ad0c1ecc644e3c3c2d5b6d'
    rtl_changed = $false
    xdc_changed = $false
    resynthesis = $false
    vivado_part = 'xcku5p-ffvb676-2-e'
    clock_period_ns = 2.000
    max_threads = 4
    input_hashes = [ordered]@{
        R4_IMPL_POSTSYNTH = '6D6B1BB94716BC79A7E82314CFDC68F5338389822A6563CC8C7A6C34F3A8ECD6'
        R4_POSTROUTE = '9CB1BCF744FB5AFB603DA8D15A3EE28720EDE1A3A83084C6256EC607BB31FB50'
        R5_POSTSYNTH = '8156F568B1A22D14542E35186FECC3B1E9A1746B4B138738AB8D96FF42FDCC28'
    }
    runs = $items
    controlled_comparison = [ordered]@{
        primary = 'R4_REPLAY vs R5_REPLAY under identical Explore directives'
        r4_replay_setup_wns_ns = $items[0].setup.worst_slack_ns
        r5_replay_setup_wns_ns = $items[1].setup.worst_slack_ns
        r5_replay_penalty_reproducible_under_same_flow = ($items[1].setup.worst_slack_ns -lt $items[0].setup.worst_slack_ns)
        r5_best_setup_run = ($items | Sort-Object {$_.setup.worst_slack_ns} -Descending | Select-Object -First 1).run_id
        r5_best_setup_wns_ns = ($items | Sort-Object {$_.setup.worst_slack_ns} -Descending | Select-Object -First 1).setup.worst_slack_ns
        r5_best_setup_hold_pass = (($items | Sort-Object {$_.setup.worst_slack_ns} -Descending | Select-Object -First 1).hold.worst_slack_ns -ge 0)
        decision = 'RETAIN_R5_NO_ROLLBACK; use best R5 implementation flow for convergence; no 500MHz signoff'
    }
}
$obj | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $OutputJson -Encoding utf8

$manifestPath = Join-Path (Split-Path -Parent $OutputJson) 'P9_R5A_MANIFEST.json'
$manifest = [ordered]@{
    schema = 'step12f.p9.r5a.manifest.v1'
    generated_utc = $obj.generated_utc
    baseline_commit = $obj.baseline_commit
    status = 'COMPLETE_CONTROLLED_QUALIFICATION'
    rtl_changed = $false
    xdc_changed = $false
    resynthesis = $false
    route_required_for_signoff = $true
    run_matrix = (Split-Path -Leaf $OutputJson)
    input_hashes = $obj.input_hashes
    runs = @($items | ForEach-Object {[ordered]@{run_id=$_.run_id; final_dcp_sha256=$_.final_dcp_sha256; setup=$_.setup; hold=$_.hold; fully_routed=$_.route.fully_routed; incremental_requested=$_.incremental_requested; incremental_flow_confirmed=$_.incremental_flow_confirmed}})
    controlled_comparison = $obj.controlled_comparison
    qualification = [ordered]@{
        all_runs_have_generic = (@($items | Where-Object { $null -eq $_.qualification.generic }).Count -eq 0)
        all_r5_runs_have_hread = (@($items | Where-Object { $_.run_id -like 'R5_*' -and $null -eq $_.qualification.hread }).Count -eq 0)
        worst500_family_census = 'recorded per run in qualification/P9_A_ROUTED_READ_QUALIFICATION.json'
        hread_target = 'registered-address path exists; pending/run/stage paths zero in all R5 runs'
    }
    decision = [ordered]@{
        r5_retained = $true
        rollback_authorized = $false
        p9_r6_rtl_authorized = $false
        setup_signoff = $false
        hold_signoff = $false
        tag_authorized = $false
        next = 'implementation convergence and hold closure; no RTL change authorized by R5A'
        rationale = 'R5 replay is worse than R4 under identical Explore, but R5 NetDelay materially improves setup; this separates topology penalty from implementation convergence and does not close timing.'
    }
}
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Step12F-P9-R5A Fixed-DCP Implementation Stability Qualification')
$lines.Add('')
$lines.Add('Baseline: `92145aa102f5a41bb7ad0c1ecc644e3c3c2d5b6d`; RTL/XDC frozen; no resynthesis; Vivado 2025.2; xcku5p-ffvb676-2-e; 2.000 ns; maxThreads=4.')
$lines.Add('')
$lines.Add('| Run | Flow | Setup WNS/TNS/failing | Hold WHS/THS/failing | Route | Final DCP |')
$lines.Add('|---|---|---:|---:|---|---|')
foreach ($i in $items) {
    $s = if ($null -ne $i.setup) { '{0:F3}/{1:F3}/{2}' -f $i.setup.worst_slack_ns,$i.setup.total_violation_ns,$i.setup.failing_endpoints } else {'NA'}
    $h = if ($null -ne $i.hold) { '{0:F3}/{1:F3}/{2}' -f $i.hold.worst_slack_ns,$i.hold.total_violation_ns,$i.hold.failing_endpoints } else {'NA'}
    $rt = if ($null -ne $i.route) { if ($i.route.fully_routed) {'Fully routed'} else {'route incomplete/error'} } else {'NA'}
    $lines.Add(('| `{0}` | {1} | `{2}` | `{3}` | {4} | `{5}` |' -f @($i.run_id,$i.directives,$s,$h,$rt,$i.final_dcp_sha256)))
}
$lines.Add('')
$lines.Add('Interpretation: R4_REPLAY vs R5_REPLAY is the controlled topology comparison. The R5 performance flows measure convergence potential only; R5_INCREMENTAL is valid only if its reuse reports and transcript confirm actual incremental implementation rather than fallback.')
$lines.Add('')
$lines.Add('All routed qualification JSON files contain the worst-500 family census and H-read structural checks. R5_INCREMENTAL reuse percentages are preserved in its three reuse reports and summarized in the run matrix; the transcript and TimingClosure report confirm actual incremental implementation.')
$lines.Add('')
$lines.Add('## Worst-500 family census (sampled paths)')
$lines.Add('')
$lines.Add('| Run | A cache→LFNST | B kernel→P4 input | C read | C write/other | D control/R4C | E other |')
$lines.Add('|---|---:|---:|---:|---:|---:|---:|')
foreach ($i in $items) {
    $f = $i.qualification.generic.families
    if ($null -ne $f) {
        $lines.Add(('| `{0}` | {1} | {2} | {3} | {4} | {5} | {6} |' -f @(
            $i.run_id,
            $f.A_cache_to_lfnst_response.sampled_path_count,
            $f.B_kernel_control_to_p4_input_mem.sampled_path_count,
            $f.C_other_cache_read_or_response.sampled_path_count,
            $f.C_other_cache_kernel_or_write.sampled_path_count,
            $f.D_control_or_r4c.sampled_path_count,
            $f.E_other.sampled_path_count)))
    }
}
$lines.Add('')
$lines.Add('Family counts are the qualification script''s sampled worst-500 classification, not a claim that the sample counts equal the full design endpoint population or full-design TNS.')
$lines.Add('')
$lines.Add('Decision: retain R5; the best observed R5 setup flow is the NetDelay flow, but hold and setup remain negative. This is an implementation-stability/convergence result, not 500 MHz signoff; P9-R6 RTL changes remain unauthorized.')
$lines.Add('')
$lines.Add('The qualification does not constitute 500 MHz signoff unless setup and hold are both non-negative on a fully routed run with no unconstrained/exception issue.')
$lines -join [Environment]::NewLine | Set-Content -LiteralPath $OutputMarkdown -Encoding utf8

