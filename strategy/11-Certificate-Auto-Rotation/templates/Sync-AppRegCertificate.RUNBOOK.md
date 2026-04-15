# Spec — `Sync-AppRegCertificate` runbook

This is the authoritative contract for the rotation runbook. Any agent
implementing the runbook (see `prompts/03-sync-cert-to-app-registration.md`)
must conform to this spec. Multiple agents producing this runbook must
produce the same observable shape.

## Trigger

- **Type:** Webhook (Event Grid subscriber).
- **Parameter:** `$WebhookData` (single parameter, untyped — the
  Automation runtime binds it).
- **Schema:** Event Grid default (array of envelopes). Must also
  tolerate CloudEvents v1 (single envelope) — detect by whether the
  parsed body is an array or a single object.
- **Not a scheduled runbook.** A scheduled variant is explicitly out of
  scope for this runbook; handle rotation only on new-version events.

## Inputs

| Source | Name | Type | Required | Notes |
|---|---|---|:-:|---|
| `$WebhookData.RequestBody` | event batch | JSON string | ✅ | Parsed to array of events. |
| Automation Variable | `AppRegistrationMap` | JSON object | ✅ | `{ "<certName>": ["<appObjectId>", ...] }` |
| Managed Identity | (system-assigned) | — | ✅ | Used for both `Connect-AzAccount -Identity` and `Connect-MgGraph -Identity`. |

No runbook *parameters* other than `$WebhookData`. No secrets on the
command line. No client IDs or tenant IDs baked in — everything comes
from the map + MI.

## Event filter

Process events where all three are true:

- `eventType == 'Microsoft.KeyVault.CertificateNewVersionCreated'`
- `data.VaultName` is non-null
- `data.ObjectName` is non-null

Silently ignore everything else. Log one `Write-Verbose` line per
ignored event with its `eventType` for debugging.

## Per-event handling

For each matching event:

1. Resolve `vault, cert = data.VaultName, data.ObjectName`.
2. Look up `apps = AppRegistrationMap[cert]`. If unset, emit a warning
   and continue to the next event (not a failure).
3. For each `appObjectId` in `apps`:
   1. Call the equivalent of `Sync-CertToAppRegistration.ps1 -VaultName
      $vault -CertName $cert -AppObjectId $appObjectId`.
   2. Capture the result PSCustomObject.
   3. `Write-Output` a structured log record (see below).

## Output contract (per cert-app pair)

```powershell
[pscustomobject]@{
    TimestampUtc   = [DateTime]::UtcNow
    VaultName      = '<vault>'
    CertName       = '<cert>'
    Thumbprint     = '<hex>'
    AppObjectId    = '<guid>'
    AddedKeyId     = '<guid or $null>'
    AlreadyPresent = [bool]
    RemovedKeyIds  = @('<guid>', ...)
    Outcome        = 'Added' | 'Skipped-Present' | 'Failed'
    Error          = '<message if Failed, else $null>'
}
```

Emit with `Write-Output` (not `Write-Host`) so the record lands in
`AutomationJobStreams` for Layer 2 KQL queries. See strategy
`10-Monitoring-And-Observability/01-Overview.md` for the table schema.

## Failure model

- Per-event failures (bad map, missing cert): warn + continue.
- Per-app failures (Graph 403, conflict, throttled): capture in
  `Error`, emit a record with `Outcome=Failed`, continue with other
  apps, but **throw at the end** of the runbook so the overall job
  state is `Failed`. This keeps partial progress visible but also
  surfaces the error for monitoring/alerting.
- 401/403 from Graph or Key Vault: fail fast **without retry** (CLAUDE.md
  project rule — do not retry auth denials).
- 429 from Graph: honor `Retry-After` header up to 3 attempts, then
  fail the app and continue.

## Idempotency

The runbook must be safe to invoke twice with the same event. The
`Sync-CertToAppRegistration.ps1` logic already checks for a pre-existing
matching key by public-key bytes and returns `AlreadyPresent=true`
without re-adding. The runbook must preserve that behavior.

## Permissions (runtime)

- MI: `Key Vault Secrets User` on the vault **is not required** for this
  runbook — it only reads the public key via `Get-AzKeyVaultCertificate`,
  which needs `Key Vault Reader` or equivalent. (Secrets User *is*
  needed by the base64 pattern in application runbooks, but not here.)
- MI: Graph app role `Application.ReadWrite.OwnedBy` (admin-consented).
- MI: listed as **owner** of every App Registration object ID in the map.

## What this runbook does NOT do

- Does not generate or issue certificates.
- Does not touch the Automation Account's own credentials (if any remain).
- Does not rotate client secrets — out of scope (see strategy 03).
- Does not notify humans on success. On failure, rely on Layer 2 KQL
  alerts against `AutomationJobLogs` where `ResultType == "Failed"` and
  `RunbookName == "Sync-AppRegCertificate"`.

## Test payload

A minimal Event Grid default-schema payload the runbook must handle:

```json
[
  {
    "id": "abc-123",
    "eventType": "Microsoft.KeyVault.CertificateNewVersionCreated",
    "subject": "SPOCert",
    "eventTime": "2026-04-15T12:00:00Z",
    "data": {
      "Id": "https://contoso-kv.vault.azure.net/certificates/SPOCert/abc",
      "VaultName": "contoso-kv",
      "ObjectName": "SPOCert",
      "Version": "abc",
      "NBF": 1774320000,
      "EXP": 1805856000
    },
    "dataVersion": "1",
    "metadataVersion": "1",
    "topic": "/subscriptions/.../providers/Microsoft.KeyVault/vaults/contoso-kv"
  }
]
```

Pester tests for the runbook must cover at minimum:

1. Valid single event → 1 record emitted, `Outcome=Added`.
2. Valid event with `AlreadyPresent` from the Sync script → 1 record
   emitted, `Outcome=Skipped-Present`.
3. Event for a cert not in the map → warning, 0 records emitted, job
   succeeds.
4. Graph 403 during sync → record emitted with `Outcome=Failed`, job
   **throws** at end.
5. CloudEvents v1 single-envelope payload → handled same as array.
