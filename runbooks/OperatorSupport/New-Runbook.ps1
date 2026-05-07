<#
    .SYNOPSIS
        Creates a new Azure Automation runbook with required tags and a chosen
        PowerShell runtime (5.1 or 7.2).

    .DESCRIPTION
        Operator support tool. Creates an empty PowerShell runbook in the target
        Automation Account, applies the mandatory governance tags (Owner and
        ResourcePurpose), and selects the runtime by mapping:

            -Runtime "5.1" -> -Type PowerShell    (Windows PowerShell 5.1)
            -Runtime "7.2" -> -Type PowerShell72  (PowerShell 7.2)

        Resource Group and Automation Account fall back to .env values
        (AUTOMATION_RESOURCE_GROUP, AUTOMATION_ACCOUNT_NAME) if not provided.

        Note on runtime environments:
        This script picks the runtime version via the legacy -Type parameter,
        which is what New-AzAutomationRunbook (Az.Automation) supports today.
        Custom Runtime Environments (e.g. PS74-ModernAuth with pinned modules)
        are a separate construct and are assigned via the Portal or REST API
        after creation. For modernized runbooks see scripts/setup/New-RuntimeEnvironment.ps1.

    .PARAMETER Name
        Runbook name (must be unique within the Automation Account).

    .PARAMETER Owner
        Value for the 'Owner' tag. Typically a person, team alias, or DL.

    .PARAMETER ResourcePurpose
        Value for the 'ResourcePurpose' tag. Short description of why this
        runbook exists (e.g. "SharePoint cleanup", "License reporting").

    .PARAMETER Runtime
        PowerShell runtime to target. Allowed: '5.1' or '7.2'.

    .PARAMETER Description
        Optional description set on the runbook.

    .PARAMETER ResourceGroupName
        Resource group containing the Automation Account. Falls back to
        AUTOMATION_RESOURCE_GROUP from .env, then prompts.

    .PARAMETER AutomationAccountName
        Automation Account name. Falls back to AUTOMATION_ACCOUNT_NAME
        from .env, then prompts.

    .EXAMPLE
        .\New-Runbook.ps1 -Name "Cleanup-OldSites" -Owner "alice@contoso.com" `
            -ResourcePurpose "SharePoint cleanup" -Runtime 7.2

    .EXAMPLE
        .\New-Runbook.ps1 -Name "Legacy-AdHoc" -Owner "ops-team" `
            -ResourcePurpose "Ad-hoc operator scripts" -Runtime 5.1 `
            -Description "Container for one-off PS 5.1 scripts" `
            -ResourceGroupName rg-automation -AutomationAccountName aa-prod
#>

param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [string]$Owner,

    [Parameter(Mandatory)]
    [string]$ResourcePurpose,

    [Parameter(Mandatory)]
    [ValidateSet('5.1','7.2')]
    [string]$Runtime,

    [Parameter()]
    [string]$Description,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$AutomationAccountName
)

$ErrorActionPreference = 'Stop'

# --- Load .env config ---
. "$PSScriptRoot\..\..\scripts\shared\Load-EnvConfig.ps1"
. "$PSScriptRoot\..\..\scripts\shared\Resolve-ConfigValue.ps1"

$ResourceGroupName     = Resolve-ConfigValue -Value $ResourceGroupName     -EnvVar 'AUTOMATION_RESOURCE_GROUP' -Prompt 'Resource Group Name'    -Required
$AutomationAccountName = Resolve-ConfigValue -Value $AutomationAccountName -EnvVar 'AUTOMATION_ACCOUNT_NAME'   -Prompt 'Automation Account Name' -Required

# --- Map runtime to cmdlet -Type value ---
$runbookType = switch ($Runtime) {
    '5.1' { 'PowerShell' }
    '7.2' { 'PowerShell72' }
}

# --- Verify Az session ---
$ctx = Get-AzContext
if (-not $ctx) {
    throw "No Azure context. Run Connect-AzAccount before invoking this script."
}

# --- Ensure runbook name isn't already taken ---
$existing = Get-AzAutomationRunbook `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -Name $Name `
    -ErrorAction SilentlyContinue
if ($existing) {
    throw "Runbook '$Name' already exists in $AutomationAccountName ($ResourceGroupName)."
}

# --- Build tag set ---
$tags = @{
    Owner           = $Owner
    ResourcePurpose = $ResourcePurpose
}

Write-Output "Creating runbook '$Name' (Type: $runbookType) in $AutomationAccountName..."
Write-Output "  Owner:           $Owner"
Write-Output "  ResourcePurpose: $ResourcePurpose"

$createParams = @{
    ResourceGroupName     = $ResourceGroupName
    AutomationAccountName = $AutomationAccountName
    Name                  = $Name
    Type                  = $runbookType
    Tags                  = $tags
    ErrorAction           = 'Stop'
}
if ($Description) { $createParams['Description'] = $Description }

$runbook = New-AzAutomationRunbook @createParams

Write-Output ""
Write-Output "Runbook created."
Write-Output "  Name:     $($runbook.Name)"
Write-Output "  Type:     $($runbook.RunbookType)"
Write-Output "  State:    $($runbook.State)"
Write-Output "  Tags:     Owner='$Owner', ResourcePurpose='$ResourcePurpose'"
Write-Output ""
Write-Output "Next steps:"
Write-Output "  1. Author content via Portal, VS Code, or Import-AzAutomationRunbook -Path <file>.ps1"
Write-Output "  2. Publish with: Publish-AzAutomationRunbook -ResourceGroupName $ResourceGroupName ``"
Write-Output "                     -AutomationAccountName $AutomationAccountName -Name $Name"
if ($Runtime -eq '7.2') {
    Write-Output "  3. (Optional) Assign a custom Runtime Environment via Portal for pinned modules."
}

return $runbook
