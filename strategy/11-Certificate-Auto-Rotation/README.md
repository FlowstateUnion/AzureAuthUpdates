# 11 — Certificate Auto-Rotation

## Goals

Eliminate the **manual cert renewal sync** between Azure Key Vault and the
App Registration used by runbooks. Today, when a cert approaches expiry an
operator has to:

1. Generate/renew a cert in Key Vault (or externally).
2. Download the `.cer` (public key).
3. Open the App Registration in the portal and upload it under
   *Certificates & secrets*.
4. Update every runbook variable that holds the new thumbprint.
5. Hope nothing breaks at 2 AM.

The two patterns in this folder make that cycle run without a human.

## Two complementary approaches

| Approach | What changes | What it removes | What it does NOT remove |
|---|---|---|---|
| **A — `-CertificateBase64Encoded` from Key Vault at runtime** | Runbooks fetch the PFX from KV as a secret instead of looking up a thumbprint in the local cert store. | Local cert store dependency; thumbprint variables; cert-propagation-to-worker steps. | Upload of the *public* key to the App Registration. |
| **B — Event Grid → rotation runbook (Graph)** | A KV `CertificateNewVersionCreated` event triggers a runbook that uploads the new public key to the App Registration via Microsoft Graph and removes the expired one. | The App Registration upload step itself — the whole cycle is automatic. | Nothing — but needs a one-time wiring of Event Grid + webhook + permissions. |

Use **A** to make every runbook renewal-tolerant. Use **B** to make the
Entra side update itself. Together, auto-renewing KV certs propagate to
both sides with no human in the loop.

## What's inside

| Path | Purpose |
|---|---|
| `01-Overview.md` | How Key Vault stores certs (cert/key/secret triad), the base64 pattern, Event Grid event shapes, PS 5.1 vs 7.x caveats, and what each approach *cannot* do. |
| `02-Implementation-Instructions.md` | Step-by-step: assess current thumbprint usage → adopt base64 pattern → enable KV auto-renewal → provision the sync runbook → wire Event Grid → end-to-end test. |
| `scripts/Test-CertRotationReadiness.ps1` | Pre-flight check — does the KV cert have an auto-renew policy, can the runbook MI read it as a secret, does the MI have `Application.ReadWrite.OwnedBy` on Graph? |
| `scripts/Get-CertificateFromKeyVault.ps1` | Returns the current cert version as a base64 PFX string. Works on PS 5.1 and PS 7+. Designed to be dot-sourced from runbooks or imported into the shared auth module. |
| `scripts/Sync-CertToAppRegistration.ps1` | Given an App Registration and a KV cert, uploads the current public key as a new `keyCredential` via Microsoft Graph and optionally removes expired ones. |
| `prompts/` | Agent prompts: (1) refactor `Contoso.Automation.Auth` to accept base64, (2) build the rotation runbook, (3) wire KV Event Grid to that runbook. |
| `templates/Sync-AppRegCertificate.RUNBOOK.md` | Contract/spec for the rotation runbook so multiple agents produce the same shape. |

## Prerequisites

- `Az.Accounts`, `Az.KeyVault`, `Az.Resources` modules (local + runtime env).
- `Microsoft.Graph.Applications` module in the runtime environment running the sync.
- Runbook Managed Identity has, at minimum:
  - Key Vault RBAC `Key Vault Secrets User` on the vault (to read the PFX).
  - Microsoft Graph app role `Application.ReadWrite.OwnedBy` (to update only
    App Registrations this MI owns — avoids blanket `Application.ReadWrite.All`).
- The human running the wiring steps needs `Owner` / `User Access Administrator`
  on the Key Vault (to grant Event Grid system-topic permissions) and `Cloud
  Application Administrator` (to designate the runbook MI as an owner of the
  target App Registrations, so `OwnedBy` is sufficient).

## What this is NOT

- **Not a cert issuance policy.** Whether the cert is issued by a public CA,
  an internal CA, or self-signed via KV is an organization decision — not
  covered here.
- **Not a replacement for Managed Identity.** MI is still the preferred auth
  wherever the service supports it (see strategies 01, 02, 06). This folder
  is for the services that *only* support app+cert (SPO classic via PnP
  some tenants, EXO app-only, etc.).
- **Not a secret-rotation system.** Client secrets are out of scope — this
  project's direction is to eliminate them entirely (strategy 03).
