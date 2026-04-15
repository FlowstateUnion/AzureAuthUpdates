# Prompt — Refactor the shared auth module to use `-CertificateBase64Encoded` from Key Vault

Copy the block below into a Claude Code session, filling in the two
placeholders.

---

```
Refactor modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psm1 to
support fetching certificates from Key Vault at runtime instead of
looking them up by thumbprint in the local cert store.

Target runtime: PowerShell 7.4 (with PS 5.1 fallback for documented
exceptions — keep both branches working).

Key Vault:    <key-vault-name>
Cert name:    <cert-name-in-kv>

Requirements:

  1. Add a NEW parameter set on Connect-ContosoPnP (and any other
     Connect-Contoso* wrappers that currently require -CertThumbprint):
       -VaultName   <string>  (mandatory)
       -CertName    <string>  (mandatory)
     Existing -CertThumbprint parameter set must keep working unchanged.
     The function should pick the parameter set by which group is bound.

  2. Introduce an internal helper function in the .psm1 named
     Get-ContosoAuthCertificateFromKeyVault (private, not exported).
     It should mirror the logic in
     strategy/11-Certificate-Auto-Rotation/scripts/Get-CertificateFromKeyVault.ps1
     — specifically:
       - Use Get-AzKeyVaultSecret (NOT Get-AzKeyVaultCertificate) to
         retrieve the full PFX.
       - PS 7+: use ConvertFrom-SecureString -AsPlainText.
       - PS 5.1: use BSTR marshalling, zero-free in finally.
       - Return a base64 string when -As Base64 (default); return an
         X509Certificate2 with EphemeralKeySet when -As Cert.

  3. Wire the new parameter set:
       - Connect-PnPOnline path uses -CertificateBase64Encoded with the
         base64 string.
       - Connect-MgGraph / Connect-ExchangeOnline paths call the helper
         with -As Cert and pass the X509Certificate2 to -Certificate.

  4. Bump the module manifest (Contoso.Automation.Auth.psd1) from 1.1 to
     1.2. Add a ModulePrivateData release note line describing the new
     parameter set.

  5. Update the smoke tests under modules/Contoso.Automation.Auth/tests/
     (create the folder if needed) with one integration test per
     wrapper that uses -VaultName/-CertName. Gate them behind an
     env var CONTOSO_INTEGRATION_TESTS=1 so CI doesn't accidentally
     try to hit Azure without creds.

Do NOT:
  - Remove the existing -CertThumbprint parameter set. Runbooks that
    still use it must keep working until their individual migration PR.
  - Change any public function names or output shape. Only add parameter sets.
  - Touch anything under runbooks/ — that's the next step, tracked separately.

When you're done:
  - Print a diff summary of every exported function's parameter sets.
  - List every runbook under runbooks/source/ that still uses
    -CertThumbprint (grep output) so the human knows what to migrate next.
```

---

## Role requirements

The developer running this change needs write access to `modules/` and
the ability to run the module tests locally (`Connect-AzAccount` to a
non-prod subscription with a test Key Vault containing a test cert).
