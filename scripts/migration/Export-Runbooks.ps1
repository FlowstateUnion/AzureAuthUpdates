<#
    .SYNOPSIS
        Exports all runbooks from an Azure Automation Account to local .ps1 files.

    .DESCRIPTION
        Connects to Azure via Managed Identity (or interactive for local use),
        then exports every PowerShell runbook to the specified output directory.
        Creates a metadata JSON alongside the scripts with runbook properties.

    .PARAMETER ResourceGroupName
        Resource group containing the Automation Account.

    .PARAMETER AutomationAccountName
        Name of the Automation Account.

    .PARAMETER OutputPath
        Local directory to export runbooks into. Created if it doesn't exist.

    .PARAMETER UseManagedIdentity
        If specified, authenticates via Managed Identity (for use inside a runbook).
        Otherwise, uses the current Azure context (for local/interactive use).

    .EXAMPLE
        # Local use (assumes you're already logged in via Connect-AzAccount)
        .\Export-Runbooks.ps1 -ResourceGroupName "rg-automation" -AutomationAccountName "aa-prod" -OutputPath ".\runbooks\source"

        # Inside an Automation runbook
        .\Export-Runbooks.ps1 -ResourceGroupName "rg-automation" -AutomationAccountName "aa-prod" -OutputPath ".\runbooks\source" -UseManagedIdentity
#>

param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$AutomationAccountName,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [Parameter()]
    [switch]$UseManagedIdentity
)

$ErrorActionPreference = "Stop"

# --- Auth ---
if ($UseManagedIdentity) {
    Connect-AzAccount -Identity | Out-Null
}
else {
    $context = Get-AzContext
    if (-not $context) {
        throw "Not logged in to Azure. Run Connect-AzAccount first, or use -UseManagedIdentity."
    }
}

# --- Create output directory ---
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# --- Get runbooks ---
Write-Output "Fetching runbooks from '$AutomationAccountName'..."
$runbooks = Get-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName

$psRunbooks = $runbooks | Where-Object { $_.RunbookType -match 'PowerShell' }
Write-Output "Found $($psRunbooks.Count) PowerShell runbooks (of $($runbooks.Count) total)."

# --- Export each runbook ---
$metadata = [System.Collections.ArrayList]::new()

foreach ($rb in $psRunbooks) {
    Write-Output "Exporting: $($rb.Name) ($($rb.RunbookType), State: $($rb.State))..."

    $exportPath = Join-Path $OutputPath "$($rb.Name).ps1"

    try {
        Export-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $rb.Name `
            -OutputFolder $OutputPath `
            -Force | Out-Null

        $null = $metadata.Add([PSCustomObject]@{
            Name           = $rb.Name
            RunbookType    = $rb.RunbookType
            State          = $rb.State
            LastModified   = $rb.LastModifiedTime
            Description    = $rb.Description
            ExportedFile   = "$($rb.Name).ps1"
            ExportedAt     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        })
    }
    catch {
        Write-Warning "Failed to export '$($rb.Name)': $($_.Exception.Message)"
    }
}

# --- Write metadata ---
$metadataPath = Join-Path $OutputPath "_runbook-metadata.json"
$metadata | ConvertTo-Json -Depth 3 | Out-File -FilePath $metadataPath -Encoding utf8
Write-Output ""
Write-Output "Exported $($metadata.Count) runbooks to: $OutputPath"
Write-Output "Metadata written to: $metadataPath"
