# Prompt — Refactor a Runbook to Use Send-ContosoEmail

Copy the block below, replacing `<RUNBOOK_FILENAME>` with the runbook you
want to refactor.

---

```
Refactor <RUNBOOK_FILENAME> to stop sending email inline and instead call
the shared Send-ContosoEmail runbook.

Source file:       runbooks/source/<RUNBOOK_FILENAME>
Working copy:      runbooks/staging/<RUNBOOK_FILENAME>
Shared runbook:    Send-ContosoEmail  (already published in the Automation Account)
Shared spec:       strategy/09-Runbook-Orchestration/templates/Send-ContosoEmail.SPEC.md

What to change:
  1. Find every call to Send-MailMessage, System.Net.Mail, Send-PnPMail, or
     direct Graph sendMail invocations.
  2. Replace each with:
        $email = .\Send-ContosoEmail.ps1 `
            -To       <recipients> `
            -Subject  <subject> `
            -Body     <body> `
            -BodyType <'Text' or 'HTML' per original> `
            -From     <sending address>
        if (-not $email.Success) {
            Write-Warning "Email send failed: $($email.Error) (category=$($email.ErrorCategory))"
            # If email was critical to this runbook's purpose, throw instead.
        }
  3. Remove now-unused SMTP credentials, Get-AutomationPSCredential calls,
     SMTP server variables, and port/SSL settings.
  4. Remove `Import-Module` lines for email-only modules
     (e.g. MailKit, System.Net.Mail wrappers).
  5. Preserve all OTHER business logic. Do not rewrite unrelated code.

Judgment calls you may make:
  - If the original silently swallowed email failures, continue to do so
    (just log a warning). If it threw, continue to throw.
  - If the original built an HTML body from data, keep that logic — only
    the transmission step changes.
  - If the original sent attachments, populate the -Attachments parameter
    per the spec's hashtable format.

Do NOT:
  - Change the runbook's parameter signature.
  - Restructure unrelated auth or business logic.
  - Publish the result to Azure.

When done, run the validator:
  agent/skills/validate-runbook.ps1 -Path runbooks/staging/<RUNBOOK_FILENAME>

Then report:
  - How many email call sites were replaced.
  - Any lines you removed that weren't email-related but were no longer
    reachable.
  - Anything about the original that surprised you (so we can adjust the
    shared runbook if a pattern is common).
```

---

## Finding candidates

```powershell
Select-String -Path runbooks\source\*.ps1 -Pattern 'Send-MailMessage|System\.Net\.Mail|Send-PnPMail|sendMail' |
    Select-Object Filename, LineNumber, Line -Unique
```
