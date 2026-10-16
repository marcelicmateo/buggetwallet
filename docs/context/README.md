# Project context (for Claude Code)

Copies of the planning docs from the claude.ai Project "Buget Wallet", so a Claude Code session has the
same context as the chat sessions. Read these at the start of a session, after `CLAUDE.md`.

| File | What |
|---|---|
| `WORKFLOW.md` | How the owner and Claude work together: roles, session loop, git rules. |
| `BRIEF.md` | What we're building: goals, budgeting strategy, scope. |
| `STATUS.md` | Current version, what's done, decisions log, open questions, next steps. |
| `ARCHITECTURE.md` | v2 requirements and the decisions behind them (transport options etc.). The as-built design is `docs/architecture.md`. |
| `IMPORT_FORMATS.md` | PBZ and Revolut export formats the importer has to handle. |

## Privacy
These are **redacted** copies. The repo rule still holds: no salary, rent, loan, balance or other personal
figures, no personal merchant names, no account or card numbers. Those stay in the claude.ai Project
(`claude/BASELINE.md`, the payday plan in `claude/STATUS.md`) and in the owner's local wallet database.
Don't add them here.

## Keeping in sync
The claude.ai Project is the source of truth. At the end of a session (chat or Claude Code), update
`STATUS.md` in both places — redacted here, full in the Project.
