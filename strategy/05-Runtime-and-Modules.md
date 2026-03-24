# Strategy: Runtime Environment & Module Management

## Target Runtime

**PowerShell 7.4** — Long-term support, best module compatibility, required by PnP.PowerShell 2.x+.

## PS 5.1 Exceptions

Some runbooks may need to remain on PS 5.1 if they:
- Use COM objects (e.g., Excel interop) not available in PS 7
- Depend on Windows-only .NET Framework APIs
- Use modules with no PS 7 support

Document each exception. Plan a separate migration path for these.

## Custom Runtime Environment Setup

Create a dedicated runtime environment with pinned module versions:

| Module | Version | Purpose |
|--------|---------|---------|
| `Az.Accounts` | 3.x+ | Azure auth, Key Vault access |
| `Az.KeyVault` | 6.x+ | Key Vault secret/cert retrieval |
| `Az.Automation` | 1.x+ | Automation account management |
| `PnP.PowerShell` | 2.4+ | SharePoint operations |
| `Microsoft.Graph.Authentication` | 2.x+ | Graph auth |
| `Microsoft.Graph.Sites` | 2.x+ | SharePoint via Graph |
| `Microsoft.Graph.Users` | 2.x+ | User operations |
| `Microsoft.Graph.Groups` | 2.x+ | Group operations |
| `Contoso.Automation.Auth` | 1.0.0 | Shared auth module |

Add additional `Microsoft.Graph.*` sub-modules only as needed per runbook. Do not install the full `Microsoft.Graph` meta-module (it is enormous and slow to import).

## Module Update Policy

- **Pin versions** in the runtime environment — never use "latest"
- **Test module updates** in a staging runtime environment before promoting to production
- **Review changelogs** for breaking changes before updating
- **Schedule quarterly reviews** of module versions for security patches

## Setup Script

See `scripts/setup/New-RuntimeEnvironment.ps1` for automated provisioning.

## PnP.PowerShell Version Notes

- **2.4.x** — stable Managed Identity support; target this minimum
- **3.x** — drops PS 5.1 support entirely; consider only after all runbooks are on PS 7.4
- Always test PnP updates in staging — the module has a history of breaking changes between minor versions
