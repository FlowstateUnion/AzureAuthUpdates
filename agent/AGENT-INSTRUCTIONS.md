# Migration Agent Instructions

You are an autonomous agent migrating Azure Automation runbooks from legacy credential-based authentication to Managed Identity. This document is everything you need to work independently.

## Your Mission

For every `.ps1` file in `runbooks/source/`, produce a migrated version that:
1. Uses the shared `Contoso.Automation.Auth` module for all authentication
2. Follows the standardized runbook template
3. Replaces legacy module calls (SPO → PnP, AzureAD → Graph, EXO creds → MI)
4. Is compatible with PowerShell 7.4 (or documented as a PS 5.1 exception)
5. Preserves all business logic, parameters, and output format exactly

## Your Workspace

```
runbooks/source/      ← READ from here. NEVER modify these files.
runbooks/staging/     ← WRITE your work here. This is your workbench.
runbooks/testing/     ← MOVE files here once they pass syntax check.
runbooks/exceptions/  ← MOVE files here if they CANNOT be migrated. Add a .reason.md.
runbooks/completed/   ← DO NOT TOUCH. Human moves files here after Azure testing.
```

## Before You Start

**Every session**, run `initialize-session.ps1` first. It handles both fresh starts and resumption:
- **Fresh start:** Scans all source files, creates progress tracker, reports what needs to be done.
- **Resuming:** Loads existing progress, detects any new files added since last session, reports remaining work. It will NOT re-scan unless you pass `-Force`.

### Step 1: Run the Scanner
Execute `scripts/migration/Scan-LegacyAuth.ps1` against `runbooks/source/`:
```powershell
.\scripts\migration\Scan-LegacyAuth.ps1 -Path ".\runbooks\source" -OutputCsv ".\agent\scan-results.csv"
```
This produces your work manifest — every pattern that needs fixing, per file.

### Step 2: Run the Permission Audit
```powershell
.\scripts\migration\Scan-Permissions.ps1 -Path ".\runbooks\source" -OutputCsv ".\agent\permission-audit.csv"
```

### Step 3: Discover Dependencies
Dependencies determine migration order. Use whichever method is available:

**If Azure access is available** (preferred — discovers schedules, webhooks, and HRW usage too):
```powershell
.\scripts\migration\Get-RunbookDependencies.ps1 -ResourceGroupName "<RG>" -AutomationAccountName "<AA>" -RunbookSourcePath ".\runbooks\source" -OutputPath ".\agent"
```

**If Azure access is NOT available** (code-only analysis):
Search all source files for `Start-AzAutomationRunbook` calls and build a parent→child map:
```powershell
Get-ChildItem ".\runbooks\source\*.ps1" | Select-String -Pattern 'Start-Az(?:ureRm)?AutomationRunbook' |
    ForEach-Object { Write-Output "$($_.Filename) calls: $($_.Line.Trim())" }
```
Record the results in `agent/dependency-notes.md`. The key rule: **migrate child runbooks before their parents.** If no child calls exist, migration order doesn't matter — work simplest-first.

### Step 4: Build the Checklist
Create `agent/PROGRESS.md` using the scan results. See the Progress Tracking section below.

## Per-Runbook Migration Process

For each runbook, follow this exact sequence. Use the skill scripts in `agent/skills/` as your reference.

### 1. ANALYZE (skill: analyze-runbook)
- Read the source file from `runbooks/source/`
- Check `agent/scan-results.csv` for its findings
- Check `agent/permission-audit.csv` for its permission needs
- Determine:
  - What auth patterns need replacing
  - What module calls need remapping (SPO→PnP, AzureAD→Graph, EXO creds→MI)
  - Any PS 7.4 compatibility issues (COM, WMI, .NET Framework)
  - Whether it calls child runbooks or is called by parents
  - Whether it must stay on PS 5.1 (if yes → exception)

### 2. MIGRATE (skill: migrate-runbook)
- Copy the file from `source/` to `staging/`
- Apply changes in this order:
  1. **Add `#Requires` statements** at the top
  2. **Add/update script header** (`.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`)
  3. **Replace the auth block** with shared module calls:
     - `Get-AutomationPSCredential` + `Connect-*` → `Connect-Contoso*`
     - `Connect-SPOService` → `Connect-ContosoSPOAdmin` or `Connect-ContosoSharePoint`
     - `Connect-PnPOnline -Credential` → `Connect-ContosoSharePoint`
     - `Connect-ExchangeOnline -Credential` → `Connect-ContosoExchange`
     - `Connect-AzAccount -ServicePrincipal` → `Connect-ContosoAzure`
     - `Connect-AzureAD` → `Connect-ContosoGraph`
     - `Connect-MsolService` → `Connect-ContosoGraph`
  4. **Remap service cmdlets** where the module changed:
     - `Get-SPOSite` → `Get-PnPTenantSite` (see `strategy/01-Connect-SPOService.md`)
     - `Get-AzureADUser` → `Get-MgUser`
     - `Get-MsolUser` → `Get-MgUser`
     - `Send-MailMessage` → `Send-MgUserMail`
  5. **Fix PS 7.4 compatibility** (see `strategy/08-PS51-to-PS74-Compatibility.md`):
     - `Get-WmiObject` → `Get-CimInstance`
     - `New-Object -ComObject` → exception or alternative module
     - `[System.Web.HttpUtility]` → `[System.Net.WebUtility]`
  6. **Wrap in template structure** (see `templates/RunbookTemplate.ps1`):
     - `$ErrorActionPreference = "Stop"`
     - `try/catch/finally`
     - `Disconnect-ContosoAll` in `finally`
  7. **Remove dead code**:
     - Delete all `$cred = Get-AutomationPSCredential ...`
     - Delete all `ConvertTo-SecureString` for credential construction
     - Delete all `New-Object PSCredential`
     - Delete unused `Import-Module` statements for replaced modules
  8. **Use `Invoke-ContosoWithRetry`** for operations that may span >30 minutes
- **PRESERVE**: parameter names, parameter types, output format, business logic
- **DO NOT**: add features, refactor working logic, rename variables, add comments to code you didn't change

### 3. VALIDATE (skill: validate-runbook)
- Run a PowerShell syntax check on the staged file
- Verify all `#Requires` modules match what's actually used
- Verify no legacy patterns remain (re-scan the single file)
- If validation passes → copy to `runbooks/testing/`
- If validation fails → fix issues in `staging/` and re-validate

### 4. EXCEPTION (skill: exception-runbook)
If a runbook CANNOT be migrated to PS 7.4 (COM objects with no replacement, etc.):
- Copy to `runbooks/exceptions/`
- Create `runbooks/exceptions/<RunbookName>.reason.md` explaining:
  - Why it can't be migrated
  - What specific patterns block it
  - What would need to change for it to become migratable
  - Whether auth-only migration is possible (MI works on PS 5.1 with Az.Accounts)
- Note: A runbook CAN be an exception for PS 7.4 runtime but STILL get auth migration

### 5. TRACK (skill: update-progress)
After each runbook is processed, update `agent/PROGRESS.md` and `agent/progress.json`.

## What You Must NOT Do

- **Never modify files in `runbooks/source/`** — these are the originals
- **Never move files to `runbooks/completed/`** — only the human does this
- **Never publish to Azure Automation** — only the human does this
- **Never change parameter names or types** — schedules and webhooks depend on them
- **Never change output format** — downstream consumers depend on it
- **Never add features or refactor business logic** — scope is auth migration only
- **Never guess at Azure resource names** — if you need RG/AA names, ask the human

## Reference Documents

Read these as needed for specific migration patterns:

| When | Read |
|------|------|
| Replacing `Connect-SPOService` | `strategy/01-Connect-SPOService.md` |
| Replacing `Connect-PnPOnline` creds | `strategy/02-Connect-PnPOnline.md` |
| Any credential/secret pattern | `strategy/03-Credentials-and-Secrets.md` |
| Applying the template | `strategy/04-Standardized-Template.md` + `templates/RunbookTemplate.ps1` |
| Module version questions | `strategy/05-Runtime-and-Modules.md` |
| Exchange Online patterns | `strategy/06-Exchange-Online.md` |
| Hybrid Worker considerations | `strategy/07-Hybrid-Runbook-Workers.md` |
| PS 5.1→7.4 compatibility | `strategy/08-PS51-to-PS74-Compatibility.md` |
| Shared module API reference | `modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psm1` |

## Migration Order

1. **Runbooks with no parent/child dependencies** — migrate in any order, simplest first
2. **Child runbooks** (called by `Start-AzAutomationRunbook`) — migrate before their parents
3. **Parent runbooks** — migrate last, after their children are in `testing/` or `completed/`

## Communicating with the Human

If you encounter something that requires human judgment:
- Write the question to `agent/QUESTIONS.md` (create if it doesn't exist)
- Continue with other runbooks while waiting
- The human will answer in the same file or in conversation

Questions that require the human:
- "This runbook's business logic seems broken even in the original — should I fix it?"
- "This runbook connects to a third-party API I don't recognize — what auth does it need?"
- "This parameter looks like it accepts a credential from a webhook — what should replace it?"
