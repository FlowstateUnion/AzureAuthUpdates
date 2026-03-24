<#
    .SYNOPSIS
        Installs all required PowerShell modules for local testing.

    .DESCRIPTION
        Installs the modules needed to run project scripts locally. Uses the
        MODULE_INSTALL_SCOPE from .env (default: CurrentUser) to determine
        install scope. Use -Scope to override.

    .PARAMETER Scope
        Module install scope: CurrentUser or AllUsers.
        Defaults to MODULE_INSTALL_SCOPE from .env, or CurrentUser if not set.

    .PARAMETER SkipIfInstalled
        Skip modules that are already installed (any version). Default: true.

    .EXAMPLE
        # Install with CurrentUser scope (default for local testing)
        .\Install-Prerequisites.ps1

        # Install with AllUsers scope (for servers/Hybrid Workers)
        .\Install-Prerequisites.ps1 -Scope AllUsers

        # Force reinstall even if already present
        .\Install-Prerequisites.ps1 -SkipIfInstalled:$false
#>

param(
    [Parameter()]
    [ValidateSet("CurrentUser", "AllUsers")]
    [string]$Scope,

    [Parameter()]
    [bool]$SkipIfInstalled = $true
)

$ErrorActionPreference = "Stop"

# --- Load .env config ---
. "$PSScriptRoot\..\shared\Load-EnvConfig.ps1"

if (-not $Scope) {
    $Scope = if ($env:MODULE_INSTALL_SCOPE) { $env:MODULE_INSTALL_SCOPE } else { "CurrentUser" }
}

Write-Output "=== Installing Prerequisites ==="
Write-Output "Scope: $Scope"
Write-Output ""

# --- Module list ---
$modules = @(
    @{ Name = "Az.Accounts";                    MinVersion = "3.0.0" }
    @{ Name = "Az.Automation";                  MinVersion = "1.10.0" }
    @{ Name = "Az.KeyVault";                    MinVersion = "6.0.0" }
    @{ Name = "PnP.PowerShell";                 MinVersion = "2.4.0" }
    @{ Name = "Microsoft.Graph.Authentication"; MinVersion = "2.0.0" }
    @{ Name = "Microsoft.Graph.Applications";   MinVersion = "2.0.0" }
    @{ Name = "Microsoft.Graph.Sites";          MinVersion = "2.0.0" }
    @{ Name = "Microsoft.Graph.Users";          MinVersion = "2.0.0" }
    @{ Name = "Microsoft.Graph.Groups";         MinVersion = "2.0.0" }
    @{ Name = "ExchangeOnlineManagement";       MinVersion = "3.2.0" }
)

$installed = 0
$skipped = 0
$failed = 0

foreach ($mod in $modules) {
    $existing = Get-Module -ListAvailable -Name $mod.Name -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1

    if ($SkipIfInstalled -and $existing) {
        if ($existing.Version -ge [version]$mod.MinVersion) {
            Write-Output "[SKIP] $($mod.Name) v$($existing.Version) (>= $($mod.MinVersion))"
            $skipped++
            continue
        } else {
            Write-Output "[UPDATE] $($mod.Name) v$($existing.Version) → $($mod.MinVersion)+"
        }
    }

    try {
        Write-Output "[INSTALL] $($mod.Name) (>= $($mod.MinVersion)) — Scope: $Scope"
        Install-Module -Name $mod.Name -MinimumVersion $mod.MinVersion `
            -Scope $Scope -Force -AllowClobber -ErrorAction Stop
        $installed++
    }
    catch {
        Write-Warning "[FAIL] $($mod.Name): $($_.Exception.Message)"
        $failed++
    }
}

Write-Output ""
Write-Output "=== Summary ==="
Write-Output "Installed: $installed"
Write-Output "Skipped:   $skipped"
Write-Output "Failed:    $failed"

if ($failed -gt 0) {
    Write-Warning "Some modules failed to install. Check errors above."
    if ($Scope -eq "AllUsers") {
        Write-Output "Tip: AllUsers scope requires an elevated (admin) PowerShell session."
    }
}

Write-Output ""
Write-Output "Install scope used: $Scope"
Write-Output "To change default scope, set MODULE_INSTALL_SCOPE in .env"
