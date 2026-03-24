# Strategy: Exchange Online (EXO) Migration

## Current State

Runbooks using Exchange Online typically authenticate with stored credentials:

```powershell
# Legacy pattern A — PSCredential
$cred = Get-AutomationPSCredential -Name "ExchangeAdmin"
Connect-ExchangeOnline -Credential $cred

# Legacy pattern B — Basic auth (deprecated)
$cred = Get-AutomationPSCredential -Name "ExchangeAdmin"
$session = New-PSSession -ConfigurationName Microsoft.Exchange `
    -ConnectionUri https://outlook.office365.com/powershell-liveid/ `
    -Credential $cred -Authentication Basic
Import-PSSession $session
```

## Why It Must Change

1. Basic Authentication for Exchange Online was permanently disabled October 2022
2. Stored credentials break with MFA and Conditional Access
3. Remote PowerShell sessions (`New-PSSession` to Exchange) are deprecated
4. The ExchangeOnlineManagement module v3+ is required for modern auth

## Module Versions

| Module | PS 5.1 | PS 7.x | MI Support | Notes |
|--------|--------|--------|------------|-------|
| ExchangeOnlineManagement v2.x | Yes | Partial | No | Legacy; EOL |
| ExchangeOnlineManagement v3.x+ | Yes | Yes | **Yes** | Required target |

## Target State

All Exchange Online operations use `Connect-ExchangeOnline` with Managed Identity or certificate-based auth via the EXO v3 module.

## Migration Approach

### Path A: Managed Identity (Preferred)

ExchangeOnlineManagement v3.2+ supports Managed Identity:

```powershell
# System-Assigned MI
Connect-ExchangeOnline -ManagedIdentity -Organization "contoso.onmicrosoft.com"

# User-Assigned MI
Connect-ExchangeOnline -ManagedIdentity `
    -ManagedIdentityAccountId "<UAMI-Client-ID>" `
    -Organization "contoso.onmicrosoft.com"
```

**Prerequisites:**
- Managed Identity must be granted the `Exchange.ManageAsApp` App Role
- The MI's service principal must be assigned an Exchange Online admin role (e.g., `Exchange Administrator` or a custom role)

**Granting Exchange permissions:**

```powershell
# Step 1: Grant the Exchange.ManageAsApp App Role
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All"

$miObjectId = "<MI-Object-ID>"
$exchangeAppId = "00000002-0000-0ff1-ce00-000000000000"  # Office 365 Exchange Online

$exchangeSP = Get-MgServicePrincipal -Filter "appId eq '$exchangeAppId'"
$role = $exchangeSP.AppRoles | Where-Object { $_.Value -eq "Exchange.ManageAsApp" }

New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miObjectId `
    -PrincipalId $miObjectId `
    -ResourceId $exchangeSP.Id `
    -AppRoleId $role.Id

# Step 2: Assign an Exchange admin role to the MI
# This must be done in the Exchange admin center or via:
$miSP = Get-MgServicePrincipal -ServicePrincipalId $miObjectId
$exchangeAdminRole = Get-MgDirectoryRole | Where-Object { $_.DisplayName -eq "Exchange Administrator" }

# If the role hasn't been activated yet:
# $roleTemplate = Get-MgDirectoryRoleTemplate | Where-Object { $_.DisplayName -eq "Exchange Administrator" }
# New-MgDirectoryRole -RoleTemplateId $roleTemplate.Id

New-MgDirectoryRoleMember -DirectoryRoleId $exchangeAdminRole.Id `
    -DirectoryObjectId $miSP.Id
```

### Path B: Certificate Auth

When MI is unavailable (cross-tenant, specific app registration requirements):

```powershell
Connect-ExchangeOnline `
    -CertificateThumbprint "<THUMBPRINT>" `
    -AppId "<APP-REGISTRATION-CLIENT-ID>" `
    -Organization "contoso.onmicrosoft.com"
```

Certificate can be retrieved from Key Vault:
```powershell
Import-Module Contoso.Automation.Auth
Connect-ContosoAzure
$thumbprint = Get-ContosoKeyVaultCertificate -VaultName "contoso-kv" -CertName "ExoCert"

Connect-ExchangeOnline `
    -CertificateThumbprint $thumbprint `
    -AppId "<APP-ID>" `
    -Organization "contoso.onmicrosoft.com"
```

### Path C: Microsoft Graph for Mail Operations

For runbooks that only send mail or read calendars, consider replacing EXO with Microsoft Graph:

```powershell
# Instead of Send-MailMessage or EXO Send-MgUserMail:
Import-Module Contoso.Automation.Auth
Connect-ContosoGraph

$message = @{
    Subject      = "Report Generated"
    Body         = @{ ContentType = "HTML"; Content = "<p>Report attached.</p>" }
    ToRecipients = @( @{ EmailAddress = @{ Address = "user@contoso.com" } } )
}

Send-MgUserMail -UserId "sender@contoso.com" -Message $message
```

**When to use Graph instead of EXO:**
- Sending mail (`Send-MgUserMail`)
- Reading mail (`Get-MgUserMessage`)
- Calendar operations (`Get-MgUserCalendarEvent`)
- Simple mailbox queries

**When EXO module is still required:**
- Mailbox management (`Set-Mailbox`, `New-Mailbox`)
- Transport rules (`Get-TransportRule`, `New-TransportRule`)
- Distribution group management
- Compliance and eDiscovery operations
- Anything requiring Exchange admin cmdlets

## Shared Module Extension

Add to `Contoso.Automation.Auth.psm1`:

```powershell
function Connect-ContosoExchange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Organization,

        [Parameter()]
        [ValidateSet('ManagedIdentity', 'Certificate')]
        [string]$AuthMethod = 'ManagedIdentity',

        [Parameter()]
        [string]$UserAssignedClientId,

        [Parameter()]
        [string]$AppId,

        [Parameter()]
        [string]$CertThumbprint
    )

    if (-not (Get-Module -ListAvailable -Name 'ExchangeOnlineManagement')) {
        throw "ExchangeOnlineManagement module is not installed."
    }

    switch ($AuthMethod) {
        'ManagedIdentity' {
            $params = @{
                ManagedIdentity = $true
                Organization    = $Organization
            }
            if ($UserAssignedClientId) {
                $params['ManagedIdentityAccountId'] = $UserAssignedClientId
            }
            Write-Verbose "Connecting to Exchange Online via Managed Identity..."
            Connect-ExchangeOnline @params -ShowBanner:$false
        }
        'Certificate' {
            if (-not $AppId -or -not $CertThumbprint) {
                throw "Certificate auth requires -AppId and -CertThumbprint."
            }
            Write-Verbose "Connecting to Exchange Online via Certificate..."
            Connect-ExchangeOnline -CertificateThumbprint $CertThumbprint `
                -AppId $AppId `
                -Organization $Organization `
                -ShowBanner:$false
        }
    }

    Write-Verbose "Connected to Exchange Online: $Organization"
}
```

## Replacing Legacy Patterns

### Remote PSSession (must be eliminated)
```powershell
# BEFORE — deprecated, non-functional
$session = New-PSSession -ConfigurationName Microsoft.Exchange `
    -ConnectionUri https://outlook.office365.com/powershell-liveid/ `
    -Credential $cred -Authentication Basic
Import-PSSession $session
# ... Exchange cmdlets ...
Remove-PSSession $session

# AFTER
Import-Module Contoso.Automation.Auth
Connect-ContosoAzure
Connect-ContosoExchange -Organization "contoso.onmicrosoft.com"
# ... Exchange cmdlets (same names, EXO module wraps them) ...
Disconnect-ExchangeOnline -Confirm:$false
```

### Send-MailMessage (deprecated cmdlet)
```powershell
# BEFORE
Send-MailMessage -To "user@contoso.com" -From "noreply@contoso.com" `
    -Subject "Report" -Body "Done" -SmtpServer "smtp.office365.com" `
    -Credential $cred -UseSsl

# AFTER (via Graph — no EXO module needed)
Connect-ContosoGraph
Send-MgUserMail -UserId "noreply@contoso.com" -Message @{
    Subject      = "Report"
    Body         = @{ ContentType = "Text"; Content = "Done" }
    ToRecipients = @( @{ EmailAddress = @{ Address = "user@contoso.com" } } )
}
```

## Cleanup After Migration

- Add `ExchangeOnlineManagement` v3.x to the runtime environment module list
- Remove any `New-PSSession` Exchange patterns
- Remove stored Exchange credentials from Automation Credential assets
- Update `Disconnect-ContosoAll` in the shared module to include `Disconnect-ExchangeOnline`

## Validation

1. Run a test runbook that connects to Exchange and runs a read-only command:
   ```powershell
   Connect-ContosoExchange -Organization "contoso.onmicrosoft.com"
   Get-EXOMailbox -ResultSize 1 | Select-Object DisplayName, PrimarySmtpAddress
   Disconnect-ExchangeOnline -Confirm:$false
   ```
2. Verify the output returns a mailbox
3. Test mail-sending if applicable (to a test mailbox)
