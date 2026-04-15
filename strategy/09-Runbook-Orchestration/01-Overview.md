# Runbook-to-Runbook Invocation Patterns

Azure Automation supports three ways for one runbook to call another. Picking
the right one depends on whether you need a reply, whether the child should
run in its own process, and how tightly parent and child should couple.

## Pattern 1 — Inline call (same process, same job)

```powershell
# Parent runbook
$result = .\Send-ContosoEmail.ps1 `
    -To 'ops@contoso.com' -Subject 'Report' -Body $body -From 'automation@contoso.com'

if (-not $result.Success) { throw $result.Error }
```

- The child runs **inside the parent's job** — same worker, same runspace.
- Variables, modules, and auth context are shared.
- The child returns data via `return` / pipeline — **easy request/response**.
- Billed as a single job.

**Requirements:**
- The child runbook must be **published** in the same Automation Account
  (draft is not callable).
- Parent and child must use the **same runtime** (don't mix PS 5.1 and PS 7.4).
- The local `.ps1` reference (`.\Name.ps1`) resolves to the runbook name —
  you can't use arbitrary paths.

**Best for:** shared utilities where the parent needs a reply (email,
logging, ticket creation, data lookup). This is the pattern for almost
everything in the Contoso library.

## Pattern 2 — `Start-AzAutomationRunbook` (async, separate job)

```powershell
$job = Start-AzAutomationRunbook `
    -ResourceGroupName $rg -AutomationAccountName $aa `
    -Name 'Long-Running-Cleanup' `
    -Parameters @{ Scope='tenant-wide'; DryRun=$false }

# Returns a job object. No reply. To get output, poll:
do {
    Start-Sleep 10
    $status = (Get-AzAutomationJob -Id $job.JobId -ResourceGroupName $rg -AutomationAccountName $aa).Status
} while ($status -in 'Queued','Running','Activating')

Get-AzAutomationJobOutput -Id $job.JobId -ResourceGroupName $rg -AutomationAccountName $aa -Stream Output
```

- Child runs as a **new job** on a (possibly different) worker.
- Parent gets a job object, **not a return value**.
- Retrieving output means polling + fetching streams — awkward for
  request/response.
- Child and parent can have **different runtimes**.
- Useful when parent must not block on a long-running child.

**Best for:** fire-and-forget, scheduling work, or orchestrators that kick
off parallel children and only care that they started.

## Pattern 3 — `Start-AutomationRunbook` (internal cmdlet)

Legacy inline-starter cmdlet that exists only inside the Automation sandbox.
Returns a job ID, not a value. Superseded by `Start-AzAutomationRunbook` for
new code.

**Best for:** nothing new. Leave it alone unless you're reading old runbooks.

## Decision matrix

| Need | Pattern |
|---|---|
| Reply / structured return | **1 (Inline)** |
| Parent should wait and react to errors | 1 |
| Long-running work, parent shouldn't block | 2 |
| Parallel fan-out, don't care about results | 2 |
| Cross-runtime call (5.1 parent → 7.4 child) | 2 |
| Pass large binary payloads | 2 (via params) or parameterize from storage |

## Gotchas

1. **Child must be published**, not draft. `Publish-SharedRunbook.ps1` in this
   folder handles that.
2. **Runtime mismatch is a silent failure mode.** A PS 7.4 parent calling a
   PS 5.1 child inline will often "work" until a cmdlet behaves differently.
   Pin runtime on both.
3. **Auth-context bleed.** If a child calls `Disconnect-ContosoAll`, the
   parent loses its connections too (Pattern 1 shares the runspace).
   Document who owns cleanup — our convention: child cleans up, parent
   reconnects anything it still needs.
4. **Parameter binding across patterns.** Pattern 2 passes `-Parameters` as
   a hashtable; Pattern 1 uses normal PS binding. Types get stringified in
   Pattern 2 — don't assume rich objects survive the boundary.
5. **Return values in Pattern 1.** If the child uses `Write-Output` at the
   top level, those objects land on the pipeline and pollute the parent's
   return stream. Wrap the actual return in `return [pscustomobject]@{...}`
   and use `Write-Verbose`/`Write-Information` for progress messages.
6. **Local testing.** Pattern 1 only works **inside** Azure Automation. You
   cannot test parent→child end-to-end on your laptop — only in the Test
   Pane or via a published run.
7. **Permission surface.** Shared runbooks inherit the Automation Account's
   MI permissions. One MI with `Mail.Send` means *any* runbook in the
   account can send mail. Use application access policies or user-assigned
   MIs to compartmentalize if needed.

## Naming convention for shared runbooks

All shared children use the **`<Verb>-Contoso<Noun>`** pattern:

- `Send-ContosoEmail`
- `Write-ContosoAuditLog`
- `New-ContosoServiceNowTicket`
- `Send-ContosoTeamsNotification`
- `Get-ContosoConfigValue`

This makes them visibly distinct from business runbooks in the Automation
Account portal and signals "safe to call from any runbook."

## Return-object convention

Every shared runbook returns a **single `[pscustomobject]`** with at least
these fields:

```powershell
[pscustomobject]@{
    Success       = $true / $false
    Error         = $null      # or exception message
    ErrorCategory = $null      # 'Auth','Permission','Throttle','Validation','Transient','Unknown'
    DurationMs    = 742
    CorrelationId = $incomingCorrelationId
    # ...capability-specific fields (MessageId, TicketNumber, etc.)
}
```

Callers use `if (-not $result.Success) { ... }`. No exceptions as the primary
error channel — the caller decides whether a failure is fatal.
