<#
    .SYNOPSIS
        Validates that inline parent-to-child runbook invocation works in a
        given Automation Account.

    .DESCRIPTION
        Publishes two tiny test runbooks — a parent that calls a child inline
        and expects a structured return — then kicks off the parent and
        inspects its output. Cleans up afterward unless -KeepTestRunbooks is
        passed.

        Use this BEFORE authoring real shared runbooks to confirm the
        environment supports the pattern.

    .PARAMETER ResourceGroupName
        Resource group containing the Automation Account.

    .PARAMETER AutomationAccountName
        Target Automation Account.

    .PARAMETER RuntimeVersion
        PowerShell runtime to target. Default 7.4.

    .PARAMETER KeepTestRunbooks
        If set, does not delete the test runbooks after the run.
#>
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $AutomationAccountName,
    [string] $RuntimeVersion = '7.4',
    [switch] $KeepTestRunbooks
)

$ErrorActionPreference = 'Stop'
$parentName = 'ZZZ-Test-InlineParent'
$childName  = 'ZZZ-Test-InlineChild'

$childBody = @'
param([string]$Message = 'hello')
return [pscustomobject]@{
    Success   = $true
    Echo      = $Message
    RanAt     = (Get-Date).ToString('o')
}
'@

$parentBody = @"
`$result = .\$childName.ps1 -Message 'from-parent'
if (`$result.Success -and `$result.Echo -eq 'from-parent') {
    Write-Output "PASS: child returned object with Echo=`$(`$result.Echo)"
} else {
    Write-Error "FAIL: unexpected result: `$(`$result | ConvertTo-Json -Compress)"
}
"@

function Publish-TempRunbook {
    param([string]$Name, [string]$Body)
    $tmp = New-TemporaryFile
    Rename-Item $tmp "$($tmp.BaseName).ps1" -PassThru | Out-Null
    $path = "$($tmp.DirectoryName)\$($tmp.BaseName).ps1"
    Set-Content -Path $path -Value $Body -Encoding UTF8
    Import-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Path $path -Name $Name -Type PowerShell74 -Force | Out-Null
    Publish-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName -Name $Name | Out-Null
    Remove-Item $path -Force
}

try {
    Write-Host "Publishing test child: $childName"
    Publish-TempRunbook -Name $childName -Body $childBody

    Write-Host "Publishing test parent: $parentName"
    Publish-TempRunbook -Name $parentName -Body $parentBody

    Write-Host "Starting parent job..."
    $job = Start-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName -Name $parentName

    do {
        Start-Sleep -Seconds 5
        $job = Get-AzAutomationJob -Id $job.JobId -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName
        Write-Host "  status: $($job.Status)"
    } while ($job.Status -in 'Queued','Starting','Running','Activating','Resuming')

    $output = Get-AzAutomationJobOutput -Id $job.JobId `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName -Stream Any

    $output | ForEach-Object {
        $rec = Get-AzAutomationJobOutputRecord -Id $_.StreamRecordId `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName -JobId $job.JobId
        "[$($_.Type)] $($rec.Value.Values -join ' ')"
    }

    if ($job.Status -eq 'Completed' -and ($output | Where-Object { $_.Summary -match 'PASS' })) {
        Write-Host ""
        Write-Host "PATTERN VERIFIED: inline parent->child invocation works." -ForegroundColor Green
    } else {
        Write-Warning "Test did not pass cleanly. Inspect job $($job.JobId) in the portal."
    }
}
finally {
    if (-not $KeepTestRunbooks) {
        foreach ($n in @($parentName, $childName)) {
            try {
                Remove-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
                    -AutomationAccountName $AutomationAccountName -Name $n -Force -ErrorAction SilentlyContinue
                Write-Host "Cleaned up: $n"
            } catch {}
        }
    } else {
        Write-Host "Kept test runbooks in place (--KeepTestRunbooks)."
    }
}
