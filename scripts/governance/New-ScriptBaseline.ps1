<#
    .SYNOPSIS
        Captures the baseline state of a runbook and generates its governance artifacts.

    .DESCRIPTION
        For a given runbook in runbooks/source/, this script:
        1. Creates a baseline document (governance/baselines/<Name>.baseline.md)
           capturing the original state, scan findings, permissions, and dependencies
        2. Creates a per-script checklist (governance/checklists/<Name>.checklist.md)
           from the template, pre-populated with scan results
        3. Records the file hash for integrity verification

    .PARAMETER RunbookName
        Filename of the runbook (e.g., "Set-SitePermissions.ps1").

    .PARAMETER All
        Process all .ps1 files in runbooks/source/.

    .EXAMPLE
        .\New-ScriptBaseline.ps1 -RunbookName "Set-SitePermissions.ps1"
        .\New-ScriptBaseline.ps1 -All
#>

param(
    [Parameter()]
    [string]$RunbookName,

    [Parameter()]
    [switch]$All,

    [Parameter()]
    [string]$SourcePath = ".\runbooks\source",

    [Parameter()]
    [string]$ScanResultsCsv = ".\agent\scan-results.csv",

    [Parameter()]
    [string]$PermissionAuditCsv = ".\agent\permission-audit.csv"
)

$ErrorActionPreference = "Stop"

# --- Determine which files to process ---
if ($All) {
    $files = Get-ChildItem -Path $SourcePath -Filter "*.ps1" -File
} elseif ($RunbookName) {
    $filePath = Join-Path $SourcePath $RunbookName
    if (-not (Test-Path $filePath)) { throw "File not found: $filePath" }
    $files = @(Get-Item $filePath)
} else {
    throw "Specify -RunbookName or -All"
}

# --- Load scan results if available ---
$scanResults = @()
if (Test-Path $ScanResultsCsv) {
    $scanResults = Import-Csv $ScanResultsCsv
}

$permResults = @()
if (Test-Path $PermissionAuditCsv) {
    $permResults = Import-Csv $PermissionAuditCsv
}

# --- Ensure output directories exist ---
$baselinePath = ".\governance\baselines"
$checklistPath = ".\governance\checklists"
New-Item -ItemType Directory -Path $baselinePath -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $checklistPath -Force -ErrorAction SilentlyContinue | Out-Null

# --- Load checklist template ---
$templatePath = ".\governance\CHECKLIST-TEMPLATE.md"
if (-not (Test-Path $templatePath)) {
    throw "Checklist template not found: $templatePath"
}
$template = Get-Content $templatePath -Raw

foreach ($file in $files) {
    $name = $file.Name
    $content = Get-Content $file.FullName -Raw
    $lines = Get-Content $file.FullName
    $hash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash
    $today = Get-Date -Format "yyyy-MM-dd"

    Write-Output "Processing: $name"

    # --- Collect findings for this file ---
    $findings = $scanResults | Where-Object { $_.File -eq $name }
    $perms = $permResults | Where-Object { $_.Runbook -eq $name }

    # --- Detect characteristics ---
    $hasParams = $content -match 'param\s*\('
    $hasErrorHandling = $content -match 'try\s*\{' -and $content -match 'catch\s*\{'
    $lineCount = $lines.Count

    # Services
    $services = @()
    if ($content -match 'Connect-SPOService|Get-SPOSite') { $services += "SharePoint-SPO (legacy)" }
    if ($content -match 'Connect-PnPOnline|Get-PnP') { $services += "SharePoint-PnP" }
    if ($content -match 'Connect-MgGraph|Get-Mg') { $services += "Microsoft Graph" }
    if ($content -match 'Connect-ExchangeOnline|Get-Mailbox') { $services += "Exchange Online" }
    if ($content -match 'Connect-AzureAD') { $services += "AzureAD (legacy)" }
    if ($content -match 'Connect-MsolService') { $services += "MSOnline (legacy)" }
    if ($content -match 'Connect-AzAccount') { $services += "Azure RM" }

    # Complexity
    $score = 0
    $score += ($findings | Where-Object Severity -eq "Critical").Count * 3
    $score += ($findings | Where-Object Severity -eq "High").Count * 2
    $score += ($findings | Where-Object Severity -eq "Medium").Count * 1
    $complexity = if ($score -le 3) { "Simple" } elseif ($score -le 8) { "Medium" } else { "Complex" }

    # PS 5.1 requirement
    $mustPS51 = $content -match 'New-Object\s+.*-ComObject' -or
                $content -match 'Add-Type\s+-AssemblyName\s+(System\.Windows|PresentationFramework)'

    # --- Create baseline document ---
    $findingsTable = if ($findings.Count -gt 0) {
        ($findings | ForEach-Object {
            "| $($_.Pattern) | $($_.Severity) | $($_.LineNumber) | ``$($_.LineText)`` |"
        }) -join "`n"
    } else { "| (none) | | | |" }

    $permsTable = if ($perms.Count -gt 0) {
        ($perms | ForEach-Object {
            "| $($_.Service) | $($_.Permission) | $($_.Level) |"
        }) -join "`n"
    } else { "| (none) | | |" }

    $baselineContent = @"
# Baseline: $name

**Captured:** $today
**SHA-256:** ``$hash``
**Lines:** $lineCount
**Complexity:** $complexity (score: $score)
**PS 5.1 required:** $(if ($mustPS51) { "Yes" } else { "No" })

## Services Detected
$(if ($services.Count -gt 0) { ($services | ForEach-Object { "- $_" }) -join "`n" } else { "- (none detected)" })

## Scanner Findings ($($findings.Count) patterns)
| Pattern | Severity | Line | Code |
|---------|----------|------|------|
$findingsTable

## Permission Requirements (advisory)
| Service | Permission | Level |
|---------|------------|-------|
$permsTable

## Script Characteristics
- Has param block: $hasParams
- Has error handling: $hasErrorHandling
- Line count: $lineCount

## Original Auth Block
``````powershell
$(($lines | Select-String -Pattern 'Get-AutomationPSCredential|Get-Credential|Connect-SPOService|Connect-PnPOnline.*-Credential|Connect-ExchangeOnline.*-Credential|Connect-AzAccount.*-ServicePrincipal|AzureRunAsConnection|Connect-AzureAD|Connect-MsolService' | ForEach-Object { $_.Line.Trim() }) -join "`n")
``````
"@

    $baselineFile = Join-Path $baselinePath "$($file.BaseName).baseline.md"
    $baselineContent | Out-File -FilePath $baselineFile -Encoding utf8
    Write-Output "  Baseline: $baselineFile"

    # --- Create checklist from template ---
    $checklistFile = Join-Path $checklistPath "$($file.BaseName).checklist.md"

    if (Test-Path $checklistFile) {
        Write-Output "  Checklist already exists — skipping (use -Force to overwrite)"
    } else {
        # Populate template
        $checklist = $template -replace '\{\{RUNBOOK_NAME\}\}', $name
        $checklist = $checklist -replace '\{\{DATE\}\}', $today

        # Fill in scanner findings table
        $scanTableRows = if ($findings.Count -gt 0) {
            ($findings | ForEach-Object {
                "| $($_.Pattern) | $($_.Severity) | $($_.LineNumber) | $($_.Guidance) |"
            }) -join "`n"
        } else {
            "| (no findings) | | | |"
        }
        # Replace the empty findings rows in the template
        $checklist = $checklist -replace '\| \| \| \| \|\n\| \| \| \| \|\n\| \| \| \| \|', $scanTableRows

        # Fill complexity
        $checklist = $checklist -replace 'Simple \| Medium \| Complex', $complexity

        $checklist | Out-File -FilePath $checklistFile -Encoding utf8
        Write-Output "  Checklist: $checklistFile"
    }
}

Write-Output ""
Write-Output "Done. Baselines: $baselinePath | Checklists: $checklistPath"
