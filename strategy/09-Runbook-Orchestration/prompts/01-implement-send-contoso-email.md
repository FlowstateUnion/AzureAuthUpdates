# Prompt — Implement Send-ContosoEmail.ps1

Copy the block below into a Claude Code session in this repo.

---

```
Implement the Send-ContosoEmail shared runbook.

Source of truth for requirements:
  strategy/09-Runbook-Orchestration/templates/Send-ContosoEmail.SPEC.md

Starting shell to adapt:
  templates/RunbookTemplate.ps1

Output file:
  runbooks/staging/Send-ContosoEmail.ps1

Hard requirements (do not deviate):
  1. Parameter block matches the spec's parameter table exactly (names, types,
     Mandatory flags, ValidateSet for BodyType and Importance).
  2. Uses Import-Module Contoso.Automation.Auth and Connect-ContosoGraph for
     authentication — do NOT call Connect-MgGraph directly.
  3. Returns a single [pscustomobject] with the fields listed in the "Return
     contract" section. Use `return` — not Write-Output — so progress messages
     don't pollute the return stream. Use Write-Information for progress.
  4. Wraps the Graph call with Invoke-ContosoWithRetry. Do NOT retry 401/403.
  5. Classifies errors into the ErrorCategory values from the spec.
  6. finally { Disconnect-ContosoAll } for cleanup.
  7. PowerShell 7.4 — no 5.1-only syntax.

After writing the file, run:
  agent/skills/validate-runbook.ps1 -Path runbooks/staging/Send-ContosoEmail.ps1

If validation passes, stop and report. Do NOT publish to Azure — the human
handles that with strategy/09-Runbook-Orchestration/scripts/Publish-SharedRunbook.ps1.

If you have ambiguity about spec behavior, ask before guessing. The spec has
an "Open questions" section at the bottom — if the human hasn't answered
them, flag which answers you assumed and why.
```

---

## What to expect

- Agent reads the spec, the RunbookTemplate, and the module's exported
  functions.
- Produces a ~150–250 line runbook in `runbooks/staging/`.
- Runs the validator and reports pass/fail.
- Flags any spec questions it had to assume answers for.

## Before running

Make sure the spec's "Open questions" section is answered, otherwise the
agent will make judgment calls you may not want.
