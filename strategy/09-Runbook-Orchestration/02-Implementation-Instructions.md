# Implementation Instructions — Shared Runbook Pattern

This guide walks through standing up `Send-ContosoEmail` as the first shared
child runbook. Once it's working, reuse the same steps for any future
shared runbook.

Audience: human operator with Contributor access to the Automation Account
and permission to grant Graph app roles.

---

## Step 0 — Before you start

Confirm the following:

- [ ] `Contoso.Automation.Auth` module is imported into the Automation Account.
- [ ] PowerShell 7.4 runtime environment exists and is the default.
- [ ] The Automation Account has a **System-Assigned Managed Identity** enabled
      (or a User-Assigned MI, if that's your standard).
- [ ] You have `Application Administrator` or `Global Administrator` in Entra
      ID (needed to grant Graph app roles).
- [ ] You know the Automation Account's resource group name, account name,
      and the MI's object ID.

Capture these as environment variables for the session:

```powershell
$env:AA_RG = '<resource-group>'
$env:AA_NAME = '<automation-account>'
$env:AA_MI_OBJECT_ID = '<managed-identity-object-id>'
```

---

## Step 1 — Validate the inline-call pattern works

Before writing real code, prove the pattern works in your environment.

```powershell
cd D:\DevProjects\AzureAuthUpdates\strategy\09-Runbook-Orchestration\scripts
.\Test-ChildRunbookInvocation.ps1 -ResourceGroupName $env:AA_RG -AutomationAccountName $env:AA_NAME
```

**Expected result:** script publishes a tiny parent + child pair, runs them,
and reports that the parent successfully received a structured object from
the child. If this fails, stop — nothing else in this doc will work.

**Cleanup:** the test script removes the dummy runbooks when done (or pass
`-KeepTestRunbooks` to leave them for inspection).

---

## Step 2 — Grant Mail.Send to the Managed Identity

```powershell
.\Grant-GraphMailSend.ps1 -ManagedIdentityObjectId $env:AA_MI_OBJECT_ID
```

**What it does:** assigns the `Mail.Send` (application) role on Microsoft
Graph to the Automation Account's MI.

**Scope warning:** application `Mail.Send` lets the MI send as **any mailbox**
in the tenant. If that's too broad:

1. Create a mail-enabled security group (e.g. `sg-automation-senders`).
2. Add only the mailbox(es) you'll send from (e.g. `automation@contoso.com`).
3. Run: `New-ApplicationAccessPolicy -AppId <MI-appId> -PolicyScopeGroupId sg-automation-senders -AccessRight RestrictAccess`.

Document which approach you chose in the runbook's header.

---

## Step 3 — Author `Send-ContosoEmail.ps1`

Use the spec at `templates/Send-ContosoEmail.SPEC.md` as the source of truth
for parameters, return contract, and behavior.

Two ways to produce the file:

**Option A — Have an agent do it.** Copy the prompt at
`prompts/01-implement-send-contoso-email.md` into a Claude Code session in
this repo. The agent reads the spec and produces the file.

**Option B — Write it by hand.** Start from `templates/RunbookTemplate.ps1`
at the repo root. Implement each section of the spec in order: params →
auth → validate → call Graph `/users/{from}/sendMail` → classify errors →
return the standard object.

Place the finished file at `runbooks/staging/Send-ContosoEmail.ps1`.

---

## Step 4 — Validate locally

```powershell
cd D:\DevProjects\AzureAuthUpdates
pwsh agent\skills\validate-runbook.ps1 -Path runbooks\staging\Send-ContosoEmail.ps1
```

On pass, the script promotes the file to `runbooks/testing/`.

---

## Step 5 — Publish to the Automation Account

```powershell
cd strategy\09-Runbook-Orchestration\scripts
.\Publish-SharedRunbook.ps1 `
    -ResourceGroupName $env:AA_RG `
    -AutomationAccountName $env:AA_NAME `
    -Path ..\..\..\runbooks\testing\Send-ContosoEmail.ps1 `
    -RuntimeVersion '7.4'
```

This imports and publishes the runbook.

---

## Step 6 — Smoke-test in Azure

In the Azure Portal → Automation Account → Runbooks → `Send-ContosoEmail` →
**Test Pane**, run it with real parameters to a safe recipient:

```
To:       your.address@contoso.com
Subject:  Contoso automation smoke test
Body:     This is a test.
BodyType: Text
From:     automation@contoso.com
```

Confirm:

- [ ] Job status = Completed.
- [ ] Output stream shows the return object with `Success = True` and a
      `MessageId`.
- [ ] The email actually arrived.

---

## Step 7 — Update the migration template

Edit `templates/RunbookTemplate.ps1` to add an example in the comments:

```powershell
# To send email from this runbook, call the shared Send-ContosoEmail runbook:
#   $email = .\Send-ContosoEmail.ps1 -To $to -Subject $subj -Body $body -From $from
#   if (-not $email.Success) { Write-Warning "Email failed: $($email.Error)" }
```

This signals to future authors and to the migration agent that email is a
solved problem — don't roll your own.

---

## Step 8 — Migrate existing callers

Find runbooks that send email today:

```powershell
Select-String -Path runbooks\source\*.ps1 -Pattern 'Send-MailMessage|System\.Net\.Mail|sendMail' |
    Select-Object Filename -Unique
```

For each match, use the prompt at
`prompts/02-refactor-caller-to-use-shared-email.md` to have an agent replace
the inline email code with a call to `Send-ContosoEmail`.

---

## Step 9 — Repeat for the next shared capability

When you identify the next cross-cutting capability (audit logging, ticket
creation, Teams notifications), follow the same flow:

1. Write a `<Name>.SPEC.md` in `templates/` using the Send-ContosoEmail spec
   as a model.
2. Grant any required MI permissions.
3. Author, validate, publish, smoke-test.
4. Migrate existing callers.

The prompt at `prompts/03-create-new-shared-runbook.md` is the starter for
step 1.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `The term '.\Send-ContosoEmail.ps1' is not recognized` | Child not published, or name mismatch | Re-run `Publish-SharedRunbook.ps1`; names are case-sensitive in Linux workers |
| `403 Forbidden` from Graph | `Mail.Send` not granted, or access policy blocks this `From` address | Re-run `Grant-GraphMailSend.ps1`; check `Get-ApplicationAccessPolicy` |
| Email sent but caller got no return object | Child used `Write-Output` for progress messages | Wrap returns in `return [pscustomobject]@{...}`, switch progress to `Write-Information` |
| Works in Test Pane, fails when called from parent | Published version out of date | Re-publish after every edit; draft ≠ published |
| Cross-runtime failure | Parent on 5.1, child on 7.4 (or vice versa) | Align runtime on both, or switch to Pattern 2 |
