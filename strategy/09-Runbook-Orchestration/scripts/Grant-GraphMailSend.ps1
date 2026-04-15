<#
    .SYNOPSIS
        Grants Mail.Send (application) on Microsoft Graph to a Managed Identity.

    .DESCRIPTION
        Assigns the Mail.Send app role to the service principal that
        corresponds to a System-Assigned or User-Assigned Managed Identity.
        Idempotent: if already granted, reports and exits.

        Requires the caller to be an Application Administrator or Global
        Administrator in Entra ID.

    .PARAMETER ManagedIdentityObjectId
        The ObjectId of the MI's service principal (NOT the appId).

    .PARAMETER AdditionalRoles
        Optional list of other Graph app roles to grant in the same pass
        (e.g. 'Mail.ReadBasic.All', 'User.Read.All').

    .EXAMPLE
        .\Grant-GraphMailSend.ps1 -ManagedIdentityObjectId 'xxxxxxxx-xxxx-...'
#>
param(
    [Parameter(Mandatory)] [string] $ManagedIdentityObjectId,
    [string[]] $AdditionalRoles = @()
)

$ErrorActionPreference = 'Stop'
$graphAppId = '00000003-0000-0000-c000-000000000000'

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Import-Module Microsoft.Graph.Applications -ErrorAction Stop

if (-not (Get-MgContext)) {
    Write-Host "Connecting to Microsoft Graph..."
    Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All','Application.Read.All' -NoWelcome
}

$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
if (-not $graphSp) { throw "Could not find Microsoft Graph service principal." }

$mi = Get-MgServicePrincipal -ServicePrincipalId $ManagedIdentityObjectId -ErrorAction Stop
Write-Host "Target MI: $($mi.DisplayName)  ($ManagedIdentityObjectId)"

$rolesToGrant = @('Mail.Send') + $AdditionalRoles

foreach ($roleName in $rolesToGrant) {
    $role = $graphSp.AppRoles | Where-Object { $_.Value -eq $roleName -and $_.AllowedMemberTypes -contains 'Application' }
    if (-not $role) {
        Write-Warning "Role '$roleName' not found as an application role on Graph. Skipping."
        continue
    }

    $existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $mi.Id |
        Where-Object { $_.AppRoleId -eq $role.Id -and $_.ResourceId -eq $graphSp.Id }

    if ($existing) {
        Write-Host "  [skip]  $roleName already granted."
        continue
    }

    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $mi.Id `
        -PrincipalId        $mi.Id `
        -ResourceId         $graphSp.Id `
        -AppRoleId          $role.Id | Out-Null

    Write-Host "  [grant] $roleName" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. It may take a few minutes for role assignments to propagate."
Write-Host ""
Write-Host "SCOPE WARNING: Mail.Send (application) allows sending as ANY mailbox in"
Write-Host "the tenant. To restrict the MI to specific mailboxes, create an"
Write-Host "Application Access Policy (Exchange Online):"
Write-Host "  New-ApplicationAccessPolicy -AppId <MI-appId> -PolicyScopeGroupId <sg-id> -AccessRight RestrictAccess"
