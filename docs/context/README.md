# Project context (for Claude Code and chat sessions)

**This folder is the source of truth** for the plan, status, decisions and workflow (owner decision, 2026-10-19).
Read these at the start of a session, after `CLAUDE.md`. Claude Code and claude.ai chat sessions both read and
update them here, on the `v2` branch.

| File | What |
|---|---|
| `WORKFLOW.md` | How the owner and Claude work together: roles, session loop, git rules. |
| `BRIEF.md` | What we're building: goals, budgeting strategy, scope. |
| `STATUS.md` | Current version, what's done, decisions log, open questions, next steps. |
| `ARCHITECTURE.md` | v2 requirements and the decisions behind them (transport options etc.). The as-built design is `docs/architecture.md`. |
| `IMPORT_FORMATS.md` | PBZ and Revolut export formats the importer has to handle. |
| `DESIGN_DECISIONS.md` | 2026-10-19 planning session: decisions, data-flow gaps, web plan, proposals (bank profiles, bills, calendar, projects), kept UI directions, task order. |
| `PATH_FORWARD.md` | 2026-10-22 plan from the six outside reviews (`docs/review/`): stages G (structure + practices) → H (hardening) → I (UI quick wins) → M6 (owner live test) → J (deeper structure) → P (product); every review KEEP/CHANGE placed (§10 index), KEEP register for the reviewer (§5), delegation, trade-offs, owner decisions D1–D7. |

## Privacy
The repo holds no personal figures: no salary, rent, loan, balance or other amounts from the owner's life, no
personal merchant names, no account or card numbers. Those live only in the claude.ai Project "Buget Wallet"
(`claude/BASELINE.md` and the payday plan in `claude/STATUS.md`) and in the owner's local wallet database.
Don't add them here. A session that needs those figures (budget planning, checking real numbers) asks the owner
or runs in the claude.ai Project.

## Keeping in sync
- End of every session: update `STATUS.md` here (done, decisions, open questions, next) and push.
- Nothing needs copying back to the claude.ai Project. Update the Project's `claude/STATUS.md` only when a
  personal figure changes (salary, payday plan, loan, savings account).
