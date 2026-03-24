<#
    .SYNOPSIS
        Skill: Reference guide for migrating a single runbook.

    .DESCRIPTION
        This script is a REFERENCE for the migration agent, not an automated
        text replacement tool. Automated regex replacement is error-prone across
        diverse scripts. The agent should read this for the migration recipe,
        then apply changes intelligently using its understanding of each script.

        The agent should:
        1. Read the source file
        2. Understand its structure and logic
        3. Apply the transformations described here
        4. Write the result to staging/

    .NOTES
        This is a SKILL REFERENCE, not an executable migration tool.
        The agent reads this, understands the patterns, and applies them manually
        with judgment — not via blind find-and-replace.
#>

# =============================================================================
# MIGRATION RECIPE — Apply these transformations in order
# =============================================================================

<#
STEP 1: ADD #Requires AT THE TOP
---------------------------------
Add module requirements based on what the script uses:

Always add:
    #Requires -Modules Contoso.Automation.Auth

Add if SharePoint operations present:
    #Requires -Modules @{ ModuleName="PnP.PowerShell"; ModuleVersion="2.4" }

Add if Graph operations present:
    #Requires -Modules @{ ModuleName="Microsoft.Graph.Authentication"; ModuleVersion="2.0" }
    (Plus specific sub-modules: Microsoft.Graph.Users, Microsoft.Graph.Sites, etc.)

Add if Exchange operations present:
    #Requires -Modules @{ ModuleName="ExchangeOnlineManagement"; ModuleVersion="3.2" }


STEP 2: ADD/UPDATE SCRIPT HEADER
---------------------------------
If no header exists, add one. If one exists, update the .NOTES section.

Template:
    <#
        .SYNOPSIS
            [Keep existing or write from the script's purpose]
        .DESCRIPTION
            [Keep existing or write from the script's logic]
        .NOTES
            Runtime:      PowerShell 7.4
            Identity:     System-Assigned Managed Identity
            Permissions:  [From permission-audit.csv for this runbook]
            Auth Module:  Contoso.Automation.Auth v1.1
            Migrated:     [Today's date]
    #>


STEP 3: REPLACE AUTH BLOCK
---------------------------------
Find the auth block (usually first 5-20 lines after param block) and replace it.

Pattern: Get-AutomationPSCredential + Connect-PnPOnline
    BEFORE:
        $cred = Get-AutomationPSCredential -Name "SomeCredential"
        Connect-PnPOnline -Url $siteUrl -Credentials $cred
    AFTER:
        Import-Module Contoso.Automation.Auth
        Connect-ContosoAzure
        Connect-ContosoSharePoint -SiteUrl $siteUrl

Pattern: Get-AutomationPSCredential + Connect-SPOService
    BEFORE:
        $cred = Get-AutomationPSCredential -Name "SPOAdmin"
        Connect-SPOService -Url "https://contoso-admin.sharepoint.com" -Credential $cred
    AFTER:
        Import-Module Contoso.Automation.Auth
        Connect-ContosoAzure
        Connect-ContosoSPOAdmin -TenantName "contoso"

Pattern: Client Secret + Connect-AzAccount
    BEFORE:
        $clientId = Get-AutomationVariable -Name "ClientId"
        $clientSecret = Get-AutomationVariable -Name "ClientSecret"
        $secSecret = ConvertTo-SecureString $clientSecret -AsPlainText -Force
        $cred = New-Object PSCredential($clientId, $secSecret)
        Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant $tenantId
    AFTER:
        Import-Module Contoso.Automation.Auth
        Connect-ContosoAzure

Pattern: Run As Connection
    BEFORE:
        $conn = Get-AutomationConnection -Name "AzureRunAsConnection"
        Connect-AzAccount -ServicePrincipal -Tenant $conn.TenantId `
            -ApplicationId $conn.ApplicationId `
            -CertificateThumbprint $conn.CertificateThumbprint
    AFTER:
        Import-Module Contoso.Automation.Auth
        Connect-ContosoAzure

Pattern: Exchange with Credential
    BEFORE:
        $cred = Get-AutomationPSCredential -Name "ExchangeAdmin"
        Connect-ExchangeOnline -Credential $cred
    AFTER:
        Import-Module Contoso.Automation.Auth
        Connect-ContosoAzure
        Connect-ContosoExchange -Organization "contoso.onmicrosoft.com"

Pattern: Connect-AzureAD
    BEFORE:
        $cred = Get-AutomationPSCredential -Name "AADAdmin"
        Connect-AzureAD -Credential $cred
    AFTER:
        Import-Module Contoso.Automation.Auth
        Connect-ContosoAzure
        Connect-ContosoGraph


STEP 4: REMAP SERVICE CMDLETS
---------------------------------
If the module changed, the cmdlet names change too.

SPO Module → PnP (see strategy/01-Connect-SPOService.md for full table):
    Get-SPOSite           → Get-PnPTenantSite
    Set-SPOSite           → Set-PnPTenantSite
    New-SPOSite           → New-PnPTenantSite
    Remove-SPOSite        → Remove-PnPTenantSite
    Set-SPOTenant         → Set-PnPTenant
    Get-SPOUser           → Get-PnPUser
    Get-SPOSiteGroup      → Get-PnPSiteGroup

AzureAD Module → Microsoft Graph:
    Get-AzureADUser       → Get-MgUser
    Get-AzureADGroup      → Get-MgGroup
    Set-AzureADUser       → Update-MgUser
    New-AzureADUser       → New-MgUser
    Remove-AzureADUser    → Remove-MgUser
    Get-AzureADGroupMember → Get-MgGroupMember
    Add-AzureADGroupMember → New-MgGroupMember

MSOnline → Microsoft Graph:
    Get-MsolUser          → Get-MgUser
    Set-MsolUser          → Update-MgUser
    Get-MsolGroup         → Get-MgGroup

Deprecated cmdlets:
    Send-MailMessage      → Send-MgUserMail (requires building message hashtable)

WMI → CIM (PS 7.4):
    Get-WmiObject         → Get-CimInstance
    Set-WmiInstance        → Set-CimInstance
    Invoke-WmiMethod       → Invoke-CimMethod


STEP 5: WRAP IN TEMPLATE STRUCTURE
---------------------------------
If the script lacks try/catch/finally, wrap the business logic:

    $ErrorActionPreference = "Stop"
    $InformationPreference = "Continue"

    Import-Module Contoso.Automation.Auth

    try {
        # Auth
        Connect-ContosoAzure
        Connect-ContosoSharePoint -SiteUrl $SiteUrl  # etc.

        # === EXISTING BUSINESS LOGIC HERE ===

    }
    catch {
        Write-Error "Runbook failed: $($_.Exception.Message)"
        Write-Error "Stack trace: $($_.ScriptStackTrace)"
        throw
    }
    finally {
        Disconnect-ContosoAll
        Write-Output "Runbook execution finished."
    }

If the script already has try/catch, add the finally block and Disconnect-ContosoAll.


STEP 6: REMOVE DEAD CODE
---------------------------------
Delete lines that are no longer needed:
    - $cred = Get-AutomationPSCredential ...
    - $secret = Get-AutomationVariable -Name "...Secret..."
    - ConvertTo-SecureString ... -AsPlainText -Force  (for credential construction)
    - New-Object PSCredential(...)
    - $conn = Get-AutomationConnection ...
    - Import-Module Microsoft.Online.SharePoint.PowerShell  (if fully migrated to PnP)
    - Import-Module AzureAD  (if migrated to Graph)
    - Import-Module MSOnline  (if migrated to Graph)
    - Import-PSSession / Remove-PSSession  (Exchange remote PS)

DO NOT delete:
    - Import-Module for modules still in use
    - Variables used by business logic
    - ConvertTo-SecureString if used for non-auth purposes (e.g., encrypting data)


STEP 7: LONG-RUNNING OPERATIONS
---------------------------------
If the script processes many items (>100) or is known to run >30 minutes,
wrap the core operation in Invoke-ContosoWithRetry:

    Invoke-ContosoWithRetry -ScriptBlock {
        foreach ($site in $sites) {
            Connect-PnPOnline -Url $site.Url -ManagedIdentity
            # ... operations ...
        }
    }
#>
