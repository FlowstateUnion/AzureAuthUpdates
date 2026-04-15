# Prompt — Extend the Monitoring Toolkit

The starter scripts in `strategy/10-Monitoring-And-Observability/scripts/`
cover the common questions. When you need more (additional queries, a
dashboard export, a cross-account rollup), use this prompt to add to the
toolkit rather than building one-off ad-hoc scripts.

Copy the block below, filling in the two placeholders.

---

```
Add a new monitoring capability to our Automation Account toolkit.

Capability to add:    <describe, e.g. "Export weekly runbook-failure heatmap
                       as HTML suitable for emailing to ops">
Lives in:             strategy/10-Monitoring-And-Observability/scripts/

Requirements:
  1. New script file named with Verb-ContosoNoun convention
     (e.g. Export-ContosoFailureHeatmap.ps1). Use the existing scripts in
     that folder as the style reference (param block, comment-based help,
     Layer 1 / Layer 2 selection pattern).
  2. Default to Layer 2 (KQL against Log Analytics) when -WorkspaceId is
     provided; fall back to Layer 1 (Az.Automation cmdlets) with a
     warning when it isn't. If the capability is impossible via Layer 1,
     make -WorkspaceId mandatory and explain why in the help.
  3. Emit objects (return them, don't just Format-Table them) so the
     script can be piped into Export-Csv, ConvertTo-Html, etc.
  4. Never hardcode tenant/subscription/workspace IDs. Take them as
     parameters.
  5. Comment-based help must include .SYNOPSIS, .DESCRIPTION, at least
     two .EXAMPLE blocks (Layer 2 and Layer 1 if both are supported).

Also update:
  - strategy/10-Monitoring-And-Observability/README.md — add a row to the
    "What's inside" table.
  - strategy/10-Monitoring-And-Observability/02-Implementation-Instructions.md
    — add a step or example that shows how to invoke the new script.

Do NOT:
  - Modify the existing scripts unless they have a bug that blocks the
    new capability. If they do, flag it; don't silently refactor.
  - Add heavyweight dependencies (new modules) without flagging it.
  - Schedule the script as a runbook yourself — that's prompt 03's job.

When done, run the script in dry-run mode if possible and paste its
output. Then stop.
```
