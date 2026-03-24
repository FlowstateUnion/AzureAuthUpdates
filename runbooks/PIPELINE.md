# Runbook Migration Pipeline

## Folder Lifecycle

Scripts move through these folders as they are processed. **Never delete a file** — only copy it forward.

```
runbooks/
├── source/         ← YOU PUT ORIGINAL PRODUCTION SCRIPTS HERE
│                     The agent reads from here but NEVER modifies these files.
│                     This is your backup and point-of-truth for rollback.
│
├── staging/        ← Agent works here
│                     Copies from source/, applies auth migration, template,
│                     PS 7.4 fixes. This is the active workbench.
│
├── testing/        ← Agent moves scripts here after passing syntax check
│                     Scripts in this folder are ready for Azure Test Pane.
│                     Human reviews and tests in Azure Automation.
│
├── completed/      ← Human moves scripts here after Azure test passes
│                     These are approved for publishing to Automation Account.
│                     Agent does NOT publish — human controls this gate.
│
└── exceptions/     ← Agent moves scripts here that CANNOT be migrated
                      COM objects, PS 5.1-only requirements, etc.
                      Each file gets a companion .reason.md explaining why.
```

## How to Start

1. Copy all your production runbook `.ps1` files into `runbooks/source/`
2. Open a new Claude Code session in this project folder
3. The agent will read `agent/AGENT-INSTRUCTIONS.md` (via CLAUDE.md) and begin
4. Track progress in `agent/PROGRESS.md` and `agent/progress.json`

## Rules

- `source/` is READ-ONLY for the agent — original scripts are never modified
- `staging/` is the agent's workspace — it creates and modifies files here
- `testing/` is the handoff point — agent puts files here, human reviews them
- `completed/` is human-controlled — only the human moves files here after Azure testing
- `exceptions/` includes a `.reason.md` file for each exception explaining what would need to change for it to become migratable

## File Naming

Files keep their original names throughout the pipeline. No renaming, no prefixes.
If a file is `Set-SitePermissions.ps1` in `source/`, it stays `Set-SitePermissions.ps1` in every folder.
