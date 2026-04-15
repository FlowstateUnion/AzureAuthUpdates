<#
    .SYNOPSIS
        Lists runbooks with zero executions in the specified window.

    .DESCRIPTION
        Cross-references the full runbook inventory against recent job
        history. Any runbook with no jobs in the window is a candidate for
        retirement.

        By default uses Layer 1 (Az.Automation cmdlets). If -WorkspaceId is
        provided, uses Layer 2 (Log Analytics) for a longer lookback window.

    .PARAMETER ResourceGroupName
        Resource group.

    .PARAMETER AutomationAccountName
        Automation Account.

    .PARAMETER Days
        How many days to consider "recent". Default 90.

    .PARAMETER WorkspaceId
        Optional Log Analytics workspace resource ID or GUID. If provided,
        bypasses the 30-day retention limit of Layer 1.

    .PARAMETER IncludeSchedules
        If set, attaches schedule info to the output so you can tell
        whether a stale runbook was merely idle or is unscheduled.

    .EXAMPLE
        .\Find-StaleRunbooks.ps1 -ResourceGroupName rg-aa -AutomationAccountName aa-ops -Days 90 -IncludeSchedules
#>
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $AutomationAccountName,
    [int] $Days = 90,
    [string] $WorkspaceId,
    [switch] $IncludeSchedules
)

$ErrorActionPreference = 'Stop'

Write-Host "Inventorying runbooks..."
$allRunbooks = Get-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName
Write-Host "  Found $($allRunbooks.Count) runbook(s)."

# Build the set of runbook names that have run recently
$recentNames = @{}

if ($WorkspaceId) {
    Write-Host "Using Layer 2 (Log Analytics) with $Days day lookback..."
    $kql = @"
AutomationJobLogs
| where TimeGenerated > ago($($Days)d)
| summarize LastRun = max(TimeGenerated), Runs = count() by RunbookName
"@
    $rows = (Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $kql).Results
    foreach ($r in $rows) { $recentNames[$r.RunbookName] = $r }
}
else {
    $effectiveDays = [Math]::Min($Days, 30)
    if ($effectiveDays -lt $Days) {
        Write-Warning "Layer 1 retention limits lookback to ~30 days. Using $effectiveDays instead of $Days. For longer windows, pass -WorkspaceId."
    }
    Write-Host "Using Layer 1 (Az.Automation) with $effectiveDays day lookback..."
    $since = (Get-Date).AddDays(-$effectiveDays)
    $jobs = Get-AzAutomationJob -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName -StartTime $since
    $grouped = $jobs | Group-Object RunbookName
    foreach ($g in $grouped) {
        $recentNames[$g.Name] = [pscustomobject]@{
            RunbookName = $g.Name
            LastRun     = ($g.Group | Sort-Object StartTime -Descending | Select-Object -First 1).StartTime
            Runs        = $g.Count
        }
    }
}

Write-Host "Computing stale set..."

# Schedules (optional)
$schedMap = @{}
if ($IncludeSchedules) {
    $allScheds = Get-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName -ErrorAction SilentlyContinue
    foreach ($s in $allScheds) {
        if (-not $schedMap.ContainsKey($s.RunbookName)) { $schedMap[$s.RunbookName] = @() }
        $schedMap[$s.RunbookName] += $s.ScheduleName
    }
}

$stale = foreach ($rb in $allRunbooks) {
    if (-not $recentNames.ContainsKey($rb.Name)) {
        $entry = [pscustomobject]@{
            RunbookName      = $rb.Name
            State            = $rb.State
            RunbookType      = $rb.RunbookType
            LastModifiedTime = $rb.LastModifiedTime
            DaysIdle         = $Days
            Schedules        = if ($IncludeSchedules) {
                if ($schedMap.ContainsKey($rb.Name)) { $schedMap[$rb.Name] -join ', ' } else { '(none)' }
            } else { $null }
        }
        $entry
    }
}

Write-Host ""
Write-Host "Stale runbooks: $($stale.Count) of $($allRunbooks.Count)" -ForegroundColor Cyan

if ($stale) {
    $cols = 'RunbookName','State','RunbookType','LastModifiedTime'
    if ($IncludeSchedules) { $cols += 'Schedules' }
    $stale | Format-Table $cols -AutoSize | Out-Host
}

return $stale
