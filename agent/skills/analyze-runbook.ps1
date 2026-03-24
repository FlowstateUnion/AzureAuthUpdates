<#
    .SYNOPSIS
        Skill: Analyze a single runbook for migration requirements.

    .DESCRIPTION
        Reads a runbook from source/, checks scan results, determines migration
        complexity, identifies auth patterns, module remappings, PS 7.4 issues,
        and dependencies. Outputs a structured analysis the agent uses to plan
        the migration.

    .PARAMETER RunbookName
        Filename of the runbook (e.g., "Set-SitePermissions.ps1").

    .PARAMETER SourcePath
        Path to source runbooks. Default: .\runbooks\source

    .PARAMETER ScanResultsCsv
        Path to scan results. Default: .\agent\scan-results.csv

    .PARAMETER PermissionAuditCsv
        Path to permission audit. Default: .\agent\permission-audit.csv

    .EXAMPLE
        .\agent\skills\analyze-runbook.ps1 -RunbookName "Set-SitePermissions.ps1"
#>

param(
    [Parameter(Mandatory)]
    [string]$RunbookName,

    [Parameter()]
    [string]$SourcePath = ".\runbooks\source",

    [Parameter()]
    [string]$ScanResultsCsv = ".\agent\scan-results.csv",

    [Parameter()]
    [string]$PermissionAuditCsv = ".\agent\permission-audit.csv"
)

$ErrorActionPreference = "Stop"

$filePath = Join-Path $SourcePath $RunbookName
if (-not (Test-Path $filePath)) {
    throw "Runbook not found: $filePath"
}

$content = Get-Content $filePath -Raw
$lines = Get-Content $filePath

# --- Scan findings ---
$findings = @()
if (Test-Path $ScanResultsCsv) {
    $findings = Import-Csv $ScanResultsCsv | Where-Object { $_.File -eq $RunbookName }
}

# --- Permission requirements ---
$permissions = @()
if (Test-Path $PermissionAuditCsv) {
    $permissions = Import-Csv $PermissionAuditCsv | Where-Object { $_.Runbook -eq $RunbookName }
}

# --- Auth patterns ---
$authPatterns = $findings | Where-Object { $_.Category -notin @("PS74Compatibility", "DeprecatedCmdlet") }
$compatPatterns = $findings | Where-Object { $_.Category -eq "PS74Compatibility" }
$deprecatedPatterns = $findings | Where-Object { $_.Category -eq "DeprecatedCmdlet" }

# --- Service detection ---
$services = [System.Collections.ArrayList]::new()
if ($content -match 'Connect-SPOService|Get-SPOSite|Set-SPOSite|SPOTenant') { $null = $services.Add("SharePoint-SPO") }
if ($content -match 'Connect-PnPOnline|Get-PnP|Set-PnP') { $null = $services.Add("SharePoint-PnP") }
if ($content -match 'Connect-MgGraph|Get-Mg|Update-Mg|New-Mg') { $null = $services.Add("MicrosoftGraph") }
if ($content -match 'Connect-ExchangeOnline|Get-EXO|Get-Mailbox|Get-TransportRule') { $null = $services.Add("ExchangeOnline") }
if ($content -match 'Connect-AzureAD|Get-AzureAD') { $null = $services.Add("AzureAD-Legacy") }
if ($content -match 'Connect-MsolService|Get-Msol') { $null = $services.Add("MSOnline-Legacy") }
if ($content -match 'Connect-AzAccount') { $null = $services.Add("Azure") }

# --- Child runbook calls ---
$childCalls = @()
$lines | ForEach-Object {
    if ($_ -match 'Start-Az(?:ureRm)?AutomationRunbook') {
        $childName = ""
        if ($_ -match '-Name\s+[''"]([^''"]+)[''"]') { $childName = $Matches[1] }
        $childCalls += $childName
    }
}

# --- PS 5.1 exception check ---
$mustStayPS51 = $false
$ps51Reasons = @()
if ($content -match 'New-Object\s+.*-ComObject') {
    $mustStayPS51 = $true
    $ps51Reasons += "Uses COM objects"
}
if ($content -match 'Add-Type\s+-AssemblyName\s+(System\.Windows|PresentationFramework)') {
    $mustStayPS51 = $true
    $ps51Reasons += "Uses Windows-only .NET assemblies"
}

# --- Complexity scoring ---
$score = 0
$score += ($findings | Where-Object Severity -eq "Critical").Count * 3
$score += ($findings | Where-Object Severity -eq "High").Count * 2
$score += ($findings | Where-Object Severity -eq "Medium").Count * 1
$score += $childCalls.Count * 2
$score += ($services | Where-Object { $_ -match 'Legacy' }).Count * 2

$complexity = switch ($true) {
    ($score -le 3)  { "Simple" }
    ($score -le 8)  { "Medium" }
    default         { "Complex" }
}

# --- Has existing template structure? ---
$hasTemplate = $content -match 'try\s*\{' -and $content -match 'catch\s*\{' -and $content -match '\$ErrorActionPreference'
$hasParams = $content -match 'param\s*\('

# --- Output analysis ---
$analysis = [PSCustomObject]@{
    Runbook            = $RunbookName
    LineCount          = $lines.Count
    Complexity         = $complexity
    Score              = $score
    MustStayPS51       = $mustStayPS51
    PS51Reasons        = ($ps51Reasons -join "; ")
    Services           = ($services -join "; ")
    AuthPatternCount   = $authPatterns.Count
    CompatIssueCount   = $compatPatterns.Count
    DeprecatedCount    = $deprecatedPatterns.Count
    ChildRunbooks      = ($childCalls -join "; ")
    HasParamBlock      = $hasParams
    HasErrorHandling   = $hasTemplate
    PermissionsNeeded  = (($permissions | Select-Object -Unique Permission).Permission -join "; ")
}

Write-Output "=== ANALYSIS: $RunbookName ==="
Write-Output ""
Write-Output "Complexity:     $complexity (score: $score)"
Write-Output "Lines:          $($lines.Count)"
Write-Output "Services:       $($services -join ', ')"
Write-Output "PS 5.1 Only:    $(if ($mustStayPS51) { "YES — $($ps51Reasons -join ', ')" } else { 'No' })"
Write-Output ""

if ($authPatterns.Count -gt 0) {
    Write-Output "Auth Patterns to Replace ($($authPatterns.Count)):"
    $authPatterns | ForEach-Object {
        Write-Output "  [$($_.Severity)] Line $($_.LineNumber): $($_.Pattern)"
        Write-Output "    → $($_.Guidance)"
    }
    Write-Output ""
}

if ($compatPatterns.Count -gt 0) {
    Write-Output "PS 7.4 Compatibility Issues ($($compatPatterns.Count)):"
    $compatPatterns | ForEach-Object {
        Write-Output "  Line $($_.LineNumber): $($_.Pattern)"
        Write-Output "    → $($_.Guidance)"
    }
    Write-Output ""
}

if ($childCalls.Count -gt 0) {
    Write-Output "Child Runbook Calls: $($childCalls -join ', ')"
    Write-Output "  → Migrate these FIRST before this runbook."
    Write-Output ""
}

if ($permissions.Count -gt 0) {
    Write-Output "Permissions Needed:"
    $permissions | ForEach-Object { Write-Output "  [$($_.Service)] $($_.Permission)" }
    Write-Output ""
}

Write-Output "Has param block:     $hasParams"
Write-Output "Has error handling:  $hasTemplate"

return $analysis
