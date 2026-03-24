#Requires -Modules Contoso.Automation.Auth
# Uncomment the modules this runbook needs:
# #Requires -Modules @{ ModuleName="PnP.PowerShell"; ModuleVersion="2.4" }
# #Requires -Modules @{ ModuleName="Microsoft.Graph.Authentication"; ModuleVersion="2.0" }
# #Requires -Modules @{ ModuleName="ExchangeOnlineManagement"; ModuleVersion="3.2" }

<#
    .SYNOPSIS
        [One-line description of what this runbook does]

    .DESCRIPTION
        [Detailed description: what it does, what it affects, when it runs]

    .PARAMETER SiteUrl
        [Description of each parameter]

    .NOTES
        Runtime:      PowerShell 7.4
        Identity:     System-Assigned Managed Identity
        Permissions:  [List required Entra ID App Roles, e.g., Sites.FullControl.All]
        Schedule:     [If scheduled, describe frequency]
        Last Updated: [Date]
        Author:       [Name]
#>

param(
    [Parameter(Mandatory)]
    [string]$SiteUrl

    # Add runbook-specific parameters here
)

# --- Configuration ---
$ErrorActionPreference = "Stop"
$InformationPreference = "Continue"

# --- Authentication ---
Import-Module Contoso.Automation.Auth

try {
    Write-Output "Authenticating via Managed Identity..."
    Connect-ContosoAzure

    # Uncomment the services this runbook needs:
    # Connect-ContosoSharePoint -SiteUrl $SiteUrl
    # Connect-ContosoGraph
    # Connect-ContosoExchange -Organization "contoso.onmicrosoft.com"

    Write-Output "Authentication successful."

    # =========================================================================
    # BUSINESS LOGIC — Replace this section with the runbook's actual work
    # =========================================================================

    Write-Output "Starting operations..."

    # Example: SharePoint operations via PnP
    # $lists = Get-PnPList
    # foreach ($list in $lists) {
    #     Write-Output "List: $($list.Title) — Items: $($list.ItemCount)"
    # }

    # Example: Graph operations
    # $users = Get-MgUser -Top 10
    # foreach ($user in $users) {
    #     Write-Output "User: $($user.DisplayName)"
    # }

    Write-Output "Operations completed successfully."

    # =========================================================================
    # END BUSINESS LOGIC
    # =========================================================================
}
catch {
    Write-Error "Runbook failed: $($_.Exception.Message)"
    Write-Error "Stack trace: $($_.ScriptStackTrace)"
    throw
}
finally {
    # --- Cleanup ---
    Disconnect-ContosoAll
    Write-Output "Runbook execution finished."
}
