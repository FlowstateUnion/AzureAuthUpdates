# Strategy: Hybrid Runbook Workers (HRW)

## Overview

Runbooks that target a Hybrid Runbook Worker Group execute on on-premises or VM-based workers rather than the Azure sandbox. This changes how Managed Identity, module management, and network access work.

## Cloud Sandbox vs. Hybrid Worker

| Aspect | Cloud Sandbox | Hybrid Worker |
|--------|--------------|---------------|
| Managed Identity | System or User-Assigned MI on Automation Account | System MI on the **VM/server** hosting the worker, OR User-Assigned MI on the Automation Account (configurable) |
| Module location | Runtime Environment in Automation Account | Locally installed on the worker machine |
| Network access | Outbound only; no access to on-prem resources | Full access to local network, AD, file shares |
| OS | Azure-managed (Windows) | Windows or Linux (you manage) |
| PowerShell version | Determined by Runtime Environment | Determined by what's installed on the worker |
| Temp disk / file system | Ephemeral; sandboxed | Persistent; full access |

## Managed Identity on Hybrid Workers

### Which Identity Is Used?

When a runbook runs on a Hybrid Worker, the identity depends on configuration:

- **Default (Automation Account MI):** The runbook uses the Automation Account's MI via Azure's token endpoint. This works the same as cloud sandbox *if the worker can reach Azure AD token endpoints*.
- **VM Managed Identity:** If the Hybrid Worker VM has its own System-Assigned MI, it can be used directly. This is useful when the worker needs access to Azure resources scoped to the VM's identity.
- **User-Assigned MI:** Can be assigned to either the Automation Account or the VM. Specify via `Connect-AzAccount -Identity -AccountId "<ClientId>"`.

### Configuration

In Azure Portal: **Automation Account** > **Hybrid Worker Groups** > select group > **Hybrid worker group settings** > **Run As** credentials:
- **Default:** Uses the Automation Account's Managed Identity
- **Custom:** Can specify a credential (legacy) — we are migrating away from this

Ensure the setting is **Default** so the shared auth module's `Connect-ContosoAzure` works.

### Connectivity Requirements

The Hybrid Worker must have network access to:

| Endpoint | Port | Purpose |
|----------|------|---------|
| `login.microsoftonline.com` | 443 | Azure AD token acquisition |
| `*.vault.azure.net` | 443 | Key Vault access |
| `graph.microsoft.com` | 443 | Microsoft Graph API |
| `*.sharepoint.com` | 443 | SharePoint Online |
| `outlook.office365.com` | 443 | Exchange Online |
| `management.azure.com` | 443 | Azure Resource Manager |

If the worker is behind a firewall or proxy, ensure these are whitelisted.

## Module Management on Hybrid Workers

### Key Difference

Cloud sandbox runbooks use modules from the Automation Account's Runtime Environment. **Hybrid Worker runbooks use modules installed locally on the worker machine.** The Runtime Environment's modules are NOT automatically synced to workers.

### Deploying Modules to Workers

**Option A: PowerShell Gallery (Recommended for internet-connected workers)**

Run on each worker machine:
```powershell
# Install modules to AllUsers scope so the Automation service account can use them
Install-Module Az.Accounts -Scope AllUsers -Force -RequiredVersion 3.0.5
Install-Module Az.KeyVault -Scope AllUsers -Force -RequiredVersion 6.2.0
Install-Module PnP.PowerShell -Scope AllUsers -Force -RequiredVersion 2.12.0
Install-Module Microsoft.Graph.Authentication -Scope AllUsers -Force -RequiredVersion 2.25.0
Install-Module ExchangeOnlineManagement -Scope AllUsers -Force -RequiredVersion 3.6.0

# Install the shared auth module
# Copy from the project or install from internal gallery
Copy-Item -Path "\\fileserver\modules\Contoso.Automation.Auth" `
    -Destination "C:\Program Files\PowerShell\Modules\Contoso.Automation.Auth" `
    -Recurse -Force
```

**Option B: Offline / Air-gapped workers**

1. On an internet-connected machine:
   ```powershell
   Save-Module -Name PnP.PowerShell -Path C:\ModulePackages -RequiredVersion 2.12.0
   Save-Module -Name Az.Accounts -Path C:\ModulePackages -RequiredVersion 3.0.5
   # ... repeat for all modules
   ```
2. Transfer `C:\ModulePackages` to the worker (USB, file share, etc.)
3. On the worker:
   ```powershell
   $source = "C:\ModulePackages"
   $dest = "C:\Program Files\PowerShell\Modules"
   Get-ChildItem $source -Directory | ForEach-Object {
       Copy-Item $_.FullName -Destination $dest -Recurse -Force
   }
   ```

**Option C: Automation via DSC or configuration management**

Use Azure Automation State Configuration, Ansible, or Group Policy to ensure modules are installed and at the correct version across all workers.

### Version Synchronization

Create a validation script that runs on each worker to confirm module versions match the runtime environment:

```powershell
# Run on each Hybrid Worker
$expected = @{
    "Az.Accounts"                      = "3.0.5"
    "Az.KeyVault"                      = "6.2.0"
    "PnP.PowerShell"                   = "2.12.0"
    "Microsoft.Graph.Authentication"   = "2.25.0"
    "Contoso.Automation.Auth"          = "1.1.0"
}

foreach ($mod in $expected.GetEnumerator()) {
    $installed = Get-Module -ListAvailable -Name $mod.Key |
        Sort-Object Version -Descending | Select-Object -First 1

    if (-not $installed) {
        Write-Warning "[MISSING] $($mod.Key) — not installed"
    } elseif ($installed.Version -lt [version]$mod.Value) {
        Write-Warning "[OUTDATED] $($mod.Key) — installed $($installed.Version), expected $($mod.Value)+"
    } else {
        Write-Output "[OK] $($mod.Key) v$($installed.Version)"
    }
}
```

## Windows vs. Linux Hybrid Workers

| Aspect | Windows Worker | Linux Worker |
|--------|---------------|--------------|
| PowerShell | 5.1 (Desktop) + 7.x (Core) | 7.x (Core) only |
| Certificate store | `Cert:\LocalMachine\My` | File-based (PFX/PEM) |
| PnP.PowerShell | Full support | Full support (2.x on PS 7) |
| Exchange Online | Full support | Full support (EXO v3) |
| COM objects | Available | Not available |
| Windows Auth / NTLM | Available | Not available |

### Linux-Specific Considerations

- Certificates must be loaded from file, not certificate store:
  ```powershell
  $certPath = "/opt/certs/spo-cert.pfx"
  $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certPath, $password)
  ```
- Windows-specific cmdlets (AD module, WMI) are not available
- File paths use `/` not `\`

## Testing on Hybrid Workers

Before migrating runbooks that run on Hybrid Workers:

1. **Deploy modules** to all workers in the group
2. **Run the validation script** above on each worker
3. **Test the shared auth module** by running `staging/Test-AuthModule.ps1` targeted at the Hybrid Worker Group:
   - In the Test pane, select "Run on: Hybrid Worker" and pick the group
4. **Verify network connectivity** from the worker:
   ```powershell
   # Test Azure AD token endpoint
   Test-NetConnection login.microsoftonline.com -Port 443
   # Test SharePoint
   Test-NetConnection contoso.sharepoint.com -Port 443
   # Test Graph
   Test-NetConnection graph.microsoft.com -Port 443
   ```

## Migration Checklist for HRW Runbooks

```
Runbook: ___________________  Worker Group: ___________________

[ ] Confirmed which identity to use (Automation Account MI vs VM MI)
[ ] Worker group "Run As" setting is Default (not custom credential)
[ ] All required modules installed on worker with correct versions
[ ] Network connectivity verified (Azure AD, SharePoint, Graph, Key Vault)
[ ] Test-AuthModule.ps1 passes when targeted at this worker group
[ ] Migrated runbook tested on this worker group
[ ] Schedule/webhook "RunOn" property verified (still targets correct group)
```
