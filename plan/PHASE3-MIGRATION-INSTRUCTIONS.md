# Phase 3: Per-Runbook Migration — Operator Instructions

## Overview

This document provides step-by-step instructions for migrating individual runbooks from legacy auth patterns to the shared `Contoso.Automation.Auth` module. Work from the staging copies created in Phase 2.

**Prerequisites:**
- Phase 0 complete (MI enabled, permissions granted, runtime environment created)
- Phase 1 complete (shared auth module deployed and validated via `Test-AuthModule.ps1`)
- Phase 2 complete (`migration-queue.csv` and staged runbook copies exist)

---

## Per-Runbook Migration Workflow

Repeat this workflow for each runbook, working through `migration-queue.csv` in order.

### Step 1: Read the Runbook and Scan Results

```powershell
$runbookName = "Set-SitePermissions.ps1"  # <-- change per runbook
$complexity  = "simple"                    # <-- from migration-queue.csv

# Open the staged copy
$path = ".\staging\$complexity\$runbookName"
code $path   # or notepad, ISE, etc.

# Review its specific findings
Import-Csv ".\plan\scan-results.csv" |
    Where-Object File -eq $runbookName |
    Format-Table LineNumber, Pattern, Severity, LineText, Guidance -AutoSize
```

Read the full script. Understand what it does before changing anything. Note:
- What service(s) it connects to (SharePoint, Graph, Azure, Exchange, etc.)
- What the auth block looks like (top of the script, usually)
- Whether auth is done once or multiple times (e.g., connecting to multiple sites)
- What parameters the script accepts (especially ones feeding into auth)
- Whether it has existing error handling

### Step 2: Identify the Auth Block

The auth block is typically the first 5–20 lines after the param block. Common shapes:

**Shape A — Simple credential:**
```powershell
$cred = Get-AutomationPSCredential -Name "SomeCredential"
Connect-SPOService -Url $adminUrl -Credential $cred
```

**Shape B — Client secret construction:**
```powershell
$clientId = Get-AutomationVariable -Name "ClientId"
$clientSecret = Get-AutomationVariable -Name "ClientSecret"
$secSecret = ConvertTo-SecureString $clientSecret -AsPlainText -Force
$cred = New-Object PSCredential($clientId, $secSecret)
Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant $tenantId
```

**Shape C — Run As connection:**
```powershell
$conn = Get-AutomationConnection -Name "AzureRunAsConnection"
Connect-AzAccount -ServicePrincipal -Tenant $conn.TenantId `
    -ApplicationId $conn.ApplicationId `
    -CertificateThumbprint $conn.CertificateThumbprint
```

**Shape D — PnP with credentials:**
```powershell
$cred = Get-AutomationPSCredential -Name "SPOUser"
Connect-PnPOnline -Url $siteUrl -Credentials $cred
```

### Step 3: Replace the Auth Block

Delete the entire auth block and replace it with the shared module pattern. Reference the appropriate strategy doc for specifics.

**Standard replacement (most runbooks):**

```powershell
# --- Authentication ---
Import-Module Contoso.Automation.Auth

Connect-ContosoAzure
# Add the services this runbook needs:
Connect-ContosoSharePoint -SiteUrl $SiteUrl          # if it uses PnP/SPO
Connect-ContosoGraph                                  # if it uses Graph
```

**If the runbook used `Connect-SPOService`:**

Replace the connection AND remap all SPO cmdlets to PnP equivalents. See `strategy/01-Connect-SPOService.md` for the full mapping table.

```powershell
# BEFORE
Connect-SPOService -Url "https://contoso-admin.sharepoint.com" -Credential $cred
$sites = Get-SPOSite -Limit All

# AFTER
Connect-ContosoSPOAdmin -TenantName "contoso"
$sites = Get-PnPTenantSite
```

**If the runbook connects to multiple SharePoint sites:**

```powershell
Connect-ContosoAzure

# Site 1
Connect-ContosoSharePoint -SiteUrl "https://contoso.sharepoint.com/sites/HR"
$hrItems = Get-PnPListItem -List "Employees"

# Site 2 (reconnect)
Connect-ContosoSharePoint -SiteUrl "https://contoso.sharepoint.com/sites/IT"
$itItems = Get-PnPListItem -List "Assets"
```

Or use connection objects for parallel access:

```powershell
Connect-ContosoAzure

$hrConn = Connect-ContosoSharePoint -SiteUrl "https://contoso.sharepoint.com/sites/HR" -ReturnConnection
$itConn = Connect-ContosoSharePoint -SiteUrl "https://contoso.sharepoint.com/sites/IT" -ReturnConnection

$hrItems = Get-PnPListItem -List "Employees" -Connection $hrConn
$itItems = Get-PnPListItem -List "Assets" -Connection $itConn
```

**If the runbook used Key Vault secrets (for third-party APIs):**

```powershell
Connect-ContosoAzure
$apiKey = Get-ContosoKeyVaultSecret -VaultName "contoso-kv" -SecretName "ThirdPartyApiKey" -AsPlainText
```

### Step 4: Apply the Standardized Template

Wrap the runbook in the standard structure from `templates/RunbookTemplate.ps1`:

1. **Add `#Requires` at the top** — list every module the runbook uses
2. **Add the script header** (`.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`)
3. **Set `$ErrorActionPreference = "Stop"`** if not already present
4. **Wrap business logic in `try/catch/finally`** if not already present
5. **Add cleanup in `finally`:**
   ```powershell
   finally {
       Disconnect-ContosoAll
       Write-Output "Runbook execution finished."
   }
   ```

**Do NOT change:**
- Existing parameter names or types (schedules/webhooks depend on them)
- Business logic that works correctly
- Output format if downstream processes consume it

### Step 5: Remove Dead Code

After replacing the auth block, delete any now-unused lines:
- `$cred = Get-AutomationPSCredential ...`
- `$clientSecret = Get-AutomationVariable ...`
- `$secString = ConvertTo-SecureString ...`
- `$credential = New-Object PSCredential ...`
- `$conn = Get-AutomationConnection ...`
- Any `Import-Module` for `Microsoft.Online.SharePoint.PowerShell` (if fully migrated to PnP)

### Step 6: Update Module Requirements

At the top of the file:

```powershell
#Requires -Modules Contoso.Automation.Auth
#Requires -Modules @{ ModuleName="PnP.PowerShell"; ModuleVersion="2.4" }
# Add Graph sub-modules only if used:
#Requires -Modules @{ ModuleName="Microsoft.Graph.Authentication"; ModuleVersion="2.0" }
#Requires -Modules @{ ModuleName="Microsoft.Graph.Users"; ModuleVersion="2.0" }
```

### Step 7: Validate Locally (Syntax Check)

Before uploading to Azure, check for syntax errors:

```powershell
$errors = $null
$null = [System.Management.Automation.PSParser]::Tokenize(
    (Get-Content ".\staging\$complexity\$runbookName" -Raw), [ref]$errors
)

if ($errors.Count -eq 0) {
    Write-Output "Syntax OK: $runbookName"
} else {
    Write-Output "Syntax errors in ${runbookName}:"
    $errors | ForEach-Object { Write-Output "  Line $($_.Token.StartLine): $($_.Message)" }
}
```

### Step 8: Test in Azure Automation

1. Go to **Azure Portal** > **Automation Account** > **Runbooks**
2. Click the runbook name > **Edit**
3. Paste the updated code (or import the file)
4. Click **Test pane**
5. Fill in required parameters
6. Click **Start**
7. Review output — compare to the last successful job output of the original

**What to verify:**
- [ ] Authentication succeeds (no credential errors)
- [ ] Business logic runs without errors
- [ ] Output data matches what the original produced
- [ ] No new warnings or errors in the job log

### Step 9: Publish

Once testing passes:

1. In the Edit pane, click **Publish**
2. Confirm the publish
3. The previous version is automatically saved as a draft you can revert to

Or via PowerShell:

```powershell
# Upload the migrated script
Import-AzAutomationRunbook -ResourceGroupName "<RG>" `
    -AutomationAccountName "<AA>" `
    -Name "<RunbookName>" `
    -Path ".\staging\$complexity\$runbookName" `
    -Type PowerShell `
    -RuntimeEnvironment "PS74-ModernAuth" `
    -Force

# Publish it
Publish-AzAutomationRunbook -ResourceGroupName "<RG>" `
    -AutomationAccountName "<AA>" `
    -Name "<RunbookName>"
```

### Step 10: Post-Migration Monitoring

After publishing, monitor for 1 week:

```powershell
# Check recent job statuses for the runbook
Get-AzAutomationJob -ResourceGroupName "<RG>" `
    -AutomationAccountName "<AA>" `
    -RunbookName "<RunbookName>" |
    Sort-Object CreationTime -Descending |
    Select-Object -First 10 Status, CreationTime, EndTime |
    Format-Table -AutoSize
```

**If a job fails:**
1. Check the job output and error stream in the portal
2. Common issues:
   - **"Managed Identity not found"** — MI not enabled on the Automation Account
   - **"Insufficient privileges"** — MI lacks required App Role; run `Grant-ManagedIdentityPermissions.ps1`
   - **"Module not found"** — Module not installed in the runtime environment
   - **"The term 'Get-PnPTenantSite' is not recognized"** — PnP.PowerShell not installed or wrong runtime
3. If the issue can't be resolved quickly, revert:
   - Portal: Edit > select previous version from draft > Publish
   - PowerShell: Re-import the original from `.\runbooks\source\`

### Step 11: Record Completion

Update the migration queue tracking:

```powershell
# Mark as complete (manually update the CSV or use this helper)
$queue = Import-Csv ".\plan\migration-queue.csv"
$entry = $queue | Where-Object Runbook -eq $runbookName
$entry | Add-Member -NotePropertyName "MigratedDate" -NotePropertyValue (Get-Date -Format "yyyy-MM-dd") -Force
$entry | Add-Member -NotePropertyName "MigratedBy" -NotePropertyValue $env:USERNAME -Force
$entry | Add-Member -NotePropertyName "Status" -NotePropertyValue "Published" -Force
$queue | Export-Csv ".\plan\migration-queue.csv" -NoTypeInformation -Force
```

---

## Batch Migration for Simple Runbooks

If you have many Simple-complexity runbooks with identical auth patterns (e.g., all use `Get-AutomationPSCredential` + `Connect-PnPOnline -Credentials`), you can script the auth replacement:

```powershell
$simpleRunbooks = Get-ChildItem ".\runbooks\staging\*.ps1"

foreach ($file in $simpleRunbooks) {
    $content = Get-Content $file.FullName -Raw

    # Replace the common credential block
    # CAUTION: Only use this if you've verified ALL simple runbooks have this exact pattern.
    # Review each result manually before publishing.

    $content = $content -replace '(?ms)\$cred\s*=\s*Get-AutomationPSCredential\s+-Name\s+[''"].*?[''"]\s*\r?\n', ''
    $content = $content -replace 'Connect-PnPOnline\s+-Url\s+(\$\w+)\s+-Credentials?\s+\$cred',
        "Import-Module Contoso.Automation.Auth`nConnect-ContosoAzure`nConnect-ContosoSharePoint -SiteUrl `$1"

    Set-Content -Path $file.FullName -Value $content
    Write-Output "Processed: $($file.Name) — REVIEW MANUALLY before publishing"
}
```

> **WARNING:** Automated text replacement is error-prone. Always review each file after batch processing. Never publish without testing.

---

## Rollback Procedure

If a migrated runbook causes production issues:

1. **Immediate:** In Azure Portal, go to the runbook > Edit > select the previous version > Publish
2. **From backup:** Re-import the original from `.\runbooks\source\`:
   ```powershell
   Import-AzAutomationRunbook -ResourceGroupName "<RG>" `
       -AutomationAccountName "<AA>" `
       -Name "<RunbookName>" `
       -Path ".\runbooks\source\<RunbookName>.ps1" `
       -Type PowerShell `
       -Force
   Publish-AzAutomationRunbook -ResourceGroupName "<RG>" `
       -AutomationAccountName "<AA>" `
       -Name "<RunbookName>"
   ```
3. **Investigate** the failure, fix the staging copy, and re-attempt migration

---

## Checklist per Runbook

Copy this checklist for each runbook being migrated:

```
Runbook: ___________________
Queue #: ___  Complexity: ___________

[ ] Read and understand the original script
[ ] Identified all legacy auth patterns (from scan-results.csv)
[ ] Replaced auth block with shared module calls
[ ] Remapped SPO cmdlets to PnP equivalents (if applicable)
[ ] Applied standardized template (header, try/catch/finally, cleanup)
[ ] Removed dead credential code
[ ] Updated #Requires statements
[ ] Passed local syntax check
[ ] Tested in Azure Automation Test pane
[ ] Output matches original behavior
[ ] Published to Automation Account
[ ] Assigned to PS74-ModernAuth runtime environment
[ ] Monitoring for 1 week post-publish
[ ] Marked complete in migration-queue.csv
```
