# Quickstart — Azure Automation Auth Modernization

## What Is This?

A complete plan, strategy documents, shared code, and step-by-step operator instructions for replacing legacy credential-based authentication across all Azure Automation runbooks with Managed Identity, certificate auth, and Key Vault.

## How to Use This Repository

Execute the phases in order. Each phase has a detailed instruction document with copy-paste-ready PowerShell commands, verification steps, and checklists.

### Phase 0 — Infrastructure Setup
**Instructions:** [`plan/PHASE0-SETUP-INSTRUCTIONS.md`](PHASE0-SETUP-INSTRUCTIONS.md)
**Time:** ~1–2 hours | **Who:** Azure admin

Enable Managed Identity, grant Entra ID permissions, create Key Vault, set up the PS 7.4 runtime environment, and deploy the shared auth module.

### Phase 1 — Validate Shared Auth Module
**Instructions:** Run `staging/Test-AuthModule.ps1` in the Automation Account Test pane
**Time:** ~15 minutes | **Who:** Azure admin

Confirms the shared module authenticates correctly to Azure, SharePoint (PnP), and Microsoft Graph using Managed Identity.

### Phase 2 — Inventory & Analysis
**Instructions:** [`plan/PHASE2-INVENTORY-INSTRUCTIONS.md`](PHASE2-INVENTORY-INSTRUCTIONS.md)
**Time:** ~30–60 minutes | **Who:** Anyone with Reader access

Export all runbooks, scan for legacy patterns, classify by complexity, produce a prioritized migration queue.

### Phase 3 — Per-Runbook Migration
**Instructions:** [`plan/PHASE3-MIGRATION-INSTRUCTIONS.md`](PHASE3-MIGRATION-INSTRUCTIONS.md)
**Time:** 15 min–2 hrs per runbook | **Who:** Script developer / agent

Migrate each runbook: replace auth blocks, remap SPO cmdlets, apply the standardized template, test, publish.

### Phase 4 — Cleanup & Hardening
**Instructions:** [`plan/PHASE4-CLEANUP-INSTRUCTIONS.md`](PHASE4-CLEANUP-INSTRUCTIONS.md)
**Time:** ~1–2 hours | **Who:** Azure admin

Remove Automation Credential/Variable assets, delete old Run As App Registrations, verify audit logging, run final validation scan.

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `plan/MASTER-PLAN.md` | High-level architecture, phases, decisions, risks |
| `plan/PHASE0-SETUP-INSTRUCTIONS.md` | Step-by-step infrastructure setup |
| `plan/PHASE2-INVENTORY-INSTRUCTIONS.md` | Step-by-step export, scan, classify |
| `plan/PHASE3-MIGRATION-INSTRUCTIONS.md` | Step-by-step per-runbook migration |
| `plan/PHASE4-CLEANUP-INSTRUCTIONS.md` | Step-by-step cleanup and hardening |
| `strategy/01-Connect-SPOService.md` | SPO module → PnP migration strategy + cmdlet map |
| `strategy/02-Connect-PnPOnline.md` | PnP credential → MI/cert migration strategy |
| `strategy/03-Credentials-and-Secrets.md` | Credential/secret elimination decision tree |
| `strategy/04-Standardized-Template.md` | Runbook template rules |
| `strategy/05-Runtime-and-Modules.md` | Runtime env and module management |
| `strategy/06-Exchange-Online.md` | EXO migration: credentials/PSSession → MI, Send-MailMessage → Graph |
| `strategy/07-Hybrid-Runbook-Workers.md` | HRW module deployment, MI auth differences, Windows vs Linux |
| `strategy/08-PS51-to-PS74-Compatibility.md` | Non-auth breaking changes: COM, WMI, .NET Framework, encoding |
| `modules/Contoso.Automation.Auth/` | Shared auth module v1.1 (Azure, SPO, Graph, EXO, per-service token refresh, fail-fast on auth denial) |
| `templates/RunbookTemplate.ps1` | Drop-in runbook template |
| `scripts/setup/Grant-ManagedIdentityPermissions.ps1` | Grants Entra ID App Roles to MI |
| `scripts/setup/New-RuntimeEnvironment.ps1` | Creates PS 7.4 runtime with pinned modules |
| `scripts/setup/Deploy-AuthModule.ps1` | Packages and deploys the shared module |
| `scripts/migration/Export-Runbooks.ps1` | Exports all runbooks from Automation Account |
| `scripts/migration/Scan-LegacyAuth.ps1` | Scans scripts for 19 patterns (multiline-aware, joins continuation lines) |
| `scripts/migration/Scan-Permissions.ps1` | Advisory cmdlet-to-permission mapping (candidate permissions, not authoritative) |
| `scripts/migration/Get-RunbookDependencies.ps1` | Inventories schedules, webhooks, child runbooks, HRW usage |
| `staging/Test-AuthModule.ps1` | Validation runbook for the shared module |
| `plan/ROLLBACK-PLAYBOOK.md` | Incident response: single/bulk rollback, pre-flight validation |
| `plan/MONITORING-AND-CHANGE-MANAGEMENT.md` | Stakeholder comms, approval gates, KQL alerts, operational runbook |

---

## For Agentic Execution

If feeding this to an AI agent for automated migration:

1. **Start with Phase 2** — the agent needs the exported runbooks and scan results to work from
2. **Provide the agent with:**
   - This entire repo (plan, strategy, modules, templates, scripts)
   - The original runbooks (in `runbooks/source/`)
   - The scan results (`plan/scan-results.csv`, `plan/migration-queue.csv`)
   - Azure subscription details (RG, AA name, tenant name, Key Vault name)
3. **The agent should follow Phase 3 instructions** for each runbook in queue order
4. **Human review is required** before each `Publish` step — the agent should produce the migrated code but a human should approve the publish

### Agent Prompt Template

```
You are migrating Azure Automation runbooks from legacy credential-based auth to
Managed Identity using a shared auth module.

Work from the files in this repo:
- plan/MASTER-PLAN.md — overall plan and architecture
- plan/PHASE3-MIGRATION-INSTRUCTIONS.md — per-runbook migration workflow
- plan/ROLLBACK-PLAYBOOK.md — rollback procedures if something goes wrong
- strategy/ — pattern-specific migration strategies (01-08)
- templates/RunbookTemplate.ps1 — standardized template to apply
- modules/Contoso.Automation.Auth/ — shared module v1.1 (already deployed)
- plan/migration-queue.csv — prioritized list of runbooks to migrate
- agent/scan-results.csv — per-line findings for each runbook (auth + PS 7.4 compat)
- agent/permission-audit.csv — minimum permissions per runbook
- agent/dependency-summary.json — schedules, webhooks, child runbook calls (if Azure access available)
- runbooks/source/ — original runbook source code (READ-ONLY)

Key rules:
- Migrate CHILD runbooks before PARENT runbooks (check dependency-summary.json)
- Do NOT change parameter names or types (schedules/webhooks depend on them)
- Use Invoke-ContosoWithRetry for long-running operations (>30 min)
- Replace Connect-SPOService → PnP (strategy/01), Connect-ExchangeOnline creds → MI (strategy/06)
- Fix PS 7.4 compatibility issues (COM, WMI, .NET Framework) per strategy/08
- If a runbook must stay on PS 5.1, document the reason and skip PS 7.4 compat changes

For each runbook in the migration queue (in order):
1. Read the original script
2. Check scan-results.csv for legacy auth AND PS 7.4 compat patterns
3. Check dependency-summary.json — are there schedules, webhooks, or child calls?
4. Replace the auth block with shared module calls (Connect-ContosoAzure, etc.)
5. Remap SPO cmdlets to PnP equivalents if applicable
6. Remap EXO credential auth to Connect-ContosoExchange if applicable
7. Fix PS 7.4 compatibility issues (COM → alternative, WMI → CIM, etc.)
8. Apply the standardized template structure
9. Remove dead credential code
10. Update #Requires statements
11. Write the migrated version to staging/<complexity>/
12. Run a syntax check
13. Do NOT publish — flag for human review

Start with runbook #1 in the queue.
```
