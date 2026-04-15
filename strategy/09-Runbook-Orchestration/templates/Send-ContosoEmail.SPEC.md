# Send-ContosoEmail Runbook — Spec

**Type:** Shared child runbook (called by other runbooks)
**Runtime:** PowerShell 7.4
**Auth:** System-Assigned Managed Identity → Microsoft Graph
**Module:** `Contoso.Automation.Auth` (uses `Connect-ContosoGraph`)

## Purpose

Single source of truth for sending email from any Azure Automation runbook.
Parents call it inline and receive a structured reply — no parent ever touches
Graph `sendMail` directly.

## Call pattern (from a parent runbook)

```powershell
$result = .\Send-ContosoEmail.ps1 `
    -To        'ops@contoso.com' `
    -Subject   'Nightly SPO report' `
    -Body      $htmlBody `
    -BodyType  'HTML' `
    -From      'automation@contoso.com'

if (-not $result.Success) {
    throw "Email failed: $($result.Error)"
}
```

## Parameters

| Name          | Type        | Mandatory | Notes |
|---------------|-------------|-----------|-------|
| `To`          | string[]    | Yes       | One or more recipients. |
| `Subject`     | string      | Yes       | Max 255 chars (truncate with warning). |
| `Body`        | string      | Yes       | Plain text or HTML per `BodyType`. |
| `BodyType`    | string      | No        | `Text` (default) or `HTML`. ValidateSet. |
| `From`        | string      | Yes       | Must be a licensed mailbox MI has `Mail.Send` over. |
| `Cc`          | string[]    | No        | |
| `Bcc`         | string[]    | No        | |
| `Attachments` | hashtable[] | No        | `@{ Name='x.csv'; ContentBytes=[byte[]]; ContentType='text/csv' }` |
| `Importance`  | string      | No        | `Low` \| `Normal` (default) \| `High`. |
| `SaveToSentItems` | bool    | No        | Default `$false` (service account hygiene). |
| `CorrelationId` | string    | No        | Parent passes its job/correlation id for log stitching. |

## Return contract (single `[pscustomobject]`)

```powershell
[pscustomobject]@{
    Success        = $true/$false
    MessageId      = '<graph internet message id, or $null>'
    Recipients     = @('a@x','b@y')
    Error          = $null  # or exception message
    ErrorCategory  = $null  # 'Auth','Permission','Throttle','Validation','Transient','Unknown'
    DurationMs     = 742
    CorrelationId  = '<pass-through>'
}
```

**Why an object, not throw:** parents decide whether email failure is fatal
(alert runbook = fatal) or non-fatal (report runbook = log and continue).

## Behavior

1. `Connect-ContosoGraph` via Managed Identity. Scope: `Mail.Send`.
2. Validate params: at least one recipient, subject non-empty, `From` not empty.
3. Build Graph `/users/{from}/sendMail` payload.
4. Wrap the call with `Invoke-ContosoWithRetry` (already in module):
   - Retry: 429, 503, 504, transient socket errors.
   - **Do NOT retry:** 401/403 (fail-fast per project rule).
5. Classify the error into `ErrorCategory` before returning.
6. `finally { Disconnect-ContosoAll }` — even when called inline, cleanup keeps
   the parent's auth context clean. (Parent reconnects its own services.)

### Auth-context caveat (important)

Because this child calls `Disconnect-ContosoAll`, the parent runbook must
**call its own `Connect-Contoso*` after** invoking Send-ContosoEmail if it
needs Graph/SPO/EXO again. Two options:

- **A (simple, default):** child disconnects; parent reconnects as needed.
- **B (optional flag):** add `-KeepAuthContext` switch that skips the
  disconnect. Document clearly that parent owns cleanup in that case.

Recommend starting with A; add B only if measured reconnect cost is real.

## Required permissions (grant to Automation Account's MI, once)

| API              | Permission          | Type        |
|------------------|---------------------|-------------|
| Microsoft Graph  | `Mail.Send`         | Application |

Grant via:

```powershell
# In scripts/setup/ — add to existing MI permission grant script
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$mailSend = $graphSp.AppRoles | Where-Object { $_.Value -eq 'Mail.Send' }
New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $automationAccountMiObjectId `
    -PrincipalId $automationAccountMiObjectId `
    -ResourceId $graphSp.Id `
    -AppRoleId $mailSend.Id
```

**Scope risk:** `Mail.Send` (application) lets the MI send as *any* mailbox.
If you need to lock this down, use **application access policy**
(`New-ApplicationAccessPolicy`) to restrict the MI to a specific mail-enabled
security group containing only `automation@contoso.com`. Document this in the
runbook header.

## Packaging & deployment

- File: `runbooks/testing/Send-ContosoEmail.ps1` after migration QA.
- **Published as a runbook** in the Automation Account (not a module).
- Child runbooks called inline (`.\Name.ps1`) must be **published**, not draft.
- Add to `governance/checklists/` with its own per-script checklist since it
  gates every other runbook that sends mail.

## Migration impact on existing runbooks

For each existing runbook that sends email (likely uses `Send-MailMessage` or
EXO `Send-MailMessage` equivalents):

1. Strip the email logic.
2. Replace with `.\Send-ContosoEmail.ps1 -To ... -Subject ... -Body ...`.
3. Remove any SMTP credential / EXO connection used *only* for email.
4. Log the returned `MessageId` for audit.

Track candidate runbooks by grepping `scan-results.csv` for `Send-MailMessage`
and SMTP patterns — add a scanner rule if it's not already flagged.

## Open questions for the human

1. **Sending identity:** one shared `automation@contoso.com` mailbox, or
   per-runbook service identities? Affects the access-policy scope.
2. **Attachment size ceiling:** Graph `sendMail` caps at ~4 MB inline; larger
   requires upload session. In-scope for v1 or defer?
3. **Bounce/NDR handling:** does the caller need to know about deferred
   delivery failures, or is fire-and-forget acceptable?
4. **PS 5.1 fallback:** any parents that will remain on 5.1 and need to call
   this? (Inline calls across runtimes are brittle.)

## Next steps (after you approve this spec)

1. Implement `templates/Send-ContosoEmail.ps1` from the `RunbookTemplate.ps1`
   shell.
2. Add `Mail.Send` grant to the MI provisioning script in `scripts/setup/`.
3. Add a unit-ish Pester test that mocks `Invoke-MgGraphRequest` and verifies
   payload shape + error classification.
4. Add a scanner rule to flag legacy email-sending patterns for redirection.
