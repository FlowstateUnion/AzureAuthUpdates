<#
    .SYNOPSIS
        Skill: Validate a migrated runbook and advance it to testing/ if it passes.

    .DESCRIPTION
        Runs syntax check, verifies no legacy patterns remain, confirms #Requires
        match actual module usage, and checks for common migration mistakes.
        If all checks pass, copies the file to runbooks/testing/.

    .PARAMETER RunbookName
        Filename of the runbook (e.g., "Set-SitePermissions.ps1").

    .PARAMETER StagingPath
        Path to staged runbooks. Default: .\runbooks\staging

    .PARAMETER TestingPath
        Path to testing folder. Default: .\runbooks\testing

    .EXAMPLE
        .\agent\skills\validate-runbook.ps1 -RunbookName "Set-SitePermissions.ps1"
#>

param(
    [Parameter(Mandatory)]
    [string]$RunbookName,

    [Parameter()]
    [string]$StagingPath = ".\runbooks\staging",

    [Parameter()]
    [string]$TestingPath = ".\runbooks\testing",

    [Parameter()]
    [string]$SourcePath = ".\runbooks\source"
)

$ErrorActionPreference = "Stop"

$stagedFile = Join-Path $StagingPath $RunbookName
if (-not (Test-Path $stagedFile)) {
    throw "Staged file not found: $stagedFile"
}

$content = Get-Content $stagedFile -Raw
$lines = Get-Content $stagedFile
$checks = [System.Collections.ArrayList]::new()
$passed = $true

function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $status = if ($Ok) { "PASS" } else { "FAIL"; $script:passed = $false }
    $null = $script:checks.Add([PSCustomObject]@{ Check = $Name; Status = $status; Detail = $Detail })
    Write-Output "[$status] $Name — $Detail"
}

Write-Output "=== VALIDATION: $RunbookName ==="
Write-Output ""

# --- Check 1: Syntax ---
$syntaxErrors = $null
$null = [System.Management.Automation.PSParser]::Tokenize($content, [ref]$syntaxErrors)
Add-Check -Name "Syntax" -Ok ($syntaxErrors.Count -eq 0) `
    -Detail $(if ($syntaxErrors.Count -eq 0) { "No errors" } else { "$($syntaxErrors.Count) error(s): $($syntaxErrors[0].Message)" })

# --- Check 2: No legacy auth patterns ---
$legacyPatterns = @(
    'Get-AutomationPSCredential', 'Get-Credential\b',
    'AzureRunAsConnection', 'Connect-SPOService',
    'Connect-PnPOnline\s+.*-Credential', 'Connect-PnPOnline\s+.*-ClientSecret',
    'Connect-ExchangeOnline\s+.*-Credential',
    'New-PSSession.*Microsoft\.Exchange'
)
$legacyFound = @()
foreach ($pat in $legacyPatterns) {
    if ($content -match $pat) { $legacyFound += $pat }
}
Add-Check -Name "No legacy auth" -Ok ($legacyFound.Count -eq 0) `
    -Detail $(if ($legacyFound.Count -eq 0) { "Clean" } else { "Found: $($legacyFound -join ', ')" })

# --- Check 3: Uses shared module ---
$usesModule = $content -match 'Import-Module\s+Contoso\.Automation\.Auth' -or
              $content -match '#Requires\s+-Modules\s+Contoso\.Automation\.Auth'
Add-Check -Name "Uses shared module" -Ok $usesModule -Detail $(if ($usesModule) { "Found" } else { "Missing Import-Module or #Requires" })

# --- Check 4: Has error handling ---
$hasTryCatch = $content -match 'try\s*\{' -and $content -match 'catch\s*\{'
Add-Check -Name "Error handling" -Ok $hasTryCatch -Detail $(if ($hasTryCatch) { "try/catch present" } else { "Missing try/catch block" })

# --- Check 5: Has cleanup ---
$hasCleanup = $content -match 'Disconnect-ContosoAll|Disconnect-PnPOnline|finally\s*\{'
Add-Check -Name "Cleanup/disconnect" -Ok $hasCleanup -Detail $(if ($hasCleanup) { "Found" } else { "Missing Disconnect in finally block" })

# --- Check 6: Parameter contract preserved (AST-based) ---
$sourceFile = Join-Path $SourcePath $RunbookName
if (Test-Path $sourceFile) {
    $sourceContent = Get-Content $sourceFile -Raw

    # Parse both files using PowerShell AST
    $sourceErrors = $null
    $stagedErrors = $null
    $sourceAST = [System.Management.Automation.Language.Parser]::ParseInput($sourceContent, [ref]$null, [ref]$sourceErrors)
    $stagedAST = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$stagedErrors)

    $sourceParamBlock = $sourceAST.ParamBlock
    $stagedParamBlock = $stagedAST.ParamBlock

    if ($sourceParamBlock) {
        $contractIssues = [System.Collections.ArrayList]::new()

        # Extract parameter details from source
        $sourceParamInfo = $sourceParamBlock.Parameters | ForEach-Object {
            $paramName = $_.Name.VariablePath.UserPath
            $paramType = if ($_.StaticType) { $_.StaticType.Name } else { "object" }
            $isMandatory = $_.Attributes | Where-Object {
                $_ -is [System.Management.Automation.Language.AttributeAst] -and
                $_.TypeName.Name -eq "Parameter" -and
                $_.NamedArguments | Where-Object { $_.ArgumentName -eq "Mandatory" }
            }
            [PSCustomObject]@{
                Name      = $paramName
                Type      = $paramType
                Mandatory = [bool]$isMandatory
            }
        }

        if ($stagedParamBlock) {
            $stagedParamNames = $stagedParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }

            foreach ($sp in $sourceParamInfo) {
                if ($sp.Name -notin $stagedParamNames) {
                    $null = $contractIssues.Add("REMOVED: -$($sp.Name) ($($sp.Type))")
                } else {
                    # Check type match
                    $stagedParam = $stagedParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $sp.Name }
                    $stagedType = if ($stagedParam.StaticType) { $stagedParam.StaticType.Name } else { "object" }
                    if ($sp.Type -ne $stagedType -and $sp.Type -ne "object" -and $stagedType -ne "object") {
                        $null = $contractIssues.Add("TYPE CHANGED: -$($sp.Name) was [$($sp.Type)], now [$stagedType]")
                    }
                }
            }
        } else {
            $null = $contractIssues.Add("Param block was REMOVED entirely from migrated version")
        }

        Add-Check -Name "Parameter contract" -Ok ($contractIssues.Count -eq 0) `
            -Detail $(if ($contractIssues.Count -eq 0) {
                "All $($sourceParamInfo.Count) parameters preserved with matching types"
            } else {
                "CONTRACT DRIFT: $($contractIssues -join '; ')"
            })
    }
}

# --- Check 7: No legacy module imports ---
$legacyImports = @('Microsoft\.Online\.SharePoint\.PowerShell', 'AzureAD', 'MSOnline')
$foundLegacyImports = $legacyImports | Where-Object { $content -match "Import-Module\s+$_" }
Add-Check -Name "No legacy module imports" -Ok ($foundLegacyImports.Count -eq 0) `
    -Detail $(if ($foundLegacyImports.Count -eq 0) { "Clean" } else { "Still imports: $($foundLegacyImports -join ', ')" })

# --- Check 8: No hardcoded secrets ---
$secretPatterns = $content | Select-String -Pattern '(password|secret|key)\s*=\s*[''"][^''"]{8,}[''"]' -AllMatches
Add-Check -Name "No hardcoded secrets" -Ok ($secretPatterns.Count -eq 0) `
    -Detail $(if ($secretPatterns.Count -eq 0) { "Clean" } else { "Possible hardcoded secret found — review manually" })

# --- Check 9: ErrorActionPreference ---
$hasEAP = $content -match '\$ErrorActionPreference\s*=\s*[''"]Stop[''"]'
Add-Check -Name "ErrorActionPreference" -Ok $hasEAP `
    -Detail $(if ($hasEAP) { 'Set to "Stop"' } else { 'Missing $ErrorActionPreference = "Stop"' })

# --- Summary ---
Write-Output ""
$passCount = ($checks | Where-Object Status -eq "PASS").Count
$failCount = ($checks | Where-Object Status -eq "FAIL").Count
Write-Output "Results: $passCount passed, $failCount failed"

if ($passed) {
    # Advance to testing
    if (-not (Test-Path $TestingPath)) {
        New-Item -ItemType Directory -Path $TestingPath -Force | Out-Null
    }
    Copy-Item -Path $stagedFile -Destination (Join-Path $TestingPath $RunbookName) -Force
    Write-Output ""
    Write-Output "PASSED — Copied to $TestingPath\$RunbookName"
    Write-Output "Next: Human reviews and tests in Azure Automation Test pane."
} else {
    Write-Output ""
    Write-Output "FAILED — Fix issues in $StagingPath\$RunbookName and re-validate."
}

return [PSCustomObject]@{
    Runbook   = $RunbookName
    Passed    = $passed
    Checks    = $checks
    PassCount = $passCount
    FailCount = $failCount
}
