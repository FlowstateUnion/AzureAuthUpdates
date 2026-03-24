# Strategy: PowerShell 5.1 → 7.4 Compatibility

## Overview

Migrating from PS 5.1 to PS 7.4 introduces breaking changes beyond authentication. This document catalogs known issues and provides detection patterns and remediation for each.

This is separate from the auth migration — a runbook can have zero legacy auth patterns but still break on PS 7.4 due to runtime differences.

## Critical Breaking Changes

### 1. COM Objects

**Impact:** HIGH — COM is Windows-only and Desktop-edition only.

**Symptom:** `New-Object -ComObject` fails with "Retrieving the COM class factory failed."

**Common patterns:**
```powershell
# These WILL NOT work on PS 7.4
$excel = New-Object -ComObject Excel.Application
$word = New-Object -ComObject Word.Application
$outlook = New-Object -ComObject Outlook.Application
$ie = New-Object -ComObject InternetExplorer.Application
$shell = New-Object -ComObject Shell.Application
$fso = New-Object -ComObject Scripting.FileSystemObject
```

**Detection pattern (add to scanner):**
```
New-Object\s+.*-ComObject
```

**Remediation:**
- **Excel:** Replace with `ImportExcel` module (PS 7 compatible, no COM needed):
  ```powershell
  Install-Module ImportExcel
  $data | Export-Excel -Path "report.xlsx" -AutoSize
  ```
- **Word:** Use `DocumentFormat.OpenXml` NuGet package or Markdown/HTML output
- **Outlook:** Use Microsoft Graph (`Send-MgUserMail`) — already covered in auth migration
- **File system:** Use native PS cmdlets (`Get-ChildItem`, `Copy-Item`, etc.)
- **Keep on PS 5.1:** If COM is essential and no replacement exists, document the exception

### 2. .NET Framework Types via Add-Type

**Impact:** MEDIUM — .NET Framework assemblies are not available in .NET (Core).

**Symptom:** `Add-Type -AssemblyName` fails or `[System.Something]` type not found.

**Common patterns:**
```powershell
# May fail if the assembly is .NET Framework only
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Web.HttpUtility]::UrlEncode($string)
[System.Windows.Forms.MessageBox]::Show("Alert")
```

**Detection pattern:**
```
Add-Type\s+-AssemblyName|System\.Web\.|System\.Windows\.Forms|PresentationFramework|Microsoft\.VisualBasic
```

**Remediation:**

| .NET Framework Type | PS 7.4 Replacement |
|---------------------|--------------------|
| `[System.Web.HttpUtility]::UrlEncode()` | `[System.Net.WebUtility]::UrlEncode()` or `[uri]::EscapeDataString()` |
| `[System.Web.HttpUtility]::HtmlEncode()` | `[System.Net.WebUtility]::HtmlEncode()` |
| `System.Windows.Forms` | Not available — use alternative output (CSV, HTML, email) |
| `Microsoft.VisualBasic.Interaction` | Use PS native equivalents |
| `System.DirectoryServices` | Use `Microsoft.Graph` module instead |

### 3. WMI Cmdlets

**Impact:** MEDIUM — Legacy WMI cmdlets removed in PS 7.

**Symptom:** `Get-WmiObject` is not recognized.

**Common patterns:**
```powershell
Get-WmiObject -Class Win32_OperatingSystem
Get-WmiObject Win32_Service
Set-WmiInstance
Invoke-WmiMethod
```

**Detection pattern:**
```
Get-WmiObject|Set-WmiInstance|Invoke-WmiMethod|Register-WmiEvent
```

**Remediation:** Replace with CIM cmdlets (available in both PS 5.1 and 7.x):

| WMI Cmdlet | CIM Replacement |
|------------|-----------------|
| `Get-WmiObject Win32_Service` | `Get-CimInstance -ClassName Win32_Service` |
| `Set-WmiInstance` | `Set-CimInstance` |
| `Invoke-WmiMethod` | `Invoke-CimMethod` |
| `Register-WmiEvent` | `Register-CimIndicationEvent` |

### 4. $null Handling Changes

**Impact:** MEDIUM — Subtle behavior changes can cause logic bugs.

**PS 5.1 behavior:**
```powershell
# In PS 5.1, iterating over $null runs the loop zero times
$null | ForEach-Object { Write-Output "This runs in 5.1" }  # Runs once with $_ = $null
```

**PS 7.4 behavior:**
```powershell
# In PS 7.x, behavior is the same, but strict mode differences exist
# More importantly: $null -eq $collection behaves differently
$arr = @()
if ($arr) { "truthy" } else { "falsy" }  # Both versions: "falsy"
# But chaining comparisons differ in edge cases
```

**Remediation:** Always use explicit null checks:
```powershell
if ($null -ne $result -and $result.Count -gt 0) {
    # Process results
}
```

### 5. Encoding Defaults

**Impact:** LOW-MEDIUM — Can corrupt file content silently.

**Change:** PS 5.1 defaults to Windows-1252/ASCII for many cmdlets. PS 7.x defaults to UTF-8 (no BOM).

**Affected cmdlets:**
```powershell
Out-File          # PS 5.1: UTF-16LE / PS 7: UTF-8 NoBOM
Set-Content       # PS 5.1: OS default  / PS 7: UTF-8 NoBOM
Add-Content       # Same change
Export-Csv        # Same change
```

**Remediation:** Explicitly specify encoding:
```powershell
# Make behavior consistent across versions
$data | Out-File -FilePath "output.txt" -Encoding utf8
$data | Set-Content -Path "output.txt" -Encoding utf8
```

### 6. Implicit Type Conversions

**Impact:** LOW — Rare but can cause subtle bugs.

**Changes:**
```powershell
# PS 5.1: string "True" converts to $true in boolean context
# PS 7.x: Same, but some edge cases with custom types differ

# PS 5.1: [int]"" returns 0
# PS 7.x: [int]"" throws an error
```

**Remediation:** Use explicit parsing:
```powershell
$value = [int]::TryParse($input, [ref]$null)
if ([string]::IsNullOrEmpty($input)) { $value = 0 }
```

### 7. Removed or Changed Cmdlet Parameters

**Impact:** VARIES

| Cmdlet | Change |
|--------|--------|
| `Invoke-WebRequest` | `-UseBasicParsing` is default in 7.x (no IE dependency) — parameter still exists but is a no-op |
| `Start-Job` | `-PSVersion` parameter removed |
| `Select-String` | Returns `MatchInfo` with slightly different properties in 7.x |
| `Get-Content` / `Set-Content` | `-Encoding` values changed (`Byte` → `byte`, new `utf8NoBOM`, etc.) |
| `Sort-Object` | Stable sort is now default in 7.x (was not guaranteed in 5.1) |

### 8. Module Compatibility

| Module | PS 5.1 | PS 7.4 | Notes |
|--------|--------|--------|-------|
| `ActiveDirectory` | Yes | Yes (Windows only, RSAT) | Same module, requires Windows |
| `AzureAD` | Yes | **No** | Deprecated; use Microsoft.Graph |
| `MSOnline` | Yes | **No** | Deprecated; use Microsoft.Graph |
| `PnP.PowerShell` 1.x | Yes | No | Legacy; unmaintained |
| `PnP.PowerShell` 2.x+ | No | **Yes** | Target version |
| `ImportExcel` | Yes | Yes | Works on both |
| `SqlServer` | Yes | Yes | Works on both |
| `ExchangeOnlineManagement` 3.x | Yes | Yes | Works on both |

## Detection Script

Extend `Scan-LegacyAuth.ps1` or run separately to find PS 7.4 compatibility issues:

```powershell
# PS 7.4 compatibility patterns to scan for
$ps74Patterns = @(
    @{ Name = "COM Object"; Pattern = 'New-Object\s+.*-ComObject'; Severity = "High"
       Guidance = "COM objects not supported in PS 7. Use alternative modules or keep on PS 5.1." }
    @{ Name = ".NET Framework Assembly"; Pattern = 'Add-Type\s+-AssemblyName\s+(System\.Web|System\.Windows|PresentationFramework|Microsoft\.VisualBasic)'
       Severity = "High"; Guidance = "Assembly may not exist in .NET Core. Find PS 7 equivalent." }
    @{ Name = "WMI Cmdlet"; Pattern = 'Get-WmiObject|Set-WmiInstance|Invoke-WmiMethod|Register-WmiEvent'
       Severity = "Medium"; Guidance = "Replace with CIM cmdlets (Get-CimInstance, etc.)" }
    @{ Name = "System.Web HttpUtility"; Pattern = 'System\.Web\.HttpUtility'
       Severity = "Medium"; Guidance = "Use [System.Net.WebUtility] or [uri]::EscapeDataString()" }
    @{ Name = "AzureAD Module"; Pattern = 'Import-Module\s+AzureAD|Connect-AzureAD'
       Severity = "High"; Guidance = "AzureAD module does not support PS 7. Use Microsoft.Graph." }
    @{ Name = "MSOnline Module"; Pattern = 'Import-Module\s+MSOnline|Connect-MsolService'
       Severity = "High"; Guidance = "MSOnline module does not support PS 7. Use Microsoft.Graph." }
    @{ Name = "Windows Forms"; Pattern = 'System\.Windows\.Forms|Windows\.Forms'
       Severity = "Medium"; Guidance = "Not available in Azure Automation cloud sandbox or PS 7 Core." }
    @{ Name = "Encoding Byte"; Pattern = '-Encoding\s+Byte'
       Severity = "Low"; Guidance = "Use -AsByteStream in PS 7 instead of -Encoding Byte." }
)
```

## Decision: When to Keep a Runbook on PS 5.1

Keep on PS 5.1 if the runbook:
- Uses COM objects with no viable replacement
- Depends on Windows-only .NET Framework assemblies critical to its function
- Uses modules that are PS 5.1-only (AzureAD, MSOnline) AND cannot be migrated to Graph yet
- Interacts with legacy Windows infrastructure via WMI and CIM is not sufficient

**Document every exception** in the migration queue CSV with a `PS51Exception` column and the reason.

**Important:** Runbooks kept on PS 5.1 can still benefit from auth migration (Managed Identity works on PS 5.1 with `Az.Accounts`). Only PnP.PowerShell 2.x+ requires PS 7.

## Recommended Testing Process

For each runbook migrating to PS 7.4:

1. Run through the compatibility scanner first
2. Fix any detected patterns
3. Test in the PS 7.4 runtime environment Test pane
4. Compare output to the last PS 5.1 run
5. Pay special attention to:
   - File encoding of any outputs
   - Date/time formatting
   - Numeric precision
   - Error message formats (downstream consumers may parse these)
