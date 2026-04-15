# Prompt — Build the `Sync-AppRegCertificate` runbook

Copy the block below into a Claude Code session, filling in the placeholders.

---

```
Create an Azure Automation runbook named Sync-AppRegCertificate that
handles Key Vault CertificateNewVersionCreated Event Grid events and
syncs the new public key to one (or more) Entra App Registrations.

Inputs to hard-code or accept as automation variables:
  AppRegistrationMap: a lookup table mapping a KV cert name to a list
                     of App Registration Object IDs that trust that cert.
                     Example JSON-in-AA-variable:
                     {
                       "SPOCert":  ["1111-...","2222-..."],
                       "EXOCert":  ["3333-..."]
                     }
                     Retrieve it at runtime with
                     Get-AutomationVariable -Name 'AppRegistrationMap'
                     and ConvertFrom-Json.

Spec to follow (authoritative):
  strategy/11-Certificate-Auto-Rotation/templates/Sync-AppRegCertificate.RUNBOOK.md

Behavior:

  1. Accept $WebhookData as the only parameter. If absent, throw a clear
     error — this runbook only runs via Event Grid webhook.

  2. Parse $WebhookData.RequestBody (JSON). Event Grid delivers an array
     in the default schema; iterate it. Filter to:
       - eventType == 'Microsoft.KeyVault.CertificateNewVersionCreated'
     For each matching event, pull data.VaultName and data.ObjectName.

  3. Authenticate with:
       Connect-AzAccount -Identity
       Connect-MgGraph -Identity -Scopes 'Application.ReadWrite.OwnedBy'
     Do NOT use any stored credentials.

  4. For each (vault, cert) tuple from the events, look up target App
     Registrations in the AppRegistrationMap variable. If the cert isn't
     in the map, log a warning and skip (do not fail the whole run —
     other events in the same batch may still be valid).

  5. For each target App Object ID, dot-source or inline the logic from
     strategy/11-Certificate-Auto-Rotation/scripts/Sync-CertToAppRegistration.ps1
     — add the new key, prune expired keys, never touch the key we just
     added. Capture the returned summary object per app.

  6. Emit a single structured log line per cert-app pair with:
       - VaultName, CertName, Thumbprint
       - AppObjectId
       - AddedKeyId (or 'already-present')
       - RemovedKeyIds (count)
     Use Write-Output with a PSCustomObject, not Write-Host, so the
     output ends up in JobStreams for Layer 2 monitoring.

  7. If ANY cert-app pair fails, throw after processing the rest. Do NOT
     swallow failures — the runbook must go to Failed state so Layer 2
     alerting can fire.

Delivery:
  - Place the .ps1 under runbooks/staging/ named Sync-AppRegCertificate.ps1.
  - Include full comment-based help with EXAMPLE showing a sample
     $WebhookData payload (Event Grid v1 default schema).
  - Add a pester test under runbooks/staging/tests/Sync-AppRegCertificate.Tests.ps1
     that mocks WebhookData and the three Graph cmdlets and asserts the
     filter/loop/emit behavior.

Do NOT:
  - Store the AppRegistrationMap inline in the runbook — it must be an
    Automation Variable so ops can update targets without re-publishing.
  - Use Application.ReadWrite.All. OwnedBy only.
  - Add retry-on-authorization-denial logic. 403s should fail fast
     (project rule, CLAUDE.md).
  - Log the full cert bytes, base64, or any Graph response body that
     could contain key material.
```

---

## Role requirements

The developer needs `Contributor` on the Automation Account (to publish
the runbook), ability to set Automation Variables, and the human
reviewer should confirm the MI is already an owner of every App
Registration listed in `AppRegistrationMap` (see Step 3 of
`02-Implementation-Instructions.md`).
