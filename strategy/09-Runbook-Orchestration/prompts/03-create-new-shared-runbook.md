# Prompt — Design a New Shared Runbook

Use this prompt when you've identified a new cross-cutting capability worth
centralizing (audit logging, ticket creation, Teams notifications, config
lookup, etc.). The agent produces the SPEC.md first, not the code — design
before implementation.

Copy the block below, filling in the three placeholders.

---

```
Draft a spec for a new shared runbook that centralizes <CAPABILITY>.

Name it:         <Verb>-Contoso<Noun>       (e.g. Write-ContosoAuditLog)
Callers today:   <list of existing runbooks or patterns this would replace>
Output location: strategy/09-Runbook-Orchestration/templates/<Name>.SPEC.md

Model the spec on:
  strategy/09-Runbook-Orchestration/templates/Send-ContosoEmail.SPEC.md

Required sections (in this order):
  - Purpose
  - Call pattern (concrete example a parent would write)
  - Parameters (table: Name, Type, Mandatory, Notes)
  - Return contract (must include Success, Error, ErrorCategory, DurationMs,
    CorrelationId — plus capability-specific fields)
  - Behavior (numbered steps; how it authenticates, validates, calls,
    classifies errors)
  - Required permissions (what the MI needs, how to grant it, scope risk)
  - Packaging & deployment (file path, publication, governance checklist)
  - Migration impact on existing runbooks (what current code gets replaced)
  - Open questions for the human

Hard rules:
  - Uses Contoso.Automation.Auth for authentication — no direct
    Connect-MgGraph / Connect-ExchangeOnline / etc.
  - Returns an object, never throws to the parent, so parents choose fatal
    vs non-fatal.
  - Wraps retryable calls with Invoke-ContosoWithRetry.
  - Does NOT retry 401/403 (auth denials fail fast, per project policy).
  - Cleans up with Disconnect-ContosoAll in a finally block.
  - PowerShell 7.4 target runtime.

Do not write the .ps1 yet. This is spec-first. After the human reviews and
answers the open questions, a separate prompt (01-implement-*.md modeled
after the email one) will produce the code.

When done, list:
  - Which existing runbooks this would simplify (from the callers you noted).
  - What permissions the MI needs that it doesn't already have.
  - The open questions you couldn't answer from context alone.
```

---

## When to use this vs. just writing the thing

Use this prompt when:
- More than one existing runbook implements the capability differently.
- The capability touches a sensitive permission (Mail.Send, directory writes,
  file system access).
- You want a written contract before code review.

Skip straight to implementation when:
- The capability is used by exactly one runbook (just keep it inline).
- It's a trivial helper (e.g. date formatting) — put it in the module instead.
