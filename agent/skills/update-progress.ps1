<#
    .SYNOPSIS
        Skill: Update the progress tracking files after processing a runbook.

    .DESCRIPTION
        Updates agent/progress.json and agent/PROGRESS.md with the current
        status of a runbook. Called after each analyze/migrate/validate/exception step.

    .PARAMETER RunbookName
        Filename of the runbook.

    .PARAMETER Status
        Current status: Analyzed, Migrated, Validated, Testing, Completed, Exception

    .PARAMETER Complexity
        Simple, Medium, or Complex.

    .PARAMETER Notes
        Optional notes about this runbook's migration.

    .EXAMPLE
        .\agent\skills\update-progress.ps1 -RunbookName "Set-SitePermissions.ps1" -Status "Validated" -Complexity "Simple"
#>

param(
    [Parameter(Mandatory)]
    [string]$RunbookName,

    [Parameter(Mandatory)]
    [ValidateSet("Pending", "Analyzed", "Migrated", "Validated", "Testing", "Completed", "Exception")]
    [string]$Status,

    [Parameter()]
    [ValidateSet("Simple", "Medium", "Complex", "Unknown")]
    [string]$Complexity = "Unknown",

    [Parameter()]
    [string]$Notes = "",

    [Parameter()]
    [string]$ProgressJsonPath = ".\agent\progress.json",

    [Parameter()]
    [string]$ProgressMdPath = ".\agent\PROGRESS.md"
)

$ErrorActionPreference = "Stop"

# --- Load or create progress.json ---
$progress = @{}
if (Test-Path $ProgressJsonPath) {
    $progress = Get-Content $ProgressJsonPath -Raw | ConvertFrom-Json -AsHashtable
}
if (-not $progress.ContainsKey("runbooks")) { $progress["runbooks"] = @{} }
if (-not $progress.ContainsKey("startedAt")) { $progress["startedAt"] = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }

# --- Update this runbook's entry ---
$progress["runbooks"][$RunbookName] = @{
    status      = $Status
    complexity  = $Complexity
    notes       = $Notes
    updatedAt   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}
$progress["lastUpdated"] = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

# --- Calculate summary stats ---
$all = $progress["runbooks"].Values
$stats = @{
    total      = $all.Count
    pending    = ($all | Where-Object { $_.status -eq "Pending" }).Count
    analyzed   = ($all | Where-Object { $_.status -eq "Analyzed" }).Count
    migrated   = ($all | Where-Object { $_.status -eq "Migrated" }).Count
    validated  = ($all | Where-Object { $_.status -eq "Validated" }).Count
    testing    = ($all | Where-Object { $_.status -eq "Testing" }).Count
    completed  = ($all | Where-Object { $_.status -eq "Completed" }).Count
    exceptions = ($all | Where-Object { $_.status -eq "Exception" }).Count
}
$stats["done"] = $stats["validated"] + $stats["testing"] + $stats["completed"]
$stats["pctComplete"] = if ($stats["total"] -gt 0) {
    [math]::Round(($stats["done"] + $stats["exceptions"]) / $stats["total"] * 100, 1)
} else { 0 }

$progress["stats"] = $stats

# --- Save progress.json ---
$progress | ConvertTo-Json -Depth 4 | Out-File -FilePath $ProgressJsonPath -Encoding utf8

# --- Generate PROGRESS.md ---
$md = @"
# Migration Progress

**Last updated:** $($progress["lastUpdated"])
**Started:** $($progress["startedAt"])

## Summary

| Metric | Count |
|--------|-------|
| Total runbooks | $($stats["total"]) |
| Pending | $($stats["pending"]) |
| Analyzed | $($stats["analyzed"]) |
| Migrated (in staging) | $($stats["migrated"]) |
| Validated (in testing) | $($stats["validated"]) |
| Tested (in testing) | $($stats["testing"]) |
| Completed (approved) | $($stats["completed"]) |
| Exceptions (can't migrate) | $($stats["exceptions"]) |
| **Progress** | **$($stats["pctComplete"])%** |

## Pipeline

``````
Pending [$($stats["pending"])] → Analyzed [$($stats["analyzed"])] → Migrated [$($stats["migrated"])] → Validated [$($stats["validated"])] → Testing [$($stats["testing"])] → Completed [$($stats["completed"])]
                                                                                                    ↘ Exception [$($stats["exceptions"])]
``````

## Per-Runbook Status

| Runbook | Status | Complexity | Notes | Updated |
|---------|--------|------------|-------|---------|
"@

$sortedRunbooks = $progress["runbooks"].GetEnumerator() | Sort-Object { $_.Value.updatedAt } -Descending
foreach ($entry in $sortedRunbooks) {
    $rb = $entry.Value
    $statusIcon = switch ($rb.status) {
        "Pending"    { "⏳" }
        "Analyzed"   { "🔍" }
        "Migrated"   { "🔧" }
        "Validated"  { "✅" }
        "Testing"    { "🧪" }
        "Completed"  { "🏁" }
        "Exception"  { "⚠️" }
        default      { "❓" }
    }
    $md += "| $($entry.Key) | $statusIcon $($rb.status) | $($rb.complexity) | $($rb.notes) | $($rb.updatedAt) |`n"
}

$md | Out-File -FilePath $ProgressMdPath -Encoding utf8

Write-Output "Updated: $RunbookName → $Status"
Write-Output "Progress: $($stats['pctComplete'])% ($($stats['done'] + $stats['exceptions'])/$($stats['total']))"
