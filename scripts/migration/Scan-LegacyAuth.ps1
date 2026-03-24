<#
    .SYNOPSIS
        Scans PowerShell scripts for legacy authentication patterns.

    .DESCRIPTION
        Recursively scans a directory of .ps1 files and reports every instance of
        legacy credential/auth patterns that need to be migrated. Outputs a
        structured report (CSV and console) with file, line number, pattern matched,
        and severity.

    .PARAMETER Path
        Directory containing the runbook .ps1 files to scan.

    .PARAMETER OutputCsv
        Path to write the CSV report. Defaults to ./scan-results.csv.

    .EXAMPLE
        .\Scan-LegacyAuth.ps1 -Path "C:\Runbooks" -OutputCsv ".\results.csv"
#>

param(
    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter()]
    [string]$OutputCsv = ".\scan-results.csv"
)

$ErrorActionPreference = "Stop"

# --- Define patterns to scan for ---
$patterns = @(
    @{
        Name     = "Get-AutomationPSCredential"
        Pattern  = 'Get-AutomationPSCredential'
        Severity = "Critical"
        Category = "StoredCredential"
        Guidance = "Replace with Managed Identity via Connect-ContosoAzure / Connect-ContosoSharePoint"
    }
    @{
        Name     = "Get-Credential"
        Pattern  = 'Get-Credential'
        Severity = "Critical"
        Category = "InteractiveCredential"
        Guidance = "Remove entirely — interactive prompts fail in Automation. Use Managed Identity."
    }
    @{
        Name     = "PSCredential Constructor"
        Pattern  = 'New-Object\s+.*PSCredential|PSCredential\]::new'
        Severity = "High"
        Category = "CredentialConstruction"
        Guidance = "Eliminate if for Azure/M365 auth. If needed for legacy system, source from Key Vault."
    }
    @{
        Name     = "ConvertTo-SecureString (password)"
        Pattern  = 'ConvertTo-SecureString'
        Severity = "High"
        Category = "SecretHandling"
        Guidance = "Remove if constructing credentials for Azure/M365. Key Vault returns SecureString natively."
    }
    @{
        Name     = "AppSecret / ClientSecret variable"
        Pattern  = 'AppSecret|ClientSecret|client_secret'
        Severity = "Critical"
        Category = "ClientSecret"
        Guidance = "Replace with Managed Identity or certificate-based auth. Remove secret from Automation Variables."
    }
    @{
        Name     = "Connect-SPOService"
        Pattern  = 'Connect-SPOService'
        Severity = "High"
        Category = "LegacyModule"
        Guidance = "Migrate to PnP.PowerShell with Managed Identity. See strategy/01-Connect-SPOService.md"
    }
    @{
        Name     = "Connect-PnPOnline with Credentials"
        Pattern  = 'Connect-PnPOnline\s+.*-Credential'
        Severity = "High"
        Category = "LegacyAuth"
        Guidance = "Replace -Credential with -ManagedIdentity. See strategy/02-Connect-PnPOnline.md"
    }
    @{
        Name     = "Connect-PnPOnline with ClientSecret"
        Pattern  = 'Connect-PnPOnline\s+.*-ClientSecret'
        Severity = "Critical"
        Category = "ClientSecret"
        Guidance = "Replace -ClientSecret with -ManagedIdentity or -Thumbprint."
    }
    @{
        Name     = "Get-AutomationVariable (potential secret)"
        Pattern  = 'Get-AutomationVariable\s+.*(-Name\s+[''"].*(?:Secret|Password|Key|Token|Credential))'
        Severity = "Medium"
        Category = "PotentialSecret"
        Guidance = "Review — if storing a secret, migrate to Key Vault."
    }
    @{
        Name     = "Connect-AzAccount with ServicePrincipal"
        Pattern  = 'Connect-AzAccount\s+.*-ServicePrincipal'
        Severity = "Medium"
        Category = "ServicePrincipalAuth"
        Guidance = "Replace with Connect-AzAccount -Identity (Managed Identity) if possible."
    }
    @{
        Name     = "AzureRunAsConnection"
        Pattern  = 'AzureRunAsConnection|RunAsConnection'
        Severity = "Critical"
        Category = "RetiredFeature"
        Guidance = "Run As accounts were retired Sep 2023. Replace with Managed Identity."
    }
    @{
        Name     = "Connect-AzureAD (legacy module)"
        Pattern  = 'Connect-AzureAD'
        Severity = "High"
        Category = "LegacyModule"
        Guidance = "AzureAD module is deprecated. Migrate to Microsoft.Graph SDK."
    }
    @{
        Name     = "Connect-MsolService (legacy module)"
        Pattern  = 'Connect-MsolService'
        Severity = "High"
        Category = "LegacyModule"
        Guidance = "MSOnline module is deprecated. Migrate to Microsoft.Graph SDK."
    }
    @{
        Name     = "Connect-ExchangeOnline with Credential"
        Pattern  = 'Connect-ExchangeOnline\s+.*-Credential'
        Severity = "High"
        Category = "LegacyAuth"
        Guidance = "Replace -Credential with -ManagedIdentity. See strategy/06-Exchange-Online.md"
    }
    @{
        Name     = "Exchange Remote PSSession (deprecated)"
        Pattern  = 'New-PSSession.*outlook\.office365\.com|New-PSSession.*Microsoft\.Exchange'
        Severity = "Critical"
        Category = "RetiredFeature"
        Guidance = "Remote PS to Exchange is deprecated. Use Connect-ExchangeOnline with MI. See strategy/06-Exchange-Online.md"
    }
    @{
        Name     = "Send-MailMessage (deprecated)"
        Pattern  = 'Send-MailMessage'
        Severity = "Medium"
        Category = "DeprecatedCmdlet"
        Guidance = "Send-MailMessage is deprecated. Use Send-MgUserMail (Graph) or EXO cmdlets."
    }
    @{
        Name     = "COM Object (PS 7.4 incompatible)"
        Pattern  = 'New-Object\s+.*-ComObject'
        Severity = "High"
        Category = "PS74Compatibility"
        Guidance = "COM objects not supported in PS 7.4. Use alternative modules or keep on PS 5.1. See strategy/08-PS51-to-PS74-Compatibility.md"
    }
    @{
        Name     = "WMI Cmdlet (PS 7.4 incompatible)"
        Pattern  = 'Get-WmiObject|Set-WmiInstance|Invoke-WmiMethod'
        Severity = "Medium"
        Category = "PS74Compatibility"
        Guidance = "WMI cmdlets removed in PS 7. Replace with CIM equivalents (Get-CimInstance, etc.)"
    }
    @{
        Name     = ".NET Framework Assembly (PS 7.4 risk)"
        Pattern  = 'Add-Type\s+-AssemblyName\s+(System\.Web|System\.Windows|PresentationFramework|Microsoft\.VisualBasic)'
        Severity = "Medium"
        Category = "PS74Compatibility"
        Guidance = "Assembly may not exist in .NET Core. See strategy/08-PS51-to-PS74-Compatibility.md"
    }
)

# --- Scan files ---
$files = Get-ChildItem -Path $Path -Filter "*.ps1" -Recurse -File
$results = [System.Collections.ArrayList]::new()

if ($files.Count -eq 0) {
    Write-Warning "No .ps1 files found in '$Path'."
    return
}

Write-Output "Scanning $($files.Count) PowerShell files in '$Path'..."
Write-Output ""

foreach ($file in $files) {
    $rawLines = Get-Content -Path $file.FullName -ErrorAction SilentlyContinue
    if (-not $rawLines) { continue }

    # --- Join backtick-continuation lines and pipe-continuation lines ---
    # This prevents false negatives on multiline commands like:
    #   Connect-PnPOnline -Url $url `
    #       -Credential $cred
    $joinedLines = [System.Collections.ArrayList]::new()
    $lineMap = [System.Collections.ArrayList]::new()  # Maps joined index → original line number
    $buffer = ""
    $bufferStartLine = 0

    for ($j = 0; $j -lt $rawLines.Count; $j++) {
        $raw = $rawLines[$j]
        if ($buffer -eq "") { $bufferStartLine = $j }

        if ($raw -match '`\s*$') {
            # Line ends with backtick — continuation
            $buffer += ($raw -replace '`\s*$', ' ')
        } elseif ($raw -match '\|\s*$') {
            # Line ends with pipe — continuation
            $buffer += $raw + ' '
        } else {
            $buffer += $raw
            $null = $joinedLines.Add($buffer)
            $null = $lineMap.Add($bufferStartLine)
            $buffer = ""
        }
    }
    if ($buffer -ne "") {
        $null = $joinedLines.Add($buffer)
        $null = $lineMap.Add($bufferStartLine)
    }

    # Also scan the full file content for splatting patterns
    $fullContent = $rawLines -join "`n"

    for ($i = 0; $i -lt $joinedLines.Count; $i++) {
        $line = $joinedLines[$i]
        $originalLineNum = $lineMap[$i] + 1  # 1-based
        foreach ($p in $patterns) {
            if ($line -match $p.Pattern) {
                $null = $results.Add([PSCustomObject]@{
                    File       = $file.Name
                    FilePath   = $file.FullName
                    LineNumber = $originalLineNum
                    LineText   = $line.Trim()
                    Pattern    = $p.Name
                    Severity   = $p.Severity
                    Category   = $p.Category
                    Guidance   = $p.Guidance
                })
            }
        }
    }
}

# --- Output results ---
if ($results.Count -eq 0) {
    Write-Output "No legacy authentication patterns found. All clear!"
}
else {
    Write-Output "Found $($results.Count) legacy pattern instances across $($files.Count) files:"
    Write-Output ""

    # Summary by severity
    $results | Group-Object Severity | Sort-Object @{Expression={
        switch ($_.Name) { "Critical" { 0 } "High" { 1 } "Medium" { 2 } "Low" { 3 } }
    }} | ForEach-Object {
        Write-Output "  $($_.Name): $($_.Count) instances"
    }
    Write-Output ""

    # Summary by file
    Write-Output "--- By File ---"
    $results | Group-Object File | Sort-Object Count -Descending | ForEach-Object {
        $severities = ($_.Group | Group-Object Severity | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ", "
        Write-Output "  $($_.Name): $($_.Count) patterns ($severities)"
    }
    Write-Output ""

    # Detail
    Write-Output "--- Details ---"
    foreach ($r in $results | Sort-Object Severity, File, LineNumber) {
        Write-Output "[$($r.Severity)] $($r.File):$($r.LineNumber) — $($r.Pattern)"
        Write-Output "  Line: $($r.LineText)"
        Write-Output "  Fix:  $($r.Guidance)"
        Write-Output ""
    }

    # Export CSV
    $results | Export-Csv -Path $OutputCsv -NoTypeInformation -Force
    Write-Output "Report exported to: $OutputCsv"
}

# --- Output summary object for programmatic use ---
return [PSCustomObject]@{
    TotalFiles    = $files.Count
    TotalFindings = $results.Count
    Findings      = $results
    BySeverity    = $results | Group-Object Severity
    ByFile        = $results | Group-Object File
    ByCategory    = $results | Group-Object Category
}
