<#
    .SYNOPSIS
        Per-runbook pass/fail/duration summary over the last N days.

    .DESCRIPTION
        Layer 1 (Az.Automation) report. Groups jobs by runbook name and
        reports total runs, outcome counts, average/max duration, and the
        timestamp of the last run.

    .PARAMETER ResourceGroupName
        Resource group.

    .PARAMETER AutomationAccountName
        Automation Account.

    .PARAMETER Days
        Lookback window in days. Default 7. Retention limit is ~30 days.

    .PARAMETER RunbookName
        Optional — filter to a single runbook.

    .EXAMPLE
        .\Get-RunbookJobSummary.ps1 -ResourceGroupName rg-aa -AutomationAccountName aa-ops -Days 14

    .EXAMPLE
        .\Get-RunbookJobSummary.ps1 -ResourceGroupName rg-aa -AutomationAccountName aa-ops -RunbookName Send-ContosoEmail
#>
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $AutomationAccountName,
    [ValidateRange(1, 30)] [int] $Days = 7,
    [string] $RunbookName
)

$ErrorActionPreference = 'Stop'
$since = (Get-Date).AddDays(-$Days)

$getParams = @{
    ResourceGroupName     = $ResourceGroupName
    AutomationAccountName = $AutomationAccountName
    StartTime             = $since
}
if ($RunbookName) { $getParams['RunbookName'] = $RunbookName }

Write-Host "Fetching jobs since $($since.ToString('yyyy-MM-dd HH:mm'))..."
$jobs = Get-AzAutomationJob @getParams
Write-Host "Retrieved $($jobs.Count) job(s)."

if (-not $jobs) { return }

$summary = $jobs | Group-Object RunbookName | ForEach-Object {
    $group = $_.Group
    $durations = $group | Where-Object { $_.EndTime -and $_.StartTime } |
        ForEach-Object { ($_.EndTime - $_.StartTime).TotalMinutes }

    [pscustomobject]@{
        RunbookName    = $_.Name
        Total          = $group.Count
        Completed      = ($group | Where-Object Status -eq 'Completed').Count
        Failed         = ($group | Where-Object Status -eq 'Failed').Count
        Suspended      = ($group | Where-Object Status -eq 'Suspended').Count
        Stopped        = ($group | Where-Object Status -eq 'Stopped').Count
        Running        = ($group | Where-Object Status -in 'Running','Activating','Starting').Count
        AvgDurationMin = if ($durations) { [math]::Round(($durations | Measure-Object -Average).Average, 2) } else { $null }
        MaxDurationMin = if ($durations) { [math]::Round(($durations | Measure-Object -Maximum).Maximum, 2) } else { $null }
        LastRun        = ($group | Sort-Object StartTime -Descending | Select-Object -First 1).StartTime
    }
}

$summary |
    Sort-Object Failed -Descending, Total -Descending |
    Format-Table RunbookName, Total, Completed, Failed, Suspended, AvgDurationMin, MaxDurationMin, LastRun -AutoSize |
    Out-Host

# Emit objects as well so callers can | Export-Csv or | ConvertTo-Json
return $summary
