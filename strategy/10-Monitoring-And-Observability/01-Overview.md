# Monitoring & Observability — Overview

Three layers, each with distinct strengths. Pick the right one for the
question you're answering.

## Layer 1 — Az.Automation cmdlets

Direct API calls against the Automation Account. No infra needed beyond
the cmdlets themselves.

**Key cmdlets:**

```powershell
# Runbook inventory + metadata
Get-AzAutomationRunbook -ResourceGroupName $rg -AutomationAccountName $aa

# Jobs in a time window
Get-AzAutomationJob -ResourceGroupName $rg -AutomationAccountName $aa `
    -StartTime (Get-Date).AddDays(-7)

# Streams for a specific job
Get-AzAutomationJobOutput -Id $jobId -Stream Error -ResourceGroupName $rg `
    -AutomationAccountName $aa
Get-AzAutomationJobOutputRecord -Id $streamRecordId -JobId $jobId `
    -ResourceGroupName $rg -AutomationAccountName $aa
```

**Strengths:**
- Always available — no diagnostic-setting dependency.
- Fast for small scopes (single runbook, single job).
- Access to the full stream record (Output, Error, Warning, Verbose, Debug,
  Progress).

**Limits:**
- Job history retention is ~30 days; jobs older than that are gone.
- No SQL-like querying — you pull lists and filter client-side.
- Fetching stream records across many jobs is slow (one API call per
  record).
- No easy way to group by error message across jobs.

**Good for:** day-to-day triage, inspecting a specific job, inventorying
runbooks, counting runs in the last week.

## Layer 2 — Log Analytics (KQL)

When the Automation Account's diagnostic setting sends `JobLogs` +
`JobStreams` to a Log Analytics workspace, every job event and every stream
record lands in queryable tables. This is the real tool for historical
analysis.

**Tables (depends on diagnostic setting mode):**

| Mode | Table(s) | Notes |
|---|---|---|
| **Azure Diagnostics** (legacy) | `AzureDiagnostics` | Shared table; filter by `ResourceProvider == "MICROSOFT.AUTOMATION"`. Column names have a `_s` / `_d` suffix by type. |
| **Resource-Specific** (recommended) | `AutomationJobLogs`, `AutomationJobStreams` | Dedicated tables with clean column names. Faster, cheaper. |

**Key fields (resource-specific mode):**

- `AutomationJobLogs`: `RunbookName`, `JobId`, `ResultType` (Completed/Failed/
  Stopped/Suspended), `StartTime`, `EndTime`, `CallerName`.
- `AutomationJobStreams`: `RunbookName`, `JobId`, `StreamType` (Error/Output/
  Warning/Verbose/Progress), `ResultDescription` (the actual message),
  `TimeGenerated`.

**Example queries:**

```kusto
// 1. Failure rate by runbook, last 14 days
AutomationJobLogs
| where TimeGenerated > ago(14d)
| summarize Total=count(), Failed=countif(ResultType=="Failed") by RunbookName
| extend FailRatePct = round(100.0 * Failed / Total, 1)
| order by Failed desc

// 2. Grouped error messages, last 7 days
AutomationJobStreams
| where StreamType == "Error" and TimeGenerated > ago(7d)
| extend Signature = substring(ResultDescription, 0, 120)
| summarize Hits=count(), Runbooks=dcount(RunbookName), Sample=any(ResultDescription) by Signature
| order by Hits desc

// 3. Stale runbooks — zero runs in 90 days (requires join against full inventory)
AutomationJobLogs
| where TimeGenerated > ago(90d)
| summarize LastRun=max(TimeGenerated), Runs=count() by RunbookName
| union (
    // left-antijoin equivalent comes from the PowerShell layer:
    // the script fetches all runbooks via Az.Automation and subtracts this list.
    datatable(RunbookName:string, LastRun:datetime, Runs:long) []
)

// 4. Long-running jobs (p95), last 30 days
AutomationJobLogs
| where TimeGenerated > ago(30d) and ResultType == "Completed"
| extend DurationMin = datetime_diff('second', EndTime, StartTime) / 60.0
| summarize P95=percentile(DurationMin, 95), Avg=avg(DurationMin), Max=max(DurationMin) by RunbookName
| order by P95 desc
```

**From PowerShell:**

```powershell
$q = @'
AutomationJobLogs
| where TimeGenerated > ago(14d)
| summarize Total=count(), Failed=countif(ResultType=="Failed") by RunbookName
'@

Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $q |
    Select-Object -ExpandProperty Results
```

**Strengths:**
- Long retention (configurable up to 730 days).
- SQL-like power — grouping, joins, time bucketing, percentiles.
- Single query across many runbooks/jobs.
- Queries feed directly into Azure Monitor alerts and Workbooks.

**Limits:**
- Requires diagnostic setting + workspace (cost).
- 5–10 minute ingestion lag — not for real-time tailing.
- Query cost grows with data scanned; use time filters aggressively.

## Layer 3 — Activity Log

Administrative events: who published, who deleted, who triggered a manual
job. Not runtime errors — governance.

```powershell
Get-AzLog -ResourceId $automationAccountId -StartTime (Get-Date).AddDays(-30) |
    Where-Object { $_.OperationName.Value -like '*runbook*' -or
                   $_.OperationName.Value -like '*job*' } |
    Select-Object EventTimestamp, Caller, OperationName, Status
```

**Good for:** "who changed that runbook last Thursday?", audit trails,
suspicious manual invocations.

## Layer selection guide

| Question | Layer |
|---|---|
| Did this specific job fail? What was the error? | 1 |
| What ran in the last 24 hours? | 1 |
| Which runbooks have the highest failure rate this month? | 2 |
| Are we being throttled by Graph? (grouped 429 errors across runbooks) | 2 |
| What runbooks are unused and safe to delete? | 2 + 1 |
| Who published a new version of Runbook X yesterday? | 3 |
| Who manually triggered this job? | 3 (Caller) |

## Sticking points to plan for

1. **Diagnostic-setting mode matters.** Resource-specific tables are much
   nicer to query than `AzureDiagnostics`. If you're setting this up for
   the first time, choose resource-specific.
2. **Retention settles the budget.** LA data charges per GB/month. 90-day
   retention on chatty runbooks (verbose logging) is expensive. Decide
   retention before turning on `JobStreams`.
3. **Verbose/Progress streams flood.** `JobStreams` captures *everything*
   including Verbose and Progress. Consider filtering at the runbook level
   (`$VerbosePreference = 'SilentlyContinue'` in production) to cut cost.
4. **Cross-account rollup.** If you have multiple Automation Accounts,
   point them all at the same workspace so one query covers everything.
5. **Test Pane jobs appear in logs too.** Filter on `JobDestination` or
   `ResourceLocation` if you need to separate Test-Pane runs from scheduled
   runs.
