<#
    .SYNOPSIS
        Packages and deploys the Contoso.Automation.Auth module to an Automation Account.

    .DESCRIPTION
        Creates a .zip of the module, uploads it to a temporary blob, then installs
        it into the specified runtime environment. Alternatively, can upload directly
        if using the portal or local file import.

    .PARAMETER ModulePath
        Path to the Contoso.Automation.Auth module folder.

    .PARAMETER ResourceGroupName
        Resource group containing the Automation Account.

    .PARAMETER AutomationAccountName
        Name of the Automation Account.

    .PARAMETER RuntimeEnvironment
        Name of the runtime environment to install into. Default: "PS74-ModernAuth"

    .PARAMETER StorageAccountName
        (Optional) Storage account for staging the module zip.

    .PARAMETER ContainerName
        (Optional) Blob container name. Default: "automation-modules"

    .EXAMPLE
        .\Deploy-AuthModule.ps1 `
            -ModulePath "..\..\modules\Contoso.Automation.Auth" `
            -ResourceGroupName "rg-automation" `
            -AutomationAccountName "aa-prod"
#>

param(
    [Parameter(Mandatory)]
    [string]$ModulePath,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$AutomationAccountName,

    [Parameter()]
    [string]$RuntimeEnvironment = "PS74-ModernAuth",

    [Parameter()]
    [string]$StorageAccountName,

    [Parameter()]
    [string]$ContainerName = "automation-modules"
)

$ErrorActionPreference = "Stop"

# --- Validate module path ---
$manifestPath = Join-Path $ModulePath "Contoso.Automation.Auth.psd1"
if (-not (Test-Path $manifestPath)) {
    throw "Module manifest not found at '$manifestPath'. Check the -ModulePath parameter."
}

$manifest = Import-PowerShellDataFile -Path $manifestPath
$version = $manifest.ModuleVersion
Write-Output "Module: Contoso.Automation.Auth v$version"

# --- Create zip ---
$zipName = "Contoso.Automation.Auth.$version.zip"
$zipPath = Join-Path ([System.IO.Path]::GetTempPath()) $zipName

if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Write-Output "Creating module package: $zipPath"
Compress-Archive -Path (Join-Path $ModulePath "*") -DestinationPath $zipPath -Force

# --- Upload and install ---
if ($StorageAccountName) {
    # Method A: Upload to blob storage, then install from URI
    Write-Output "Uploading to storage account '$StorageAccountName'..."

    $ctx = (Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName).Context
    $blob = Set-AzStorageBlobContent -File $zipPath -Container $ContainerName -Blob $zipName -Context $ctx -Force

    # Generate a short-lived SAS URI
    $sasToken = New-AzStorageBlobSASToken -Container $ContainerName -Blob $zipName `
        -Permission r -ExpiryTime (Get-Date).AddHours(1) -Context $ctx
    $uri = "$($blob.ICloudBlob.Uri.AbsoluteUri)$sasToken"

    Write-Output "Installing module from blob URI..."
    New-AzAutomationModule -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name "Contoso.Automation.Auth" `
        -ContentLinkUri $uri `
        -RuntimeEnvironment $RuntimeEnvironment

    Write-Output "Module installation queued."
}
else {
    # Method B: Direct guidance for manual upload
    Write-Output ""
    Write-Output "No storage account specified. To install manually:"
    Write-Output "  1. Go to Azure Portal > Automation Account > Runtime Environments"
    Write-Output "  2. Select '$RuntimeEnvironment' > Modules > Add module"
    Write-Output "  3. Upload the zip file: $zipPath"
    Write-Output ""
    Write-Output "Or provide -StorageAccountName for automated deployment."
}

# --- Cleanup ---
Write-Output ""
Write-Output "Package location: $zipPath"
Write-Output "Done."
