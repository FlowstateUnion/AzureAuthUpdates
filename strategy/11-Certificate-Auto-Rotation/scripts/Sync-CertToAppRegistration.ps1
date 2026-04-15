<#
    .SYNOPSIS
        Uploads the current public key of a Key Vault certificate to an
        Entra App Registration as a new keyCredential, then prunes
        expired keyCredentials.

    .DESCRIPTION
        Designed to be called from the Sync-AppRegCertificate runbook that
        is triggered by Key Vault's CertificateNewVersionCreated Event
        Grid event. Also usable standalone for manual rotation.

        What it does, in order:
          1. Downloads the cert's PUBLIC key (.Cer) from Key Vault.
          2. Adds it to the App Registration as a new keyCredential with
             DisplayName = "<CertName>-<Thumbprint-8chars>" and matching
             not-before / not-after from the cert itself.
          3. Prunes keyCredentials on the same app whose EndDateTime is
             in the past. NEVER prunes the key it just added.
          4. Returns a PSCustomObject with what changed, for logging.

        Uses Microsoft.Graph.Applications. Caller must be authenticated
        to Graph (Connect-MgGraph or -Identity) with permission to edit
        the target app (Application.ReadWrite.OwnedBy is enough if the
        calling principal is an owner of the app).

    .PARAMETER VaultName
        Key Vault containing the cert.

    .PARAMETER CertName
        Cert object name in the vault. The latest version is used.

    .PARAMETER AppObjectId
        Object ID of the App Registration (NOT the App ID / client ID).

    .PARAMETER KeepPreviousKeyHours
        Grace period during which previous (non-expired) keys are left
        alone even if a newer key exists, to avoid mid-run rejections.
        Only *expired* keys are ever removed. Default: 1.

    .EXAMPLE
        .\Sync-CertToAppRegistration.ps1 -VaultName contoso-kv `
            -CertName SPOCert -AppObjectId 11111111-2222-3333-4444-555555555555

    .NOTES
        Idempotent: if a keyCredential with the same public key already
        exists on the app, it is not re-added.
#>
param(
    [Parameter(Mandatory)] [string] $VaultName,
    [Parameter(Mandatory)] [string] $CertName,
    [Parameter(Mandatory)] [string] $AppObjectId,
    [int] $KeepPreviousKeyHours = 1
)

$ErrorActionPreference = 'Stop'

# 1. Pull the cert (public key only — no secret fetch needed here)
$cert = Get-AzKeyVaultCertificate -VaultName $VaultName -Name $CertName
if (-not $cert) { throw "Cert '$CertName' not found in vault '$VaultName'." }

$rawBytes   = $cert.Certificate.RawData
$thumbShort = $cert.Thumbprint.Substring(0, 8)
$displayName = "$CertName-$thumbShort"
$notBefore  = $cert.NotBefore
$notAfter   = $cert.Expires

# 2. Read current keyCredentials on the app
$app = Get-MgApplication -ApplicationId $AppObjectId
$existing = @($app.KeyCredentials)

$alreadyPresent = $existing | Where-Object {
    # Graph returns Key as base64 of the raw bytes for AsymmetricX509Cert
    $_.Type -eq 'AsymmetricX509Cert' -and
    $_.Key -and
    ([Convert]::ToBase64String($_.Key) -eq [Convert]::ToBase64String($rawBytes))
}

$added = $null
if ($alreadyPresent) {
    Write-Verbose "Cert $($cert.Thumbprint) already present on app $AppObjectId as key $($alreadyPresent.KeyId)."
} else {
    # 3. Build the new keyCredential and append (replace the whole collection)
    $newKey = @{
        Type           = 'AsymmetricX509Cert'
        Usage          = 'Verify'
        Key            = $rawBytes
        DisplayName    = $displayName
        StartDateTime  = $notBefore
        EndDateTime    = $notAfter
    }

    $updatedKeys = @($existing) + $newKey
    Update-MgApplication -ApplicationId $AppObjectId -KeyCredentials $updatedKeys

    # Re-read to discover the KeyId Graph assigned to our new entry
    $app = Get-MgApplication -ApplicationId $AppObjectId
    $added = $app.KeyCredentials | Where-Object {
        $_.Type -eq 'AsymmetricX509Cert' -and
        ([Convert]::ToBase64String($_.Key) -eq [Convert]::ToBase64String($rawBytes))
    } | Select-Object -First 1

    Write-Verbose "Added keyCredential $($added.KeyId) for cert $($cert.Thumbprint)."
}

# 4. Prune expired keys. Never touch the one we just added.
$now = [DateTime]::UtcNow
$toRemove = $app.KeyCredentials | Where-Object {
    $_.Type -eq 'AsymmetricX509Cert' -and
    $_.EndDateTime -lt $now -and
    (-not $added -or $_.KeyId -ne $added.KeyId)
}

$removedIds = @()
if ($toRemove) {
    $keepers = $app.KeyCredentials | Where-Object { $_.KeyId -notin ($toRemove.KeyId) }
    Update-MgApplication -ApplicationId $AppObjectId -KeyCredentials @($keepers)
    $removedIds = $toRemove.KeyId
    Write-Verbose "Pruned $($removedIds.Count) expired keyCredential(s): $($removedIds -join ', ')"
}

[pscustomobject]@{
    AppObjectId   = $AppObjectId
    CertName      = $CertName
    Thumbprint    = $cert.Thumbprint
    AddedKeyId    = $added.KeyId
    AlreadyPresent = [bool]$alreadyPresent
    RemovedKeyIds = $removedIds
    Timestamp     = [DateTime]::UtcNow
}
