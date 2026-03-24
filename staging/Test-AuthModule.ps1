<#
    .SYNOPSIS
        Validates the Contoso.Automation.Auth module in a live Azure Automation context.

    .DESCRIPTION
        Tests each authentication function in the shared module to verify
        Managed Identity connectivity to Azure, SharePoint, and Microsoft Graph.
        Run this as a test runbook after deploying the module and granting permissions.

    .PARAMETER SharePointSiteUrl
        A SharePoint site URL to test PnP connectivity against.

    .PARAMETER KeyVaultName
        Name of the Key Vault to test secret retrieval (optional).

    .PARAMETER TestSecretName
        Name of a test secret in Key Vault (optional).

    .NOTES
        Runtime:     PowerShell 7.4
        Identity:    System-Assigned Managed Identity
        Permissions: Sites.FullControl.All (SharePoint), User.Read.All (Graph)
#>

#Requires -Modules Contoso.Automation.Auth

param(
    [Parameter(Mandatory)]
    [string]$SharePointSiteUrl,

    [Parameter()]
    [string]$KeyVaultName,

    [Parameter()]
    [string]$TestSecretName
)

$ErrorActionPreference = "Stop"
$testResults = [System.Collections.ArrayList]::new()

function Add-TestResult {
    param([string]$Test, [bool]$Passed, [string]$Details)
    $null = $script:testResults.Add([PSCustomObject]@{
        Test    = $Test
        Passed  = $Passed
        Details = $Details
    })
    $status = if ($Passed) { "PASS" } else { "FAIL" }
    Write-Output "[$status] $Test — $Details"
}

Import-Module Contoso.Automation.Auth -Force

try {
    # --- Test 1: Azure connection ---
    Write-Output ""
    Write-Output "=== Test 1: Connect-ContosoAzure ==="
    try {
        Connect-ContosoAzure -Verbose
        $ctx = Get-AzContext
        Add-TestResult -Test "Azure MI Connection" -Passed $true `
            -Details "Subscription: $($ctx.Subscription.Name), Tenant: $($ctx.Tenant.Id)"
    }
    catch {
        Add-TestResult -Test "Azure MI Connection" -Passed $false -Details $_.Exception.Message
    }

    # --- Test 2: SharePoint (PnP) connection ---
    Write-Output ""
    Write-Output "=== Test 2: Connect-ContosoSharePoint ==="
    try {
        Connect-ContosoSharePoint -SiteUrl $SharePointSiteUrl -Verbose
        $web = Get-PnPWeb
        Add-TestResult -Test "SharePoint PnP Connection" -Passed $true `
            -Details "Site: $($web.Title) ($($web.Url))"
    }
    catch {
        Add-TestResult -Test "SharePoint PnP Connection" -Passed $false -Details $_.Exception.Message
    }

    # --- Test 3: Microsoft Graph connection ---
    Write-Output ""
    Write-Output "=== Test 3: Connect-ContosoGraph ==="
    try {
        Connect-ContosoGraph -Verbose
        $graphCtx = Get-MgContext
        Add-TestResult -Test "Graph MI Connection" -Passed $true `
            -Details "TenantId: $($graphCtx.TenantId), Scopes: $($graphCtx.Scopes -join ', ')"
    }
    catch {
        Add-TestResult -Test "Graph MI Connection" -Passed $false -Details $_.Exception.Message
    }

    # --- Test 4: Key Vault (optional) ---
    if ($KeyVaultName -and $TestSecretName) {
        Write-Output ""
        Write-Output "=== Test 4: Key Vault Secret Retrieval ==="
        try {
            $secret = Get-ContosoKeyVaultSecret -VaultName $KeyVaultName -SecretName $TestSecretName
            $hasValue = $null -ne $secret
            Add-TestResult -Test "Key Vault Secret" -Passed $hasValue `
                -Details "Secret '$TestSecretName' retrieved: $hasValue"
        }
        catch {
            Add-TestResult -Test "Key Vault Secret" -Passed $false -Details $_.Exception.Message
        }
    }

    # --- Summary ---
    Write-Output ""
    Write-Output "========================================="
    Write-Output "         TEST SUMMARY"
    Write-Output "========================================="
    $passed = ($testResults | Where-Object Passed).Count
    $failed = ($testResults | Where-Object { -not $_.Passed }).Count
    Write-Output "Passed: $passed / $($testResults.Count)"
    Write-Output "Failed: $failed / $($testResults.Count)"

    if ($failed -gt 0) {
        Write-Output ""
        Write-Output "Failed tests:"
        $testResults | Where-Object { -not $_.Passed } | ForEach-Object {
            Write-Output "  - $($_.Test): $($_.Details)"
        }
        throw "$failed test(s) failed. See details above."
    }
    else {
        Write-Output ""
        Write-Output "All tests passed. The shared auth module is working correctly."
    }
}
finally {
    Disconnect-ContosoAll
}
