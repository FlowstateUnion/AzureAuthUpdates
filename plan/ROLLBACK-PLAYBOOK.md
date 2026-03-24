# Rollback & Incident Response Playbook

## Purpose

Procedures for recovering from migration-related failures, from single-runbook issues to cascading multi-runbook outages caused by Managed Identity misconfiguration.

---

## Severity Levels

| Level | Symptom | Example | Response Time |
|-------|---------|---------|---------------|
| **SEV-1** | Multiple runbooks failing simultaneously | MI permissions revoked or misconfigured; runtime environment broken | Immediate — bulk rollback |
| **SEV-2** | Single critical runbook failing | Auth error in a business-critical runbook | Within 1 hour — single rollback |
| **SEV-3** | Single non-critical runbook failing | Test or reporting runbook error | Within 1 business day |
| **SEV-4** | Degraded performance, no failure | Slower execution, token refresh warnings | Next maintenance window |

---

## Pre-Flight Validation (Run BEFORE Publishing)

### Permission Validation Script

Run this before publishing any batch of migrated runbooks to confirm the MI has the permissions it needs:

```powershell
<#
    Validates that the Managed Identity has expected permissions.
    Run this BEFORE publishing migrated runbooks.
#>
param(
    [Parameter(Mandatory)]
    [string]$ManagedIdentityObjectId
)

$ErrorActionPreference = "Stop"
Connect-MgGraph -Scopes "Application.Read.All"

$assignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityObjectId

# Expected permissions (adjust to your environment)
$expected = @(
    @{ Resource = "Microsoft Graph"; Role = "Sites.ReadWrite.All" }
    @{ Resource = "Microsoft Graph"; Role = "User.Read.All" }
    @{ Resource = "Microsoft Graph"; Role = "Group.Read.All" }
    @{ Resource = "Office 365 SharePoint Online"; Role = "Sites.FullControl.All" }
)

Write-Output "=== Permission Validation ==="
$allFound = $true

foreach ($exp in $expected) {
    # Look up the resource SP
    $resourceSP = Get-MgServicePrincipal -Filter "displayName eq '$($exp.Resource)'" -Top 1
    if (-not $resourceSP) {
        Write-Warning "Resource '$($exp.Resource)' not found."
        $allFound = $false
        continue
    }

    $role = $resourceSP.AppRoles | Where-Object { $_.Value -eq $exp.Role }
    if (-not $role) {
        Write-Warning "Role '$($exp.Role)' not found on '$($exp.Resource)'."
        $allFound = $false
        continue
    }

    $match = $assignments | Where-Object {
        $_.AppRoleId -eq $role.Id -and $_.ResourceId -eq $resourceSP.Id
    }

    if ($match) {
        Write-Output "[OK]   $($exp.Resource) / $($exp.Role)"
    } else {
        Write-Output "[MISS] $($exp.Resource) / $($exp.Role)"
        $allFound = $false
    }
}

Write-Output ""
if ($allFound) {
    Write-Output "All expected permissions are present. Safe to publish."
} else {
    Write-Error "Missing permissions detected. DO NOT publish until resolved."
    Write-Output "Run scripts\setup\Grant-ManagedIdentityPermissions.ps1 to fix."
}

Disconnect-MgGraph
```

### Runtime Environment Validation

```powershell
# Confirm all required modules are installed and available
$requiredModules = @(
    "Az.Accounts", "Az.KeyVault", "PnP.PowerShell",
    "Microsoft.Graph.Authentication", "Contoso.Automation.Auth"
)

$runtimeModules = Get-AzAutomationModule -ResourceGroupName "<RG>" `
    -AutomationAccountName "<AA>" -RuntimeEnvironment "PS74-ModernAuth"

foreach ($mod in $requiredModules) {
    $installed = $runtimeModules | Where-Object { $_.Name -eq $mod -and $_.ProvisioningState -eq "Succeeded" }
    if ($installed) {
        Write-Output "[OK]   $mod v$($installed.Version)"
    } else {
        Write-Output "[MISS] $mod — not installed or failed provisioning"
    }
}
```

---

## Single Runbook Rollback (SEV-2 / SEV-3)

### Option A: Revert via Portal
1. **Automation Account** > **Runbooks** > click the failing runbook
2. **Edit** > the editor shows the current published version
3. Click **Gallery** or **Versions** to access the previous draft
4. Alternatively: paste the original code from `runbooks\source/<RunbookName>.ps1`
5. **Publish**

### Option B: Revert via PowerShell
```powershell
$rg = "<RG>"
$aa = "<AA>"
$runbookName = "<RUNBOOK-NAME>"
$originalPath = ".\runbooks\source\$runbookName.ps1"

# Re-import the original
Import-AzAutomationRunbook -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -Name $runbookName `
    -Path $originalPath `
    -Type PowerShell `
    -Force

# Publish immediately
Publish-AzAutomationRunbook -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -Name $runbookName

Write-Output "Rolled back '$runbookName' to original version."
```

### Option C: Switch Runtime Environment
If the runbook code is correct but the PS 7.4 runtime is the issue:

```powershell
# Reassign to the default PS 5.1 runtime (runbook must be compatible)
Set-AzAutomationRunbook -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -Name $runbookName `
    -RuntimeEnvironment "PowerShell-5.1"
```

---

## Bulk Rollback (SEV-1)

Use when multiple runbooks fail simultaneously — typically caused by:
- MI permissions removed or incorrectly configured
- Runtime environment corrupted (module update broke dependencies)
- Key Vault access lost

### Step 1: Assess Scope

```powershell
$rg = "<RG>"
$aa = "<AA>"

# Get all failed jobs in the last 24 hours
$failedJobs = Get-AzAutomationJob -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -StartTime (Get-Date).AddDays(-1) |
    Where-Object { $_.Status -eq "Failed" }

Write-Output "Failed jobs in last 24 hours: $($failedJobs.Count)"

# Group by runbook to see which are affected
$failedJobs | Group-Object RunbookName |
    Sort-Object Count -Descending |
    Select-Object Count, Name |
    Format-Table -AutoSize

# Check for common error pattern (auth failures)
$authFailures = foreach ($job in $failedJobs | Select-Object -First 10) {
    $output = Get-AzAutomationJobOutput -ResourceGroupName $rg `
        -AutomationAccountName $aa `
        -Id $job.JobId -Stream Error

    $output | Where-Object { $_.Summary -match 'Managed Identity|403|401|Unauthorized|Forbidden' }
}

if ($authFailures.Count -gt 0) {
    Write-Warning "AUTH FAILURE PATTERN DETECTED — likely MI permission issue."
    Write-Warning "Proceed with bulk rollback of all migrated runbooks."
} else {
    Write-Output "Errors are varied — investigate individually before bulk rollback."
}
```

### Step 2: Bulk Rollback Script

```powershell
<#
    Rolls back ALL migrated runbooks to their original versions.
    Only use for SEV-1 cascading failures.
#>
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$AutomationAccountName,

    [Parameter()]
    [string]$OriginalRunbookPath = ".\runbooks\source",

    [Parameter()]
    [string]$MigrationQueuePath = ".\plan\migration-queue.csv"
)

$ErrorActionPreference = "Stop"
$rg = $ResourceGroupName
$aa = $AutomationAccountName

# Load migration queue to know which runbooks were migrated
$queue = Import-Csv $MigrationQueuePath
$migrated = $queue | Where-Object { $_.Status -eq "Published" -or $_.MigratedDate }

Write-Output "=== BULK ROLLBACK ==="
Write-Output "Runbooks to roll back: $($migrated.Count)"
Write-Output ""

$results = [System.Collections.ArrayList]::new()

foreach ($item in $migrated) {
    $originalFile = Join-Path $OriginalRunbookPath $item.Runbook

    if (-not (Test-Path $originalFile)) {
        Write-Warning "SKIP: Original not found for '$($item.Runbook)'"
        $null = $results.Add([PSCustomObject]@{ Runbook = $item.Runbook; Status = "SKIPPED"; Reason = "Original file not found" })
        continue
    }

    try {
        Import-AzAutomationRunbook -ResourceGroupName $rg `
            -AutomationAccountName $aa `
            -Name ($item.Runbook -replace '\.ps1$', '') `
            -Path $originalFile `
            -Type PowerShell `
            -Force | Out-Null

        Publish-AzAutomationRunbook -ResourceGroupName $rg `
            -AutomationAccountName $aa `
            -Name ($item.Runbook -replace '\.ps1$', '') | Out-Null

        Write-Output "[OK] Rolled back: $($item.Runbook)"
        $null = $results.Add([PSCustomObject]@{ Runbook = $item.Runbook; Status = "ROLLED_BACK"; Reason = "" })
    }
    catch {
        Write-Warning "[FAIL] Could not roll back '$($item.Runbook)': $($_.Exception.Message)"
        $null = $results.Add([PSCustomObject]@{ Runbook = $item.Runbook; Status = "FAILED"; Reason = $_.Exception.Message })
    }
}

# Summary
Write-Output ""
Write-Output "=== ROLLBACK SUMMARY ==="
$results | Group-Object Status | ForEach-Object {
    Write-Output "  $($_.Name): $($_.Count)"
}

$results | Export-Csv ".\plan\rollback-results.csv" -NoTypeInformation -Force
Write-Output "Results exported to: .\plan\rollback-results.csv"

Write-Output ""
Write-Output "NEXT STEPS:"
Write-Output "  1. Verify failed jobs stop recurring"
Write-Output "  2. Investigate root cause (permissions, runtime, module versions)"
Write-Output "  3. Fix the root cause"
Write-Output "  4. Re-run pre-flight validation"
Write-Output "  5. Re-migrate in smaller batches"
```

### Step 3: Root Cause Investigation

After bulk rollback, diagnose the cause:

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| All jobs show 401/403 errors | MI permissions lost or never granted | Re-run `Grant-ManagedIdentityPermissions.ps1` |
| "Managed Identity not found" | MI disabled on Automation Account | Re-enable under Identity settings |
| "Module not found" errors | Runtime environment module failed to install | Check module provisioning state; reinstall |
| "Could not load type" errors | Module version conflict in runtime env | Check dependency versions; rebuild runtime env |
| Some runbooks work, others don't | Scope issue — some need permissions not yet granted | Audit per-runbook permissions (see permission audit) |
| Token errors after ~1 hour | Token expiry on long-running jobs | Implement token refresh (see shared module) |

### Step 4: Re-Migrate After Fix

1. Fix the root cause
2. Re-run pre-flight validation (both permissions and runtime)
3. Start with a **single** simple runbook as a canary
4. Test it thoroughly
5. If canary passes, re-migrate in batches of 3-5 runbooks
6. Monitor each batch for 24 hours before the next

---

## Incident Communication Template

Use this to notify stakeholders during a SEV-1 or SEV-2 incident:

```
Subject: [SEV-X] Azure Automation Runbook Failures — Auth Migration Related

Impact: [X] runbooks are failing due to [root cause summary].
Affected processes: [list business processes impacted]

Timeline:
- [Time] — Failures detected
- [Time] — Investigation started
- [Time] — Root cause identified: [cause]
- [Time] — Rollback initiated
- [Time] — Rollback complete / services restored

Current Status: [Investigating | Rolling Back | Resolved | Monitoring]

Next Steps:
- [action items]

ETA to Full Resolution: [estimate]
```

---

## Post-Incident Review

After any SEV-1 or SEV-2 incident, document:

1. **What happened** — timeline of events
2. **Root cause** — what specifically failed and why
3. **Detection** — how was the failure discovered? Could it have been caught earlier?
4. **Resolution** — what fixed it?
5. **Prevention** — what changes to the migration process would have prevented this?
6. **Action items** — specific changes to make before resuming migration
