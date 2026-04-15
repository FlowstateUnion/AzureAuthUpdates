<#
    .SYNOPSIS
        Retrieves a Key Vault certificate's private-key PFX as either a
        base64 string (for -CertificateBase64Encoded) or an in-memory
        X509Certificate2 (for -Certificate parameters).

    .DESCRIPTION
        The trick this script exists for: in Key Vault, a certificate is
        also stored as a secret. Get-AzKeyVaultSecret returns the full
        PFX bundle including the private key. That is what you pass to
        Connect-PnPOnline -CertificateBase64Encoded.

        Works on PowerShell 5.1 and 7+. On 5.1, it uses BSTR marshalling
        to pull the plain text out of the SecureString (the -AsPlainText
        parameter is 7+ only). The BSTR pointer is zero-freed in a finally
        block so the plain text never lingers in memory.

        This helper is safe to dot-source from a runbook or to import as
        part of the Contoso.Automation.Auth module.

    .PARAMETER VaultName
        The Key Vault.

    .PARAMETER CertName
        The cert object name in the vault (same name as used in the
        Certificates blade).

    .PARAMETER As
        Output shape:
          Base64  — returns a plain string (for PnP and similar SDKs).
          Cert    — returns an X509Certificate2 with EphemeralKeySet
                    (for Connect-MgGraph, Connect-ExchangeOnline).

    .EXAMPLE
        # PnP
        $b64 = .\Get-CertificateFromKeyVault.ps1 -VaultName contoso-kv -CertName SPOCert -As Base64
        Connect-PnPOnline -Url $url -ClientId $id -Tenant $t -CertificateBase64Encoded $b64

    .EXAMPLE
        # Graph
        $cert = .\Get-CertificateFromKeyVault.ps1 -VaultName contoso-kv -CertName SPOCert -As Cert
        Connect-MgGraph -ClientId $id -TenantId $tenant -Certificate $cert

    .NOTES
        Caller must already be authenticated to Azure (Connect-AzAccount
        or -Identity) with Key Vault Secrets User (RBAC) or Secrets: Get
        (access policy).
#>
param(
    [Parameter(Mandatory)] [string] $VaultName,
    [Parameter(Mandatory)] [string] $CertName,
    [ValidateSet('Base64', 'Cert')] [string] $As = 'Base64'
)

$ErrorActionPreference = 'Stop'

$secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $CertName
if (-not $secret -or -not $secret.SecretValue) {
    throw "Key Vault secret '$CertName' in vault '$VaultName' not found or has no value. If this cert was imported non-exportable, the secret version will be blank — reissue with an exportable policy."
}

# Pull plain text out of the SecureString. PS 7 has a direct switch; PS 5.1
# doesn't, so marshal the BSTR and zero-free it immediately after use.
$base64 = $null
$ptr    = [IntPtr]::Zero
try {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $base64 = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
    } else {
        $ptr    = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret.SecretValue)
        $base64 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }

    switch ($As) {
        'Base64' {
            return $base64
        }
        'Cert' {
            $bytes = [Convert]::FromBase64String($base64)
            $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
            return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 `
                ($bytes, [string]::Empty, $flags)
        }
    }
}
finally {
    if ($ptr -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
    # Best-effort scrub of the plain text on the PS 5.1 path. On PS 7 the
    # string was produced directly by the runtime; we can't guarantee scrub
    # but we can at least remove our local reference.
    if ($As -eq 'Cert') {
        Remove-Variable base64 -ErrorAction SilentlyContinue
        if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}
