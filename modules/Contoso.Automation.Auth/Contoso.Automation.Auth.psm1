#Requires -Modules Az.Accounts, Az.KeyVault

<#
    .SYNOPSIS
        Shared authentication module for Azure Automation runbooks.

    .DESCRIPTION
        Provides standardized authentication functions using Managed Identity
        (primary) or certificate-based auth (fallback). Centralizes all auth
        logic so runbooks never handle credentials directly.

    .NOTES
        Module:  Contoso.Automation.Auth
        Version: 1.1.0
        Requires: Az.Accounts 3.x+, Az.KeyVault 6.x+
        Optional: PnP.PowerShell 2.4+, Microsoft.Graph.Authentication 2.x+,
                  ExchangeOnlineManagement 3.2+
#>

# --- Module-scoped state ---
$script:IsAzureConnected = $false
$script:AzureConnectParams = @{}
$script:LastAzureTokenRefresh = $null
$script:TokenRefreshIntervalMinutes = 45  # Refresh before the typical 60-min expiry

# Per-service connection context for reliable reconnect
$script:GraphConnectParams = @{}
$script:SharePointConnectParams = @{}
$script:ExchangeConnectParams = @{}

# Error patterns that indicate token expiry (retryable)
$script:TokenExpiryPatterns = @(
    'AADSTS700024'           # Token expired
    'AADSTS500133'           # Token not yet valid or expired
    'lifetime validation failed'
    'Access token has expired'
    'token is expired'
    'AADSTS70043'            # Refresh token expired
)

# Error patterns that indicate authorization denial (NOT retryable — fail fast)
$script:AuthorizationDenialPatterns = @(
    'Authorization_RequestDenied'
    'Insufficient privileges'
    'Access is denied'
    'does not have authorization'
    'UnauthorizedAccessException'
    'AADSTS65001'            # Consent required
    'AADSTS530003'           # Conditional Access block
)

# =============================================================================
# PUBLIC FUNCTIONS
# =============================================================================

function Connect-ContosoAzure {
    <#
        .SYNOPSIS
            Authenticates to Azure using Managed Identity.

        .PARAMETER UserAssignedClientId
            Client ID of a User-Assigned Managed Identity. If omitted, uses System-Assigned MI.

        .EXAMPLE
            Connect-ContosoAzure
            Connect-ContosoAzure -UserAssignedClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$UserAssignedClientId
    )

    $params = @{ Identity = $true }
    if ($UserAssignedClientId) {
        $params['AccountId'] = $UserAssignedClientId
    }

    try {
        Write-Verbose "Connecting to Azure via Managed Identity..."
        $context = Connect-AzAccount @params -WarningAction SilentlyContinue
        $script:IsAzureConnected = $true
        $script:AzureConnectParams = $params
        $script:LastAzureTokenRefresh = Get-Date
        Write-Verbose "Connected to Azure. Subscription: $($context.Context.Subscription.Name)"
    }
    catch {
        Write-Error "Failed to connect to Azure via Managed Identity: $($_.Exception.Message)"
        throw
    }
}

function Connect-ContosoSharePoint {
    <#
        .SYNOPSIS
            Connects to SharePoint Online via PnP.PowerShell.

        .PARAMETER SiteUrl
            Full URL of the SharePoint site (e.g., https://contoso.sharepoint.com/sites/IT).

        .PARAMETER AuthMethod
            Authentication method: ManagedIdentity (default) or Certificate.

        .PARAMETER ClientId
            App Registration Client ID. Required for Certificate auth.

        .PARAMETER TenantName
            Tenant name (e.g., contoso.onmicrosoft.com). Required for Certificate auth.

        .PARAMETER CertThumbprint
            Certificate thumbprint. Required for Certificate auth.

        .PARAMETER UserAssignedClientId
            Client ID for User-Assigned MI. Optional; only for ManagedIdentity auth.

        .PARAMETER ReturnConnection
            If specified, returns a PnP connection object for use with -Connection parameter.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SiteUrl,

        [Parameter()]
        [ValidateSet('ManagedIdentity', 'Certificate')]
        [string]$AuthMethod = 'ManagedIdentity',

        [Parameter()]
        [string]$ClientId,

        [Parameter()]
        [string]$TenantName,

        [Parameter()]
        [string]$CertThumbprint,

        [Parameter()]
        [string]$UserAssignedClientId,

        [Parameter()]
        [switch]$ReturnConnection
    )

    # Ensure PnP.PowerShell is available
    if (-not (Get-Module -ListAvailable -Name 'PnP.PowerShell')) {
        throw "PnP.PowerShell module is not installed. Install it in the runtime environment."
    }

    try {
        switch ($AuthMethod) {
            'ManagedIdentity' {
                $pnpParams = @{
                    Url             = $SiteUrl
                    ManagedIdentity = $true
                }
                if ($UserAssignedClientId) {
                    $pnpParams['UserAssignedManagedIdentityClientId'] = $UserAssignedClientId
                }
                if ($ReturnConnection) {
                    $pnpParams['ReturnConnection'] = $true
                }

                Write-Verbose "Connecting to SharePoint ($SiteUrl) via Managed Identity..."
                $result = Connect-PnPOnline @pnpParams
                $script:SharePointConnectParams = @{ AuthMethod = 'ManagedIdentity'; SiteUrl = $SiteUrl; UserAssignedClientId = $UserAssignedClientId }
            }
            'Certificate' {
                if (-not $ClientId -or -not $TenantName -or -not $CertThumbprint) {
                    throw "Certificate auth requires -ClientId, -TenantName, and -CertThumbprint."
                }

                $pnpParams = @{
                    Url        = $SiteUrl
                    ClientId   = $ClientId
                    Tenant     = $TenantName
                    Thumbprint = $CertThumbprint
                }
                if ($ReturnConnection) {
                    $pnpParams['ReturnConnection'] = $true
                }

                Write-Verbose "Connecting to SharePoint ($SiteUrl) via Certificate..."
                $result = Connect-PnPOnline @pnpParams
                $script:SharePointConnectParams = @{
                    AuthMethod = 'Certificate'; SiteUrl = $SiteUrl
                    ClientId = $ClientId; TenantName = $TenantName; CertThumbprint = $CertThumbprint
                }
            }
        }

        Write-Verbose "Connected to SharePoint: $SiteUrl via $AuthMethod."

        if ($ReturnConnection) {
            return $result
        }
    }
    catch {
        Write-Error "Failed to connect to SharePoint ($SiteUrl): $($_.Exception.Message)"
        throw
    }
}

function Connect-ContosoSPOAdmin {
    <#
        .SYNOPSIS
            Connects to SharePoint Online Admin Center.
            Convenience wrapper that targets the -admin.sharepoint.com URL.

        .PARAMETER TenantName
            Tenant prefix (e.g., "contoso" for contoso.sharepoint.com).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantName,

        [Parameter()]
        [ValidateSet('ManagedIdentity', 'Certificate')]
        [string]$AuthMethod = 'ManagedIdentity',

        [Parameter()]
        [string]$ClientId,

        [Parameter()]
        [string]$CertThumbprint,

        [Parameter()]
        [string]$UserAssignedClientId
    )

    $adminUrl = "https://$TenantName-admin.sharepoint.com"
    $params = @{
        SiteUrl    = $adminUrl
        AuthMethod = $AuthMethod
    }
    if ($ClientId) { $params['ClientId'] = $ClientId }
    if ($CertThumbprint) { $params['CertThumbprint'] = $CertThumbprint }
    if ($AuthMethod -eq 'Certificate') { $params['TenantName'] = "$TenantName.onmicrosoft.com" }
    if ($UserAssignedClientId) { $params['UserAssignedClientId'] = $UserAssignedClientId }

    Connect-ContosoSharePoint @params
}

function Connect-ContosoGraph {
    <#
        .SYNOPSIS
            Connects to Microsoft Graph using Managed Identity or Certificate.

        .PARAMETER AuthMethod
            ManagedIdentity (default) or Certificate.

        .PARAMETER UserAssignedClientId
            Client ID for User-Assigned MI.

        .PARAMETER ClientId
            App Registration Client ID. Required for Certificate auth.

        .PARAMETER TenantId
            Tenant ID. Required for Certificate auth.

        .PARAMETER CertThumbprint
            Certificate thumbprint. Required for Certificate auth.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('ManagedIdentity', 'Certificate')]
        [string]$AuthMethod = 'ManagedIdentity',

        [Parameter()]
        [string]$UserAssignedClientId,

        [Parameter()]
        [string]$ClientId,

        [Parameter()]
        [string]$TenantId,

        [Parameter()]
        [string]$CertThumbprint
    )

    # Ensure Microsoft.Graph.Authentication is available
    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
        throw "Microsoft.Graph.Authentication module is not installed. Install it in the runtime environment."
    }

    try {
        switch ($AuthMethod) {
            'ManagedIdentity' {
                $params = @{ Identity = $true }
                if ($UserAssignedClientId) {
                    $params['ClientId'] = $UserAssignedClientId
                }
                Write-Verbose "Connecting to Microsoft Graph via Managed Identity..."
                Connect-MgGraph @params -NoWelcome
                $script:GraphConnectParams = @{ AuthMethod = 'ManagedIdentity'; Params = $params }
            }
            'Certificate' {
                if (-not $ClientId -or -not $TenantId -or -not $CertThumbprint) {
                    throw "Certificate auth requires -ClientId, -TenantId, and -CertThumbprint."
                }
                Write-Verbose "Connecting to Microsoft Graph via Certificate..."
                Connect-MgGraph -ClientId $ClientId -TenantId $TenantId -CertificateThumbprint $CertThumbprint -NoWelcome
                $script:GraphConnectParams = @{
                    AuthMethod = 'Certificate'
                    Params = @{ ClientId = $ClientId; TenantId = $TenantId; CertificateThumbprint = $CertThumbprint }
                }
            }
        }

        $context = Get-MgContext
        Write-Verbose "Connected to Graph. TenantId: $($context.TenantId) | AppName: $($context.AppName)"
    }
    catch {
        Write-Error "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
        throw
    }
}

function Get-ContosoKeyVaultSecret {
    <#
        .SYNOPSIS
            Retrieves a secret from Azure Key Vault.

        .PARAMETER VaultName
            Name of the Key Vault.

        .PARAMETER SecretName
            Name of the secret.

        .PARAMETER AsPlainText
            If specified, returns the secret as a plain text string instead of SecureString.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$SecretName,

        [Parameter()]
        [switch]$AsPlainText
    )

    Assert-AzureConnected

    try {
        if ($AsPlainText) {
            return Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -AsPlainText
        }
        else {
            $secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName
            return $secret.SecretValue
        }
    }
    catch {
        Write-Error "Failed to retrieve secret '$SecretName' from vault '$VaultName': $($_.Exception.Message)"
        throw
    }
}

function Get-ContosoKeyVaultCertificate {
    <#
        .SYNOPSIS
            Retrieves a certificate thumbprint from Azure Key Vault.

        .PARAMETER VaultName
            Name of the Key Vault.

        .PARAMETER CertName
            Name of the certificate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$CertName
    )

    Assert-AzureConnected

    try {
        $cert = Get-AzKeyVaultCertificate -VaultName $VaultName -Name $CertName
        Write-Verbose "Retrieved certificate '$CertName'. Thumbprint: $($cert.Thumbprint)"
        return $cert.Thumbprint
    }
    catch {
        Write-Error "Failed to retrieve certificate '$CertName' from vault '$VaultName': $($_.Exception.Message)"
        throw
    }
}

function Connect-ContosoExchange {
    <#
        .SYNOPSIS
            Connects to Exchange Online using Managed Identity or Certificate.

        .PARAMETER Organization
            The tenant domain (e.g., "contoso.onmicrosoft.com").

        .PARAMETER AuthMethod
            ManagedIdentity (default) or Certificate.

        .PARAMETER UserAssignedClientId
            Client ID for User-Assigned MI.

        .PARAMETER AppId
            App Registration Client ID. Required for Certificate auth.

        .PARAMETER CertThumbprint
            Certificate thumbprint. Required for Certificate auth.
    #>
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
        throw "ExchangeOnlineManagement module is not installed. Install v3.2+ in the runtime environment."
    }

    try {
        switch ($AuthMethod) {
            'ManagedIdentity' {
                $params = @{
                    ManagedIdentity = $true
                    Organization    = $Organization
                    ShowBanner      = $false
                }
                if ($UserAssignedClientId) {
                    $params['ManagedIdentityAccountId'] = $UserAssignedClientId
                }
                Write-Verbose "Connecting to Exchange Online via Managed Identity..."
                Connect-ExchangeOnline @params
                $script:ExchangeConnectParams = @{ AuthMethod = 'ManagedIdentity'; Organization = $Organization; UserAssignedClientId = $UserAssignedClientId }
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
                $script:ExchangeConnectParams = @{
                    AuthMethod = 'Certificate'; Organization = $Organization
                    AppId = $AppId; CertThumbprint = $CertThumbprint
                }
            }
        }

        Write-Verbose "Connected to Exchange Online: $Organization via $AuthMethod."
    }
    catch {
        Write-Error "Failed to connect to Exchange Online: $($_.Exception.Message)"
        throw
    }
}

function Invoke-ContosoWithRetry {
    <#
        .SYNOPSIS
            Executes a script block with automatic token refresh and retry on auth failures.

        .DESCRIPTION
            Wraps a script block in retry logic that detects token expiry (401/403 errors)
            and automatically reconnects before retrying. Use this for long-running operations
            or loops that may span beyond the token lifetime (~60 minutes).

        .PARAMETER ScriptBlock
            The code to execute.

        .PARAMETER MaxRetries
            Maximum number of retry attempts after auth failure. Default: 2.

        .PARAMETER RetryDelaySeconds
            Seconds to wait after reconnecting before retrying. Default: 5.

        .EXAMPLE
            # Wrap a long-running operation
            Invoke-ContosoWithRetry -ScriptBlock {
                $items = Get-PnPListItem -List "LargeList" -PageSize 500
                foreach ($item in $items) {
                    Set-PnPListItem -List "LargeList" -Identity $item.Id -Values @{ Status = "Processed" }
                }
            }

        .EXAMPLE
            # Process items in a loop with automatic token refresh
            $sites = Get-PnPTenantSite
            foreach ($site in $sites) {
                Invoke-ContosoWithRetry -ScriptBlock {
                    Connect-PnPOnline -Url $site.Url -ManagedIdentity
                    $lists = Get-PnPList
                    Write-Output "$($site.Url): $($lists.Count) lists"
                }
            }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [int]$MaxRetries = 2,

        [Parameter()]
        [int]$RetryDelaySeconds = 5
    )

    # Proactively refresh Azure token if approaching expiry
    Test-ContosoTokenFreshness

    $attempt = 0
    while ($true) {
        try {
            return (& $ScriptBlock)
        }
        catch {
            $errMsg = $_.Exception.Message

            # Check for non-recoverable authorization denial — fail fast, do not retry
            $isAuthzDenial = $script:AuthorizationDenialPatterns | Where-Object { $errMsg -match $_ }
            if ($isAuthzDenial) {
                Write-Error "Authorization denied (not retryable): $errMsg"
                throw
            }

            # Check for retryable token expiry
            $isTokenExpiry = ($errMsg -match '401|Unauthorized') -or
                ($script:TokenExpiryPatterns | Where-Object { $errMsg -match $_ })

            if ($isTokenExpiry -and $attempt -lt $MaxRetries) {
                $attempt++
                Write-Warning "Token expiry detected (attempt $attempt of $MaxRetries). Refreshing connections..."

                # Refresh Azure context
                if ($script:IsAzureConnected -and $script:AzureConnectParams.Count -gt 0) {
                    try {
                        Connect-AzAccount @script:AzureConnectParams -WarningAction SilentlyContinue | Out-Null
                        $script:LastAzureTokenRefresh = Get-Date
                        Write-Verbose "Azure token refreshed."
                    }
                    catch { Write-Warning "Azure reconnect failed: $($_.Exception.Message)" }
                }

                # Refresh Graph using original auth context
                if ($script:GraphConnectParams.Count -gt 0) {
                    try {
                        switch ($script:GraphConnectParams.AuthMethod) {
                            'ManagedIdentity' {
                                Connect-MgGraph @($script:GraphConnectParams.Params) -NoWelcome
                            }
                            'Certificate' {
                                $p = $script:GraphConnectParams.Params
                                Connect-MgGraph -ClientId $p.ClientId -TenantId $p.TenantId `
                                    -CertificateThumbprint $p.CertificateThumbprint -NoWelcome
                            }
                        }
                        Write-Verbose "Graph token refreshed with original auth context."
                    }
                    catch { Write-Warning "Graph reconnect failed: $($_.Exception.Message)" }
                }

                # Refresh PnP SharePoint using original auth context
                if ($script:SharePointConnectParams.Count -gt 0) {
                    try {
                        $sp = $script:SharePointConnectParams
                        switch ($sp.AuthMethod) {
                            'ManagedIdentity' {
                                $pnpParams = @{ Url = $sp.SiteUrl; ManagedIdentity = $true }
                                if ($sp.UserAssignedClientId) {
                                    $pnpParams['UserAssignedManagedIdentityClientId'] = $sp.UserAssignedClientId
                                }
                                Connect-PnPOnline @pnpParams
                            }
                            'Certificate' {
                                Connect-PnPOnline -Url $sp.SiteUrl -ClientId $sp.ClientId `
                                    -Tenant $sp.TenantName -Thumbprint $sp.CertThumbprint
                            }
                        }
                        Write-Verbose "PnP SharePoint reconnected to $($sp.SiteUrl)."
                    }
                    catch { Write-Warning "PnP reconnect failed: $($_.Exception.Message)" }
                }

                # Refresh Exchange using original auth context
                if ($script:ExchangeConnectParams.Count -gt 0) {
                    try {
                        $ex = $script:ExchangeConnectParams
                        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
                        switch ($ex.AuthMethod) {
                            'ManagedIdentity' {
                                $exParams = @{ ManagedIdentity = $true; Organization = $ex.Organization; ShowBanner = $false }
                                if ($ex.UserAssignedClientId) { $exParams['ManagedIdentityAccountId'] = $ex.UserAssignedClientId }
                                Connect-ExchangeOnline @exParams
                            }
                            'Certificate' {
                                Connect-ExchangeOnline -CertificateThumbprint $ex.CertThumbprint `
                                    -AppId $ex.AppId -Organization $ex.Organization -ShowBanner:$false
                            }
                        }
                        Write-Verbose "Exchange Online reconnected."
                    }
                    catch { Write-Warning "Exchange reconnect failed: $($_.Exception.Message)" }
                }

                Start-Sleep -Seconds $RetryDelaySeconds
            }
            else {
                # Not a token expiry, or retries exhausted
                throw
            }
        }
    }
}

function Disconnect-ContosoAll {
    <#
        .SYNOPSIS
            Disconnects from all services. Call in the finally block.
    #>
    [CmdletBinding()]
    param()

    Write-Verbose "Disconnecting from all services..."

    # Exchange Online
    if (Get-Module -Name 'ExchangeOnlineManagement' -ErrorAction SilentlyContinue) {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }

    # PnP
    if (Get-Module -Name 'PnP.PowerShell' -ErrorAction SilentlyContinue) {
        Disconnect-PnPOnline -ErrorAction SilentlyContinue
    }

    # Microsoft Graph
    if (Get-Module -Name 'Microsoft.Graph.Authentication' -ErrorAction SilentlyContinue) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
    }

    # Azure (disconnect last)
    Disconnect-AzAccount -ErrorAction SilentlyContinue
    $script:IsAzureConnected = $false
    $script:AzureConnectParams = @{}
    $script:LastAzureTokenRefresh = $null

    Write-Verbose "Disconnected from all services."
}

# =============================================================================
# PRIVATE FUNCTIONS
# =============================================================================

function Assert-AzureConnected {
    <#
        .SYNOPSIS
            Ensures Connect-ContosoAzure has been called. Used by Key Vault functions.
    #>
    if (-not $script:IsAzureConnected) {
        throw "Not connected to Azure. Call Connect-ContosoAzure first."
    }

    # Proactively refresh token if stale
    Test-ContosoTokenFreshness
}

function Test-ContosoTokenFreshness {
    <#
        .SYNOPSIS
            Proactively refreshes the Azure token if it is approaching expiry.
            Called internally before Key Vault operations and by Invoke-ContosoWithRetry.
    #>
    if (-not $script:IsAzureConnected -or -not $script:LastAzureTokenRefresh) {
        return
    }

    $elapsed = (Get-Date) - $script:LastAzureTokenRefresh
    if ($elapsed.TotalMinutes -ge $script:TokenRefreshIntervalMinutes) {
        Write-Verbose "Azure token is $([int]$elapsed.TotalMinutes) min old (threshold: $($script:TokenRefreshIntervalMinutes) min). Refreshing..."
        try {
            Connect-AzAccount @script:AzureConnectParams -WarningAction SilentlyContinue | Out-Null
            $script:LastAzureTokenRefresh = Get-Date
            Write-Verbose "Azure token refreshed successfully."
        }
        catch {
            Write-Warning "Proactive token refresh failed: $($_.Exception.Message). Continuing with current token."
        }
    }
}

Export-ModuleMember -Function Connect-Contoso*, Get-ContosoKeyVault*, Invoke-ContosoWithRetry, Disconnect-ContosoAll
