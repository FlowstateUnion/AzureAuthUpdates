# 10 — Monitoring and Observability

## Goals

Answer four recurring operational questions about the Automation Account
**without opening the portal**:

1. **Which runbooks ran, passed, and failed in the last N days?**
2. **Where are errors concentrated — is it one misbehaving runbook or a
   cross-cutting failure (auth, throttling, module)?**
3. **Which runbooks haven't run in 90 days and can probably be retired?**
4. **Who changed what, and when?** (governance / audit)

## Three-layer approach

| Layer | What | Scriptable via | Retention |
|---|---|---|---|
| **1. Az.Automation cmdlets** | Job list, job status, job streams | `Get-AzAutomationJob`, `Get-AzAutomationJobOutput`, `Get-AzAutomationRunbook` | ~30 days |
| **2. Log Analytics (KQL)** | Rich historical querying across jobs + streams | `Invoke-AzOperationalInsightsQuery` | Per workspace retention (default 30, configurable up to 730) |
| **3. Azure Monitor Activity Log** | Admin events (publish, edit, delete, manual start) | `Get-AzLog -ResourceId <aa-id>` | 90 days (longer if exported) |

Layer 1 is always available. Layer 2 is the real power tool — but only if
diagnostic settings send `JobLogs` and `JobStreams` to a Log Analytics
workspace. **That is the first thing to verify.**

## What's inside

| Path | Purpose |
|---|---|
| `01-Overview.md` | Detailed explanation of each layer, the tables/fields they expose, and when to reach for which. |
| `02-Implementation-Instructions.md` | Step-by-step: verify diagnostics, run each script, schedule a nightly health report. |
| `scripts/Test-DiagnosticSettings.ps1` | Prerequisite check — is the AA piping `JobLogs` + `JobStreams` into a Log Analytics workspace? Reports the workspace ID. |
| `scripts/Get-RunbookJobSummary.ps1` | Per-runbook pass/fail/duration table for the last N days. Layer 1. |
| `scripts/Find-StaleRunbooks.ps1` | Runbooks with zero executions in N days — candidates to retire. Layer 1. |
| `scripts/Get-RunbookErrors.ps1` | Groups error streams by signature to spot repeating failures. Layer 2 preferred, falls back to Layer 1. |
| `prompts/` | Agent prompts for wiring diagnostics, building out the toolkit, and scheduling a recurring health report. |

## Prerequisites

- `Az.Accounts`, `Az.Automation`, `Az.Monitor`, `Az.OperationalInsights` modules.
- The account running these scripts needs `Reader` + `Automation Operator` on
  the Automation Account, and `Log Analytics Reader` on any workspace queried.
- If diagnostics aren't wired up, you'll need a role that can create
  diagnostic settings (`Contributor` or `Monitoring Contributor`).

## What this is NOT

- **Not an alerting system.** For real-time alerts (job failure, long-running
  job), configure Azure Monitor alerts against the same KQL queries — out of
  scope for this folder.
- **Not APM.** Runbook-level insight only; if you need dependency tracing
  into SharePoint/Graph, instrument via Application Insights separately.
