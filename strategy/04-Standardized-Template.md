# Strategy: Standardized Runbook Template

## Purpose

Every migrated runbook should follow a consistent structure. This reduces cognitive load, simplifies troubleshooting, and ensures the shared auth module is used correctly.

## Template Location

`templates/RunbookTemplate.ps1`

## Template Structure

```
1.  #Requires statements (modules, version)
2.  Script header (.SYNOPSIS, .DESCRIPTION, .NOTES)
3.  Parameters (param block)
4.  Configuration ($ErrorActionPreference, $InformationPreference)
5.  Authentication (shared module)
6.  Business logic (wrapped in try/catch)
7.  Cleanup (disconnect, dispose)
```

## Template Rules

### R1: Module Requirements
Every runbook must declare its module dependencies:
```powershell
#Requires -Modules Contoso.Automation.Auth
#Requires -Modules @{ ModuleName="PnP.PowerShell"; ModuleVersion="2.4" }
```

### R2: Script Header
Every runbook must have a comment-based help block with at minimum:
- `.SYNOPSIS` — one-line description
- `.DESCRIPTION` — what it does, when it runs, what it affects
- `.NOTES` — runtime version, identity type, required permissions

### R3: Error Handling
- `$ErrorActionPreference = "Stop"` at the top
- All business logic in a `try/catch/finally` block
- `finally` block handles disconnection
- Errors must be surfaced via `Write-Error` and `throw` (not silently caught)

### R4: Authentication via Shared Module
- `Import-Module Contoso.Automation.Auth` — never inline auth code
- Call only `Connect-Contoso*` functions
- No direct calls to `Connect-AzAccount`, `Connect-PnPOnline`, or `Connect-MgGraph` in the runbook body

### R5: Output Standards
- Use `Write-Output` for data that should appear in job output
- Use `Write-Verbose` for diagnostic info (enabled by callers via `-Verbose`)
- Use `Write-Warning` for non-fatal issues
- Use `Write-Error` + `throw` for fatal errors
- Never use `Write-Host` (not captured in Automation job output)

### R6: Cleanup
Always disconnect in a `finally` block to prevent connection leaks:
```powershell
finally {
    Disconnect-PnPOnline -ErrorAction SilentlyContinue
    Disconnect-MgGraph -ErrorAction SilentlyContinue
}
```

## Applying the Template to Existing Runbooks

### For Simple Runbooks (single auth, linear logic)
1. Wrap existing business logic in the template's try/catch structure
2. Replace auth block with shared module calls
3. Add #Requires and header
4. Done

### For Complex Runbooks (multiple auth targets, branching logic)
1. Extract auth into shared module calls at the top
2. Keep business logic mostly intact
3. Wrap in template structure
4. Add error handling around each distinct operation if not already present

### What NOT to Change
- Do not refactor business logic that works correctly
- Do not rename variables unless they conflict with the template
- Do not add features or optimizations beyond the auth migration scope
- Preserve existing parameter names and types for backward compatibility with schedules/webhooks
