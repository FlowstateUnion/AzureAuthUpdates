# Change Governance Framework

## Purpose

Every script in this migration follows a formal lifecycle with documented gates. No script moves to production without passing through requirements, peer review, execution, validation, testing, and documentation — each recorded in a per-script checklist that persists for the life of the project.

## Lifecycle Gates

Each runbook script passes through these gates in order. A gate cannot be skipped. If a gate fails, the script returns to the previous gate for remediation.

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  GATE 1     │    │  GATE 2     │    │  GATE 3     │    │  GATE 4     │    │  GATE 5     │    │  GATE 6     │
│ BASELINE &  │───▶│ REQUIREMENTS│───▶│ EXECUTION & │───▶│ VALIDATION  │───▶│ TESTING     │───▶│ DOCUMENTATION│
│ REQUIREMENTS│    │ PEER REVIEW │    │ MIGRATION   │    │ & QA        │    │ (AZURE)     │    │ & SIGN-OFF  │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

### Gate 1: Baseline & Requirements Gathering
**Who:** Agent + Human
**What:**
- Original script captured in `runbooks/source/` (never modified)
- Baseline snapshot recorded in `governance/baselines/<ScriptName>.baseline.md`
- Scanner results recorded (auth patterns, PS 7.4 compat, permissions needed)
- Dependencies documented (schedules, webhooks, child runbooks, HRW usage)
- Requirements defined: what changes, what stays the same, what's out of scope

**Exit criteria:**
- [ ] Baseline document exists and is complete
- [ ] Per-script checklist created in `governance/checklists/`
- [ ] All scan findings documented in the checklist
- [ ] Dependencies and constraints identified

### Gate 2: Requirements Peer Review
**Who:** Human reviewer (or second agent)
**What:**
- Review the baseline and requirements in the checklist
- Confirm the migration approach is correct for this specific script
- Flag any concerns, edge cases, or business logic that needs special handling
- Approve the migration to proceed

**Exit criteria:**
- [ ] Reviewer has read the baseline and requirements
- [ ] Approach approved (or modifications requested and incorporated)
- [ ] Reviewer sign-off recorded in checklist

### Gate 3: Execution & Migration
**Who:** Agent
**What:**
- Copy script to `runbooks/staging/`
- Apply auth migration, module remapping, PS 7.4 fixes, template structure
- Record every change made in the checklist's change log section
- Stage the migrated script

**Exit criteria:**
- [ ] Migrated script exists in `runbooks/staging/`
- [ ] All changes documented in checklist change log
- [ ] No changes made outside the approved scope

### Gate 4: Validation & QA
**Who:** Agent + Human
**What:**
- Run `validate-runbook.ps1` (9-point automated check)
- AST parameter contract comparison (source vs staged)
- Re-scan for any remaining legacy patterns
- Compare migrated script against requirements — does it do what was asked?
- Human spot-check of business logic preservation

**Exit criteria:**
- [ ] All 9 automated validation checks pass
- [ ] Parameter contract intact (AST-verified)
- [ ] Zero legacy patterns remain
- [ ] Human reviewed the diff between source and staged
- [ ] Moved to `runbooks/testing/`

### Gate 5: Testing (Azure Automation)
**Who:** Human
**What:**
- Import migrated script into Azure Automation Test pane
- Execute with representative parameters
- Compare output to last 3 successful runs of the original
- Verify no errors in job streams
- Test on Hybrid Worker if applicable

**Exit criteria:**
- [ ] Test pane execution successful
- [ ] Output matches original behavior
- [ ] No new errors or warnings
- [ ] Test evidence recorded in checklist (date, job ID, result)
- [ ] Moved to `runbooks/completed/`

### Gate 6: Documentation & Sign-Off
**Who:** Human
**What:**
- Checklist fully completed with all gates signed off
- Change request document finalized (if required by org process)
- Publish to Automation Account
- Post-publish monitoring initiated (7 days)
- Final sign-off after monitoring period

**Exit criteria:**
- [ ] All 6 gates passed and signed in checklist
- [ ] Published to Automation Account
- [ ] Runtime environment assigned
- [ ] 7-day monitoring period complete with no failures
- [ ] Checklist marked COMPLETE with final date

## Artifacts Produced Per Script

| Artifact | Location | Created At | Purpose |
|----------|----------|------------|---------|
| Original script | `runbooks/source/<Name>.ps1` | Gate 1 | Immutable baseline; rollback source |
| Baseline document | `governance/baselines/<Name>.baseline.md` | Gate 1 | Starting state, scan results, dependencies |
| Per-script checklist | `governance/checklists/<Name>.checklist.md` | Gate 1 | Full lifecycle tracking through all 6 gates |
| Migrated script | `runbooks/staging/<Name>.ps1` | Gate 3 | Work in progress |
| Validated script | `runbooks/testing/<Name>.ps1` | Gate 4 | Ready for Azure testing |
| Approved script | `runbooks/completed/<Name>.ps1` | Gate 5 | Ready for publishing |
| Change request | `governance/change-requests/CR-<NNN>.md` | As needed | Formal change documentation (optional per org) |

## Change Requests

For organizations that require formal change requests, use `governance/change-requests/CR-TEMPLATE.md`. A change request can cover a single script or a batch of simple scripts. Complex scripts should have individual CRs.

## Audit Trail

The per-script checklist IS the audit trail. It captures:
- Who performed each gate
- When each gate was completed
- What changed (detailed change log)
- What was tested and the results
- Who approved each gate
- Any issues encountered and how they were resolved

The checklist is a living document updated throughout the migration. It is NEVER deleted — even after the script is published.
