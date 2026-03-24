# Monitoring, Alerting & Change Management

## Part 1: Change Management

### Stakeholder Communication

Before beginning migration, identify and notify stakeholders:

| Stakeholder | When to Notify | What to Tell Them |
|-------------|----------------|-------------------|
| Runbook owners / script authors | Before Phase 2 | Audit is happening; they may be asked questions about specific scripts |
| Teams consuming runbook output | Before Phase 3 (per runbook) | Their data feed is being updated; verify output format is unchanged |
| On-call / operations | Before Phase 3 starts | Runbook behavior is changing; escalation path for failures |
| Security / compliance | Phase 0 | Credential assets are being eliminated; MI and Key Vault are replacing them |
| Management | Phase 0 | Timeline, risk, and expected improvement |

### Communication Template — Per-Runbook Migration

```
Subject: Automation Runbook Update: [RUNBOOK NAME]

What: The authentication method for [RUNBOOK NAME] is being updated from
stored credentials to Managed Identity. Business logic is unchanged.

When: [DATE] during [WINDOW]

Impact: The runbook will be briefly unavailable during publish (~1 minute).
If the update causes issues, it will be rolled back immediately.

What you may notice: Nothing — output and behavior should be identical.

If something seems wrong: Contact [NAME/TEAM] or file an incident.

Rollback plan: The original version is preserved and can be restored in <5 minutes.
```

### Approval Gates

Use this lightweight approval process before publishing each batch:

**For Simple runbooks (batch of up to 5):**
- [ ] Peer review of code changes (diff between original and migrated)
- [ ] Test pane execution successful
- [ ] Stakeholder notified (if they consume output)
- [ ] Approver sign-off: _____________ Date: _______

**For Medium/Complex runbooks (individual):**
- [ ] Peer review of code changes
- [ ] Test pane execution successful
- [ ] Output compared to last 3 successful runs
- [ ] Stakeholder notified and acknowledged
- [ ] Change request logged (if using ITSM)
- [ ] Approver sign-off: _____________ Date: _______

### Service Windows

Schedule migration work during:
- Business hours (for faster rollback response) OR
- Maintenance windows (for lower-risk publishing)

Avoid:
- Month-end close periods (if runbooks support financial processes)
- Active incident periods
- Within 48 hours of another major change

---

## Part 2: Monitoring During Migration

### Per-Runbook Monitoring (Phase 3)

After publishing each runbook, monitor for **7 calendar days**:

```powershell
# Daily check — run each morning during the monitoring period
$rg = "<RG>"
$aa = "<AA>"
$runbookName = "<RUNBOOK>"
$since = (Get-Date).AddDays(-1)

$jobs = Get-AzAutomationJob -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -RunbookName $runbookName `
    -StartTime $since

$summary = $jobs | Group-Object Status
Write-Output "=== $runbookName — Last 24 Hours ==="
$summary | ForEach-Object { Write-Output "  $($_.Name): $($_.Count)" }

# Flag any failures
$failed = $jobs | Where-Object { $_.Status -eq "Failed" }
if ($failed) {
    Write-Warning "$($failed.Count) FAILED JOBS detected!"
    foreach ($job in $failed) {
        $errors = Get-AzAutomationJobOutput -ResourceGroupName $rg `
            -AutomationAccountName $aa `
            -Id $job.JobId -Stream Error
        Write-Output "  Job $($job.JobId) ($($job.CreationTime)):"
        $errors | ForEach-Object { Write-Output "    $($_.Summary)" }
    }
}
```

### Migration Dashboard (Track Overall Progress)

Generate a summary across all runbooks:

```powershell
$rg = "<RG>"
$aa = "<AA>"

# Get all jobs from last 7 days
$allJobs = Get-AzAutomationJob -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -StartTime (Get-Date).AddDays(-7)

# Load migration queue
$queue = Import-Csv ".\plan\migration-queue.csv"
$migrated = $queue | Where-Object { $_.Status -eq "Published" }
$migratedNames = $migrated | ForEach-Object { $_.Runbook -replace '\.ps1$', '' }

Write-Output "=== MIGRATION DASHBOARD ==="
Write-Output "Total runbooks in queue:  $($queue.Count)"
Write-Output "Migrated and published:   $($migrated.Count)"
Write-Output "Remaining:                $($queue.Count - $migrated.Count)"
Write-Output ""

# Health of migrated runbooks
Write-Output "=== MIGRATED RUNBOOK HEALTH (Last 7 Days) ==="
foreach ($name in $migratedNames) {
    $jobs = $allJobs | Where-Object { $_.RunbookName -eq $name }
    $total = $jobs.Count
    $failed = ($jobs | Where-Object Status -eq "Failed").Count
    $rate = if ($total -gt 0) { [math]::Round((($total - $failed) / $total) * 100, 1) } else { "N/A" }

    $status = if ($failed -eq 0 -and $total -gt 0) { "[OK]  " }
              elseif ($failed -gt 0) { "[WARN]" }
              else { "[----]" }

    Write-Output "$status $name — $total jobs, $failed failed, ${rate}% success"
}
```

---

## Part 3: Long-Term Alerting (Post-Migration)

### Azure Monitor Alert Rules

After migration is complete, set up persistent alerting.

#### Alert 1: Runbook Job Failures

```json
// Azure Monitor Log Analytics query (KQL)
// Fires when any Automation job fails with an auth-related error

AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobStreams"
| where StreamType_s == "Error"
| where ResultDescription has_any ("401", "403", "Unauthorized", "Forbidden",
    "Managed Identity", "token", "AADSTS")
| summarize FailureCount = count() by RunbookName_s, bin(TimeGenerated, 1h)
| where FailureCount > 0
```

**Setup:**
1. Azure Portal > Automation Account > **Diagnostic settings** > Add:
   - Send to Log Analytics workspace
   - Enable: `JobLogs`, `JobStreams`
2. Log Analytics workspace > **Alerts** > New alert rule
3. Use the KQL query above
4. Condition: Greater than 0
5. Action group: Email/Teams notification to operations team

#### Alert 2: Managed Identity Permission Errors

```
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobStreams"
| where StreamType_s == "Error"
| where ResultDescription has_any ("Insufficient privileges", "Authorization_RequestDenied",
    "Access is denied", "does not have authorization")
| summarize FailureCount = count() by RunbookName_s, bin(TimeGenerated, 1h)
| where FailureCount > 0
```

#### Alert 3: Key Vault Access Failures

```
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where ResultSignature == "Forbidden" or httpStatusCode_d == 403
| summarize FailureCount = count() by CallerIPAddress, OperationName, bin(TimeGenerated, 1h)
| where FailureCount > 0
```

#### Alert 4: Runbook Duration Anomaly

Detect runbooks taking significantly longer than usual (could indicate token refresh loops):

```
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobLogs"
| where ResultType == "Completed"
| extend Duration = datetime_diff('second', EndTime_t, StartTime_t)
| summarize AvgDuration = avg(Duration), MaxDuration = max(Duration) by RunbookName_s
| join kind=inner (
    AzureDiagnostics
    | where ResourceProvider == "MICROSOFT.AUTOMATION"
    | where Category == "JobLogs"
    | where ResultType == "Completed"
    | where TimeGenerated > ago(24h)
    | extend Duration = datetime_diff('second', EndTime_t, StartTime_t)
    | summarize RecentMax = max(Duration) by RunbookName_s
) on RunbookName_s
| where RecentMax > AvgDuration * 3
```

### Log Analytics Workbook (Optional Dashboard)

Create a workbook in Azure Monitor with these tiles:

1. **Job Success Rate** — Pie chart: Completed vs Failed vs Suspended (last 7 days)
2. **Failures by Runbook** — Bar chart: Top 10 failing runbooks
3. **Auth Error Trend** — Line chart: Auth-related errors over time
4. **Key Vault Operations** — Table: Recent KV access with caller identity
5. **Migration Progress** — Manual text tile or linked to migration-queue.csv

---

## Part 4: Operational Runbook (Post-Migration)

After Phase 4, document the operational posture:

### Routine Tasks

| Task | Frequency | How |
|------|-----------|-----|
| Check Automation job failures | Daily (automated alert) | Alert rule fires → investigate |
| Review Key Vault audit logs | Weekly | Log Analytics query |
| Verify module versions | Monthly | Run version check script on runtime env |
| Rotate certificates (if cert auth used) | Before expiry (Key Vault alerts) | Replace cert in KV; update app registration |
| Review MI permissions | Quarterly | Run `Scan-Permissions.ps1` against current runbooks |
| Update module versions | Quarterly | Test in staging runtime env first |

### Incident Escalation Path

```
Runbook failure detected
  ↓
Is it an auth error (401/403)?
  ├── YES → Check MI status → Check permissions → See ROLLBACK-PLAYBOOK.md
  └── NO → Check runbook logic → Check module versions → Normal debugging
```

### Key Contacts

| Role | Name | Contact |
|------|------|---------|
| Automation Account Owner | _________ | _________ |
| Entra ID Admin (for permissions) | _________ | _________ |
| Key Vault Admin | _________ | _________ |
| On-call Operations | _________ | _________ |
