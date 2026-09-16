param(
    [Parameter(Mandatory=$true)][string]$Report,
    [Parameter(Mandatory=$true)][string]$Csv
)

$raw = Get-Content -LiteralPath $Report -Raw
$chunks = $raw -split '(?m)(?=Slack \(VIOLATED\)\s*:)' | Where-Object { $_ -match 'Slack \(VIOLATED\)' }
$rows = [System.Collections.Generic.List[object]]::new()
$index = 0
foreach ($chunk in $chunks) {
    $index++
    $slackMatch = [regex]::Match($chunk, 'Slack \(VIOLATED\)\s*:\s*(-?\d+\.\d+)ns')
    $sourceMatch = [regex]::Match($chunk, '(?m)^  Source:\s+(.+)$')
    $destMatch = [regex]::Match($chunk, '(?m)^  Destination:\s+(.+)$')
    $delayMatch = [regex]::Match($chunk, 'Data Path Delay:\s+([0-9.]+)ns\s*\(logic\s+([0-9.]+)ns.*route\s+([0-9.]+)ns')
    if (!$slackMatch.Success -or !$sourceMatch.Success -or !$destMatch.Success -or !$delayMatch.Success) { continue }

    $lines = $chunk -split "`r?`n"
    $ramLine = $lines | Where-Object { $_ -match '(ADDR[A-Z]?[0-9]*|RADR[0-9]*)$' } | Select-Object -First 1
    $ramCumulative = $null
    if ($ramLine) {
        $ramNums = [regex]::Matches($ramLine, '(?<![A-Za-z])\d+\.\d+') | ForEach-Object { [double]$_.Value }
        if ($ramNums.Count -gt 0) { $ramCumulative = $ramNums[-1] }
    }

    $sourceQLine = $lines | Where-Object { $_ -match 'Prop_.*_Q\)' } | Select-Object -First 1
    $sourceQCumulative = $null
    if ($sourceQLine) {
        $sourceQLineIndex = [array]::IndexOf($lines, $sourceQLine)
        $sourceQTimingLine = if ($sourceQLineIndex -ge 0 -and $sourceQLineIndex + 1 -lt $lines.Count) { $lines[$sourceQLineIndex + 1] } else { '' }
        $sourceQNums = [regex]::Matches($sourceQTimingLine, '(?<![A-Za-z])\d+\.\d+') | ForEach-Object { [double]$_.Value }
        if ($sourceQNums.Count -gt 0) { $sourceQCumulative = $sourceQNums[-1] }
    }

    $arrivalMatch = [regex]::Match($chunk, 'arrival time\s+(-?\d+\.\d+)')
    $arrivalMagnitude = $null
    if ($arrivalMatch.Success) { $arrivalMagnitude = [math]::Abs([double]$arrivalMatch.Groups[1].Value) }
    $preRam = $null
    $postRam = $null
    if ($null -ne $ramCumulative -and $null -ne $sourceQCumulative) { $preRam = $ramCumulative - $sourceQCumulative }
    if ($null -ne $arrivalMagnitude -and $null -ne $ramCumulative) { $postRam = $arrivalMagnitude - $ramCumulative }

    $rows.Add([pscustomobject]@{
        family = 'A_cache_to_lfnst_response'
        path_index = $index
        slack_ns = [double]$slackMatch.Groups[1].Value
        datapath_delay_ns = [double]$delayMatch.Groups[1].Value
        logic_delay_ns = [double]$delayMatch.Groups[2].Value
        route_delay_ns = [double]$delayMatch.Groups[3].Value
        source_q_cumulative_ns = $sourceQCumulative
        ram_addr_cumulative_ns = $ramCumulative
        pre_ram_ns = $preRam
        post_ram_ns = $postRam
        source = $sourceMatch.Groups[1].Value.Trim()
        endpoint = $destMatch.Groups[1].Value.Trim()
        ram_resource = if ($ramLine) { $ramLine.Trim() } else { '' }
    })
}

$rows | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
Write-Output "ROWS=$($rows.Count)"
