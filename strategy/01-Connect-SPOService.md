# Strategy: Connect-SPOService Migration

## Current State

`Connect-SPOService` is from the `Microsoft.Online.SharePoint.PowerShell` module. It is typically used with stored credentials:

```powershell
# Legacy pattern
$cred = Get-AutomationPSCredential -Name "SPOAdmin"
Connect-SPOService -Url "https://contoso-admin.sharepoint.com" -Credential $cred
```

## Why It Must Change

1. **No Managed Identity support** — the module has no `-Identity` or `-ManagedIdentity` parameter
2. **No PowerShell 7.x support** — Windows PowerShell 5.1 only
3. **Maintenance mode** — Microsoft is not adding new features
4. **Credential-based auth is deprecated** — MFA and Conditional Access break stored credentials

## Target State

Replace all `Connect-SPOService` usage with **PnP.PowerShell** equivalents using Managed Identity.

## Migration Approach

### Step 1: Identify All Usages

The scanner (`scripts/migration/Scan-LegacyAuth.ps1`) will flag every instance. For each, determine which SPO cmdlets are called after `Connect-SPOService`.

### Step 2: Map SPO Cmdlets to PnP Equivalents

| SPO Module Cmdlet | PnP.PowerShell Equivalent |
|---|---|
| `Get-SPOSite` | `Get-PnPTenantSite` |
| `Set-SPOSite` | `Set-PnPTenantSite` |
| `New-SPOSite` | `New-PnPTenantSite` |
| `Remove-SPOSite` | `Remove-PnPTenantSite` |
| `Get-SPODeletedSite` | `Get-PnPTenantDeletedSite` |
| `Set-SPOTenant` | `Set-PnPTenant` |
| `Get-SPOTenant` | `Get-PnPTenant` |
| `Set-SPOUser` | `Set-PnPTenantSite` (permissions) or Graph |
| `Get-SPOUser` | `Get-PnPUser` or Graph |
| `Get-SPOSiteGroup` | `Get-PnPSiteGroup` |
| `Add-SPOSiteCollectionAppCatalog` | `Add-PnPSiteCollectionAppCatalog` |

### Step 3: Replace Auth Block

**Before:**
```powershell
$cred = Get-AutomationPSCredential -Name "SPOAdmin"
Connect-SPOService -Url "https://contoso-admin.sharepoint.com" -Credential $cred
```

**After:**
```powershell
Import-Module Contoso.Automation.Auth
Connect-ContosoAzure
Connect-ContosoSharePoint -SiteUrl "https://contoso-admin.sharepoint.com"
```

### Step 4: Replace SPO Cmdlet Calls

For each SPO cmdlet, replace with the PnP equivalent. Example:

**Before:**
```powershell
$sites = Get-SPOSite -Limit All
```

**After:**
```powershell
$sites = Get-PnPTenantSite
```

### Step 5: Update Module Requirements

**Before:**
```powershell
#Requires -Modules Microsoft.Online.SharePoint.PowerShell
```

**After:**
```powershell
#Requires -Modules @{ ModuleName="PnP.PowerShell"; ModuleVersion="2.4" }
#Requires -Modules Contoso.Automation.Auth
```

## Edge Cases

- **`Set-SPOTenant` with parameters not in PnP** — Verify all parameters exist in `Set-PnPTenant`. Most do; for any gaps, use `Invoke-PnPSPRestMethod` to call the admin REST API directly.
- **SPO module-specific output object properties** — PnP cmdlets may return slightly different object structures. Audit any property references (e.g., `.StorageQuota`, `.LockState`) and adjust.
- **Hybrid Worker runbooks** — If the runbook runs on a Hybrid Worker, confirm PnP.PowerShell is installed there as well.

## Validation

1. Run migrated runbook in Test pane
2. Compare output to the original runbook's last successful output
3. Spot-check any sites/settings that were modified
4. Monitor for 1 week post-publish

## Fallback

If PnP migration is blocked for a specific cmdlet:
- Use certificate-based `Connect-SPOService` on PS 5.1 runtime as interim
- File a tracking issue and revisit when PnP adds coverage
