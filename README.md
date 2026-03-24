# Azure Automation Auth Modernization

A complete plan, strategy, shared code, migration tooling, and agent-ready execution framework for replacing legacy credential-based authentication across Azure Automation runbooks with Managed Identity, certificate auth, and Key Vault.

## The Problem

Azure Automation runbooks commonly authenticate using patterns that are now deprecated, insecure, or broken:

- **Stored credentials** (`Get-AutomationPSCredential`) — break with MFA and Conditional Access
- **Client secrets** (`AppSecret`) — expire, leak, require manual rotation
- **Run As accounts** — retired by Microsoft in September 2023
- **Legacy modules** (`AzureAD`, `MSOnline`) — deprecated, no PS 7 support
- **Remote PowerShell to Exchange** — Basic Auth disabled October 2022
- **SPO Management Shell** — no Managed Identity support, PS 5.1 only

## The Solution

This project provides everything needed to migrate an entire Automation Account to modern authentication:

| Component | What It Does |
|-----------|-------------|
| **Master Plan** | 4-phase execution plan with step-by-step operator instructions |
| **8 Strategy Docs** | Pattern-specific migration guides (SPO, PnP, EXO, credentials, Hybrid Workers, PS 7.4 compat) |
| **Shared Auth Module** | `Contoso.Automation.Auth` v1.1 — drop-in module for MI, certificate, Key Vault auth with token refresh |
| **Scanner (19 patterns)** | Detects legacy auth, deprecated cmdlets, and PS 7.4 compatibility issues |
| **Permission Auditor** | Maps cmdlet usage to minimum API permissions (least-privilege) |
| **Dependency Inventory** | Discovers schedules, webhooks, child runbooks, and Hybrid Worker usage |
| **Rollback Playbook** | Pre-flight validation, single/bulk rollback, cascading failure recovery |
| **Agent Framework** | Pipeline, skill scripts, and progress tracking for autonomous AI-driven migration |

## How It Works

### For Humans

1. **Phase 0** — Set up infrastructure (Managed Identity, Key Vault, runtime environment)
2. **Phase 1** — Deploy the shared auth module and validate it
3. **Phase 2** — Export runbooks, scan for legacy patterns, build a prioritized migration queue
4. **Phase 3** — Migrate each runbook (or hand off to an AI agent)
5. **Phase 4** — Clean up legacy credentials, set up monitoring

Start with [`plan/QUICKSTART.md`](plan/QUICKSTART.md).

### For AI Agents

The project is designed for autonomous execution by an AI coding agent:

1. Drop production `.ps1` files into `runbooks/source/`
2. The agent reads `CLAUDE.md` → `agent/AGENT-INSTRUCTIONS.md`
3. Runs `agent/skills/initialize-session.ps1` to scan and set up tracking
4. Processes each runbook: **analyze** → **migrate** → **validate** → **track progress**
5. Human reviews validated scripts in `runbooks/testing/` and approves publishing

The agent never modifies originals, never publishes to Azure, and tracks all progress in `agent/PROGRESS.md`.

## Project Structure

```
plan/                       Execution plan, phase instructions, rollback, monitoring
strategy/                   8 migration strategy documents
modules/                    Shared PowerShell auth module (Contoso.Automation.Auth)
templates/                  Standardized runbook template
scripts/setup/              Infrastructure provisioning (MI, Key Vault, runtime)
scripts/migration/          Scanners, exporters, dependency analysis
agent/                      AI agent instructions, skills, and progress tracking
runbooks/                   Migration pipeline (source → staging → testing → completed)
peer-review/                Peer review prompt for external validation
```

## Key Technical Decisions

- **Managed Identity** over certificate auth (zero secret management, auto-rotated)
- **PnP.PowerShell** over SPO module (MI support, PS 7 support, richer cmdlets)
- **PowerShell 7.4** runtime (LTS, best module compatibility)
- **Shared module pattern** (single point of change for auth across all runbooks)
- **Key Vault** for remaining secrets (RBAC, auditable, supports rotation)
- **Token refresh at 45 minutes** for long-running runbooks
- **Children migrated before parents** (dependency-aware ordering)

## What Gets Replaced

The scanner detects 19 legacy patterns across these categories:

| Category | Examples |
|----------|----------|
| Stored Credentials | `Get-AutomationPSCredential`, `Get-Credential`, `PSCredential` |
| Client Secrets | `AppSecret`, `ClientSecret`, `ConvertTo-SecureString` for passwords |
| Retired Features | `AzureRunAsConnection`, Exchange remote `New-PSSession` |
| Legacy Modules | `Connect-AzureAD`, `Connect-MsolService`, `Connect-SPOService` |
| Deprecated Cmdlets | `Send-MailMessage` |
| PS 7.4 Incompatible | COM objects, WMI cmdlets, .NET Framework assemblies |

## Requirements

- Azure subscription with an Automation Account
- PowerShell 5.1+ (for running setup scripts locally) or Azure Cloud Shell
- `Az` PowerShell modules (`Az.Accounts`, `Az.Automation`, `Az.KeyVault`)
- Global Administrator or Privileged Role Administrator (for granting Entra ID App Roles)
- Contributor on the Automation Account resource group

## Status

**Planning and framework complete.** Ready for infrastructure setup (Phase 0) and runbook migration (Phase 3).

## License

Internal use. Adapt the `Contoso.Automation.Auth` module name and permissions to your organization.
