# Suggested Modifications (Do Not Apply Automatically)

**Purpose:** Companion change proposal to `PEER-REVIEW-RESPONSE-2026-03-24.md`.

This document lists suggested edits without changing any original project files.

## A) Critical / High Priority Patch Plan

### 1) Align staging paths across framework
- **Files to update:**
  - `agent/skills/validate-runbook.ps1`
  - `plan/PHASE3-MIGRATION-INSTRUCTIONS.md`
  - `runbooks/PIPELINE.md`
  - `agent/AGENT-INSTRUCTIONS.md`
- **Proposed standard:** Use one canonical staged location format, either:
  - Flat: `runbooks/staging/<RunbookName>.ps1`, or
  - Tiered: `runbooks/staging/<complexity>/<RunbookName>.ps1`
- **Recommendation:** Tiered, because complexity is already used in planning artifacts.

### 2) Replace regex-based parameter preservation check with AST contract validation
- **File:** `agent/skills/validate-runbook.ps1`
- **Proposed behavior:**
  - Parse source and staged scripts with `[System.Management.Automation.Language.Parser]::ParseInput()`
  - Compare parameter names, types, mandatory flags, positions, default values, and set names.
  - Fail validation if any contract drift is detected.

### 3) Harden retry/auth refresh in shared module
- **File:** `modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psm1`
- **Proposed behavior:**
  - Separate reconnect functions per service: Azure, PnP, Graph, EXO.
  - Store connection/auth context for each service (AuthMethod, Tenant, ClientId/UAMI).
  - Retry only for clearly transient/expiry errors.
  - Fail fast on access-policy/authorization `403` cases.

### 4) Improve scanner robustness for multiline/splat patterns
- **Files:**
  - `scripts/migration/Scan-LegacyAuth.ps1`
  - `scripts/migration/Get-RunbookDependencies.ps1`
- **Proposed behavior:**
  - Parse script AST and inspect command invocations/arguments.
  - Keep regex path as fallback only.

### 5) Reposition and tighten permission audit
- **File:** `scripts/migration/Scan-Permissions.ps1`
- **Proposed behavior:**
  - Update output language from “minimum required” to “recommended candidate permissions”.
  - Fix dedupe logic to either:
    - emit one highest-level permission per service (if that is intent), or
    - explicitly emit multiple permissions and state why.
  - Add known blind spots in report header (REST calls, parameter-conditional permissions).

## B) Medium Priority Hardening

### 6) Redact potentially sensitive parameter payloads in dependency exports
- **File:** `scripts/migration/Get-RunbookDependencies.ps1`
- **Proposed behavior:**
  - Export only parameter keys by default.
  - Add optional `-IncludeParameterValues` switch for privileged troubleshooting.

### 7) Fix contradictory cleanup guidance
- **File:** `plan/PHASE4-CLEANUP-INSTRUCTIONS.md`
- **Issue:** Script examples check `runbooks/source`, while caution says to check migrated scripts.
- **Proposed fix:** Use published/latest migrated exports consistently as source-of-truth for cleanup validation.

### 8) Fail fast in runtime setup flow
- **File:** `scripts/setup/New-RuntimeEnvironment.ps1`
- **Proposed behavior:**
  - If runtime creation fails, stop and instruct operator to remediate.
  - Do not continue module install into a runtime that may not exist.

### 9) Add explicit SPO property mapping appendix
- **Files:**
  - `strategy/01-Connect-SPOService.md`
  - Add new: `strategy/appendix/SPO-to-PnP-Property-Mapping.md`
- **Proposed content:** Common object/property deltas and known version-specific caveats.

### 10) Add out-of-scope placeholders for uncovered services
- **Files:** add stubs under `strategy/`:
  - `09-Azure-SQL.md`
  - `10-Azure-DevOps-and-PAT.md`
  - `11-Teams-and-Graph-Chat.md`
  - `12-Third-Party-APIs.md`
  - `13-CosmosDB.md`
  - `14-PowerPlatform-Dataverse.md`

## C) Suggested Validation Expansion

Add these gates in `agent/skills/validate-runbook.ps1`:
1. Auth block contract check (legacy removed + expected shared-module calls present by service type).
2. Cmdlet remap assertions for known migrations (SPO/AzureAD/MSOnline/EXO patterns).
3. Optional golden-output schema assertions for high-criticality runbooks.
4. Explicit legacy-module import detection (`AzureAD`, `MSOnline`, `Microsoft.Online.SharePoint.PowerShell`).

## D) Suggested Documentation Consistency Sweep

Unify the following terms/paths in one pass:
- `agent/scan-results.csv` vs `plan/scan-results.csv`
- staging path conventions
- copy vs move semantics
- definitions of “Validated”, “Testing”, and “Completed”

## E) Proposed Delivery Sequence

1. Fix path/validator/auth retry blockers.
2. Upgrade scanners and permission audit semantics.
3. Complete documentation normalization.
4. Run a dry-run migration with 3 representative runbooks (Simple, Medium, Complex).
5. Re-open peer review with evidence pack.
