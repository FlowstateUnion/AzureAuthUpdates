# Migration Checklist: {{RUNBOOK_NAME}}

**Created:** {{DATE}}
**Status:** Pending | In Progress | Complete | Exception
**Complexity:** Simple | Medium | Complex
**Assigned To:** ___________________

---

## Gate 1: Baseline & Requirements

### 1.1 Original Script
- **File:** `runbooks/source/{{RUNBOOK_NAME}}`
- **Line count:** ___
- **Has param block:** Yes / No
- **Has existing error handling:** Yes / No
- **Current runtime:** PS 5.1 / PS 7.x / Unknown

### 1.2 Scanner Findings
| Pattern | Severity | Line | Guidance |
|---------|----------|------|----------|
| | | | |
| | | | |
| | | | |

### 1.3 Services Used
- [ ] SharePoint (PnP)
- [ ] SharePoint (SPO module — needs migration)
- [ ] Microsoft Graph
- [ ] Exchange Online
- [ ] Azure Resource Manager
- [ ] Azure AD / MSOnline (legacy — needs migration)
- [ ] Other: ___________________

### 1.4 Permissions Required
| Service | Permission | Level |
|---------|------------|-------|
| | | |
| | | |

### 1.5 Dependencies
- **Schedules:** ___________________
- **Webhooks:** ___________________
- **Called by (parent runbooks):** ___________________
- **Calls (child runbooks):** ___________________
- **Runs on Hybrid Worker:** Yes / No — Group: ___________________
- **Accepts credential-type parameters:** Yes / No

### 1.6 Migration Requirements
- [ ] Replace auth block with shared module calls
- [ ] Remap SPO cmdlets to PnP equivalents
- [ ] Remap AzureAD/MSOnline cmdlets to Graph
- [ ] Replace Exchange credential auth with MI
- [ ] Fix PS 7.4 compatibility issues: ___________________
- [ ] Apply standardized template (try/catch/finally)
- [ ] Must stay on PS 5.1 — Reason: ___________________
- [ ] Other: ___________________

### 1.7 Out of Scope
_List anything explicitly NOT being changed:_
-
-

### Gate 1 Sign-Off
- **Completed by:** ___________________ **Date:** ___________
- **Baseline document:** `governance/baselines/{{RUNBOOK_NAME}}.baseline.md`

---

## Gate 2: Requirements Peer Review

### 2.1 Review
- **Reviewer:** ___________________
- **Date reviewed:** ___________
- **Approach approved:** Yes / No

### 2.2 Review Notes
_Reviewer comments, concerns, or required modifications:_
-
-

### 2.3 Modifications from Review
_Changes made to the plan based on review feedback:_
-
-

### Gate 2 Sign-Off
- **Reviewer:** ___________________ **Date:** ___________
- **Approved to proceed:** Yes / No

---

## Gate 3: Execution & Migration

### 3.1 Change Log
_Every change made to the script, in order:_

| # | Change Description | Lines Affected |
|---|-------------------|----------------|
| 1 | | |
| 2 | | |
| 3 | | |
| 4 | | |
| 5 | | |
| 6 | | |
| 7 | | |
| 8 | | |

### 3.2 Auth Block Replacement
- **Original auth pattern:** ___________________
- **Replaced with:** ___________________
- **Lines removed:** ___
- **Lines added:** ___

### 3.3 Cmdlet Remapping
| Original Cmdlet | Replaced With | Count |
|----------------|---------------|-------|
| | | |
| | | |

### 3.4 Template Applied
- [ ] `#Requires` statements added
- [ ] Script header added/updated
- [ ] `$ErrorActionPreference = "Stop"` set
- [ ] Business logic wrapped in try/catch/finally
- [ ] `Disconnect-ContosoAll` in finally block
- [ ] `Invoke-ContosoWithRetry` used where needed

### 3.5 Dead Code Removed
_Lines/blocks removed:_
-
-

### Gate 3 Sign-Off
- **Completed by:** ___________________ **Date:** ___________
- **Staged file:** `runbooks/staging/{{RUNBOOK_NAME}}`

---

## Gate 4: Validation & QA

### 4.1 Automated Validation (validate-runbook.ps1)
| Check | Result | Detail |
|-------|--------|--------|
| 1. Syntax | Pass / Fail | |
| 2. No legacy auth patterns | Pass / Fail | |
| 3. Shared module imported | Pass / Fail | |
| 4. Error handling (try/catch) | Pass / Fail | |
| 5. Cleanup/disconnect | Pass / Fail | |
| 6. Parameter contract (AST) | Pass / Fail | |
| 7. No legacy module imports | Pass / Fail | |
| 8. No hardcoded secrets | Pass / Fail | |
| 9. ErrorActionPreference | Pass / Fail | |

### 4.2 Manual Review
- [ ] Diff reviewed between `source/` and `staging/` versions
- [ ] Business logic preserved — no functional changes
- [ ] Parameter names and types unchanged
- [ ] Output format unchanged
- [ ] No scope creep — only approved changes made

### 4.3 Issues Found During Validation
| Issue | Resolution |
|-------|------------|
| | |
| | |

### Gate 4 Sign-Off
- **Validated by:** ___________________ **Date:** ___________
- **Testing file:** `runbooks/testing/{{RUNBOOK_NAME}}`

---

## Gate 5: Testing (Azure Automation)

### 5.1 Test Execution
- **Test date:** ___________
- **Tested by:** ___________________
- **Automation Account:** ___________________
- **Runtime Environment:** ___________________
- **Test pane / Published draft:** ___________________

### 5.2 Test Parameters Used
| Parameter | Value |
|-----------|-------|
| | |
| | |

### 5.3 Test Results
- **Job ID:** ___________________
- **Status:** Completed / Failed / Suspended
- **Duration:** ___________________
- **Output matches original:** Yes / No
- **Errors in job stream:** None / ___________________
- **Warnings in job stream:** None / ___________________

### 5.4 Comparison to Original
- [ ] Output format matches
- [ ] Data values match (spot-checked)
- [ ] No new errors or warnings
- [ ] Performance comparable (not significantly slower)

### 5.5 Hybrid Worker Test (if applicable)
- **Worker Group:** ___________________
- **Test date:** ___________
- **Result:** Pass / Fail / N/A

### Gate 5 Sign-Off
- **Tested by:** ___________________ **Date:** ___________
- **Completed file:** `runbooks/completed/{{RUNBOOK_NAME}}`

---

## Gate 6: Documentation & Sign-Off

### 6.1 Publication
- **Published date:** ___________
- **Published by:** ___________________
- **Runtime assigned:** ___________________
- **Change request #:** ___________________ (if applicable)

### 6.2 Post-Publish Monitoring
| Day | Jobs Run | Failures | Notes |
|-----|----------|----------|-------|
| Day 1 | | | |
| Day 2 | | | |
| Day 3 | | | |
| Day 4 | | | |
| Day 5 | | | |
| Day 6 | | | |
| Day 7 | | | |

### 6.3 Legacy Asset Cleanup
- [ ] Automation Credential asset removed (if no longer referenced): ___________________
- [ ] Automation Variable assets removed: ___________________
- [ ] N/A — shared credentials still used by other scripts

### 6.4 Final Sign-Off

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Migrator (agent/developer) | | | |
| Reviewer | | | |
| Tester | | | |
| Approver (publish authority) | | | |

### Status: {{PENDING / IN PROGRESS / COMPLETE / EXCEPTION}}
### Completion Date: ___________

---

## Issue Log

_Track any issues encountered during migration, regardless of gate:_

| # | Date | Gate | Issue | Resolution | Resolved By |
|---|------|------|-------|------------|-------------|
| | | | | | |
| | | | | | |
