# 09 — Runbook Orchestration

## Goals

Turn cross-cutting capabilities (email, logging, notifications, ticket creation)
into **shared child runbooks** that any other runbook can call with a few lines.

- **One source of truth per capability.** Fix a bug once, every caller benefits.
- **Consistent auth.** Children authenticate via Managed Identity using the
  `Contoso.Automation.Auth` module — callers don't touch Graph/SMTP directly.
- **Simple request/response.** Parents call children inline and receive a
  structured object (`Success`, `Error`, `MessageId`, etc.). No polling, no
  fragile string parsing.
- **Least-privilege surface.** Only the shared runbook needs the sensitive
  permission (e.g. `Mail.Send`); callers inherit the capability without
  inheriting the permission.

## What's inside

| Path | Purpose |
|---|---|
| `01-Overview.md` | Three runbook-to-runbook patterns in Azure Automation, when to use each, gotchas. |
| `02-Implementation-Instructions.md` | Step-by-step human checklist to stand up the first shared runbook (`Send-ContosoEmail`). |
| `templates/Send-ContosoEmail.SPEC.md` | Reference spec: params, return contract, permissions, behavior. |
| `scripts/Test-ChildRunbookInvocation.ps1` | Validates that inline child-runbook calls actually work in your Automation Account. |
| `scripts/Grant-GraphMailSend.ps1` | Grants `Mail.Send` (application) to the Automation Account's Managed Identity. |
| `scripts/Publish-SharedRunbook.ps1` | Imports + publishes a local `.ps1` as a runbook — the deployment step for shared children. |
| `prompts/` | Copy-paste prompts for an agent to implement, refactor callers, and add new shared runbooks. |

## First shared runbook

`Send-ContosoEmail` is the canonical example. Once it works end-to-end, the
same pattern extends to:

- `Write-ContosoAuditLog` — writes to a central Log Analytics workspace.
- `New-ContosoServiceNowTicket` — opens tickets from any runbook.
- `Send-ContosoTeamsNotification` — posts to a Teams channel via Graph.

## Prerequisites

- Phase 0 infrastructure is done (MI provisioned, Key Vault available).
- `Contoso.Automation.Auth` module is imported into the Automation Account.
- PowerShell 7.4 runtime environment is set as the default.
