<#
    .SYNOPSIS
        Loads configuration from .env file into the current session.

    .DESCRIPTION
        Reads key=value pairs from the project's .env file and sets them as
        environment variables ($env:KEY) for the current session. Skips comments
        and blank lines. Does NOT overwrite existing environment variables unless
        -Force is specified.

        All project scripts source this file at the top to pick up tenant config.

    .PARAMETER EnvFilePath
        Path to the .env file. Default: searches up from script location for .env

    .PARAMETER Force
        Overwrite existing environment variables with .env values.

    .EXAMPLE
        # Dot-source in any script:
        . "$PSScriptRoot\..\shared\Load-EnvConfig.ps1"

        # Then use values:
        $rg = $env:AUTOMATION_RESOURCE_GROUP
#>

param(
    [Parameter()]
    [string]$EnvFilePath,

    [Parameter()]
    [switch]$Force
)

# --- Find .env file ---
if (-not $EnvFilePath) {
    # Walk up from current script directory to find .env
    $searchDir = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
    $found = $false
    for ($depth = 0; $depth -lt 5; $depth++) {
        $candidate = Join-Path $searchDir ".env"
        if (Test-Path $candidate) {
            $EnvFilePath = $candidate
            $found = $true
            break
        }
        $searchDir = Split-Path $searchDir -Parent
        if (-not $searchDir) { break }
    }

    if (-not $found) {
        # Try project root explicitly
        $projectRoot = Join-Path $PSScriptRoot "..\.." | Resolve-Path -ErrorAction SilentlyContinue
        if ($projectRoot) {
            $candidate = Join-Path $projectRoot ".env"
            if (Test-Path $candidate) {
                $EnvFilePath = $candidate
                $found = $true
            }
        }
    }

    if (-not $found) {
        Write-Warning "No .env file found. Copy .env.template to .env and fill in your values."
        Write-Warning "Scripts will use parameter defaults or prompt for required values."
        return
    }
}

if (-not (Test-Path $EnvFilePath)) {
    Write-Warning ".env file not found at: $EnvFilePath"
    return
}

# --- Parse and load ---
$loaded = 0
Get-Content $EnvFilePath | ForEach-Object {
    $line = $_.Trim()

    # Skip comments and blanks
    if ($line -eq "" -or $line.StartsWith("#")) { return }

    # Parse key=value
    $eqIndex = $line.IndexOf("=")
    if ($eqIndex -le 0) { return }

    $key = $line.Substring(0, $eqIndex).Trim()
    $value = $line.Substring($eqIndex + 1).Trim()

    # Remove surrounding quotes if present
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
    }

    # Skip empty values
    if ($value -eq "") { return }

    # Set as environment variable
    $existing = [System.Environment]::GetEnvironmentVariable($key)
    if ($Force -or -not $existing) {
        [System.Environment]::SetEnvironmentVariable($key, $value)
        $loaded++
    }
}

Write-Verbose "Loaded $loaded variables from $EnvFilePath"
