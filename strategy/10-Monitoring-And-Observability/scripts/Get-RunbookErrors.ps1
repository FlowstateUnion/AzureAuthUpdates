<#
    .SYNOPSIS
        Groups runbook error streams by message signature to reveal
        recurring failures across jobs and runbooks.

    .DESCRIPTION
        Preferred mode: Layer 2 (Log Analytics) — fast, cross-runbook
        aggregation via KQL.

        Fallback mode: Layer 1 (Az.Automation) — walks failed jobs and
        pulls their error streams one at a time. Slower; only practical
        for a single runbook or small time windows.

    .PARAMETER WorkspaceId
        Log Analytics workspace ID (GUID) or resource ID. Triggers Layer 2.

    .PARAMETER ResourceGroupName
        For Layer 1 fallback.

    .PARAMETER AutomationAccountName
        For Layer 1 fallback.

    .PARAMETER RunbookName
        Optional — restrict to a single runbook.

    .PARAMETER Days
        Lookback window. Default 7.

    .PARAMETER SignatureLength
        How many chars of the error message to use as the grouping
        signature. Default 120.

    .EXAMPLE
        # Layer 2 — all runbooks, last 7 days
        .\Get-RunbookErrors.ps1 -WorkspaceId $wsId

    .EXAMPLE
        # Layer 1 fallback — one runbook, last 3 days
        .\Get-RunbookErrors.ps1 -ResourceGroupName rg-aa -AutomationAccountName aa-ops -RunbookName Send-ContosoEmail -Days 3
#>
param(
    [string] $WorkspaceId,
    [string] $ResourceGroupName,
    [string] $AutomationAccountName,
    [string] $RunbookName,
    [int] $Days = 7,
    [int] $SignatureLength = 120
)

$ErrorActionPreference = 'Stop'

if (-not $WorkspaceId -and (-not $ResourceGroupName -or -not $AutomationAccountName)) {
    throw "Provide either -WorkspaceId (Layer 2) or -ResourceGroupName + -AutomationAccountName (Layer 1)."
}

if ($WorkspaceId) {
    Write-Host "Querying Log Analytics (last $Days day(s))..."
    $filter = if ($RunbookName) { "| where RunbookName == '$RunbookName'" } else { '' }
    $kql = @"
AutomationJobStreams
| where TimeGenerated > ago($($Days)d) and StreamType == 'Error'
$filter
| extend Signature = substring(ResultDescription, 0, $SignatureLength)
| summarize
    Hits     = count(),
    Runbooks = dcount(RunbookName),
    RunbookList = make_set(RunbookName, 10),
    Sample   = any(ResultDescription),
    FirstSeen = min(TimeGenerated),
    LastSeen  = max(TimeGenerated)
    by Signature
| order by Hits desc
"@
    $result = (Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $kql).Results
    if (-not $result) {
        Write-Host "No error records found in window." -ForegroundColor Green
        return
    }
    $result | Select-Object Hits, Runbooks, Signature, FirstSeen, LastSeen | Format-Table -AutoSize | Out-Host
    return $result
}

# ---- Layer 1 fallback ----
Write-Host "Using Layer 1 (slower). For cross-runbook analysis, pass -WorkspaceId."
$effectiveDays = [Math]::Min($Days, 30)
$since = (Get-Date).AddDays(-$effectiveDays)

$jobParams = @{
    ResourceGroupName     = $ResourceGroupName
    AutomationAccountName = $AutomationAccountName
    StartTime             = $since
}
if ($RunbookName) { $jobParams['RunbookName'] = $RunbookName }

$failedJobs = Get-AzAutomationJob @jobParams | Where-Object Status -eq 'Failed'
Write-Host "Found $($failedJobs.Count) failed job(s). Fetching error streams..."

$errorRecords = foreach ($j in $failedJobs) {
    $streams = Get-AzAutomationJobOutput -Id $j.JobId `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName -Stream Error
    foreach ($s in $streams) {
        $rec = Get-AzAutomationJobOutputRecord -Id $s.StreamRecordId -JobId $j.JobId `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName
        $msg = ($rec.Value.Values | Out-String).Trim()
        [pscustomobject]@{
            RunbookName = $j.RunbookName
            JobId       = $j.JobId
            Time        = $s.Time
            Message     = $msg
            Signature   = if ($msg.Length -gt $SignatureLength) { $msg.Substring(0, $SignatureLength) } else { $msg }
        }
    }
}

if (-not $errorRecords) {
    Write-Host "No error streams found." -ForegroundColor Green
    return
}

$grouped = $errorRecords | Group-Object Signature | ForEach-Object {
    [pscustomobject]@{
        Hits      = $_.Count
        Runbooks  = ($_.Group.RunbookName | Sort-Object -Unique).Count
        Signature = $_.Name
        Sample    = ($_.Group | Select-Object -First 1).Message
        FirstSeen = ($_.Group.Time | Measure-Object -Minimum).Minimum
        LastSeen  = ($_.Group.Time | Measure-Object -Maximum).Maximum
    }
} | Sort-Object Hits -Descending

$grouped | Select-Object Hits, Runbooks, Signature, FirstSeen, LastSeen |
    Format-Table -AutoSize | Out-Host

return $grouped
