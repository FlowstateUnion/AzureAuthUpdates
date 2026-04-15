<#
    .SYNOPSIS
        Imports a local .ps1 into an Azure Automation Account and publishes it.

    .DESCRIPTION
        Thin wrapper around Import-AzAutomationRunbook + Publish-AzAutomationRunbook
        that enforces the project's conventions:
          - PowerShell 7.4 runtime by default
          - Overwrites existing draft
          - Validates the name matches the file's base name (shared runbooks
            are called by name via .\<Name>.ps1, so the two MUST match)

    .PARAMETER ResourceGroupName
        Resource group containing the Automation Account.

    .PARAMETER AutomationAccountName
        Target Automation Account.

    .PARAMETER Path
        Path to the local .ps1 file to publish.

    .PARAMETER Name
        Optional override for the runbook name. Defaults to the file's base
        name (recommended — matches the inline-call convention).

    .PARAMETER RuntimeVersion
        '7.4' (default) or '5.1'.

    .PARAMETER Description
        Runbook description shown in the portal.

    .EXAMPLE
        .\Publish-SharedRunbook.ps1 -ResourceGroupName rg-aa -AutomationAccountName aa-ops `
            -Path ..\..\..\runbooks\testing\Send-ContosoEmail.ps1
#>
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $AutomationAccountName,
    [Parameter(Mandatory)] [string] $Path,
    [string] $Name,
    [ValidateSet('7.4','5.1')] [string] $RuntimeVersion = '7.4',
    [string] $Description
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Path)) { throw "File not found: $Path" }
$file = Get-Item $Path
if (-not $Name) { $Name = $file.BaseName }

if ($Name -ne $file.BaseName) {
    Write-Warning "Name '$Name' differs from file base name '$($file.BaseName)'."
    Write-Warning "Inline calls (.\$Name.ps1) depend on exact name match. Continue only if you know why."
}

$type = if ($RuntimeVersion -eq '7.4') { 'PowerShell74' } else { 'PowerShell' }

Write-Host "Importing '$Name' from $($file.FullName) as $type..."
$params = @{
    ResourceGroupName     = $ResourceGroupName
    AutomationAccountName = $AutomationAccountName
    Path                  = $file.FullName
    Name                  = $Name
    Type                  = $type
    Force                 = $true
}
if ($Description) { $params['Description'] = $Description }

Import-AzAutomationRunbook @params | Out-Null

Write-Host "Publishing '$Name'..."
Publish-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName -Name $Name | Out-Null

$runbook = Get-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName -Name $Name

Write-Host ""
Write-Host "Published." -ForegroundColor Green
Write-Host "  Name:            $($runbook.Name)"
Write-Host "  State:           $($runbook.State)"
Write-Host "  Runtime:         $($runbook.RunbookType)"
Write-Host "  LastModified:    $($runbook.LastModifiedTime)"
Write-Host ""
Write-Host "Callable from other runbooks as:  .\$Name.ps1 -Param1 value1 ..."
