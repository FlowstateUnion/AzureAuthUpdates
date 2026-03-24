# Peer Review Request — Azure Automation Auth Modernization Project

## Your Role

You are a senior engineer reviewing a project plan, strategy documents, shared code, migration tooling, and an agent-ready execution framework. Your job is to assess whether this project is complete, correct, and safe enough for a migration agent to execute against production Azure Automation runbooks with minimal human intervention.

Be direct. Flag anything that would cause a failure, a security incident, or confusion for the executing agent or the human operator.

---

## Project Context

### What Is This?

An organization has an Azure Automation Account containing an unknown number of PowerShell runbooks that authenticate using legacy patterns:

- Stored credentials (`Get-AutomationPSCredential`)
- Client secrets (`AppSecret`, `ConvertTo-SecureString` for password construction)
- Retired Run As connections (`AzureRunAsConnection` — retired September 2023)
- Deprecated modules (`Connect-AzureAD`, `Connect-MsolService`)
- Credential-based Exchange Online (`Connect-ExchangeOnline -Credential`)
- Legacy SPO module (`Connect-SPOService` — no Managed Identity support, PS 5.1 only)
- Deprecated remote PowerShell to Exchange (`New-PSSession` to outlook.office365.com)

These patterns break with MFA, Conditional Access, and modern security baselines. The project replaces all of them with **Managed Identity**, **certificate-based auth via Key Vault**, and a **shared authentication module** that centralizes all auth logic.

### What Has Been Built?

This is NOT just a plan document. It is a complete execution framework:

1. **A 4-phase master plan** with step-by-step operator instructions for each phase
2. **8 strategy documents** covering every migration pattern including Exchange Online, Hybrid Runbook Workers, and PS 5.1→7.4 runtime compatibility
3. **A shared PowerShell module** (`Contoso.Automation.Auth` v1.1) with functions for Azure, SharePoint (PnP), Microsoft Graph, Exchange Online, Key Vault, token refresh, and retry logic
4. **4 migration/analysis scripts**: legacy auth scanner (19 patterns), permission auditor, dependency inventory (schedules/webhooks/child runbooks), and runbook exporter
5. **3 infrastructure setup scripts**: Managed Identity permission grants, runtime environment creation, module deployment
6. **A standardized runbook template** all migrated scripts must follow
7. **A rollback playbook** with pre-flight validation, single-runbook rollback, and bulk rollback for cascading failures
8. **Monitoring and change management guidance** with KQL alert queries, stakeholder communication templates, and approval gates
9. **An agent-ready execution framework** with a pipeline (`source/` → `staging/` → `testing/` → `completed/`), 5 skill scripts, progress tracking, and comprehensive agent instructions

### Who Will Execute This?

- **Phase 0** (infrastructure): A human Azure admin
- **Phase 1** (module deployment): A human Azure admin
- **Phase 2** (inventory): A human with Azure Reader access, assisted by scripts
- **Phase 3** (migration): An **AI agent** (Claude Code or similar) working autonomously through each runbook, with human review before publishing
- **Phase 4** (cleanup): A human Azure admin

The AI agent receives the full project folder, reads `CLAUDE.md` which points it to `agent/AGENT-INSTRUCTIONS.md`, runs `agent/skills/initialize-session.ps1`, and then processes each runbook through analyze → migrate → validate → update progress. The human reviews validated scripts in `runbooks/testing/` and approves them for publishing.

---

## What to Review

Please review the following in this order and provide findings for each section.

### 1. Architecture & Approach

Read these files:
- `plan/MASTER-PLAN.md` — overall architecture, phases, decisions, risks
- `plan/QUICKSTART.md` — the entry point and file reference

Evaluate:
- Is Managed Identity the right default choice? Are there scenarios where it wouldn't work that we've missed?
- Is the phased approach (infra → module → inventory → migrate → cleanup) correct? Should anything be reordered?
- Is the "shared auth module" pattern appropriate, or is it adding unnecessary coupling?
- Are the decisions in the Decision Log sound? Would you challenge any of them?
- Are the risks in the Risk Register complete? What's missing?

### 2. Strategy Documents

Read all 8 files in `strategy/`:
- `01-Connect-SPOService.md`
- `02-Connect-PnPOnline.md`
- `03-Credentials-and-Secrets.md`
- `04-Standardized-Template.md`
- `05-Runtime-and-Modules.md`
- `06-Exchange-Online.md`
- `07-Hybrid-Runbook-Workers.md`
- `08-PS51-to-PS74-Compatibility.md`

Evaluate:
- Are the cmdlet mappings (SPO→PnP, AzureAD→Graph, etc.) correct and complete?
- Are there migration patterns or edge cases not covered?
- Is the PS 5.1→7.4 compatibility list sufficient? What common breaking changes are missing?
- Is the Hybrid Worker guidance practical for real-world deployments?
- Is the Exchange Online strategy accurate regarding EXO v3 Managed Identity support?

### 3. Shared Auth Module

Read these files:
- `modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psm1`
- `modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psd1`

Evaluate:
- Is the module well-structured? Are there any code issues (parameter validation, error handling, edge cases)?
- Does the token refresh logic (`Test-ContosoTokenFreshness` at 45 minutes, `Invoke-ContosoWithRetry` on 401/403) actually work? Are the error patterns matched correctly?
- Is `Disconnect-ContosoAll` thorough enough?
- Would you trust this module in a production Automation Account?
- Is the `Export-ModuleMember` pattern correct given the `.psd1` also declares `FunctionsToExport`?

### 4. Migration Scripts

Read these files:
- `scripts/migration/Scan-LegacyAuth.ps1`
- `scripts/migration/Scan-Permissions.ps1`
- `scripts/migration/Get-RunbookDependencies.ps1`
- `scripts/migration/Export-Runbooks.ps1`

Evaluate:
- Do the scanner regex patterns correctly match what they claim to match? Are there false positives or false negatives?
- Is the permission mapping in `Scan-Permissions.ps1` accurate (cmdlet → API permission)?
- Does `Get-RunbookDependencies.ps1` correctly discover schedules, webhooks, and child calls?
- Are there any runtime bugs (function ordering, variable scoping, error handling)?

### 5. Agent Execution Framework

Read these files:
- `CLAUDE.md` — agent's first contact point
- `agent/AGENT-INSTRUCTIONS.md` — full operating instructions
- `agent/skills/initialize-session.ps1`
- `agent/skills/analyze-runbook.ps1`
- `agent/skills/migrate-runbook.ps1`
- `agent/skills/validate-runbook.ps1`
- `agent/skills/update-progress.ps1`
- `runbooks/PIPELINE.md`

Evaluate:
- Could an AI agent pick this up and execute it without asking the human questions? What would confuse it?
- Is the pipeline flow (`source/` → `staging/` → `testing/` → `completed/`) clear and enforceable?
- Are the skill scripts robust? Would they work on diverse, real-world runbook code?
- Is the validation in `validate-runbook.ps1` sufficient to catch migration mistakes?
- Is progress tracking reliable? Would the agent correctly resume a half-finished migration?
- Is there any way the agent could accidentally damage production (modify source files, publish to Azure, delete originals)?

### 6. Operational Readiness

Read these files:
- `plan/ROLLBACK-PLAYBOOK.md`
- `plan/MONITORING-AND-CHANGE-MANAGEMENT.md`
- `plan/PHASE0-SETUP-INSTRUCTIONS.md`
- `plan/PHASE4-CLEANUP-INSTRUCTIONS.md`

Evaluate:
- Is the rollback procedure realistic? Would it actually work under pressure?
- Are the KQL alert queries correct?
- Is the change management process lightweight enough to not block progress, but thorough enough to prevent incidents?
- Are the Phase 0 prerequisites complete? Would a real admin be able to follow them?

### 7. Cross-Cutting Concerns

Evaluate:
- **Security**: Could this migration introduce new vulnerabilities? Is the Managed Identity permission model secure?
- **Consistency**: Are there contradictions between documents? Do file path references all resolve correctly?
- **Completeness**: What services or scenarios are NOT covered that commonly appear in Azure Automation? (e.g., Azure SQL, Cosmos DB, Azure DevOps, Teams, third-party APIs)
- **Maintainability**: After migration, can the organization maintain this without the original implementers?

---

## Known Concerns from the Author

These are areas where I'm less confident and would specifically like your assessment:

### Concern 1: Token Refresh Reliability
The shared module refreshes the Azure token proactively at 45 minutes and retries on 401/403 errors. However:
- PnP.PowerShell and Microsoft Graph manage their own token caches internally
- Reconnecting `Connect-AzAccount` refreshes the Az module token but doesn't necessarily refresh the PnP or Graph tokens
- `Invoke-ContosoWithRetry` catches errors and reconnects, but for PnP specifically, a `Connect-PnPOnline -ManagedIdentity` reconnect mid-runbook may lose the current site context

**Question**: Is the token refresh approach sound, or does it create a false sense of security? Should each service's reconnection be handled independently?

### Concern 2: Scan-Permissions.ps1 Accuracy
The permission scanner maps cmdlet names to API permissions via regex. This is inherently approximate:
- A runbook using `Get-PnPListItem` is flagged as needing `Sites.Read.All`, but if it also writes items, the scanner catches that separately
- Some cmdlets may need different permissions depending on which parameters are used (e.g., `Get-MgUser -Property Manager` needs `User.Read.All`, but getting all properties may need more)
- The scanner can't detect permissions needed for REST API calls (`Invoke-RestMethod`, `Invoke-MgGraphRequest`)

**Question**: Is this level of approximation acceptable for a planning tool, or does it need disclaimers? Should it be positioned differently?

### Concern 3: Agent Migration Quality
The `migrate-runbook.ps1` skill is a reference document, not an automated replacement tool. The actual migration work is done by the AI agent reading the source code and applying transformations with judgment. This means:
- Quality depends entirely on the agent's understanding of PowerShell
- Complex scripts with interleaved auth and business logic may be mishandled
- The validation checks (8 points in `validate-runbook.ps1`) catch structural issues but can't verify semantic correctness

**Question**: Is the validation sufficient? Should there be additional checks? Is it realistic to expect an AI agent to correctly migrate complex runbooks without introducing bugs?

### Concern 4: PnP Cmdlet Output Compatibility
When migrating from `Get-SPOSite` to `Get-PnPTenantSite`, the returned objects have different property names and structures. The strategy documents mention this but don't provide a comprehensive property mapping. If downstream code references `.StorageQuota` on an SPO object, the PnP equivalent may be `.StorageQuota` or `.StorageMaximumLevel` depending on the version.

**Question**: Is this risk adequately mitigated by "test in Azure Automation Test pane," or should we build a property mapping reference?

### Concern 5: What We Haven't Covered
Services NOT addressed in the current strategies:
- Azure SQL authentication (`Invoke-Sqlcmd` with credentials)
- Azure DevOps API calls with PATs
- Teams messaging (`Connect-MicrosoftTeams`)
- Third-party REST APIs with API keys
- Azure Key Vault certificate-based auth for non-Microsoft services
- Cosmos DB connection strings
- Power Platform / Dataverse connections

**Question**: Should these be called out as out-of-scope, or should we add placeholder strategies?

---

## Deliverables Requested

Please provide:

1. **A findings report** organized by the 7 review sections above, with severity ratings (Critical / High / Medium / Low / Info) for each finding
2. **A list of blocking issues** that must be fixed before this goes to an executing agent
3. **A list of recommended improvements** that would strengthen the project but aren't blocking
4. **An overall assessment**: Is this project ready for execution? What's your confidence level (1-10) that the migration agent can successfully process a typical set of 30-50 runbooks with this framework?
5. **Answers to the 5 specific concerns** raised above

---

## File Inventory

For reference, the project contains these 39 files:

```
.gitignore
CLAUDE.md
agent/AGENT-INSTRUCTIONS.md
agent/skills/analyze-runbook.ps1
agent/skills/initialize-session.ps1
agent/skills/migrate-runbook.ps1
agent/skills/update-progress.ps1
agent/skills/validate-runbook.ps1
modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psd1
modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psm1
plan/MASTER-PLAN.md
plan/MONITORING-AND-CHANGE-MANAGEMENT.md
plan/PHASE0-SETUP-INSTRUCTIONS.md
plan/PHASE2-INVENTORY-INSTRUCTIONS.md
plan/PHASE3-MIGRATION-INSTRUCTIONS.md
plan/PHASE4-CLEANUP-INSTRUCTIONS.md
plan/QUICKSTART.md
plan/ROLLBACK-PLAYBOOK.md
runbooks/PIPELINE.md
scripts/migration/Export-Runbooks.ps1
scripts/migration/Get-RunbookDependencies.ps1
scripts/migration/Scan-LegacyAuth.ps1
scripts/migration/Scan-Permissions.ps1
scripts/setup/Deploy-AuthModule.ps1
scripts/setup/Grant-ManagedIdentityPermissions.ps1
scripts/setup/New-RuntimeEnvironment.ps1
staging/Test-AuthModule.ps1
strategy/01-Connect-SPOService.md
strategy/02-Connect-PnPOnline.md
strategy/03-Credentials-and-Secrets.md
strategy/04-Standardized-Template.md
strategy/05-Runtime-and-Modules.md
strategy/06-Exchange-Online.md
strategy/07-Hybrid-Runbook-Workers.md
strategy/08-PS51-to-PS74-Compatibility.md
templates/RunbookTemplate.ps1
peer-review/PEER-REVIEW-PROMPT.md
promptNarrative.txt
```

Begin your review by reading `CLAUDE.md`, then `plan/QUICKSTART.md`, then work through the 7 sections above in order. Read every file. Do not skim.
