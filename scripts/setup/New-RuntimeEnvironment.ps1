<#
    .SYNOPSIS
        Creates a custom PowerShell 7.4 Runtime Environment with pinned modules.

    .DESCRIPTION
        Provisions a custom runtime environment on the Azure Automation Account
        with all modules required for the modernized runbooks, at pinned versions.

    .PARAMETER ResourceGroupName
        Resource group containing the Automation Account.

    .PARAMETER AutomationAccountName
        Name of the Automation Account.

    .PARAMETER EnvironmentName
        Name for the custom runtime environment. Default: "PS74-ModernAuth"

    .EXAMPLE
        .\New-RuntimeEnvironment.ps1 -ResourceGroupName "rg-automation" -AutomationAccountName "aa-prod"
#>

param(
    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$AutomationAccountName,

    [Parameter()]
    [string]$EnvironmentName
)

$ErrorActionPreference = "Stop"

# --- Load .env config ---
. "$PSScriptRoot\..\shared\Load-EnvConfig.ps1"
. "$PSScriptRoot\..\shared\Resolve-ConfigValue.ps1"

$ResourceGroupName    = Resolve-ConfigValue -Value $ResourceGroupName    -EnvVar "AUTOMATION_RESOURCE_GROUP"  -Prompt "Resource Group Name" -Required
$AutomationAccountName = Resolve-ConfigValue -Value $AutomationAccountName -EnvVar "AUTOMATION_ACCOUNT_NAME"   -Prompt "Automation Account Name" -Required
$EnvironmentName       = Resolve-ConfigValue -Value $EnvironmentName       -EnvVar "AUTOMATION_RUNTIME_ENV"    -Prompt "Runtime Environment Name"
if (-not $EnvironmentName) { $EnvironmentName = "PS74-ModernAuth" }

# --- Module manifest: name → version ---
# Update these versions as needed; always pin to a specific version.
$modules = @(
    @{ Name = "Az.Accounts";                      Version = "3.0.5" }
    @{ Name = "Az.KeyVault";                       Version = "6.2.0" }
    @{ Name = "Az.Automation";                     Version = "1.10.0" }
    @{ Name = "PnP.PowerShell";                    Version = "2.12.0" }
    @{ Name = "Microsoft.Graph.Authentication";    Version = "2.25.0" }
    @{ Name = "Microsoft.Graph.Sites";             Version = "2.25.0" }
    @{ Name = "Microsoft.Graph.Users";             Version = "2.25.0" }
    @{ Name = "Microsoft.Graph.Groups";            Version = "2.25.0" }
    # Add more Graph sub-modules here as needed
)

Write-Output "Creating runtime environment '$EnvironmentName' on '$AutomationAccountName'..."

# Note: As of early 2026, runtime environment creation may require the REST API
# or the latest Az.Automation module. The cmdlets below may vary by Az.Automation version.
# If New-AzAutomationRuntimeEnvironment is not available, use the Azure REST API approach below.

try {
    # Attempt cmdlet-based approach
    New-AzAutomationRuntimeEnvironment `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $EnvironmentName `
        -Language "PowerShell" `
        -Runtime "7.4" `
        -Description "Modern auth runtime with pinned modules for migrated runbooks" `
        -ErrorAction Stop

    Write-Output "Runtime environment created."
}
catch {
    Write-Error "New-AzAutomationRuntimeEnvironment cmdlet failed: $($_.Exception.Message)"
    Write-Output ""
    Write-Output "CANNOT CONTINUE — runtime environment must exist before installing modules."
    Write-Output ""
    Write-Output "Create it manually, then re-run this script:"
    Write-Output "  Portal: Automation Account > Runtime Environments > Create"
    Write-Output "  Name: $EnvironmentName"
    Write-Output "  Language: PowerShell"
    Write-Output "  Runtime: 7.4"
    throw "Runtime environment creation failed. Resolve before continuing."
}

# --- Install modules ---
Write-Output ""
Write-Output "Installing modules into '$EnvironmentName'..."

$psGalleryBase = "https://www.powershellgallery.com/api/v2/package"

foreach ($mod in $modules) {
    $uri = "$psGalleryBase/$($mod.Name)/$($mod.Version)"
    Write-Output "  Installing $($mod.Name) v$($mod.Version)..."

    try {
        New-AzAutomationModule `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $mod.Name `
            -ContentLinkUri $uri `
            -RuntimeEnvironment $EnvironmentName `
            -ErrorAction Stop | Out-Null

        Write-Output "    Queued for installation."
    }
    catch {
        Write-Warning "    Failed to install $($mod.Name): $($_.Exception.Message)"
    }
}

Write-Output ""
Write-Output "Module installation queued. Monitor status in Azure Portal:"
Write-Output "  Automation Account > Runtime Environments > $EnvironmentName > Modules"
Write-Output ""
Write-Output "Note: Module installation is async. Wait for all modules to show 'Available'"
Write-Output "before assigning runbooks to this runtime environment."
