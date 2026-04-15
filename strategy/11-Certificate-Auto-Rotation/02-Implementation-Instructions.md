# Implementation Instructions — Certificate Auto-Rotation

Audience: human operator with permission to:

- Manage the Automation Account and its Managed Identity.
- Grant RBAC on the Key Vault.
- Consent Microsoft Graph app roles (`Cloud Application Administrator` is enough).
- Add an owner to each target App Registration.

---

## Step 0 — Set session variables

```powershell
$env:AA_RG         = '<automation-account-rg>'
$env:AA_NAME       = '<automation-account>'
$env:KV_NAME       = '<key-vault>'
$env:CERT_NAME     = '<cert-name-in-kv>'          # e.g. SPOCert
$env:APP_OBJECT_ID = '<app-reg-object-id>'        # the target App Registration
$env:TENANT_ID     = '<tenant-guid>'

Connect-AzAccount
Connect-MgGraph -Scopes 'Application.ReadWrite.All','Directory.Read.All'
```

Install modules (once):

```powershell
Install-Module Az.Accounts, Az.KeyVault, Az.Resources, Az.Automation,
               Microsoft.Graph.Applications -Scope CurrentUser
```

---

## Step 1 — Inventory current thumbprint usage

Find every runbook that still looks up certs by thumbprint:

```powershell
cd D:\DevProjects\AzureAuthUpdates
Select-String -Path .\runbooks\source\*.ps1 `
    -Pattern 'CertificateThumbprint|CertThumbprint|-Thumbprint ' |
    Select-Object Filename, LineNumber, Line |
    Format-Table -AutoSize
```

Cross-reference against the migration scanner output if available
(`agent/scan-results.csv`). The list here is what will change to the
base64 pattern in Step 2.

---

## Step 2 — Adopt the base64 pattern in the shared auth module

The canonical place is `modules/Contoso.Automation.Auth/`. Add:

- A new parameter set on `Connect-ContosoPnP` (and any EXO/Graph wrappers)
  that accepts `-VaultName -CertName` instead of `-CertThumbprint`.
- An internal helper `Get-ContosoAuthCertificateFromKeyVault` that returns
  a base64 string on PS 7+ and an `X509Certificate2` on PS 5.1 (see
  `scripts/Get-CertificateFromKeyVault.ps1` for the reference body).
- Backward compatibility: if `-CertThumbprint` is passed, keep the old
  behavior — do not break existing callers in one go.

The agent prompt `prompts/01-adopt-base64-cert-pattern.md` drives this
refactor with the exact file locations and tests.

Bump the module manifest minor version (`1.1` → `1.2`) so any pinned
runbooks opt in deliberately.

---

## Step 3 — Verify the Key Vault cert has an auto-renew policy

```powershell
.\strategy\11-Certificate-Auto-Rotation\scripts\Test-CertRotationReadiness.ps1 `
    -VaultName       $env:KV_NAME `
    -CertName        $env:CERT_NAME `
    -AutomationAccountRG   $env:AA_RG `
    -AutomationAccountName $env:AA_NAME `
    -AppRegistrationObjectId $env:APP_OBJECT_ID
```

The script reports six rows; every one must be **Pass** before Step 4:

| Check | What a Pass looks like |
|---|---|
| Cert exists in KV | `Present` with a current version |
| Auto-renew policy | `AutoRenewAtPercentageLifetime` or days-before-expiry set |
| MI can read the secret | `Key Vault Secrets User` on the vault (or access policy equiv) |
| MI is an owner of the App Reg | Graph `owners` collection on the app includes the MI SP object ID |
| MI has Graph app role | `Application.ReadWrite.OwnedBy` granted and admin-consented |
| Automation Account has modules | `Az.KeyVault`, `Microsoft.Graph.Applications` present in the runtime env |

If auto-renew is missing, set it on the cert policy:

```powershell
$policy = Get-AzKeyVaultCertificatePolicy -VaultName $env:KV_NAME -Name $env:CERT_NAME
$policy.RenewAtPercentageLifetime = 80     # renew at 80% through the lifetime
Set-AzKeyVaultCertificatePolicy -VaultName $env:KV_NAME -Name $env:CERT_NAME -InputObject $policy
```

---

## Step 4 — Publish the sync runbook

Use the spec in `templates/Sync-AppRegCertificate.RUNBOOK.md` and the
agent prompt `prompts/03-sync-cert-to-app-registration.md`. The runbook:

- Is webhook-triggered (receives `WebhookData` from Event Grid).
- Parses the KV event payload (`VaultName`, `ObjectName`, `Version`).
- Authenticates with `Connect-AzAccount -Identity` and
  `Connect-MgGraph -Identity`.
- Calls `Sync-CertToAppRegistration.ps1` logic (can dot-source the script
  in this folder, or inline it if you prefer a self-contained runbook).

Publish it to the Automation Account and create a webhook:

```powershell
$wh = New-AzAutomationWebhook -Name 'sync-cert-to-app-reg' `
    -ResourceGroupName $env:AA_RG -AutomationAccountName $env:AA_NAME `
    -RunbookName 'Sync-AppRegCertificate' `
    -IsEnabled $true `
    -ExpiryTime (Get-Date).AddYears(2) -Force

# CAPTURE $wh.WebhookURI NOW. It is only returned on creation.
$wh.WebhookURI | Set-Clipboard   # or write to a temp file you can paste into KV
```

Store the webhook URL as a Key Vault secret so the next step can reference
it without secrets in source:

```powershell
Set-AzKeyVaultSecret -VaultName $env:KV_NAME -Name 'AA-SyncCertWebhook' `
    -SecretValue (ConvertTo-SecureString $wh.WebhookURI -AsPlainText -Force)
```

---

## Step 5 — Wire Event Grid from Key Vault to the runbook webhook

```powershell
$kv  = Get-AzKeyVault -VaultName $env:KV_NAME
$wh  = (Get-AzKeyVaultSecret -VaultName $env:KV_NAME -Name 'AA-SyncCertWebhook' -AsPlainText)

New-AzEventGridSubscription `
    -ResourceId  $kv.ResourceId `
    -EventSubscriptionName "$($env:CERT_NAME)-to-aa-sync" `
    -Endpoint    $wh `
    -EndpointType 'webhook' `
    -IncludedEventType 'Microsoft.KeyVault.CertificateNewVersionCreated' `
    -SubjectBeginsWith  $env:CERT_NAME          # scope to this cert only
```

If your tenant requires CloudEvents v1 schema, add `-DeliverySchema
CloudEventSchemaV1_0`. Azure Automation webhooks accept both.

Verify the subscription:

```powershell
Get-AzEventGridSubscription -ResourceId $kv.ResourceId |
    Where-Object EventSubscriptionName -like '*-to-aa-sync' |
    Select EventSubscriptionName, Filter, ProvisioningState, Destination
```

`ProvisioningState` must be `Succeeded`.

---

## Step 6 — End-to-end test

### Safer: force a new version without replacing the active cert

```powershell
# Add a new version of the SAME cert (KV creates a new version, policy stays)
Add-AzKeyVaultCertificate -VaultName $env:KV_NAME -Name $env:CERT_NAME `
    -CertificatePolicy (Get-AzKeyVaultCertificatePolicy -VaultName $env:KV_NAME -Name $env:CERT_NAME)
```

Within a minute or two, Event Grid fires `CertificateNewVersionCreated`,
the runbook fires, and the App Registration gets the new public key.

### Verify

```powershell
# New key appears in the App Reg
Get-MgApplication -ApplicationId $env:APP_OBJECT_ID |
    Select-Object -ExpandProperty KeyCredentials |
    Select DisplayName, KeyId, StartDateTime, EndDateTime

# Runbook job succeeded
Get-AzAutomationJob -ResourceGroupName $env:AA_RG `
    -AutomationAccountName $env:AA_NAME `
    -RunbookName 'Sync-AppRegCertificate' `
    -StartTime (Get-Date).AddMinutes(-10) |
    Select CreationTime, Status
```

### Functional smoke test

Trigger one of the migrated runbooks (the ones that now use the base64
pattern) and confirm it connects with the renewed cert:

```powershell
Start-AzAutomationRunbook -ResourceGroupName $env:AA_RG `
    -AutomationAccountName $env:AA_NAME -Name '<migrated-runbook>'
# then: Get-AzAutomationJobOutput ...
```

---

## Step 7 — Decommission the old flow

Once Steps 1–6 are green for a cert:

1. Remove runbook variables that hold the old thumbprint.
2. Remove the cert from the Automation Account's *Certificates* blade (if
   it was stored there).
3. Remove the cert from hybrid workers' local machine store (if any).
4. Delete any scripts/scheduled tasks that manually exported/uploaded the
   cert on renewal.

Keep Approach A rollout and Approach B rollout **decoupled** — don't
decommission the old thumbprint path until all runbooks using that cert
are migrated and one successful auto-rotation has been observed.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Runbook gets `AADSTS700027` / `Invalid client secret/certificate` after renewal | App Registration hasn't received the new public key yet | Confirm the sync runbook ran and `addKey` succeeded; give it 1–2 minutes for Entra propagation |
| `Sync-AppRegCertificate` fails with `Insufficient privileges` | MI is not an *owner* of the App Registration, or `Application.ReadWrite.OwnedBy` isn't admin-consented | Add the MI SP as an owner (`New-MgApplicationOwnerByRef`); consent the app role in Entra admin |
| Event Grid subscription `ProvisioningState = Failed` | Webhook URL expired or was regenerated without updating the subscription | Create a fresh webhook, update the secret in KV, recreate the Event Grid subscription with the new URL |
| `Get-AzKeyVaultSecret` returns empty `SecretValue` | The cert was imported with "no private key export" — the secret version is blocked | Reissue the cert in KV with an exportable policy, or ship public-key-only rotation and keep private keys manually. The base64 pattern requires exportable. |
| Runbook hits Entra keyCredentials cap (~150 keys) | Prune step isn't running | Inspect the sync runbook log; confirm `removeKey` for `endDateTime < now` executes each run |
| New cert version created but no event fires | Event Grid subscription's `SubjectBeginsWith` filter doesn't match the cert name's case | Match case exactly; subjects are case-sensitive |
| Everything works in Test Pane, fails when triggered by Event Grid | Webhook-triggered jobs have `$WebhookData` populated; Test Pane runs don't | Guard the parsing with `if ($WebhookData) { … } else { throw 'This runbook requires webhook input.' }` |
