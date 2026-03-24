# Blocking Fixes Checklist

**Date:** 2026-03-24
**Scope:** Must pass before autonomous migration execution.

## Exit Criteria
- [ ] All critical/high blockers resolved
- [ ] Dry-run evidence produced for 3 runbooks (Simple/Medium/Complex)
- [ ] Peer-review sign-off updated

## Blocker 1: Staging path mismatch
- Owner: __________________
- Target files:
  - `agent/skills/validate-runbook.ps1`
  - `plan/PHASE3-MIGRATION-INSTRUCTIONS.md`
  - `runbooks/PIPELINE.md`
  - `agent/AGENT-INSTRUCTIONS.md`
- Verification:
  - [ ] Validator finds staged file on canonical path
  - [ ] Docs and scripts use same path convention

## Blocker 2: Parameter contract validation weakness
- Owner: __________________
- Target file: `agent/skills/validate-runbook.ps1`
- Verification:
  - [ ] AST-based parameter comparison implemented
  - [ ] Fails on renamed/retitled/retagged params
  - [ ] Passes unchanged contract

## Blocker 3: Token refresh/retry reliability
- Owner: __________________
- Target file: `modules/Contoso.Automation.Auth/Contoso.Automation.Auth.psm1`
- Verification:
  - [ ] Service-specific reconnect paths exist
  - [ ] Original auth context is preserved for reconnect
  - [ ] Non-recoverable 403 errors fail fast

## Blocker 4: Scanner false negatives for multiline/splat
- Owner: __________________
- Target files:
  - `scripts/migration/Scan-LegacyAuth.ps1`
  - `scripts/migration/Get-RunbookDependencies.ps1`
- Verification:
  - [ ] Multiline command cases detected
  - [ ] Splat-based command arguments detected
  - [ ] Regression tests added with fixtures

## Blocker 5: Permission audit certainty/logic mismatch
- Owner: __________________
- Target file: `scripts/migration/Scan-Permissions.ps1`
- Verification:
  - [ ] Output language states advisory nature
  - [ ] Dedupe/aggregation behavior matches documentation
  - [ ] REST-call blind spot is explicitly flagged in report output

## Optional but Recommended Before Pilot
- [ ] Redact dependency export parameter values by default
- [ ] Phase 4 cleanup instructions aligned with actual validated source
- [ ] Runtime setup script fail-fast semantics implemented

## Sign-off
- Engineering Reviewer: __________________ Date: __________
- Platform Owner: _______________________ Date: __________
- Security Reviewer: _____________________ Date: __________
