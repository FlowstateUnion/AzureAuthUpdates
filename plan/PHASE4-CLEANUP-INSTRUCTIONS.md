# Phase 4: Cleanup & Hardening — Operator Instructions

## Overview

After all runbooks are migrated and monitored for stability, remove legacy assets and lock down the environment. Do not start this phase until every runbook in `migration-queue.csv` shows Status = "Published" and has been monitored for at least 1 week.

**Estimated time:** 1–2 hours.
**Who should run this:** Azure admin with Contributor on the Automation Account and the ability to delete Entra ID App Registrations.

---

## Step 4.1: Identify and Remove Unused Automation Credential Assets

```powershell
$rg = "<RG>"
$aa = "<AA>"

# List all credential assets
$creds = Get-AzAutomationCredential -ResourceGroupName $rg -AutomationAccountName $aa
Write-Output "Credential assets found: $($creds.Count)"
$creds | Select-Object Name, UserName, CreationTime | Format-Table -AutoSize

# For each credential, verify no runbook references it
foreach ($cred in $creds) {
    $refs = Get-ChildItem ".\runbooks\source\*.ps1" |
        Select-String -Pattern $cred.Name -SimpleMatch
    if ($refs) {
        Write-Warning "$($cred.Name) is still referenced in: $(($refs | Select-Object -Unique Filename).Filename -join ', ')"
    } else {
        Write-Output "SAFE TO DELETE: $($cred.Name) — no references found"
    }
}
```

**Delete unused credentials:**
```powershell
# Only after confirming no references
Remove-AzAutomationCredential -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -Name "<CREDENTIAL-NAME>"
```

> **CAUTION:** Cross-check against the *migrated* runbooks (in `staging/`), not the originals. The originals still reference the old credentials, but the published versions should not.

---

## Step 4.2: Identify and Remove Unused Automation Variables

```powershell
$vars = Get-AzAutomationVariable -ResourceGroupName $rg -AutomationAccountName $aa
Write-Output "Variable assets found: $($vars.Count)"
$vars | Select-Object Name, Encrypted, CreationTime | Format-Table -AutoSize

# Flag variables that look like secrets
$suspectVars = $vars | Where-Object {
    $_.Name -match 'Secret|Password|Key|Token|Credential|AppId|ClientId|TenantId'
}
Write-Output "Suspect secret-like variables: $($suspectVars.Count)"
$suspectVars | Select-Object Name, Encrypted | Format-Table -AutoSize

# Check references (same as credentials)
foreach ($var in $suspectVars) {
    $refs = Get-ChildItem ".\staging\**\*.ps1" -Recurse |
        Select-String -Pattern $var.Name -SimpleMatch
    if ($refs) {
        Write-Warning "$($var.Name) is still referenced in migrated runbooks"
    } else {
        Write-Output "SAFE TO DELETE: $($var.Name)"
    }
}
```

**Delete unused variables:**
```powershell
Remove-AzAutomationVariable -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -Name "<VARIABLE-NAME>"
```

**Keep variables that:**
- Store non-secret configuration still referenced by migrated runbooks (e.g., site URLs, list names)
- Are used by non-PowerShell runbooks (Python, etc.) not in scope of this migration

---

## Step 4.3: Remove Old Run As Account Artifacts

Run As accounts were retired Sep 2023, but their Entra ID App Registrations and certificates may still exist.

```powershell
# List App Registrations that look like Run As accounts
Connect-MgGraph -Scopes "Application.Read.All"

# Run As apps are typically named like:
# "<AutomationAccountName>_<random>" or "AzureAutomation_<GUID>"
$apps = Get-MgApplication -Filter "startsWith(displayName, '<AA>')" -All
$apps += Get-MgApplication -Filter "startsWith(displayName, 'AzureAutomation')" -All

$apps | Select-Object DisplayName, AppId, CreatedDateTime | Format-Table -AutoSize
```

**Before deleting, confirm:**
- The app is not used by anything other than the old Run As connection
- No runbooks reference its Application ID or certificate thumbprint

```powershell
# Delete the App Registration (requires Application.ReadWrite.All)
Remove-MgApplication -ApplicationId "<APP-OBJECT-ID>"
```

---

## Step 4.4: Disable Legacy Runtime Environments

If all runbooks have been migrated to `PS74-ModernAuth`:

1. **Portal:** Automation Account > Runtime Environments
2. Check if any runbooks still use the default PS 5.1 or PS 7.2 environments
3. Reassign any stragglers to `PS74-ModernAuth`
4. Do NOT delete the default runtime environments — they can't be recreated. Just ensure no runbooks use them.

```powershell
# Check which runtime each runbook uses
Get-AzAutomationRunbook -ResourceGroupName $rg -AutomationAccountName $aa |
    Select-Object Name, RunbookType, State, RuntimeEnvironment |
    Sort-Object RuntimeEnvironment |
    Format-Table -AutoSize
```

---

## Step 4.5: Verify Key Vault Audit Logging

Confirm logging is active:

```powershell
$kvId = (Get-AzKeyVault -VaultName "<VAULT-NAME>").ResourceId
Get-AzDiagnosticSetting -ResourceId $kvId |
    Select-Object Name, StorageAccountId, WorkspaceId |
    Format-Table -AutoSize
```

---

## Step 4.6: Final Validation

Run the scanner one more time against the **published** runbook source to confirm zero legacy patterns remain:

```powershell
# Re-export the now-migrated runbooks
.\scripts\migration\Export-Runbooks.ps1 `
    -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -OutputPath ".\validation-export"

# Scan them
.\scripts\migration\Scan-LegacyAuth.ps1 `
    -Path ".\validation-export" `
    -OutputCsv ".\plan\post-migration-scan.csv"
```

**Expected result:** `No legacy authentication patterns found. All clear!`

If findings remain, those runbooks were missed or incompletely migrated — go back to Phase 3 for those specific runbooks.

---

## Phase 4 Completion Checklist

```
[ ] All Automation Credential assets reviewed; unused ones deleted
[ ] All Automation Variable assets storing secrets reviewed; unused ones deleted
[ ] Old Run As account App Registrations deleted from Entra ID
[ ] All runbooks assigned to PS74-ModernAuth runtime environment
[ ] Key Vault audit logging confirmed active
[ ] Post-migration scan shows zero legacy auth patterns
[ ] Final architecture documented (see below)
```

---

## Final Documentation

Update the Automation Account description or a wiki page with:

- **Auth method:** Managed Identity (System-Assigned)
- **MI Object ID:** `________`
- **Key Vault:** `________`
- **Runtime Environment:** `PS74-ModernAuth`
- **Shared module:** `Contoso.Automation.Auth v1.x`
- **Permissions granted:** (list from Step 0.3)
- **Runbook count:** `___` migrated
- **Date completed:** `________`
