<#
    .SYNOPSIS
        Reports whether an Automation Account is piping its JobLogs and
        JobStreams into a Log Analytics workspace.

    .DESCRIPTION
        Layer 2 (KQL) monitoring only works when a diagnostic setting is
        in place. This script tells you exactly what you have and what's
        missing, and prints the workspace ID you'll pass to the other
        monitoring scripts.

    .PARAMETER ResourceGroupName
        Resource group containing the Automation Account.

    .PARAMETER AutomationAccountName
        The Automation Account name.

    .EXAMPLE
        .\Test-DiagnosticSettings.ps1 -ResourceGroupName rg-aa -AutomationAccountName aa-ops
#>
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $AutomationAccountName
)

$ErrorActionPreference = 'Stop'

$aa = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName
if (-not $aa) { throw "Automation Account not found: $AutomationAccountName in $ResourceGroupName" }

$resourceId = $aa.AutomationAccountId ?? $aa.ResourceId
if (-not $resourceId) {
    # Az.Automation historically exposes it via Id on some object shapes
    $resourceId = (Get-AzResource -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.Automation/automationAccounts' `
        -Name $AutomationAccountName).ResourceId
}

Write-Host "Automation Account: $AutomationAccountName"
Write-Host "Resource ID:        $resourceId"
Write-Host ""

$settings = Get-AzDiagnosticSetting -ResourceId $resourceId -ErrorAction SilentlyContinue

if (-not $settings) {
    Write-Host "Layer 2: NOT CONFIGURED" -ForegroundColor Yellow
    Write-Host "  No diagnostic settings found. You only have Layer 1 (Az.Automation cmdlets, ~30 day retention)."
    Write-Host "  To enable Layer 2, see 02-Implementation-Instructions.md Step 2."
    return [pscustomobject]@{ Status = 'NotConfigured'; WorkspaceId = $null }
}

$results = foreach ($s in $settings) {
    $logs = $s.Log
    $jobLogsOn    = $logs | Where-Object { $_.Category -eq 'JobLogs'    -and $_.Enabled } | Select-Object -First 1
    $jobStreamsOn = $logs | Where-Object { $_.Category -eq 'JobStreams' -and $_.Enabled } | Select-Object -First 1

    [pscustomobject]@{
        SettingName   = $s.Name
        WorkspaceId   = $s.WorkspaceId
        JobLogs       = [bool]$jobLogsOn
        JobStreams    = [bool]$jobStreamsOn
        Dedicated     = ($s.LogAnalyticsDestinationType -eq 'Dedicated')
    }
}

$results | Format-Table -AutoSize | Out-Host

$ready = $results | Where-Object { $_.JobLogs -and $_.JobStreams -and $_.WorkspaceId }
$partial = $results | Where-Object { ($_.JobLogs -xor $_.JobStreams) -and $_.WorkspaceId }

if ($ready) {
    Write-Host "Layer 2: READY" -ForegroundColor Green
    foreach ($r in $ready) {
        Write-Host "  Workspace ID: $($r.WorkspaceId)"
        if (-not $r.Dedicated) {
            Write-Warning "  Setting '$($r.SettingName)' uses legacy AzureDiagnostics table. Consider 'Dedicated' (resource-specific) mode — see instructions."
        }
    }
    return [pscustomobject]@{ Status='Ready'; WorkspaceId = ($ready | Select-Object -First 1).WorkspaceId }
}
elseif ($partial) {
    Write-Host "Layer 2: PARTIAL" -ForegroundColor Yellow
    Write-Host "  One of JobLogs/JobStreams is disabled. Enable both for full observability."
    return [pscustomobject]@{ Status='Partial'; WorkspaceId = ($partial | Select-Object -First 1).WorkspaceId }
}
else {
    Write-Host "Layer 2: NOT CONFIGURED (diagnostic settings exist but not routed to a workspace, or not enabled for job categories)" -ForegroundColor Yellow
    return [pscustomobject]@{ Status='NotConfigured'; WorkspaceId = $null }
}
