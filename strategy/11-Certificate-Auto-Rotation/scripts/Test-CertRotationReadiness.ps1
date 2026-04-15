<#
    .SYNOPSIS
        Pre-flight check that a Key Vault certificate + Automation Account
        + App Registration are wired up correctly for automated rotation.

    .DESCRIPTION
        Verifies the six preconditions for the two auto-rotation approaches
        (base64 at runtime + Event Grid sync):

          1. Cert exists in Key Vault and has a current version.
          2. Cert policy has auto-renewal enabled.
          3. Automation Account's system-assigned MI can read the secret
             version of the cert (needed for the base64 pattern).
          4. The MI is listed as an owner of the target App Registration
             (so Application.ReadWrite.OwnedBy is sufficient).
          5. Required modules are present in the Automation Account's
             default runtime environment (Az.KeyVault, Microsoft.Graph.Applications).
          6. Runs in a safe, non-mutating way — this script reports only.

        It does NOT check Graph app-role consent directly (that requires
        a privileged Graph call) — it prints a reminder instead.

    .PARAMETER VaultName
        The Key Vault holding the cert.

    .PARAMETER CertName
        Name of the cert object in the vault.

    .PARAMETER AutomationAccountRG
        Resource group of the Automation Account whose MI will run the sync.

    .PARAMETER AutomationAccountName
        The Automation Account whose system-assigned MI will run the sync.

    .PARAMETER AppRegistrationObjectId
        Object ID (not App ID) of the target App Registration.

    .EXAMPLE
        .\Test-CertRotationReadiness.ps1 -VaultName contoso-kv -CertName SPOCert `
            -AutomationAccountRG rg-aa -AutomationAccountName aa-ops `
            -AppRegistrationObjectId 11111111-2222-3333-4444-555555555555

    .NOTES
        Required session auth:
            Connect-AzAccount
            Connect-MgGraph -Scopes 'Application.Read.All','Directory.Read.All'
#>
param(
    [Parameter(Mandatory)] [string] $VaultName,
    [Parameter(Mandatory)] [string] $CertName,
    [Parameter(Mandatory)] [string] $AutomationAccountRG,
    [Parameter(Mandatory)] [string] $AutomationAccountName,
    [Parameter(Mandatory)] [string] $AppRegistrationObjectId
)

$ErrorActionPreference = 'Stop'

function New-Row {
    param([string]$Check, [string]$Status, [string]$Detail)
    [pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail }
}

$rows = [System.Collections.Generic.List[object]]::new()

# --- 1. Cert exists ---
try {
    $cert = Get-AzKeyVaultCertificate -VaultName $VaultName -Name $CertName -ErrorAction Stop
    if ($cert -and $cert.Id) {
        $rows.Add((New-Row 'Cert exists in KV' 'Pass' "Version: $($cert.Version); Expires: $($cert.Expires)"))
    } else {
        $rows.Add((New-Row 'Cert exists in KV' 'Fail' 'Get-AzKeyVaultCertificate returned nothing'))
    }
} catch {
    $rows.Add((New-Row 'Cert exists in KV' 'Fail' $_.Exception.Message))
    $cert = $null
}

# --- 2. Auto-renew policy ---
try {
    $policy = Get-AzKeyVaultCertificatePolicy -VaultName $VaultName -Name $CertName -ErrorAction Stop
    $renewPct  = $policy.RenewAtPercentageLifetime
    $renewDays = $policy.RenewAtNumberOfDaysBeforeExpiry
    if ($renewPct -or $renewDays) {
        $detail = if ($renewPct) { "RenewAt ${renewPct}% lifetime" } else { "RenewAt ${renewDays} days before expiry" }
        $rows.Add((New-Row 'Auto-renew policy' 'Pass' $detail))
    } else {
        $rows.Add((New-Row 'Auto-renew policy' 'Fail' 'No auto-renew trigger set on the cert policy'))
    }
} catch {
    $rows.Add((New-Row 'Auto-renew policy' 'Fail' $_.Exception.Message))
}

# --- MI principal lookup (used by checks 3 and 4) ---
$miPrincipalId = $null
try {
    $aa = Get-AzAutomationAccount -ResourceGroupName $AutomationAccountRG -Name $AutomationAccountName -ErrorAction Stop
    $miPrincipalId = $aa.Identity.PrincipalId
    if (-not $miPrincipalId) {
        $rows.Add((New-Row 'Automation Account MI' 'Fail' 'System-assigned managed identity is not enabled on this Automation Account'))
    }
} catch {
    $rows.Add((New-Row 'Automation Account MI' 'Fail' $_.Exception.Message))
}

# --- 3. MI can read the secret version of the cert ---
if ($miPrincipalId) {
    try {
        $kv = Get-AzKeyVault -VaultName $VaultName
        $hasRbac = $false
        $hasPolicy = $false

        if ($kv.EnableRbacAuthorization) {
            $assignments = Get-AzRoleAssignment -ObjectId $miPrincipalId -Scope $kv.ResourceId -ErrorAction SilentlyContinue
            $hasRbac = $assignments | Where-Object {
                $_.RoleDefinitionName -in 'Key Vault Secrets User', 'Key Vault Administrator'
            } | Select-Object -First 1
            $detail = if ($hasRbac) { "RBAC role '$($hasRbac.RoleDefinitionName)' on vault" } else { 'No KV Secrets User (or equivalent) RBAC role on the vault' }
        } else {
            $ap = $kv.AccessPolicies | Where-Object { $_.ObjectId -eq $miPrincipalId }
            $hasPolicy = $ap -and ($ap.PermissionsToSecrets -contains 'Get')
            $detail = if ($hasPolicy) { 'Access policy grants Secrets: Get' } else { 'Access policy missing Secrets: Get for this MI' }
        }

        $status = if ($hasRbac -or $hasPolicy) { 'Pass' } else { 'Fail' }
        $rows.Add((New-Row 'MI can read cert-as-secret' $status $detail))
    } catch {
        $rows.Add((New-Row 'MI can read cert-as-secret' 'Fail' $_.Exception.Message))
    }
}

# --- 4. MI is an owner of the App Registration ---
if ($miPrincipalId) {
    try {
        $owners = Get-MgApplicationOwner -ApplicationId $AppRegistrationObjectId -All -ErrorAction Stop
        $isOwner = $owners | Where-Object { $_.Id -eq $miPrincipalId }
        if ($isOwner) {
            $rows.Add((New-Row 'MI is App Reg owner' 'Pass' 'Runbook MI listed as owner — Application.ReadWrite.OwnedBy is sufficient'))
        } else {
            $rows.Add((New-Row 'MI is App Reg owner' 'Fail' "MI object $miPrincipalId is NOT in the app's owners collection"))
        }
    } catch {
        $rows.Add((New-Row 'MI is App Reg owner' 'Warn' "Could not query Graph owners (need Directory.Read.All on your session): $($_.Exception.Message)"))
    }
}

# --- 5. Required modules in runtime environment ---
try {
    $modules = Get-AzAutomationModule -ResourceGroupName $AutomationAccountRG -AutomationAccountName $AutomationAccountName -ErrorAction Stop
    $needed = @('Az.KeyVault', 'Az.Accounts', 'Microsoft.Graph.Applications')
    $missing = $needed | Where-Object { $_ -notin $modules.Name }
    if (-not $missing) {
        $rows.Add((New-Row 'Runtime modules present' 'Pass' ($needed -join ', ')))
    } else {
        $rows.Add((New-Row 'Runtime modules present' 'Fail' "Missing: $($missing -join ', ')"))
    }
} catch {
    $rows.Add((New-Row 'Runtime modules present' 'Warn' $_.Exception.Message))
}

# --- 6. Graph app role reminder ---
$rows.Add((New-Row 'Graph app role (manual verify)' 'Info' `
    "Confirm 'Application.ReadWrite.OwnedBy' is granted to the MI service principal and admin-consented. This script cannot verify without elevated Graph access."))

# Emit results
$rows | Format-Table -AutoSize | Out-Host

$fail = ($rows | Where-Object Status -eq 'Fail').Count
Write-Host ''
if ($fail -eq 0) {
    Write-Host 'READY — all mandatory checks pass.' -ForegroundColor Green
} else {
    Write-Host "NOT READY — $fail check(s) failed. Address them before wiring Event Grid." -ForegroundColor Yellow
}

return $rows
