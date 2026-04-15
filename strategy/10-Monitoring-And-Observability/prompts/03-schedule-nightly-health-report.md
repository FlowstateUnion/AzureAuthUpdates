# Prompt — Package Monitoring as a Nightly Self-Monitoring Runbook

Once the shared `Send-ContosoEmail` runbook is in place and Log Analytics
diagnostics are wired up, the Automation Account can monitor itself and
email a nightly health report.

Copy the block below, filling in the two placeholders.

---

```
Build a new runbook, Get-ContosoAutomationHealth, that runs nightly inside
the Automation Account, summarizes the past 24 hours of runbook activity,
and emails the result to ops.

Output file:          runbooks/staging/Get-ContosoAutomationHealth.ps1
Starting template:    templates/RunbookTemplate.ps1
Reference scripts:    strategy/10-Monitoring-And-Observability/scripts/
                        (Get-RunbookJobSummary, Find-StaleRunbooks,
                         Get-RunbookErrors)
Report recipient:     <ops distribution list>
From address:         <sending mailbox, same one Send-ContosoEmail uses>

Behavior:
  1. Authenticate via Managed Identity using Contoso.Automation.Auth.
     (Connect-ContosoAzure for Az.Automation + Az.OperationalInsights.)
  2. Resolve the Automation Account's own resource ID at runtime — the
     runbook should not be hardcoded to a single AA. Use the
     $PSPrivateMetadata.JobId plus Get-AzResource lookup, or accept
     -ResourceGroupName and -AutomationAccountName as parameters with
     sensible defaults pulled from Automation Variables.
  3. Build the report body with three sections:
       a. Yesterday's job summary (table: runbook, total, failed, avg duration)
       b. Top 10 error signatures from the last 24h (from Layer 2 if
          workspace is available)
       c. Any newly-stale runbooks (no runs in 90 days, not previously
          flagged — track "previously flagged" via an Automation Variable
          named 'StaleRunbookLastReport')
  4. Render as HTML. Include a timestamp and the AA name in the subject.
  5. Send via:
        $email = .\Send-ContosoEmail.ps1 -To $recipients -Subject $subj `
            -Body $html -BodyType HTML -From $from
        if (-not $email.Success) { throw $email.Error }
  6. Return a summary object (Success, ItemsInReport, EmailMessageId).
  7. Cleanup in finally with Disconnect-ContosoAll.

Schedule (human does this after publishing):
  - Daily at 06:00 local (or the team's preferred time).
  - No retry on failure — if the monitoring runbook itself fails, alert
    separately via an Azure Monitor alert on the AA itself.

Hard rules:
  - Must not depend on a workspace being present. If -WorkspaceId is empty,
    fall back to Layer 1 for the summary, skip the grouped-errors section,
    and note the limitation in the report footer.
  - Reuse the helper scripts' LOGIC but do not Invoke-Expression them —
    this runbook runs inside Azure and the .ps1 files in strategy/ are
    local-tools, not published children. Copy or adapt the logic; cite the
    source file in a comment.
  - Do NOT call Mail.Send directly. Always go through .\Send-ContosoEmail.ps1.

When done:
  1. Run agent/skills/validate-runbook.ps1 on the result.
  2. Report the line count and what fell back vs. what was fully implemented.
  3. List the Automation Variables the human needs to create before first run:
       - StaleRunbookLastReport (JSON array of names, initial value: [])
       - Any others you introduced.
```

---

## After the agent produces the runbook

1. Human publishes it via `Publish-SharedRunbook.ps1` (same deploy tool we
   use for shared children).
2. Human creates the listed Automation Variables in the portal.
3. Human creates a Daily schedule and links it to the runbook.
4. Smoke-test via the Test Pane with a small window (e.g. last 1 hour)
   before scheduling.
