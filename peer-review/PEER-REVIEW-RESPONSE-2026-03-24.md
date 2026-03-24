# Peer Review Findings Report

**Project:** Azure Automation Auth Modernization
**Date:** 2026-03-24
**Reviewer:** Codex

## Executive Summary
The project is directionally strong and close to execution-ready, but not yet safe for autonomous migration at production scale.

Overall readiness: **Not Ready Yet**
Confidence for 30-50 runbooks: **5/10**

Primary blockers:
1. Path/layout mismatch breaks validator in normal flow.
2. Validation checks can pass broken parameter contracts.
3. Token refresh/retry logic over-claims safety and mishandles reconnect state.
4. Scanners are line-based and miss common multiline/splat patterns.
5. Permission audit positioning/logic can be misread as authoritative minimum.

---

## 1) Architecture & Approach

### Findings
- **High**: Token refresh is presented as a broad mitigation, but implementation only reliably refreshes Azure context and partially Graph. PnP/EXO service contexts are not fully re-established.
  - References:
    - `plan/MASTER-PLAN.md:156`
    - `modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psm1:491`
    - `modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psm1:523`
- **Medium**: Risk register and scope do not explicitly govern non-Microsoft auth surfaces (Azure DevOps PATs, SQL creds, third-party APIs).

### Assessment
- Managed Identity as default is correct.
- Phased approach is correct.
- Shared auth module is the right pattern; implementation hardening is required.

---

## 2) Strategy Documents

### Findings
- **High**: Fallback guidance suggests certificate-based `Connect-SPOService` interim path, which conflicts with modernization direction and practical support expectations.
  - Reference: `strategy/01-Connect-SPOService.md:104`
- **Medium**: SPO->PnP object/property drift is noted but no concrete mapping reference is provided.
  - Reference: `strategy/01-Connect-SPOService.md:91`

### Assessment
- Most mappings are directionally right.
- Coverage is good for core services; edge-case codification needs to be more concrete.

---

## 3) Shared Auth Module

### Findings
- **High**: Retry logic treats all `403` as retryable auth expiry; many are authorization failures and should fail fast.
  - Reference: `modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psm1:500`
- **High**: Graph reconnect in retry uses hardcoded `Connect-MgGraph -Identity`, dropping original auth mode and UAMI/cert context.
  - Reference: `modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psm1:523`
- **Medium**: SharePoint connection state variable exists but is not used to manage/recover connection contexts.
  - References:
    - `modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psm1:23`
    - `modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psm1:540`
- **Info**: `Export-ModuleMember` plus `FunctionsToExport` is redundant but valid.
  - References:
    - `modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psm1:615`
    - `modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psd1:18`

### Assessment
- Structure is good and production-leaning, but retry/reconnect behavior needs correction before relying on it operationally.

---

## 4) Migration Scripts

### Findings
- **High**: Legacy scanner is line-by-line; multiline commands with backticks/splatting are likely missed.
  - References:
    - `scripts/migration/Scan-LegacyAuth.ps1:180`
    - `scripts/migration/Scan-LegacyAuth.ps1:184`
    - `scripts/migration/Scan-LegacyAuth.ps1:187`
- **High**: Permission scanner claims highest-by-service behavior but keeps multiple entries per service; can be misread as strict minimum and produce noisy recommendations.
  - References:
    - `scripts/migration/Scan-Permissions.ps1:137`
    - `scripts/migration/Scan-Permissions.ps1:145`
    - `scripts/migration/Scan-Permissions.ps1:147`
- **Medium**: Dependency scanner for child runbooks is also line-based and can miss multiline invocation forms.
  - Reference: `scripts/migration/Get-RunbookDependencies.ps1:170`
- **Medium**: Dependency exports include schedule/webhook parameter payloads and may leak sensitive values into local artifacts.
  - References:
    - `scripts/migration/Get-RunbookDependencies.ps1:105`
    - `scripts/migration/Get-RunbookDependencies.ps1:140`

### Assessment
- Useful tooling foundation, but parser robustness and security hygiene need upgrades.

---

## 5) Agent Execution Framework

### Findings
- **Critical**: Staging path mismatch: validator expects `runbooks/staging/<RunbookName>` while migration instructions write `staging/<complexity>/<RunbookName>`.
  - References:
    - `agent/skills/validate-runbook.ps1:39`
    - `plan/PHASE3-MIGRATION-INSTRUCTIONS.md:25`
- **High**: Parameter preservation check is regex-based, limited to first 20 token-like matches, and not param-block-aware.
  - References:
    - `agent/skills/validate-runbook.ps1:99`
    - `agent/skills/validate-runbook.ps1:100`
- **Medium**: Move/copy semantics are inconsistent across docs/scripts and can confuse agents.
  - References:
    - `runbooks/PIPELINE.md:5`
    - `agent/AGENT-INSTRUCTIONS.md:19`
    - `agent/skills/validate-runbook.ps1:132`

### Assessment
- Framework is close, but current validator behavior is not reliable enough for autonomous execution.

---

## 6) Operational Readiness

### Findings
- **High**: Phase 4 credential cleanup logic checks references in `runbooks/source` while warning text says to check migrated scripts, causing contradictory operator behavior.
  - References:
    - `plan/PHASE4-CLEANUP-INSTRUCTIONS.md:25`
    - `plan/PHASE4-CLEANUP-INSTRUCTIONS.md:43`
- **Medium**: Runtime setup script continues after runtime creation failure, leading to partial/ambiguous setup outcomes.
  - References:
    - `scripts/setup/New-RuntimeEnvironment.ps1:68`
    - `scripts/setup/New-RuntimeEnvironment.ps1:72`

### Assessment
- Rollback/monitoring posture is strong; setup and cleanup instruction consistency needs tightening.

---

## 7) Cross-Cutting Concerns

### Security
- **High**: Permission scanner language implies minimum required permissions with higher certainty than implementation supports.
  - References:
    - `scripts/migration/Scan-Permissions.ps1:3`
    - `scripts/migration/Scan-Permissions.ps1:7`
    - `scripts/migration/Scan-Permissions.ps1:32`
- **Medium**: Dependency report data exposure risk from webhook/schedule parameters.

### Consistency
- **Medium**: Artifact paths differ across docs (`plan/scan-results.csv` vs `agent/scan-results.csv`) and staging conventions differ.
  - References:
    - `plan/QUICKSTART.md:83`
    - `plan/QUICKSTART.md:102`
    - `plan/PHASE3-MIGRATION-INSTRUCTIONS.md:25`

### Completeness
- Common enterprise scenarios missing first-class strategy treatment: Azure SQL, Azure DevOps PAT/API, Teams, Cosmos DB, third-party OAuth/API keys, Dataverse.

### Maintainability
- Good baseline docs and structure.
- Long-term maintainability improves significantly once validation/scanner reliability is upgraded.

---

## Blocking Issues Before Agent Execution
1. Fix staging path mismatch between migration flow and validator.
2. Replace regex parameter-preservation check with AST-based param contract comparison.
3. Implement service-specific reconnect semantics in retry logic; do not retry non-recoverable authorization errors.
4. Improve scanners for multiline/splat/AST scenarios.
5. Reposition permission audit output as advisory and fix dedupe logic to match claims.

---

## Recommended Improvements (Non-Blocking)
1. Add explicit SPO-to-PnP property mapping reference.
2. Add out-of-scope placeholder strategies for uncovered service domains.
3. Redact/mask schedule and webhook parameter values in dependency exports.
4. Normalize all path and pipeline semantics across docs.
5. Add setup-script guardrails to fail fast when prerequisites are missing.

---

## Overall Assessment
Current state is **not ready for autonomous execution** against production runbooks without additional safeguards.

Readiness score: **5/10**.

The strategic architecture is solid; the blocker set is implementation and execution-hardening focused.

---

## Responses to Author’s 5 Concerns

1. **Token refresh reliability**: Current approach creates false confidence if treated as universal. Reconnect must be tracked and handled per service context.
2. **Permission scanner accuracy**: Acceptable as planning aid only. Add explicit disclaimer + manual approval gate.
3. **Agent migration quality**: Current validation checks are necessary but insufficient for complex scripts; add deeper semantic checks.
4. **PnP output compatibility**: Test pane alone is not enough; add a concrete property mapping reference and contract checks.
5. **Uncovered services**: Mark explicitly out-of-scope and add placeholder strategy docs/checklists.
