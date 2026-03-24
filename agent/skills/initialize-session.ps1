<#
    .SYNOPSIS
        Skill: Initialize the agent's working session.

    .DESCRIPTION
        Run this at the start of every new agent session. It:
        1. Scans runbooks/source/ for all .ps1 files
        2. Runs the legacy auth scanner (if not already done)
        3. Runs the permission audit (if not already done)
        4. Initializes or loads the progress tracker
        5. Reports what work remains

        The agent should run this FIRST before doing anything else.

    .PARAMETER SourcePath
        Path to source runbooks. Default: .\runbooks\source

    .PARAMETER Force
        Re-run scans even if results already exist.

    .EXAMPLE
        .\agent\skills\initialize-session.ps1
#>

param(
    [Parameter()]
    [string]$SourcePath = ".\runbooks\source",

    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Output "=== SESSION INITIALIZATION ==="
Write-Output ""

# --- Check source folder ---
$sourceFiles = Get-ChildItem -Path $SourcePath -Filter "*.ps1" -File -ErrorAction SilentlyContinue
if ($sourceFiles.Count -eq 0) {
    Write-Warning "No .ps1 files found in $SourcePath"
    Write-Output ""
    Write-Output "WAITING: The human needs to copy production runbook scripts into:"
    Write-Output "  $((Resolve-Path $SourcePath -ErrorAction SilentlyContinue) ?? $SourcePath)"
    Write-Output ""
    Write-Output "Once files are in place, run this skill again."
    return
}

Write-Output "Source runbooks found: $($sourceFiles.Count)"
$sourceFiles | ForEach-Object { Write-Output "  $($_.Name)" }
Write-Output ""

# --- Run scanner ---
$scanCsv = ".\agent\scan-results.csv"
if (-not (Test-Path $scanCsv) -or $Force) {
    Write-Output "Running legacy auth scanner..."
    & ".\scripts\migration\Scan-LegacyAuth.ps1" -Path $SourcePath -OutputCsv $scanCsv
    Write-Output ""
} else {
    Write-Output "Scan results already exist: $scanCsv (use -Force to re-scan)"
}

# --- Run permission audit ---
$permCsv = ".\agent\permission-audit.csv"
if (-not (Test-Path $permCsv) -or $Force) {
    Write-Output "Running permission audit..."
    & ".\scripts\migration\Scan-Permissions.ps1" -Path $SourcePath -OutputCsv $permCsv
    Write-Output ""
} else {
    Write-Output "Permission audit already exists: $permCsv (use -Force to re-scan)"
}

# --- Initialize progress tracker ---
$progressJson = ".\agent\progress.json"
$progressMd = ".\agent\PROGRESS.md"

if (-not (Test-Path $progressJson)) {
    Write-Output "Initializing progress tracker..."

    # Create initial entries for all source files
    foreach ($file in $sourceFiles) {
        & ".\agent\skills\update-progress.ps1" `
            -RunbookName $file.Name `
            -Status "Pending" `
            -Complexity "Unknown" `
            -Notes "Awaiting analysis"
    }
    Write-Output "Progress tracker created with $($sourceFiles.Count) runbooks."
} else {
    Write-Output "Progress tracker exists. Loading current state..."
    $progress = Get-Content $progressJson -Raw | ConvertFrom-Json
    $stats = $progress.stats

    Write-Output ""
    Write-Output "=== CURRENT PROGRESS ==="
    Write-Output "Total:      $($stats.total)"
    Write-Output "Pending:    $($stats.pending)"
    Write-Output "Analyzed:   $($stats.analyzed)"
    Write-Output "Migrated:   $($stats.migrated)"
    Write-Output "Validated:  $($stats.validated)"
    Write-Output "Testing:    $($stats.testing)"
    Write-Output "Completed:  $($stats.completed)"
    Write-Output "Exceptions: $($stats.exceptions)"
    Write-Output "Progress:   $($stats.pctComplete)%"

    # Check for new files not yet in tracker
    $tracked = $progress.runbooks.PSObject.Properties.Name
    $newFiles = $sourceFiles | Where-Object { $_.Name -notin $tracked }
    if ($newFiles.Count -gt 0) {
        Write-Output ""
        Write-Output "New runbooks detected ($($newFiles.Count)):"
        foreach ($file in $newFiles) {
            Write-Output "  Adding: $($file.Name)"
            & ".\agent\skills\update-progress.ps1" `
                -RunbookName $file.Name `
                -Status "Pending" `
                -Complexity "Unknown" `
                -Notes "New — added this session"
        }
    }
}

# --- Report next actions ---
Write-Output ""
Write-Output "=== NEXT ACTIONS ==="

if (Test-Path $progressJson) {
    $progress = Get-Content $progressJson -Raw | ConvertFrom-Json
    $pending = $progress.runbooks.PSObject.Properties |
        Where-Object { $_.Value.status -eq "Pending" } |
        Select-Object -ExpandProperty Name

    $analyzed = $progress.runbooks.PSObject.Properties |
        Where-Object { $_.Value.status -eq "Analyzed" } |
        Select-Object -ExpandProperty Name

    if ($pending.Count -gt 0) {
        Write-Output "Ready to ANALYZE ($($pending.Count)):"
        $pending | Select-Object -First 5 | ForEach-Object { Write-Output "  $_" }
        if ($pending.Count -gt 5) { Write-Output "  ... and $($pending.Count - 5) more" }
    }

    if ($analyzed.Count -gt 0) {
        Write-Output "Ready to MIGRATE ($($analyzed.Count)):"
        $analyzed | Select-Object -First 5 | ForEach-Object { Write-Output "  $_" }
    }
}

Write-Output ""
Write-Output "Session initialized. Begin with: analyze-runbook.ps1 -RunbookName '<first-pending>'"
