# Azure Automation Auth Modernization — Master Plan

## Objective

Replace all legacy credential-based authentication patterns across Azure Automation runbooks with modern, secure alternatives (Managed Identity, certificate-based auth, Key Vault integration). Apply a standardized runbook template and shared authentication module to eliminate per-script credential management.

## Scope

### Legacy Patterns to Eliminate

| # | Pattern | Risk | Replacement |
|---|---------|------|-------------|
| 1 | `Get-AutomationPSCredential` | Stored username/password; breaks with MFA/Conditional Access | Managed Identity or Key Vault |
| 2 | `Get-Credential` | Interactive prompt; fails in Automation context | Managed Identity |
| 3 | `PSCredential` / `New-Object PSCredential` | Manual credential construction from secrets | Managed Identity or certificate auth |
| 4 | `ConvertTo-SecureString` (for passwords) | Password strings in code or variables | Managed Identity; Key Vault for remaining secrets |
| 5 | `AppSecret` / Client Secret auth | Secrets expire (max 2yr); leakable | Managed Identity or certificate-based SP auth |
| 6 | `Connect-SPOService` with credentials | Legacy module; no MI support; PS 5.1 only | Migrate to PnP.PowerShell with MI |
| 7 | `Connect-PnPOnline` with credentials | Works but credential-based auth is deprecated | PnP `-ManagedIdentity` or `-Thumbprint` |
| 8 | `Connect-ExchangeOnline` with credentials | Breaks with MFA; legacy pattern | EXO v3 `-ManagedIdentity` |
| 9 | `New-PSSession` to Exchange | Remote PS deprecated; Basic Auth disabled Oct 2022 | EXO v3 module with MI |
| 10 | `Send-MailMessage` | Cmdlet deprecated; uses SMTP Basic Auth | `Send-MgUserMail` (Graph) |
| 11 | COM objects (`New-Object -ComObject`) | Not supported in PS 7.4 | Alternative modules or PS 5.1 exception |
| 12 | WMI cmdlets (`Get-WmiObject`) | Removed in PS 7.x | CIM equivalents (`Get-CimInstance`) |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   Azure Automation Account                   │
│                                                              │
│  ┌──────────────┐   ┌──────────────────────────────────┐    │
│  │ Managed       │   │ Runtime Environment (PS 7.4)      │    │
│  │ Identity      │   │                                    │    │
│  │ (System or    │   │  ┌─ Contoso.Automation.Auth ──┐   │    │
│  │  User-Assigned│   │  │ Connect-ContosoAzure       │   │    │
│  │  )            │──▶│  │ Connect-ContosoSharePoint  │   │    │
│  └──────┬───────┘   │  │ Connect-ContosoGraph       │   │    │
│         │           │  │ Get-ContosoKeyVaultSecret   │   │    │
│         │           │  └──────────────────────────────┘   │    │
│         │           │                                    │    │
│         │           │  ┌─ Runbook (uses template) ────┐  │    │
│         │           │  │ Import-Module Auth            │  │    │
│         │           │  │ Connect-ContosoAzure          │  │    │
│         │           │  │ Connect-ContosoSharePoint     │  │    │
│         │           │  │ ... business logic ...        │  │    │
│         │           │  │ Disconnect-*                  │  │    │
│         │           │  └──────────────────────────────┘  │    │
│         │           └──────────────────────────────────────┘   │
│         │                                                      │
│         ▼                                                      │
│  ┌──────────────┐     ┌──────────────┐                        │
│  │ Azure Key     │     │ Entra ID App │                        │
│  │ Vault         │     │ Roles        │                        │
│  │ (certs,       │     │ (Graph, SPO  │                        │
│  │  secrets)     │     │  permissions)│                        │
│  └──────────────┘     └──────────────┘                        │
└─────────────────────────────────────────────────────────────┘
```

## Phases

> **Detailed operator instructions for each phase are in separate documents.**
> Start with [`QUICKSTART.md`](QUICKSTART.md) for a guided walkthrough.

### Phase 0 — Infrastructure Setup (Prerequisites)
**Goal:** Prepare the Automation Account, identity, and supporting resources.
**Detailed instructions:** [`PHASE0-SETUP-INSTRUCTIONS.md`](PHASE0-SETUP-INSTRUCTIONS.md)

| Step | Task | Owner | Details |
|------|------|-------|---------|
| 0.1 | Enable System-Assigned Managed Identity on Automation Account | Infra/Admin | Portal or IaC |
| 0.2 | (Optional) Create User-Assigned MI if cross-account sharing needed | Infra/Admin | — |
| 0.3 | Grant MI required Entra ID App Roles (Graph, SharePoint) | Admin | See `scripts/setup/Grant-ManagedIdentityPermissions.ps1` |
| 0.4 | Create/configure Azure Key Vault | Infra/Admin | RBAC model; grant MI "Key Vault Secrets User" + "Key Vault Certificate User" |
| 0.5 | Upload certificates to Key Vault (if cert-based auth needed) | Admin | For services that don't support MI |
| 0.6 | Create custom Runtime Environment (PS 7.4) with required modules | Admin | See `scripts/setup/New-RuntimeEnvironment.ps1` |
| 0.7 | Install modules: `PnP.PowerShell`, `Microsoft.Graph.*`, `Az.*`, `ExchangeOnlineManagement` | Admin | Pin versions in runtime env |
| 0.8 | Grant Exchange Online permissions (if EXO runbooks exist) | Admin | `Exchange.ManageAsApp` App Role + Exchange Admin directory role |
| 0.9 | Deploy modules to Hybrid Workers (if applicable) | Admin | See `strategy/07-Hybrid-Runbook-Workers.md` |

### Phase 1 — Shared Auth Module
**Goal:** Build and deploy `Contoso.Automation.Auth` module.
**Validation:** Run `staging/Test-AuthModule.ps1` in the Automation Account Test pane.

| Step | Task | Details |
|------|------|---------|
| 1.1 | Develop the shared module | See `modules/Contoso.Automation.Auth/` |
| 1.2 | Write Pester tests for the module | Mock-based unit tests |
| 1.3 | Upload module to Automation Account runtime environment | Manual or via `scripts/setup/Deploy-AuthModule.ps1` |
| 1.4 | Validate module loads and authenticates in a test runbook | Use `staging/Test-AuthModule.ps1` |

### Phase 2 — Inventory & Analysis
**Goal:** Catalog every runbook and its auth patterns.
**Detailed instructions:** [`PHASE2-INVENTORY-INSTRUCTIONS.md`](PHASE2-INVENTORY-INSTRUCTIONS.md)

| Step | Task | Details |
|------|------|---------|
| 2.1 | Export all runbooks from Automation Account | Multiple methods documented (script, Cloud Shell, portal, source control) |
| 2.2 | Scan for legacy auth patterns AND PS 7.4 compatibility | `scripts/migration/Scan-LegacyAuth.ps1` (covers 19 patterns) |
| 2.3 | Scan for permission requirements | `scripts/migration/Scan-Permissions.ps1` (least-privilege audit) |
| 2.4 | Inventory schedules, webhooks, and child runbook dependencies | `scripts/migration/Get-RunbookDependencies.ps1` |
| 2.5 | Generate per-runbook migration report | CSV: runbook name, patterns found, complexity, dependencies |
| 2.6 | Classify runbooks by complexity (Simple / Medium / Complex) | Automated scoring in instructions |
| 2.7 | Build prioritized migration queue (children before parents) | `plan/migration-queue.csv` |
| 2.8 | Ensure source scripts are in `runbooks/source/` | Agent reads from here; complexity tracked in `migration-queue.csv` |
| 2.9 | Run pre-flight permission validation | `plan/ROLLBACK-PLAYBOOK.md` — verify MI has required permissions |

### Phase 3 — Migration Execution
**Goal:** Update each runbook using the staged approach.
**Detailed instructions:** [`PHASE3-MIGRATION-INSTRUCTIONS.md`](PHASE3-MIGRATION-INSTRUCTIONS.md)

**Per-runbook workflow:**
1. Read and understand the runbook + its scan results
2. Identify the auth block shape (credential, client secret, Run As, PnP cred)
3. Replace auth block with shared module calls (`Connect-Contoso*`)
4. Remap `Connect-SPOService` / SPO cmdlets to PnP equivalents where applicable
5. Apply standardized template (header, `#Requires`, try/catch/finally, cleanup)
6. Remove dead credential code
7. Syntax-check locally
8. Test in Azure Automation Test pane
9. Publish updated runbook (assign to `PS74-ModernAuth` runtime)
10. Monitor for 1 week; rollback = revert to previous published version
11. Record completion in `migration-queue.csv`

**Includes:** Per-runbook checklist, batch migration helper for simple runbooks, rollback procedure.
**Rollback:** [`ROLLBACK-PLAYBOOK.md`](ROLLBACK-PLAYBOOK.md) — single-runbook, bulk, and cascading failure recovery.
**Change management:** [`MONITORING-AND-CHANGE-MANAGEMENT.md`](MONITORING-AND-CHANGE-MANAGEMENT.md) — stakeholder comms, approval gates, service windows.

### Phase 4 — Cleanup & Hardening
**Goal:** Remove legacy assets and lock down.
**Detailed instructions:** [`PHASE4-CLEANUP-INSTRUCTIONS.md`](PHASE4-CLEANUP-INSTRUCTIONS.md)

| Step | Task |
|------|------|
| 4.1 | Remove unused Automation Credential assets |
| 4.2 | Remove unused Automation Variable assets (old secrets) |
| 4.3 | Remove old Run As account artifacts (App Registrations, certs) |
| 4.4 | Disable legacy runtime environments (PS 5.1) if all runbooks migrated |
| 4.5 | Verify Key Vault audit logging active |
| 4.6 | Run post-migration scan (expect zero findings) |
| 4.7 | Set up long-term Azure Monitor alert rules |
| 4.8 | Document final architecture and operational procedures |

## Decision Log

| Decision | Rationale |
|----------|-----------|
| Prefer Managed Identity over certificate auth | Zero secret management; auto-rotated by Azure |
| Migrate `Connect-SPOService` to PnP.PowerShell | SPO module has no MI support, no PS 7.x support, effectively in maintenance mode |
| Target PS 7.4 runtime | LTS; best module compatibility; PnP 2.x+ requires PS 7 |
| Shared auth module approach | Single point of change; consistent error handling; eliminates per-runbook auth code |
| Key Vault for remaining secrets | RBAC-controlled; auditable; supports rotation; replaces Automation Variables |
| Migrate children before parents | Child runbooks are dependencies; breaking them breaks the parent chain |
| Least-privilege permissions | Audit actual cmdlet usage; avoid blanket Sites.FullControl.All where possible |
| Token refresh in shared module | Proactive refresh at 45 min prevents silent failures on long-running jobs |
| EXO v3 for Exchange operations | v3+ supports MI; replaces deprecated remote PSSession and Basic Auth |

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| PnP cmdlet behavior differs from SPO module | Medium | Test each migrated cmdlet against staging tenant |
| Managed Identity permissions insufficient for edge cases | Medium | Fallback to certificate auth via Key Vault; document in strategy |
| PS 7.4 runtime breaks legacy script logic (e.g., COM objects) | High | Scan with compatibility checker; maintain PS 5.1 runtime for documented exceptions |
| Module version conflicts in runtime environment | Low | Pin all versions; use custom runtime environment |
| Long-running runbooks hit token expiry | Medium | `Invoke-ContosoWithRetry` + proactive 45-min refresh in shared module |
| Cascading failure if MI permissions misconfigured | High | Pre-flight validation script; bulk rollback playbook; migrate in small batches |
| Child runbooks break parent chains | High | Dependency inventory (`Get-RunbookDependencies.ps1`); migrate children first |
| Webhooks/schedules break due to parameter changes | Medium | Dependency inventory; preserve all existing parameter names and types |
| Hybrid Workers lack required modules | Medium | Module version validation script; documented deployment process |
| Over-permissioned MI becomes security liability | Medium | Permission audit (`Scan-Permissions.ps1`); tiered MI for read-only vs. write |
| Silent failures after monitoring window closes | Medium | Azure Monitor alert rules for auth errors; operational runbook |

## Success Criteria

### Auth Migration
- [ ] Zero runbooks use `Get-AutomationPSCredential`, `Get-Credential`, or `ConvertTo-SecureString` for Azure/M365 auth
- [ ] Zero runbooks use client secrets (`AppSecret`) for authentication
- [ ] Zero runbooks use `New-PSSession` to Exchange Online
- [ ] Zero runbooks use `Send-MailMessage` for email
- [ ] All runbooks use the shared `Contoso.Automation.Auth` module (v1.1+)

### Standardization
- [ ] All runbooks follow the standardized template
- [ ] All SharePoint operations use PnP.PowerShell (not SPO module) unless documented exception
- [ ] All Exchange operations use EXO v3 or Microsoft Graph unless documented exception
- [ ] All runbooks target PS 7.4 runtime unless documented exception (with reason)

### Security & Compliance
- [ ] Automation Account credential/variable assets contain no stored passwords
- [ ] Key Vault audit logging enabled
- [ ] MI permissions audited — no broader than necessary per `Scan-Permissions.ps1` output
- [ ] Old Run As App Registrations deleted from Entra ID

### Operational Readiness
- [ ] Azure Monitor alert rules active for auth failures and Key Vault errors
- [ ] Dependency inventory complete (schedules, webhooks, child runbooks documented)
- [ ] Hybrid Worker modules synced (if applicable)
- [ ] Rollback playbook tested
- [ ] Operational runbook documented (routine tasks, escalation path, key contacts)

## Additional References

| Document | Purpose |
|----------|---------|
| [`ROLLBACK-PLAYBOOK.md`](ROLLBACK-PLAYBOOK.md) | Incident response: single, bulk, and cascading failure recovery with pre-flight validation |
| [`MONITORING-AND-CHANGE-MANAGEMENT.md`](MONITORING-AND-CHANGE-MANAGEMENT.md) | Stakeholder communication, approval gates, KQL alert queries, operational procedures |
| [`strategy/06-Exchange-Online.md`](../strategy/06-Exchange-Online.md) | EXO module migration: credentials → MI, remote PSSession → EXO v3, Send-MailMessage → Graph |
| [`strategy/07-Hybrid-Runbook-Workers.md`](../strategy/07-Hybrid-Runbook-Workers.md) | HRW module deployment, MI differences, Windows vs Linux, network requirements |
| [`strategy/08-PS51-to-PS74-Compatibility.md`](../strategy/08-PS51-to-PS74-Compatibility.md) | Non-auth breaking changes: COM, WMI, .NET Framework, encoding, type coercion |
| [`scripts/migration/Get-RunbookDependencies.ps1`](../scripts/migration/Get-RunbookDependencies.ps1) | Inventories schedules, webhooks, child calls, HRW usage, credential parameters |
| [`scripts/migration/Scan-Permissions.ps1`](../scripts/migration/Scan-Permissions.ps1) | Maps cmdlet usage to minimum API permissions per runbook |
