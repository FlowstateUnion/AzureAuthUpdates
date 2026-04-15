# Prompt — Enable Log Analytics Diagnostics for the Automation Account

Copy the block below into a Claude Code session, filling in the two
placeholders.

---

```
Enable Log Analytics diagnostics on our Automation Account so that Layer 2
(KQL) monitoring works.

Automation Account:   <name>
Resource group:       <rg>
Workspace:            <workspace resource ID, or "create new" if we don't have one>

Steps to take:
  1. Run strategy/10-Monitoring-And-Observability/scripts/Test-DiagnosticSettings.ps1
     to confirm the current state. If it already reports READY, stop and
     report that — no action needed.

  2. If a workspace resource ID was provided: attach a diagnostic setting
     to the Automation Account that sends BOTH JobLogs and JobStreams to
     it, in resource-specific (Dedicated) mode. Name the setting 'aa-to-la'.

  3. If no workspace was provided: stop and ask the human whether to use
     an existing workspace (give them Get-AzOperationalInsightsWorkspace
     output to pick from) or create a new one. Do not create a workspace
     unsupervised — cost and retention decisions are involved.

  4. After the diagnostic setting is created, wait 60 seconds, then rerun
     Test-DiagnosticSettings.ps1 and confirm it reports READY with
     Dedicated = True.

  5. Report:
       - The workspace ID to use for the other monitoring scripts.
       - An estimate of ingestion lag (usually 5–15 minutes for first data).
       - A note for the human: verify retention settings on the workspace
         match the team's budget and compliance needs.

Do NOT:
  - Modify any other diagnostic settings on the subscription.
  - Change workspace retention unless explicitly asked.
  - Apply the same setting to other Automation Accounts — this is a
    per-AA operation.
```

---

## Role requirements

The account running this needs `Monitoring Contributor` (or `Contributor`)
on the Automation Account's resource group and at least `Log Analytics
Contributor` on the target workspace.
