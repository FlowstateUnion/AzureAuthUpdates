# Prompt — Wire Key Vault Event Grid to the sync runbook

Copy the block below into a Claude Code session, filling in the four
placeholders.

---

```
Wire an Azure Event Grid system-topic subscription on our Key Vault so
that CertificateNewVersionCreated events for one specific cert trigger
our Sync-AppRegCertificate runbook.

Inputs:
  Key Vault:              <vault-name>
  Cert name:              <cert-name>       (SubjectBeginsWith filter)
  Automation Account RG:  <aa-rg>
  Automation Account:     <aa-name>

Steps to take:

  1. Verify prerequisites (report and STOP if any fail):
       - Runbook 'Sync-AppRegCertificate' exists and is in 'Published' state.
       - A webhook secret named 'AA-SyncCertWebhook' exists in the Key Vault
         (it holds the webhook URL). If it's missing, stop and ask the
         human to run Step 4 of 02-Implementation-Instructions.md first —
         do NOT create a webhook unsupervised, because the URL can only
         be retrieved once.
       - The Key Vault's provider registration for Microsoft.EventGrid is
         'Registered' in the subscription (Get-AzResourceProvider).

  2. Read the webhook URL from the KV secret using the current session's
     auth (do not print the URL).

  3. Create an Event Grid subscription with:
       - Name: '<cert-name>-to-aa-sync'
       - ResourceId: the Key Vault's resource ID
       - Endpoint: the webhook URL
       - EndpointType: webhook
       - IncludedEventType: Microsoft.KeyVault.CertificateNewVersionCreated
       - SubjectBeginsWith: <cert-name>
       - If tenant policy requires it, DeliverySchema: CloudEventSchemaV1_0.
         Try the default first; fall back to CloudEventSchemaV1_0 only if
         the default is rejected.

  4. Verify:
       - Get-AzEventGridSubscription returns ProvisioningState=Succeeded.
       - A test: call Add-AzKeyVaultCertificate on the SAME cert with the
         SAME policy. This creates a new version; wait up to 3 minutes
         and confirm the runbook fired by querying
         Get-AzAutomationJob -RunbookName 'Sync-AppRegCertificate'
         -StartTime (Get-Date).AddMinutes(-5). Abort the test (do not
         force a new version) if the human asks — mention this explicitly
         before running step 4.

  5. Report:
       - Name + ResourceId of the new Event Grid subscription.
       - Whether the verification test ran and its outcome.
       - Any warnings (e.g., system topic had to be created, provider
         registration just completed, etc.).

Do NOT:
  - Print the webhook URL anywhere — it's a credential.
  - Create a new webhook. Webhook URLs are one-shot-readable; if it's
    missing, that's the human's call.
  - Subscribe to all three KV cert events. Only NewVersionCreated belongs
    on the sync runbook. (NearExpiry/Expired are alerting concerns and
    are out of scope for this folder.)
  - Apply the subscription to other certs in the same vault. One cert
    name per subscription, scoped by SubjectBeginsWith.
```

---

## Role requirements

The human needs `Contributor` on the Key Vault's resource group (or the
minimum of `Microsoft.EventGrid/eventSubscriptions/write` +
`Microsoft.KeyVault/vaults/providers/Microsoft.EventGrid/...`) and read
on the Automation Account.
