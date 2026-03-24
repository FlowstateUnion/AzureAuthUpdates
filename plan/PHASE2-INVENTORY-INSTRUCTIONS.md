# Phase 2: Runbook Inventory & Analysis — Operator Instructions

## Overview

This document provides step-by-step instructions for exporting all runbooks from the Azure Automation Account, scanning them for legacy authentication patterns, classifying them by migration complexity, and producing a prioritized migration queue. This is a prerequisite before any runbook code is modified.

**Estimated time:** 30–60 minutes depending on runbook count.
**Who should run this:** Someone with Reader or Contributor access to the Automation Account.

---

## Prerequisites

Before starting, confirm the following:

### Access Requirements
- [ ] Azure subscription access with at least **Reader** role on the Automation Account
- [ ] `Az.Accounts` and `Az.Automation` PowerShell modules installed locally (or use Azure Cloud Shell)
- [ ] Authenticated to Azure (`Connect-AzAccount` completed, or Cloud Shell session active)

### Verify Access
```powershell
# Confirm you're logged in and can see the Automation Account
Connect-AzAccount
Get-AzAutomationAccount -ResourceGroupName "<YOUR-RG>" -Name "<YOUR-AA-NAME>"
```

If this returns the account details, you're ready. If it errors, check your subscription/role.

### Local Environment
- PowerShell 5.1+ or 7.x (either works for export/scan)
- This project repo cloned or copied locally
- Sufficient disk space (~1 MB per runbook; 100 runbooks ≈ 100 MB worst case)

---

## Step 1: Export Runbooks

You have three options. Choose the one that fits your environment.

### Option A: Use the Export Script (Recommended)

```powershell
# Navigate to the project
cd D:\DevProjects\AzureAuthUpdates

# Authenticate if not already
Connect-AzAccount

# Run the export script
.\scripts\migration\Export-Runbooks.ps1 `
    -ResourceGroupName "<YOUR-RESOURCE-GROUP>" `
    -AutomationAccountName "<YOUR-AUTOMATION-ACCOUNT>" `
    -OutputPath ".\runbooks\source"
```

**What this does:**
- Connects to the Automation Account
- Exports every PowerShell runbook as a `.ps1` file
- Creates `_runbook-metadata.json` with each runbook's name, type, state, last modified date, and description
- Skips non-PowerShell runbooks (Python, Graph)

**Expected output:**
```
Fetching runbooks from 'aa-prod'...
Found 47 PowerShell runbooks (of 52 total).
Exporting: Set-SitePermissions (PowerShell, State: Published)...
Exporting: Sync-UserAccounts (PowerShell, State: Published)...
...
Exported 47 runbooks to: .\runbooks\source
Metadata written to: .\runbooks\source\_runbook-metadata.json
```

### Option B: Use Azure Cloud Shell

If you can't install modules locally, use Cloud Shell (portal.azure.com > Cloud Shell icon):

```powershell
# Cloud Shell already has Az modules and is authenticated

# Create a temp directory
mkdir ~/runbook-export

# Export
$rg = "<YOUR-RESOURCE-GROUP>"
$aa = "<YOUR-AUTOMATION-ACCOUNT>"

Get-AzAutomationRunbook -ResourceGroupName $rg -AutomationAccountName $aa |
    Where-Object { $_.RunbookType -match 'PowerShell' } |
    ForEach-Object {
        Write-Output "Exporting: $($_.Name)..."
        Export-AzAutomationRunbook -ResourceGroupName $rg `
            -AutomationAccountName $aa `
            -Name $_.Name `
            -OutputFolder ~/runbook-export `
            -Force
    }

# Download the folder
# Use Cloud Shell's Upload/Download feature (click the upload/download icon)
# Or zip and download:
Compress-Archive -Path ~/runbook-export/* -DestinationPath ~/runbook-export.zip
# Then download ~/runbook-export.zip via Cloud Shell's download button
```

After downloading, extract into `D:\DevProjects\AzureAuthUpdates\runbooks\source\`.

### Option C: Export via Azure Portal (Manual)

If scripted access is not possible:

1. Go to **Azure Portal** > your **Automation Account** > **Runbooks**
2. For each runbook:
   a. Click the runbook name
   b. Click **View** (or **Edit**)
   c. Click **...** menu > **Export**
   d. Save the `.ps1` file to `D:\DevProjects\AzureAuthUpdates\runbooks\source\`
3. Also record a list of all runbooks with their state and description (screenshot the runbook list page as a fallback)

> **Note:** Portal export is tedious for more than ~10 runbooks. Prefer Option A or B.

### Option D: Copy from Source Control

If your runbooks are already stored in a Git repo or Azure DevOps:

```powershell
# Clone the source repo that contains runbook scripts
git clone <YOUR-RUNBOOK-REPO-URL> temp-runbooks

# Copy the .ps1 files into the project
Copy-Item -Path .\temp-runbooks\**\*.ps1 -Destination .\runbooks\source\ -Recurse
```

---

## Step 2: Verify the Export

Before scanning, confirm the export is complete:

```powershell
cd D:\DevProjects\AzureAuthUpdates

# Count exported files
$files = Get-ChildItem -Path .\runbooks\source -Filter "*.ps1" -Recurse
Write-Output "Exported runbook count: $($files.Count)"

# Quick sanity check — list them
$files | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize

# If metadata was generated, review it
if (Test-Path .\runbooks\source\_runbook-metadata.json) {
    $meta = Get-Content .\runbooks\source\_runbook-metadata.json | ConvertFrom-Json
    Write-Output "Metadata records: $($meta.Count)"
    $meta | Select-Object Name, RunbookType, State, LastModified | Format-Table -AutoSize
}
```

**What to look for:**
- File count matches what you expect from the Automation Account
- No empty (0 byte) files — those indicate export failures
- If any are missing, re-export individually

---

## Step 3: Run the Legacy Auth Scanner

```powershell
cd D:\DevProjects\AzureAuthUpdates

.\scripts\migration\Scan-LegacyAuth.ps1 `
    -Path ".\runbooks\source" `
    -OutputCsv ".\plan\scan-results.csv"
```

**What this does:**
- Reads every `.ps1` file in the directory
- Checks each line against 13 legacy auth patterns
- Assigns severity (Critical / High / Medium) and category
- Outputs a console summary and a CSV file

**Expected output example:**
```
Scanning 47 PowerShell files in '.\runbooks\source'...

Found 83 legacy pattern instances across 47 files:

  Critical: 24 instances
  High: 41 instances
  Medium: 18 instances

--- By File ---
  Set-SitePermissions.ps1: 5 patterns (2 Critical, 2 High, 1 Medium)
  Sync-UserAccounts.ps1: 4 patterns (1 Critical, 3 High)
  ...

--- Details ---
[Critical] Set-SitePermissions.ps1:12 — Get-AutomationPSCredential
  Line: $cred = Get-AutomationPSCredential -Name "SPOAdmin"
  Fix:  Replace with Managed Identity via Connect-ContosoAzure / Connect-ContosoSharePoint
...

Report exported to: .\plan\scan-results.csv
```

---

## Step 4: Review and Classify Results

### 4a: Open the CSV

Open `plan\scan-results.csv` in Excel or your preferred tool. It contains these columns:

| Column | Description |
|--------|-------------|
| File | Runbook filename |
| FilePath | Full path |
| LineNumber | Line where the pattern was found |
| LineText | The actual code line |
| Pattern | Name of the legacy pattern matched |
| Severity | Critical / High / Medium |
| Category | Grouping (StoredCredential, ClientSecret, LegacyModule, etc.) |
| Guidance | Recommended fix (references strategy docs) |

### 4b: Generate the Per-Runbook Summary

Run this to create a per-runbook classification:

```powershell
$results = Import-Csv ".\plan\scan-results.csv"

$summary = $results | Group-Object File | ForEach-Object {
    $patterns = $_.Group
    $categories = ($patterns | Select-Object -Unique Category).Category

    # Complexity scoring
    $score = 0
    $score += ($patterns | Where-Object Severity -eq "Critical").Count * 3
    $score += ($patterns | Where-Object Severity -eq "High").Count * 2
    $score += ($patterns | Where-Object Severity -eq "Medium").Count * 1

    $complexity = switch ($true) {
        ($score -le 3)  { "Simple" }
        ($score -le 8)  { "Medium" }
        default         { "Complex" }
    }

    [PSCustomObject]@{
        Runbook        = $_.Name
        PatternCount   = $patterns.Count
        CriticalCount  = ($patterns | Where-Object Severity -eq "Critical").Count
        HighCount      = ($patterns | Where-Object Severity -eq "High").Count
        MediumCount    = ($patterns | Where-Object Severity -eq "Medium").Count
        Categories     = ($categories -join "; ")
        Complexity     = $complexity
        Score          = $score
    }
} | Sort-Object Score

# Display
$summary | Format-Table -AutoSize

# Export
$summary | Export-Csv ".\plan\runbook-classification.csv" -NoTypeInformation
Write-Output "Classification exported to: .\plan\runbook-classification.csv"

# Summary stats
$simpleCount  = ($summary | Where-Object Complexity -eq "Simple").Count
$mediumCount  = ($summary | Where-Object Complexity -eq "Medium").Count
$complexCount = ($summary | Where-Object Complexity -eq "Complex").Count
Write-Output ""
Write-Output "Complexity Breakdown:"
Write-Output "  Simple:  $simpleCount runbooks"
Write-Output "  Medium:  $mediumCount runbooks"
Write-Output "  Complex: $complexCount runbooks"
```

### 4c: Complexity Definitions

| Complexity | Score | Typical Profile | Migration Effort |
|------------|-------|-----------------|------------------|
| **Simple** | 1–3 | Single `Get-AutomationPSCredential` + one `Connect-*` call. Linear logic. | Replace auth block, apply template. ~15 min. |
| **Medium** | 4–8 | Multiple auth patterns, or mixes SPO + PnP + Graph. Some branching logic. | Auth replacement + cmdlet mapping + testing. ~45 min. |
| **Complex** | 9+ | Multiple credential types, cross-service calls, `Connect-SPOService` with many SPO cmdlets to remap, error handling intertwined with auth. | Full rewrite of auth layer, cmdlet remapping, extensive testing. ~2 hrs. |

### 4d: Identify Runbooks with No Findings

Some runbooks may not use any legacy auth patterns (already modern, or don't authenticate at all). These need no migration:

```powershell
$allRunbooks = Get-ChildItem ".\runbooks\source" -Filter "*.ps1" | Select-Object -ExpandProperty Name
$flaggedRunbooks = $results | Select-Object -Unique File | Select-Object -ExpandProperty File
$cleanRunbooks = $allRunbooks | Where-Object { $_ -notin $flaggedRunbooks }

Write-Output "Runbooks with NO legacy auth patterns ($($cleanRunbooks.Count)):"
$cleanRunbooks | ForEach-Object { Write-Output "  $_" }
```

---

## Step 5: Build the Migration Queue

### 5a: Prioritization Rules

Migrate in this order:
1. **Simple runbooks first** — fast wins, validate the process
2. **Group by category** within each complexity tier — batch similar changes
3. **Critical severity first** within each group — highest risk patterns first
4. **Recently-modified runbooks before stale ones** — actively used scripts get priority

### 5b: Generate the Queue

```powershell
$classification = Import-Csv ".\plan\runbook-classification.csv"

# If metadata exists, join it for last-modified dates
$metadataPath = ".\runbooks\source\_runbook-metadata.json"
if (Test-Path $metadataPath) {
    $metadata = Get-Content $metadataPath | ConvertFrom-Json
    $queue = $classification | ForEach-Object {
        $rb = $_
        $meta = $metadata | Where-Object { $_.ExportedFile -eq $rb.Runbook }
        $rb | Add-Member -NotePropertyName "LastModified" -NotePropertyValue $meta.LastModified -PassThru
        $rb | Add-Member -NotePropertyName "State" -NotePropertyValue $meta.State -PassThru
        $rb | Add-Member -NotePropertyName "Description" -NotePropertyValue $meta.Description -PassThru
    }
}
else {
    $queue = $classification
}

# Sort: Simple first, then by Critical count descending
$queue = $queue | Sort-Object @(
    @{ Expression = { switch ($_.Complexity) { "Simple" { 0 } "Medium" { 1 } "Complex" { 2 } } } }
    @{ Expression = "CriticalCount"; Descending = $true }
    @{ Expression = "Score"; Descending = $false }
)

# Add a sequence number
$i = 1
$queue = $queue | ForEach-Object {
    $_ | Add-Member -NotePropertyName "Order" -NotePropertyValue $i -PassThru
    $i++
}

# Export the final queue
$queue | Export-Csv ".\plan\migration-queue.csv" -NoTypeInformation
$queue | Select-Object Order, Runbook, Complexity, Score, CriticalCount, HighCount, Categories |
    Format-Table -AutoSize

Write-Output ""
Write-Output "Migration queue exported to: .\plan\migration-queue.csv"
```

---

## Step 6: Verify Source Scripts Are in Place

Confirm all runbook scripts are in `runbooks/source/` — this is where the migration agent reads from.

```powershell
$queue = Import-Csv ".\plan\migration-queue.csv"

foreach ($item in $queue) {
    $source = Join-Path ".\runbooks\source" $item.Runbook

    if (Test-Path $source) {
        Write-Output "[OK] $($item.Runbook)"
    }
    else {
        Write-Warning "[MISSING] $($item.Runbook) — not found in runbooks\source\"
    }
}

Write-Output ""
Write-Output "Source scripts verified. Ready for Phase 3 migration."
Write-Output "The migration agent will work in runbooks\staging\ and advance to runbooks\testing\."
```

---

## Step 7: Output Summary for Phase 3 Handoff

Run this final block to produce a handoff summary:

```powershell
$queue = Import-Csv ".\plan\migration-queue.csv"
$scanResults = Import-Csv ".\plan\scan-results.csv"

Write-Output "============================================="
Write-Output "  PHASE 2 COMPLETE — INVENTORY SUMMARY"
Write-Output "============================================="
Write-Output ""
Write-Output "Total runbooks exported:    $(( Get-ChildItem .\runbooks\source -Filter *.ps1 ).Count)"
Write-Output "Runbooks needing migration: $($queue.Count)"
Write-Output "Total legacy patterns:      $($scanResults.Count)"
Write-Output ""
Write-Output "Complexity Breakdown:"
$queue | Group-Object Complexity | ForEach-Object {
    Write-Output "  $($_.Name): $($_.Count) runbooks"
}
Write-Output ""
Write-Output "Top Categories:"
$scanResults | Group-Object Category | Sort-Object Count -Descending | ForEach-Object {
    Write-Output "  $($_.Name): $($_.Count) instances"
}
Write-Output ""
Write-Output "Files produced:"
Write-Output "  plan\scan-results.csv          — Full scan findings (per-line detail)"
Write-Output "  plan\runbook-classification.csv — Per-runbook complexity classification"
Write-Output "  plan\migration-queue.csv        — Prioritized migration order"
Write-Output "  runbooks\source\              — Original scripts (ready for agent)"
Write-Output ""
Write-Output "Next step: Begin Phase 3 — migrate runbooks starting at Order #1."
Write-Output "Reference: plan\MASTER-PLAN.md (Phase 3) and strategy\ docs."
```

---

## Troubleshooting

### "Not logged in to Azure"
Run `Connect-AzAccount`. If using a service principal, use `Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant $tenantId`.

### Export script exports 0 runbooks
- Verify the Automation Account name and resource group are correct
- Verify your account has at least Reader access
- Check `$runbooks.RunbookType` — the script filters for `PowerShell`; your account may have `PowerShellWorkflow` or `Python` types that are filtered out

### Scanner finds 0 patterns
- Verify the export directory has `.ps1` files (not `.txt` or other extensions)
- Run `Get-Content <any-exported-file>.ps1 | Select-String "Get-Credential|Connect-SPO"` to manually spot-check

### Module not found errors
```powershell
# Install required modules
Install-Module Az.Accounts -Scope CurrentUser -Force
Install-Module Az.Automation -Scope CurrentUser -Force
```
