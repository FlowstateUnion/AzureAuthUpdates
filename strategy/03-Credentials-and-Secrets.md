# Strategy: Eliminating Credential & Secret Patterns

## Patterns Covered

This strategy covers all direct credential construction and secret handling:

- `Get-AutomationPSCredential`
- `Get-Credential`
- `New-Object System.Management.Automation.PSCredential`
- `[PSCredential]::new()`
- `ConvertTo-SecureString` (when used for password construction)
- `AppSecret` / Client Secret variables

## Current State — Common Patterns Found in Runbooks

### Pattern 1: Automation Credential Asset
```powershell
$cred = Get-AutomationPSCredential -Name "ServiceAccount"
Connect-SomeService -Credential $cred
```

### Pattern 2: Manual PSCredential Construction
```powershell
$user = Get-AutomationVariable -Name "AdminUser"
$pass = Get-AutomationVariable -Name "AdminPass"
$secPass = ConvertTo-SecureString $pass -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($user, $secPass)
```

### Pattern 3: Client Secret Auth
```powershell
$clientId = Get-AutomationVariable -Name "AppClientId"
$clientSecret = Get-AutomationVariable -Name "AppClientSecret"
$secSecret = ConvertTo-SecureString $clientSecret -AsPlainText -Force
$cred = New-Object PSCredential($clientId, $secSecret)
Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant $tenantId
```

### Pattern 4: Inline ConvertTo-SecureString
```powershell
$token = "hardcoded-or-variable-secret"
$secToken = ConvertTo-SecureString $token -AsPlainText -Force
```

## Replacement Decision Tree

```
Is the credential used to authenticate to Azure/M365?
├── YES → Use Managed Identity (no credentials needed)
│         Connect-AzAccount -Identity
│         Connect-PnPOnline -Url $url -ManagedIdentity
│         Connect-MgGraph -Identity
│
└── NO → Is it for a third-party API or system?
    ├── YES → Store the secret in Azure Key Vault
    │         Connect-AzAccount -Identity
    │         $secret = Get-AzKeyVaultSecret -VaultName "kv" -Name "ApiKey" -AsPlainText
    │         Invoke-RestMethod -Headers @{ "Authorization" = "Bearer $secret" }
    │
    └── Is it a certificate-based auth scenario?
        ├── YES → Store cert in Key Vault; retrieve at runtime
        │         $thumbprint = (Get-AzKeyVaultCertificate -VaultName "kv" -Name "cert").Thumbprint
        │         Connect-Service -CertificateThumbprint $thumbprint
        │
        └── Is username/password absolutely required (legacy system)?
            └── YES → Store both in Key Vault as separate secrets
                      $user = Get-AzKeyVaultSecret -VaultName "kv" -Name "LegacyUser" -AsPlainText
                      $pass = Get-AzKeyVaultSecret -VaultName "kv" -Name "LegacyPass"
                      $cred = New-Object PSCredential($user, $pass.SecretValue)
```

## Migration Rules

### Rule 1: `Get-AutomationPSCredential` → DELETE
Every usage of `Get-AutomationPSCredential` for Azure/M365 services should be **completely removed** (not replaced with another credential mechanism). The service connection should use Managed Identity instead.

### Rule 2: `Get-Credential` → DELETE
`Get-Credential` prompts for interactive input. It should never appear in an Automation runbook. Remove it.

### Rule 3: `ConvertTo-SecureString` for passwords → CONDITIONALLY REMOVE
- If it's constructing a credential for Azure/M365: **remove entirely** (use MI)
- If it's constructing a credential for Key Vault retrieval: Key Vault returns `SecureString` natively — no conversion needed
- If it's needed for a third-party API that requires `SecureString` input: keep but source the value from Key Vault

### Rule 4: `AppSecret` / Client Secrets → REPLACE WITH MI OR CERT
- Remove Automation Variables storing client secrets
- If MI can replace the service principal auth: use MI
- If a service principal is required (e.g., cross-tenant): use certificate auth with cert stored in Key Vault

### Rule 5: `New-Object PSCredential` → MINIMIZE
- The only acceptable use is for legacy third-party systems that require `PSCredential`
- Username and password must come from Key Vault, not Automation Variables

## Shared Module Support

The `Contoso.Automation.Auth` module provides `Get-ContosoKeyVaultSecret` and `Get-ContosoKeyVaultCertificate` for the remaining cases where secrets are needed. All Azure/M365 auth goes through `Connect-Contoso*` functions which use MI internally.

## Cleanup After Migration

For each runbook migrated:

1. Remove the corresponding Automation Credential asset if no other runbook references it
2. Remove Automation Variable assets that stored secrets
3. Update the runbook's description to note it uses Managed Identity
4. Verify no other runbooks depend on the removed assets (cross-reference with scan results)

## Security Improvements Gained

| Before | After |
|--------|-------|
| Passwords stored in Automation Credential assets | No passwords; MI handles auth |
| Client secrets in Automation Variables | Certificates in Key Vault or MI |
| Manual secret rotation | Auto-rotated MI; Key Vault rotation policies for certs |
| No audit trail for credential access | Key Vault audit logs |
| Credentials break with MFA/CA policies | MI is exempt from user-level MFA |
| Secrets visible to Automation Account contributors | Key Vault RBAC; principle of least privilege |
