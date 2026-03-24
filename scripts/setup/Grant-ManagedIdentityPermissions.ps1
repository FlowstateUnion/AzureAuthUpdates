<#
    .SYNOPSIS
        Grants required Entra ID App Roles to a Managed Identity.

    .DESCRIPTION
        Assigns Microsoft Graph and SharePoint Online API permissions to the
        Automation Account's Managed Identity. Run this ONCE from an admin
        workstation (not inside a runbook).

    .PARAMETER ManagedIdentityObjectId
        Object ID of the Managed Identity (from Entra ID > Enterprise Applications).

    .PARAMETER GrantSharePoint
        If specified, grants SharePoint Online Sites.FullControl.All.

    .PARAMETER GrantGraph
        If specified, grants common Microsoft Graph permissions.

    .PARAMETER GraphPermissions
        Array of Graph permission names to grant. Defaults to a common set.

    .EXAMPLE
        .\Grant-ManagedIdentityPermissions.ps1 `
            -ManagedIdentityObjectId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
            -GrantSharePoint `
            -GrantGraph
#>

param(
    [Parameter(Mandatory)]
    [string]$ManagedIdentityObjectId,

    [Parameter()]
    [switch]$GrantSharePoint,

    [Parameter()]
    [switch]$GrantGraph,

    [Parameter()]
    [string[]]$GraphPermissions = @(
        "Sites.ReadWrite.All"
        "User.Read.All"
        "Group.Read.All"
        "Mail.Send"
    )
)

$ErrorActionPreference = "Stop"

# --- Ensure Graph SDK is available and connected ---
if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Applications')) {
    throw "Microsoft.Graph.Applications module is required. Install-Module Microsoft.Graph.Applications"
}

Write-Output "Connecting to Microsoft Graph (interactive)..."
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All", "Application.Read.All"

# --- Well-known App IDs ---
$graphAppId      = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph
$sharepointAppId = "00000003-0000-0ff1-ce00-000000000000"  # SharePoint Online

# --- Helper function ---
function Grant-AppRole {
    param(
        [string]$MIObjectId,
        [string]$ResourceAppId,
        [string]$RoleName
    )

    $resourceSP = Get-MgServicePrincipal -Filter "appId eq '$ResourceAppId'"
    if (-not $resourceSP) {
        Write-Warning "Service principal for appId '$ResourceAppId' not found. Skipping."
        return
    }

    $role = $resourceSP.AppRoles | Where-Object { $_.Value -eq $RoleName }
    if (-not $role) {
        Write-Warning "App role '$RoleName' not found on '$ResourceAppId'. Skipping."
        return
    }

    # Check if already assigned
    $existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $MIObjectId |
        Where-Object { $_.AppRoleId -eq $role.Id -and $_.ResourceId -eq $resourceSP.Id }

    if ($existing) {
        Write-Output "  Already assigned: $RoleName"
        return
    }

    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $MIObjectId `
        -PrincipalId $MIObjectId `
        -ResourceId $resourceSP.Id `
        -AppRoleId $role.Id | Out-Null

    Write-Output "  Granted: $RoleName"
}

# --- Grant SharePoint permissions ---
if ($GrantSharePoint) {
    Write-Output ""
    Write-Output "Granting SharePoint Online permissions..."
    Grant-AppRole -MIObjectId $ManagedIdentityObjectId `
        -ResourceAppId $sharepointAppId `
        -RoleName "Sites.FullControl.All"
}

# --- Grant Graph permissions ---
if ($GrantGraph) {
    Write-Output ""
    Write-Output "Granting Microsoft Graph permissions..."
    foreach ($perm in $GraphPermissions) {
        Grant-AppRole -MIObjectId $ManagedIdentityObjectId `
            -ResourceAppId $graphAppId `
            -RoleName $perm
    }
}

Write-Output ""
Write-Output "Done. Verify assignments in Entra ID > Enterprise Applications > [MI Name] > Permissions."
Disconnect-MgGraph
