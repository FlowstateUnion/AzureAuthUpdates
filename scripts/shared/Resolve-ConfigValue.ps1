<#
    .SYNOPSIS
        Resolves a config value from: explicit parameter → env var → prompt.

    .DESCRIPTION
        Used by project scripts to resolve required values with graceful fallback.
        Priority: 1) explicit parameter value, 2) environment variable, 3) interactive prompt.

    .EXAMPLE
        $rg = Resolve-ConfigValue -Value $ResourceGroupName -EnvVar "AUTOMATION_RESOURCE_GROUP" -Prompt "Resource Group"
#>

function Resolve-ConfigValue {
    param(
        [Parameter()]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$EnvVar,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter()]
        [switch]$Required
    )

    # 1. Explicit parameter
    if ($Value) { return $Value }

    # 2. Environment variable (from .env)
    $envValue = [System.Environment]::GetEnvironmentVariable($EnvVar)
    if ($envValue) { return $envValue }

    # 3. Interactive prompt
    if ($Required) {
        $input = Read-Host -Prompt $Prompt
        if (-not $input) { throw "$Prompt is required. Set it via parameter, .env file ($EnvVar), or prompt." }
        return $input
    }

    return $null
}
