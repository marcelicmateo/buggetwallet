# Budget Wallet — How we work

## Roles
- **Owner:** sets goals, tests on phone and computer, gives feedback, approves big decisions.
- **Claude (builder):** designs, builds, tests, documents. Makes small decisions alone; asks only when a choice is hard to undo or really the owner's (money categories, privacy, scope).

## Source of truth
- **Git (`docs/context/` on `v2`) holds the plan, status, decisions and workflow.** Claude Code and claude.ai chat sessions both read and update them here.
- The claude.ai Project "Buget Wallet" holds only personal figures: `claude/BASELINE.md` (bank analysis) and `claude/STATUS.md` (payday plan, salary, loan, savings). They never go into git.
- Every session starts by reading `docs/context/STATUS.md`, so nothing has to be re-explained. A chat session in the Project clones the repo first.

## The product
- v1: private claude.ai web app (artifact) with its own database — `artifact/` (v2 branch) or `app/index.html` (master).
- v2: standalone Flutter app (Android, iPhone, Windows, macOS, Linux), offline first, own SQLite database, encrypted Syncthing sync.

## Code & git
- Private GitHub repo **marcelicmateo/buggetwallet**. `master` = v1 + Docker dev setup; `v2` = standalone app (to be merged into master once the owner is happy).
- The repo holds code only. Bank exports, statements and real transactions never go into git (`.gitignore` blocks .xls/.xlsx/.csv/.pdf). Test data must be made up.
- Any version can be restored from git history if an update breaks something.

## Session loop
1. **Owner:** one line — what's next, or feedback on the last version.
2. **Claude:** builds it, checks it (tests / CI green), commits + pushes, publishes (v1: artifact link; v2: GitHub releases via CI), updates `docs/context/STATUS.md`.
3. **Claude:** short summary — what changed, what to test, what's suggested next.
4. **Owner:** tries it, replies with feedback. Repeat.

One feature per session. The owner often works by voice: short, spoken-friendly replies, one change at a time.

## Feedback format (optional, but fastest)
- ✅ works / ❌ broken / ✏️ change
- Screenshots welcome.

## Milestones
- **M0 Setup** — workflow + brief agreed. ✅
- **M1 Core** — add income/expenses, categories, list view. ✅ (v1)
- **M2 Standalone app** — v2 Flutter app on all platforms, sync. In testing.
- **M3 Views** — more charts: spending by category, over time, budget vs actual.
- **M4 Polish** — import/export, recurring items, settings.
