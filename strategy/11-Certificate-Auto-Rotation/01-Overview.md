# Certificate Auto-Rotation — Overview

## How Key Vault actually stores a certificate

A KV "certificate" is three linked objects stored under a single name:

| Object | Endpoint | Contains |
|---|---|---|
| **Certificate** | `Get-AzKeyVaultCertificate` | Metadata + public key (`.cer`) |
| **Key** | `Get-AzKeyVaultKey` | The private key (non-exportable handle) |
| **Secret** | `Get-AzKeyVaultSecret` | The full PFX/PEM bundle — private key **included** |

The critical insight: **the secret version of the cert is the full PFX**.
That is what you pass to `-CertificateBase64Encoded` at runtime. Most
people miss this because the three objects share the same name and the
portal shows them under "Certificates".

When Key Vault auto-renews a cert, all three versions advance together.
Pulling by name (no version) always returns "current" — which means
runbooks that read it at connect time pick up the new cert automatically.

## Approach A — `-CertificateBase64Encoded` at runtime

### PS 7+ (target runtime)

```powershell
Connect-AzAccount -Identity                          # MI gets us into Azure

$secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $CertName
$base64 = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText

Connect-PnPOnline -Url $SiteUrl `
    -ClientId $ClientId `
    -Tenant  "$TenantName.onmicrosoft.com" `
    -CertificateBase64Encoded $base64
```

### PS 5.1 (documented exceptions only)

`ConvertFrom-SecureString -AsPlainText` is PS 7+. On 5.1, extract via
marshalled BSTR and *zero-free it immediately*:

```powershell
$secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $CertName
$ptr    = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret.SecretValue)
try {
    $base64 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    Connect-PnPOnline -Url $SiteUrl -ClientId $ClientId `
        -Tenant "$TenantName.onmicrosoft.com" `
        -CertificateBase64Encoded $base64
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    Remove-Variable base64 -ErrorAction SilentlyContinue
}
```

`Get-CertificateFromKeyVault.ps1` in this folder wraps both branches.

### Which services accept a base64 cert today

| Cmdlet | Parameter | Notes |
|---|---|---|
| `Connect-PnPOnline` | `-CertificateBase64Encoded` | Preferred path. Works in Automation sandbox. |
| `Connect-MgGraph` | `-Certificate` (X509Certificate2 object) | Convert base64 → `X509Certificate2` in memory (see below). |
| `Connect-ExchangeOnline` | `-Certificate` (X509Certificate2) | Same — pass object, not thumbprint. |
| `Connect-AzAccount` (SPN) | `-CertificateThumbprint` only | Use MI for Azure instead. Do not cert-auth to Azure itself if you can help it. |

Build the in-memory cert for Graph/EXO:

```powershell
$bytes = [Convert]::FromBase64String($base64)
$cert  = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 `
            ($bytes, [string]::Empty,
             [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
```

`EphemeralKeySet` keeps the private key in memory only — no writes to the
sandbox disk/cert store. Safer for PS 7 Azure Automation workers.

### What this approach solves

- Cert does not need to be in the local machine cert store.
- No thumbprint variable to update on renewal.
- When KV auto-renews, the next runbook run picks up the new cert — no
  code deployment, no schedule change.

### What it does NOT solve

- The **public key** still has to be trusted by the App Registration. If
  you renew the cert, the Entra side must accept the new public key *or*
  already have it on the allow list. That is what Approach B handles.

## Approach B — Event-driven App Registration sync

Key Vault fires these Event Grid events on certificates:

| Event type | When |
|---|---|
| `Microsoft.KeyVault.CertificateNearExpiry` | 30 days before expiration (configurable on the cert policy). |
| `Microsoft.KeyVault.CertificateExpired` | On expiration. |
| `Microsoft.KeyVault.CertificateNewVersionCreated` | Whenever a new version is created — including KV auto-renewal. |

The trigger we care about is `CertificateNewVersionCreated`. Wire it to a
webhook-triggered runbook that does three things:

1. **Fetch** the new cert's public key from KV
   (`Get-AzKeyVaultCertificate` → `.Cer`).
2. **Upload** it to the App Registration as a new `keyCredential` via
   Microsoft Graph (`Add-MgApplicationKeyCredential` or POST
   `/applications/{id}/addKey`).
3. **Prune** expired `keyCredentials` from the same App Registration
   (`Remove-MgApplicationKeyCredential` / `removeKey`).

### Event payload shape (Resource-specific mode)

```json
{
  "id": "...",
  "type": "Microsoft.KeyVault.CertificateNewVersionCreated",
  "subject": "SPOCert",
  "data": {
    "Id":        "https://contoso-kv.vault.azure.net/certificates/SPOCert/<ver>",
    "VaultName": "contoso-kv",
    "ObjectName": "SPOCert",
    "Version":   "<ver>",
    "NBF": <epoch>,
    "EXP": <epoch>
  },
  "eventTime": "2026-...Z"
}
```

The runbook binds `$VaultName`, `$CertName` (=`ObjectName`), and `$Version`
from `WebhookData.RequestBody` (JSON). See the spec in
`templates/Sync-AppRegCertificate.RUNBOOK.md`.

### Graph API contract

The modern call is [`applications: addKey`](https://learn.microsoft.com/graph/api/application-addkey)
which requires a short-lived proof-of-possession JWT signed with the
*existing* cert. That works when the same app already has the current
cert. For a first-time rollout, use a patch of the `keyCredentials`
collection with application-level permission instead — one-time, human-run.

Required Graph permissions:

| Scenario | App role |
|---|---|
| Runbook MI updates only App Registrations it owns | `Application.ReadWrite.OwnedBy` (least privilege — **preferred**) |
| Runbook MI updates any app registration | `Application.ReadWrite.All` (avoid — breaks least privilege) |

To use `OwnedBy`, the MI's service principal must be listed as an **owner**
of each target App Registration. Do that once in setup; after that, the MI
can rotate that app's certs forever with the lesser permission.

### Why auto-upload and prune matter together

If you only upload, `keyCredentials` grows without bound and eventually
hits the Entra cap (≈150 keys per app). Prune expired keys on every run.
Never prune the *current* key — match by `keyId` of the version you just
added.

## PS 5.1 vs 7.x checklist

| Concern | PS 5.1 | PS 7.4 |
|---|---|---|
| `ConvertFrom-SecureString -AsPlainText` | Not supported — use BSTR marshalling | Supported |
| `X509Certificate2` ephemeral flag | Supported | Supported |
| `Microsoft.Graph.Applications` module | Loads but slower; check runtime env has it pinned | Preferred |
| Webhook-triggered runbook | Supported | Supported |

## Sticking points to plan for

1. **Cert policy governs auto-renewal.** A cert in KV is only auto-renewed
   if it has a policy with `AutoRenewAtPercentageLifetime` (or
   `AutoRenewAtNumberOfDaysBeforeExpiry`) set. Import-only certs have no
   policy and will not renew.
2. **Event Grid permissions are fiddly.** The system topic on the vault
   needs to exist (auto-created on first subscription in most tenants,
   but not always). The subscriber webhook must accept the CloudEvents or
   EventGrid validation handshake — Automation webhook URLs already do.
3. **Webhook URLs are secrets.** They embed a SAS token. Store the URL in
   KV, not in source. If leaked, delete and regenerate.
4. **Overlap window.** Keep the *previous* `keyCredential` on the App
   Registration for ≥1 hour after upload, so in-flight runbooks holding
   the old cert don't get rejected mid-run. Prune by `endDateTime < now`,
   never by "second newest".
5. **Tenant-wide cert policies.** Some orgs reject self-signed certs
   added via Graph. If your Entra has `Certificate-based authentication
   policy` enforcement, align the KV issuer with it before turning on
   auto-sync.
