<#
    .SYNOPSIS
        Inventories all schedules, webhooks, and child runbook calls for each runbook.

    .DESCRIPTION
        Connects to an Azure Automation Account and discovers:
        - Schedules linked to each runbook
        - Webhooks configured for each runbook
        - Child runbook calls (Start-AzAutomationRunbook) found in source code
        - Parameters passed to child runbooks
        - Credential parameters passed from external triggers

        Produces a dependency report that must be reviewed before migration to ensure
        schedules/webhooks survive the transition and child runbooks are migrated in
        the correct order.

    .PARAMETER ResourceGroupName
        Resource group containing the Automation Account.

    .PARAMETER AutomationAccountName
        Name of the Automation Account.

    .PARAMETER RunbookSourcePath
        Path to exported runbook .ps1 files (from Export-Runbooks.ps1).

    .PARAMETER OutputPath
        Directory to write reports. Default: .\plan\

    .PARAMETER UseManagedIdentity
        Authenticate via Managed Identity (for running inside a runbook).

    .EXAMPLE
        .\Get-RunbookDependencies.ps1 `
            -ResourceGroupName "rg-automation" `
            -AutomationAccountName "aa-prod" `
            -RunbookSourcePath ".\runbooks\source" `
            -OutputPath ".\plan"
#>

param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$AutomationAccountName,

    [Parameter()]
    [string]$RunbookSourcePath = ".\runbooks\source",

    [Parameter()]
    [string]$OutputPath = ".\plan",

    [Parameter()]
    [switch]$UseManagedIdentity
)

$ErrorActionPreference = "Stop"

# --- Auth ---
if ($UseManagedIdentity) {
    Connect-AzAccount -Identity | Out-Null
} else {
    $context = Get-AzContext
    if (-not $context) {
        throw "Not logged in to Azure. Run Connect-AzAccount first, or use -UseManagedIdentity."
    }
}

$rg = $ResourceGroupName
$aa = $AutomationAccountName

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# =============================================================================
# SECTION 1: Schedules
# =============================================================================
Write-Output "=== Discovering Schedules ==="

$schedules = Get-AzAutomationSchedule -ResourceGroupName $rg -AutomationAccountName $aa
Write-Output "Found $($schedules.Count) schedules."

$runbooks = Get-AzAutomationRunbook -ResourceGroupName $rg -AutomationAccountName $aa |
    Where-Object { $_.RunbookType -match 'PowerShell' }

$scheduleLinks = [System.Collections.ArrayList]::new()

foreach ($rb in $runbooks) {
    try {
        $links = Get-AzAutomationScheduledRunbook -ResourceGroupName $rg `
            -AutomationAccountName $aa `
            -RunbookName $rb.Name -ErrorAction SilentlyContinue

        foreach ($link in $links) {
            $schedule = $schedules | Where-Object { $_.Name -eq $link.ScheduleName }
            $null = $scheduleLinks.Add([PSCustomObject]@{
                Runbook           = $rb.Name
                ScheduleName      = $link.ScheduleName
                Frequency         = $schedule.Frequency
                Interval          = $schedule.Interval
                StartTime         = $schedule.StartTime
                NextRun           = $schedule.NextRun
                IsEnabled         = $schedule.IsEnabled
                Parameters        = ($link.Parameters | ConvertTo-Json -Compress -Depth 2)
                RunOn             = $link.RunOn  # Empty = cloud; value = Hybrid Worker Group
            })
        }
    }
    catch {
        Write-Warning "Could not get schedules for '$($rb.Name)': $($_.Exception.Message)"
    }
}

Write-Output "Found $($scheduleLinks.Count) schedule-runbook links."

# =============================================================================
# SECTION 2: Webhooks
# =============================================================================
Write-Output ""
Write-Output "=== Discovering Webhooks ==="

$allWebhooks = [System.Collections.ArrayList]::new()

foreach ($rb in $runbooks) {
    try {
        $webhooks = Get-AzAutomationWebhook -ResourceGroupName $rg `
            -AutomationAccountName $aa `
            -RunbookName $rb.Name -ErrorAction SilentlyContinue

        foreach ($wh in $webhooks) {
            $null = $allWebhooks.Add([PSCustomObject]@{
                Runbook          = $rb.Name
                WebhookName      = $wh.Name
                IsEnabled        = $wh.IsEnabled
                ExpiryTime       = $wh.ExpiryTime
                CreationTime     = $wh.CreationTime
                LastInvokedTime  = $wh.LastInvokedTime
                RunOn            = $wh.RunOn
                Parameters       = ($wh.Parameters | ConvertTo-Json -Compress -Depth 2)
            })
        }
    }
    catch {
        Write-Warning "Could not get webhooks for '$($rb.Name)': $($_.Exception.Message)"
    }
}

Write-Output "Found $($allWebhooks.Count) webhooks."

# =============================================================================
# SECTION 3: Child Runbook Calls (source code analysis)
# =============================================================================
Write-Output ""
Write-Output "=== Scanning for Child Runbook Calls ==="

$childCalls = [System.Collections.ArrayList]::new()
$credentialParams = [System.Collections.ArrayList]::new()

$sourceFiles = Get-ChildItem -Path $RunbookSourcePath -Filter "*.ps1" -Recurse -File

foreach ($file in $sourceFiles) {
    $lines = Get-Content $file.FullName -ErrorAction SilentlyContinue
    if (-not $lines) { continue }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        # Detect Start-AzAutomationRunbook or Start-AzAutomationRunbook (older Az)
        if ($line -match 'Start-Az(?:ureRm)?AutomationRunbook') {
            # Try to extract the child runbook name
            $childName = ""
            if ($line -match '-Name\s+[''"]([^''"]+)[''"]') {
                $childName = $Matches[1]
            } elseif ($line -match '-Name\s+(\$\w+)') {
                $childName = $Matches[1] + " (variable)"
            }

            # Check if -Wait is used (synchronous call)
            $isSync = $line -match '-Wait'

            # Check if parameters are passed
            $hasParams = $line -match '-Parameters?\s+'

            $null = $childCalls.Add([PSCustomObject]@{
                ParentRunbook  = $file.Name
                ChildRunbook   = $childName
                LineNumber     = $i + 1
                LineText       = $line.Trim()
                IsSynchronous  = $isSync
                PassesParams   = $hasParams
                RunOn          = if ($line -match '-RunOn\s+[''"]([^''"]+)[''"]') { $Matches[1] } else { "Cloud (default)" }
            })
        }

        # Detect credential-like parameters being passed to the runbook from external callers
        if ($line -match 'param\s*\(' -or $line -match '\[Parameter') {
            # Scan the param block for credential-type parameters
            $paramBlock = ""
            for ($j = $i; $j -lt [Math]::Min($i + 50, $lines.Count); $j++) {
                $paramBlock += $lines[$j] + "`n"
                if ($lines[$j] -match '^\s*\)') { break }
            }

            if ($paramBlock -match '\[(?:PSCredential|SecureString|System\.Management\.Automation\.PSCredential)\]') {
                $null = $credentialParams.Add([PSCustomObject]@{
                    Runbook    = $file.Name
                    LineNumber = $i + 1
                    Detail     = "Parameter block accepts credential/secure type — external callers may pass credentials"
                })
            }
        }
    }
}

Write-Output "Found $($childCalls.Count) child runbook calls."
Write-Output "Found $($credentialParams.Count) runbooks accepting credential-type parameters."

# =============================================================================
# SECTION 4: Hybrid Worker Group Usage
# =============================================================================
Write-Output ""
Write-Output "=== Hybrid Worker Group Usage ==="

$hwgRunbooks = @()
$hwgRunbooks += $scheduleLinks | Where-Object { $_.RunOn -and $_.RunOn -ne "" } |
    Select-Object @{N='Runbook';E={$_.Runbook}}, @{N='Source';E={"Schedule: $($_.ScheduleName)"}}, RunOn
$hwgRunbooks += $allWebhooks | Where-Object { $_.RunOn -and $_.RunOn -ne "" } |
    Select-Object @{N='Runbook';E={$_.Runbook}}, @{N='Source';E={"Webhook: $($_.WebhookName)"}}, RunOn
$hwgRunbooks += $childCalls | Where-Object { $_.RunOn -ne "Cloud (default)" } |
    Select-Object @{N='Runbook';E={$_.ParentRunbook}}, @{N='Source';E={"ChildCall→$($_.ChildRunbook)"}}, RunOn

if ($hwgRunbooks.Count -gt 0) {
    Write-Output "Runbooks targeting Hybrid Worker Groups:"
    $hwgRunbooks | Format-Table -AutoSize
} else {
    Write-Output "No Hybrid Worker Group usage detected."
}

# =============================================================================
# SECTION 5: Build Dependency Graph
# =============================================================================
Write-Output ""
Write-Output "=== Dependency Graph ==="

# Determine migration order: children must be migrated before parents
$parentRunbooks = $childCalls | Select-Object -Unique ParentRunbook
$childRunbookNames = $childCalls | Where-Object { $_.ChildRunbook -notmatch 'variable' } |
    Select-Object -Unique ChildRunbook

Write-Output "Parent runbooks (call other runbooks): $($parentRunbooks.Count)"
$parentRunbooks | ForEach-Object { Write-Output "  $($_.ParentRunbook)" }

Write-Output ""
Write-Output "Child runbooks (called by others): $($childRunbookNames.Count)"
$childRunbookNames | ForEach-Object { Write-Output "  $($_.ChildRunbook)" }

Write-Output ""
Write-Output "Migration order recommendation:"
Write-Output "  1. Migrate CHILD runbooks first (they are dependencies)"
Write-Output "  2. Then migrate PARENT runbooks"
Write-Output "  3. Runbooks with no parent/child relationships can be migrated in any order"

# =============================================================================
# SECTION 6: Export Reports
# =============================================================================
Write-Output ""
Write-Output "=== Exporting Reports ==="

# Schedules
$schedulePath = Join-Path $OutputPath "dependency-schedules.csv"
if ($scheduleLinks.Count -gt 0) {
    $scheduleLinks | Export-Csv -Path $schedulePath -NoTypeInformation -Force
    Write-Output "Schedule links: $schedulePath"
}

# Webhooks
$webhookPath = Join-Path $OutputPath "dependency-webhooks.csv"
if ($allWebhooks.Count -gt 0) {
    $allWebhooks | Export-Csv -Path $webhookPath -NoTypeInformation -Force
    Write-Output "Webhooks: $webhookPath"
}

# Child calls
$childPath = Join-Path $OutputPath "dependency-child-calls.csv"
if ($childCalls.Count -gt 0) {
    $childCalls | Export-Csv -Path $childPath -NoTypeInformation -Force
    Write-Output "Child runbook calls: $childPath"
}

# Credential parameters
$credParamPath = Join-Path $OutputPath "dependency-credential-params.csv"
if ($credentialParams.Count -gt 0) {
    $credentialParams | Export-Csv -Path $credParamPath -NoTypeInformation -Force
    Write-Output "Credential parameters: $credParamPath"
}

# Combined summary
$summaryPath = Join-Path $OutputPath "dependency-summary.json"
$summary = [PSCustomObject]@{
    GeneratedAt       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    AutomationAccount = $aa
    ResourceGroup     = $rg
    TotalRunbooks     = $runbooks.Count
    Schedules         = [PSCustomObject]@{
        TotalSchedules    = $schedules.Count
        LinkedToRunbooks  = $scheduleLinks.Count
        RunbooksWithSchedules = ($scheduleLinks | Select-Object -Unique Runbook).Count
    }
    Webhooks          = [PSCustomObject]@{
        Total                = $allWebhooks.Count
        RunbooksWithWebhooks = ($allWebhooks | Select-Object -Unique Runbook).Count
        Expired              = ($allWebhooks | Where-Object { [datetime]$_.ExpiryTime -lt (Get-Date) }).Count
    }
    ChildRunbookCalls = [PSCustomObject]@{
        TotalCalls       = $childCalls.Count
        ParentRunbooks   = ($childCalls | Select-Object -Unique ParentRunbook).Count
        ChildRunbooks    = ($childCalls | Where-Object { $_.ChildRunbook -notmatch 'variable' } | Select-Object -Unique ChildRunbook).Count
        SynchronousCalls = ($childCalls | Where-Object IsSynchronous).Count
    }
    HybridWorkerUsage = [PSCustomObject]@{
        RunbooksOnHWG = $hwgRunbooks.Count
        WorkerGroups  = ($hwgRunbooks | Select-Object -Unique RunOn).Count
    }
    CredentialParameters = [PSCustomObject]@{
        RunbooksAcceptingCreds = $credentialParams.Count
    }
    MigrationOrder    = [PSCustomObject]@{
        Phase1_Children = ($childRunbookNames | ForEach-Object { $_.ChildRunbook })
        Phase2_Parents  = ($parentRunbooks | ForEach-Object { $_.ParentRunbook })
        Phase3_Independent = "All remaining runbooks"
    }
}

$summary | ConvertTo-Json -Depth 4 | Out-File -FilePath $summaryPath -Encoding utf8
Write-Output "Summary: $summaryPath"

# =============================================================================
# SECTION 7: Warnings
# =============================================================================
Write-Output ""
Write-Output "=== Warnings ==="

# Runbooks with schedules that pass parameters
$schedWithParams = $scheduleLinks | Where-Object { $_.Parameters -and $_.Parameters -ne '{}' -and $_.Parameters -ne 'null' }
if ($schedWithParams.Count -gt 0) {
    Write-Warning "These schedule links pass parameters. Verify parameters are preserved after migration:"
    $schedWithParams | Select-Object Runbook, ScheduleName, Parameters | Format-Table -AutoSize
}

# Webhooks about to expire
$soonExpiring = $allWebhooks | Where-Object {
    $expiry = [datetime]$_.ExpiryTime
    $expiry -gt (Get-Date) -and $expiry -lt (Get-Date).AddDays(90)
}
if ($soonExpiring.Count -gt 0) {
    Write-Warning "These webhooks expire within 90 days — consider regenerating during migration:"
    $soonExpiring | Select-Object Runbook, WebhookName, ExpiryTime | Format-Table -AutoSize
}

# Credential-type parameters
if ($credentialParams.Count -gt 0) {
    Write-Warning "These runbooks accept credential-type parameters from external callers."
    Write-Warning "If webhooks or parent runbooks pass credentials, the calling code must also be updated:"
    $credentialParams | Select-Object Runbook, Detail | Format-Table -AutoSize
}

# Dynamic child runbook names
$dynamicCalls = $childCalls | Where-Object { $_.ChildRunbook -match 'variable' }
if ($dynamicCalls.Count -gt 0) {
    Write-Warning "These parent runbooks use variables for child runbook names — manual review required:"
    $dynamicCalls | Select-Object ParentRunbook, ChildRunbook, LineNumber | Format-Table -AutoSize
}

Write-Output ""
Write-Output "Dependency analysis complete."
Write-Output "Review these reports before beginning Phase 3 migration."
Write-Output "Key rule: Migrate CHILD runbooks before their PARENTS."
