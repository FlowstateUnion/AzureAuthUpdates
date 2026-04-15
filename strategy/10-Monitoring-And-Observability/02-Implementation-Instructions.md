# Implementation Instructions — Monitoring

Audience: human operator with Reader + Automation Operator on the Automation
Account, and permission to create diagnostic settings if needed.

---

## Step 0 — Set session variables

```powershell
$env:AA_RG   = '<resource-group>'
$env:AA_NAME = '<automation-account>'
$env:AA_SUB  = '<subscription-id>'  # optional; only if not in default context

Connect-AzAccount
if ($env:AA_SUB) { Select-AzSubscription -SubscriptionId $env:AA_SUB }
```

Install required modules (once):

```powershell
Install-Module Az.Accounts, Az.Automation, Az.Monitor, Az.OperationalInsights -Scope CurrentUser
```

---

## Step 1 — Check what you have

```powershell
cd D:\DevProjects\AzureAuthUpdates\strategy\10-Monitoring-And-Observability\scripts
.\Test-DiagnosticSettings.ps1 -ResourceGroupName $env:AA_RG -AutomationAccountName $env:AA_NAME
```

**What the output tells you:**

| Result | Meaning | Next step |
|---|---|---|
| `Layer 2: READY` — workspace ID shown, `JobLogs` + `JobStreams` enabled | You're set. Note the workspace ID. | Go to Step 3. |
| `Layer 2: PARTIAL` — only one category enabled | Get the richer data by enabling both. | Enable the missing category (Step 2). |
| `Layer 2: NOT CONFIGURED` — no diagnostic settings | You only have Layer 1 (30-day window). | Decide: set up Layer 2 now (Step 2) or proceed with Layer 1 only. |

---

## Step 2 — (If needed) Set up Log Analytics diagnostics

If `Test-DiagnosticSettings.ps1` showed NOT CONFIGURED or PARTIAL, either:

**A. Use an existing Log Analytics workspace.** Preferred if you already
have one for other Azure telemetry.

```powershell
# Find workspaces in the subscription
Get-AzOperationalInsightsWorkspace | Select Name, ResourceGroupName, Location, ResourceId

$wsId = '<workspace resource ID>'

$logs = @(
    @{ category = 'JobLogs';    enabled = $true },
    @{ category = 'JobStreams'; enabled = $true }
)

$aaId = (Get-AzAutomationAccount -ResourceGroupName $env:AA_RG -Name $env:AA_NAME).AutomationAccountId

New-AzDiagnosticSetting -ResourceId $aaId -Name 'aa-to-la' `
    -WorkspaceId $wsId -Log $logs

# Switch to resource-specific mode for cleaner tables
Set-AzDiagnosticSetting -ResourceId $aaId -Name 'aa-to-la' -LogAnalyticsDestinationType 'Dedicated'
```

**B. Create a new workspace.** Out of scope here — see `plan/PHASE0-*` for
workspace provisioning patterns.

After enabling, wait 10–15 minutes for the first data to land, then rerun
`Test-DiagnosticSettings.ps1` to confirm.

---

## Step 3 — Run the triage queries

### Per-runbook summary (last 7 days)

```powershell
.\Get-RunbookJobSummary.ps1 -ResourceGroupName $env:AA_RG `
    -AutomationAccountName $env:AA_NAME -Days 7
```

Produces a table: `RunbookName, Total, Completed, Failed, Suspended,
AvgDurationMin, LastRun`. Pipe to `Export-Csv` for spreadsheet review.

### Find stale runbooks (no runs in 90 days)

```powershell
.\Find-StaleRunbooks.ps1 -ResourceGroupName $env:AA_RG `
    -AutomationAccountName $env:AA_NAME -Days 90 |
    Export-Csv stale-runbooks.csv -NoTypeInformation
```

Review the CSV. For each:

1. Check for schedules — even if it didn't run, an attached schedule implies
   intent.
2. Check for webhooks that might trigger it from outside.
3. Confirm with the original author (if known) before retiring.

Retirement workflow: move the runbook to a holding Automation Account or
export its content, then delete from production.

### Group recurring errors (last 7 days)

```powershell
.\Get-RunbookErrors.ps1 -WorkspaceId $wsId -Days 7 |
    Sort-Object Hits -Descending |
    Select-Object -First 20
```

Output groups error-stream messages by signature. Top of the list is where
to focus. If you don't have a workspace, the script falls back to Layer 1:

```powershell
.\Get-RunbookErrors.ps1 -ResourceGroupName $env:AA_RG `
    -AutomationAccountName $env:AA_NAME -Days 3
```

(Layer 1 fallback is slower and scoped to one runbook at a time.)

---

## Step 4 — Schedule a nightly health report

Two paths:

### A. Run it yourself via Windows Task Scheduler / cron

```powershell
# nightly-aa-health.ps1
$out = Join-Path $env:TEMP "aa-health-$(Get-Date -Format yyyyMMdd).csv"
.\Get-RunbookJobSummary.ps1 -ResourceGroupName $env:AA_RG `
    -AutomationAccountName $env:AA_NAME -Days 1 |
    Export-Csv $out -NoTypeInformation
# Email the CSV — via Send-ContosoEmail once that's deployed, or your usual channel.
```

### B. Run it inside Azure Automation itself (self-monitoring)

Turn the scripts in this folder into a `Get-ContosoAutomationHealth.ps1`
runbook that:

1. Calls the same Get/Find cmdlets using the Automation Account's MI.
2. Builds an HTML summary.
3. Calls `.\Send-ContosoEmail.ps1` (from the orchestration folder) to send
   it to the ops distribution list.
4. Scheduled daily at 06:00 local.

Use the prompt at `prompts/03-schedule-nightly-health-report.md` for an
agent to produce this runbook.

---

## Step 5 — Optional: Azure Monitor alerts

For proactive alerting, convert the KQL queries in `01-Overview.md` into
Log Analytics alert rules:

```powershell
# Example: alert when more than 5 failures from the same runbook in 15 min
$query = @'
AutomationJobLogs
| where TimeGenerated > ago(15m) and ResultType == "Failed"
| summarize count() by RunbookName
| where count_ > 5
'@

# Set up via the portal (Monitor > Alerts > New alert rule) pointing at
# the workspace, using this query as the signal. Threshold: count > 0.
# Out of scope for this repo — document the rules in plan/MONITORING.md.
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Get-AzAutomationJob` returns nothing | Wrong RG or account name; or no jobs in the window | Sanity-check with `Get-AzAutomationRunbook` first |
| KQL query returns nothing, but Layer 1 shows jobs | Diagnostic setting not enabled, or ingestion lag | Check diagnostic setting; wait 10–15 min after first enabling |
| `Invoke-AzOperationalInsightsQuery` 403 | Missing `Log Analytics Reader` on the workspace | Assign the role |
| `AzureDiagnostics` has data but `AutomationJobLogs` doesn't | Diagnostic setting is in legacy mode | Re-run `Set-AzDiagnosticSetting ... -LogAnalyticsDestinationType 'Dedicated'` |
| Stream record value is empty | Verbose/Progress records often have payload elsewhere; not every record has ResultDescription | Inspect in the portal job detail pane to confirm |
