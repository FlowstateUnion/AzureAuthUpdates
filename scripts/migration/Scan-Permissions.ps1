<#
    .SYNOPSIS
        Analyzes runbook source code to recommend CANDIDATE API permissions (advisory).

    .DESCRIPTION
        Scans runbooks for cmdlet usage patterns and maps them to likely
        Entra ID App Roles (Graph and SharePoint permissions).

        IMPORTANT — ADVISORY ONLY: This is a planning aid, not an authoritative
        minimum-permissions tool. Known limitations:
        - Cannot detect permissions needed for REST calls (Invoke-RestMethod, Invoke-MgGraphRequest)
        - Cannot detect parameter-conditional permissions (e.g., Get-MgUser -Property Manager needs more than User.Read.All)
        - Cannot detect permissions needed by splatted or dynamically-invoked commands
        - Results should be reviewed by a human before granting to Managed Identity

    .PARAMETER Path
        Directory containing exported runbook .ps1 files.

    .PARAMETER OutputCsv
        Path for the permission report CSV. Default: .\plan\permission-audit.csv

    .EXAMPLE
        .\Scan-Permissions.ps1 -Path ".\runbooks\source"
#>

param(
    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter()]
    [string]$OutputCsv = ".\plan\permission-audit.csv"
)

$ErrorActionPreference = "Stop"

# --- Cmdlet-to-Permission Mappings ---
# Maps PowerShell cmdlets to the minimum API permissions they require.
# These are application-level permissions (for Managed Identity / app-only context).

$cmdletPermissions = @(
    # --- PnP SharePoint: Read operations ---
    @{ Pattern = 'Get-PnPList\b|Get-PnPListItem|Get-PnPWeb\b|Get-PnPSite\b|Get-PnPField'
       Permission = "Sites.Read.All"; Service = "SharePoint"; Level = "Read" }
    @{ Pattern = 'Get-PnPTenantSite|Get-PnPTenant\b|Get-PnPTenantDeletedSite'
       Permission = "Sites.Read.All"; Service = "SharePoint"; Level = "Read" }

    # --- PnP SharePoint: Write operations ---
    @{ Pattern = 'Set-PnPListItem|Add-PnPListItem|Remove-PnPListItem|New-PnPList'
       Permission = "Sites.ReadWrite.All"; Service = "SharePoint"; Level = "ReadWrite" }
    @{ Pattern = 'Set-PnPTenantSite|New-PnPTenantSite|Remove-PnPTenantSite'
       Permission = "Sites.FullControl.All"; Service = "SharePoint"; Level = "FullControl" }
    @{ Pattern = 'Set-PnPTenant\b'
       Permission = "Sites.FullControl.All"; Service = "SharePoint"; Level = "FullControl" }

    # --- PnP SharePoint: Permission management ---
    @{ Pattern = 'Set-PnPSiteGroup|Add-PnPSiteCollectionAdmin|Set-PnPWebPermission|Grant-PnPSiteDesignRights'
       Permission = "Sites.FullControl.All"; Service = "SharePoint"; Level = "FullControl" }

    # --- PnP SharePoint: File operations ---
    @{ Pattern = 'Get-PnPFile\b|Get-PnPFolder'
       Permission = "Sites.Read.All"; Service = "SharePoint"; Level = "Read" }
    @{ Pattern = 'Add-PnPFile|Set-PnPFile|Remove-PnPFile|Add-PnPFolder|Copy-PnPFile|Move-PnPFile'
       Permission = "Sites.ReadWrite.All"; Service = "SharePoint"; Level = "ReadWrite" }

    # --- Graph: User operations ---
    @{ Pattern = 'Get-MgUser\b|Get-MgUserMember'
       Permission = "User.Read.All"; Service = "Graph"; Level = "Read" }
    @{ Pattern = 'Update-MgUser|New-MgUser|Remove-MgUser'
       Permission = "User.ReadWrite.All"; Service = "Graph"; Level = "ReadWrite" }

    # --- Graph: Group operations ---
    @{ Pattern = 'Get-MgGroup\b|Get-MgGroupMember'
       Permission = "Group.Read.All"; Service = "Graph"; Level = "Read" }
    @{ Pattern = 'New-MgGroup|Update-MgGroup|Remove-MgGroup|New-MgGroupMember|Remove-MgGroupMember'
       Permission = "Group.ReadWrite.All"; Service = "Graph"; Level = "ReadWrite" }

    # --- Graph: Mail operations ---
    @{ Pattern = 'Send-MgUserMail'
       Permission = "Mail.Send"; Service = "Graph"; Level = "Write" }
    @{ Pattern = 'Get-MgUserMessage|Get-MgUserMailFolder'
       Permission = "Mail.Read"; Service = "Graph"; Level = "Read" }
    @{ Pattern = 'Update-MgUserMessage|Remove-MgUserMessage|Move-MgUserMessage'
       Permission = "Mail.ReadWrite"; Service = "Graph"; Level = "ReadWrite" }

    # --- Graph: Calendar ---
    @{ Pattern = 'Get-MgUserCalendarEvent|Get-MgUserEvent'
       Permission = "Calendars.Read"; Service = "Graph"; Level = "Read" }
    @{ Pattern = 'New-MgUserEvent|Update-MgUserEvent|Remove-MgUserEvent'
       Permission = "Calendars.ReadWrite"; Service = "Graph"; Level = "ReadWrite" }

    # --- Graph: Sites (via Graph, not PnP) ---
    @{ Pattern = 'Get-MgSite\b'
       Permission = "Sites.Read.All"; Service = "Graph"; Level = "Read" }
    @{ Pattern = 'Update-MgSite'
       Permission = "Sites.ReadWrite.All"; Service = "Graph"; Level = "ReadWrite" }

    # --- Graph: Directory operations ---
    @{ Pattern = 'Get-MgDirectoryRole|Get-MgServicePrincipal'
       Permission = "Directory.Read.All"; Service = "Graph"; Level = "Read" }

    # --- Exchange Online ---
    @{ Pattern = 'Connect-ExchangeOnline|Get-EXOMailbox|Get-Mailbox|Get-TransportRule'
       Permission = "Exchange.ManageAsApp"; Service = "Exchange"; Level = "Admin" }

    # --- SPO Admin (legacy, flagged separately) ---
    @{ Pattern = 'Connect-SPOService|Get-SPOSite|Set-SPOSite|Set-SPOTenant'
       Permission = "Sites.FullControl.All"; Service = "SharePoint"; Level = "FullControl" }
)

# --- Helper: compare permission levels (must be defined before use) ---
function Compare-PermissionLevel {
    param([string]$A, [string]$B)
    $order = @{ "Read" = 1; "ReadWrite" = 2; "Write" = 2; "FullControl" = 3; "Admin" = 3 }
    $aVal = if ($order.ContainsKey($A)) { $order[$A] } else { 0 }
    $bVal = if ($order.ContainsKey($B)) { $order[$B] } else { 0 }
    return $aVal - $bVal
}

# --- Scan ---
$files = Get-ChildItem -Path $Path -Filter "*.ps1" -Recurse -File
$results = [System.Collections.ArrayList]::new()

Write-Output "Scanning $($files.Count) runbooks for permission requirements..."

foreach ($file in $files) {
    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }

    $filePerms = @{}

    foreach ($mapping in $cmdletPermissions) {
        if ($content -match $mapping.Pattern) {
            $key = "$($mapping.Service)|$($mapping.Permission)"
            # Keep the highest level if multiple matches for same service
            if (-not $filePerms.ContainsKey($key) -or
                (Compare-PermissionLevel $mapping.Level $filePerms[$key].Level) -gt 0) {
                $filePerms[$key] = $mapping
            }
        }
    }

    # Deduplicate by service — keep highest permission per service
    $servicePerms = @{}
    foreach ($perm in $filePerms.Values) {
        $svcKey = $perm.Service
        if (-not $servicePerms.ContainsKey($svcKey)) {
            $servicePerms[$svcKey] = [System.Collections.ArrayList]::new()
        }
        # Check if a higher-level perm for same API scope already exists
        $existing = $servicePerms[$svcKey] | Where-Object { $_.Permission -eq $perm.Permission }
        if (-not $existing) {
            $null = $servicePerms[$svcKey].Add($perm)
        }
    }

    # Build result
    foreach ($svc in $servicePerms.Keys) {
        foreach ($p in $servicePerms[$svc]) {
            $null = $results.Add([PSCustomObject]@{
                Runbook    = $file.Name
                Service    = $p.Service
                Permission = $p.Permission
                Level      = $p.Level
                Rationale  = "Detected cmdlet pattern: $($p.Pattern)"
            })
        }
    }
}

# --- Output ---
if ($results.Count -eq 0) {
    Write-Output "No permission-requiring cmdlets detected."
} else {
    # Advisory disclaimer
    Write-Output ""
    Write-Output "================================================================"
    Write-Output "  ADVISORY: These are CANDIDATE permissions based on cmdlet"
    Write-Output "  detection. Not authoritative. Review before granting."
    Write-Output "  Blind spots: REST API calls, splatted params, dynamic commands."
    Write-Output "================================================================"

    # Per-runbook summary
    Write-Output ""
    Write-Output "=== Per-Runbook Candidate Permissions ==="
    $results | Group-Object Runbook | ForEach-Object {
        Write-Output ""
        Write-Output "  $($_.Name):"
        $_.Group | ForEach-Object {
            Write-Output "    [$($_.Service)] $($_.Permission) ($($_.Level))"
        }
    }

    # Global candidate permission set
    Write-Output ""
    Write-Output "=== Candidate Permission Set (Union of All Runbooks) ==="
    $globalPerms = $results | Select-Object -Unique Service, Permission, Level |
        Sort-Object Service, Level
    $globalPerms | ForEach-Object {
        Write-Output "  [$($_.Service)] $($_.Permission)"
    }

    # Check for over-provisioning opportunities
    Write-Output ""
    Write-Output "=== Over-Provisioning Analysis ==="
    $fullControlRunbooks = $results | Where-Object { $_.Level -eq "FullControl" }
    $readOnlyRunbooks = $results | Group-Object Runbook | Where-Object {
        $maxLevel = ($_.Group.Level | ForEach-Object {
            switch ($_) { "Read" { 1 } "ReadWrite" { 2 } "Write" { 2 } "FullControl" { 3 } "Admin" { 3 } default { 0 } }
        } | Measure-Object -Maximum).Maximum
        $maxLevel -le 1
    }

    if ($readOnlyRunbooks.Count -gt 0) {
        Write-Output "  Runbooks needing READ-ONLY access ($($readOnlyRunbooks.Count)):"
        Write-Output "  These could use a separate, read-only MI to limit blast radius:"
        $readOnlyRunbooks | ForEach-Object { Write-Output "    $($_.Name)" }
    }

    if ($fullControlRunbooks.Count -gt 0) {
        Write-Output ""
        Write-Output "  Runbooks requiring FULL CONTROL ($( ($fullControlRunbooks | Select-Object -Unique Runbook).Count )):"
        $fullControlRunbooks | Select-Object -Unique Runbook | ForEach-Object { Write-Output "    $($_.Runbook)" }
        Write-Output "  Consider: Do these actually need FullControl, or can admin cmdlets be refactored?"
    }

    # Export
    $results | Export-Csv -Path $OutputCsv -NoTypeInformation -Force
    Write-Output ""
    Write-Output "Full report exported to: $OutputCsv"
}

return [PSCustomObject]@{
    TotalRunbooks         = $files.Count
    RunbooksWithPerms     = ($results | Select-Object -Unique Runbook).Count
    TotalPermissions      = ($results | Select-Object -Unique Service, Permission).Count
    FullControlRequired   = ($results | Where-Object Level -eq "FullControl" | Select-Object -Unique Runbook).Count
    ReadOnlyEligible      = ($results | Group-Object Runbook | Where-Object {
        ($_.Group.Level | ForEach-Object { switch ($_) { "Read" { 1 } default { 2 } } } | Measure-Object -Maximum).Maximum -le 1
    }).Count
    Results               = $results
}
