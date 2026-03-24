# Strategy: Connect-PnPOnline Auth Modernization

## Current State

`Connect-PnPOnline` is used with stored credentials or client secrets:

```powershell
# Legacy pattern A — stored credential
$cred = Get-AutomationPSCredential -Name "SPOUser"
Connect-PnPOnline -Url "https://contoso.sharepoint.com/sites/MySite" -Credentials $cred

# Legacy pattern B — client secret
$clientId = Get-AutomationVariable -Name "PnPClientId"
$clientSecret = Get-AutomationVariable -Name "PnPClientSecret"
Connect-PnPOnline -Url "https://contoso.sharepoint.com/sites/MySite" `
    -ClientId $clientId -ClientSecret $clientSecret
```

## Why It Must Change

1. Credential auth breaks with MFA/Conditional Access
2. Client secrets expire and require manual rotation
3. Secrets stored in Automation Variables are less auditable than Key Vault
4. `-ClientSecret` parameter was removed in PnP.PowerShell 2.x

## Target State

All `Connect-PnPOnline` calls use **Managed Identity** (primary) or **certificate-based auth** (fallback).

## Migration Approach

### Path A: Managed Identity (Preferred)

**After:**
```powershell
Import-Module Contoso.Automation.Auth
Connect-ContosoSharePoint -SiteUrl "https://contoso.sharepoint.com/sites/MySite"
```

Which internally calls:
```powershell
Connect-PnPOnline -Url $SiteUrl -ManagedIdentity
```

**Prerequisites:**
- Managed Identity enabled on Automation Account
- MI granted SharePoint API `Sites.FullControl.All` (or appropriate scoped permission)
- PnP.PowerShell 2.4+ installed in PS 7.4 runtime environment

### Path B: Certificate Auth (When MI Can't Be Used)

Scenarios: cross-tenant access, specific app registration requirements.

**After:**
```powershell
Import-Module Contoso.Automation.Auth

Connect-ContosoAzure  # MI auth to Azure for Key Vault access
$thumbprint = Get-ContosoKeyVaultCertificate -VaultName "contoso-kv" -CertName "PnPCert"

Connect-ContosoSharePoint -SiteUrl "https://contoso.sharepoint.com/sites/MySite" `
    -AuthMethod Certificate `
    -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TenantName "contoso.onmicrosoft.com" `
    -CertThumbprint $thumbprint
```

## Pattern-Specific Replacements

### `-Credentials $cred`
Replace with `-ManagedIdentity`. Remove all `Get-AutomationPSCredential` and `$cred` variables.

### `-ClientId $id -ClientSecret $secret`
Replace with `-ManagedIdentity` or `-ClientId $id -Thumbprint $thumbprint`. Delete the Automation Variable holding the client secret.

### `-AppId $id -AppSecret $secret` (older PnP versions)
Same as above — these parameters are aliases that were removed in PnP 2.x.

## Version Considerations

| PnP Version | PS Version | `-ManagedIdentity` | `-ClientSecret` | Notes |
|---|---|---|---|---|
| 1.x (legacy) | 5.1 | No | Yes | Do not use; unmaintained |
| 2.0–2.3 | 7.2+ | Yes (some bugs) | Removed | MI token refresh issues on long runs |
| 2.4+ | 7.2+ | Yes (stable) | Removed | **Target version** |
| 3.x | 7.4+ | Yes | Removed | Drops PS 5.1 entirely |

## Important Notes

- `-Url` is still required with Managed Identity — MI does not infer the tenant
- When connecting to the admin site (e.g., `-admin.sharepoint.com`), use the admin URL explicitly
- For runbooks that connect to multiple sites, call `Connect-PnPOnline` again with the new URL (or use `Connect-PnPOnline -ReturnConnection` and pass `-Connection` to cmdlets)

## Validation

1. Run migrated runbook in Test pane
2. Verify all PnP operations succeed (list reads, item updates, site operations)
3. Test with a long-running scenario (>30 min) to validate token refresh
4. Monitor for 1 week post-publish
