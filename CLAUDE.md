# Budget Wallet — notes for Claude

## Privacy (hard rule)
This repo holds **code only**. Never commit bank exports, statements, real transactions, balances,
salary/rent/loan figures, merchant lists derived from the owner's spending, keys or seed data.
- Real numbers live only in the user's local wallet database (and v1's artifact database).
- Personal merchant rules live in the `merchantPatterns` setting; built-in rules cover only well-known chains and brands.
- Test fixtures are synthetic: `tools/make_fixtures.py` generates them. Planning docs (BRIEF, STATUS, BASELINE, ARCHITECTURE decisions) stay in the claude.ai Project.

## Layout
- `app/` — Flutter app (Android, iOS, Windows, macOS, Linux).
- `packages/wallet_importer/` — bank files → normalized transactions. The only code that knows bank formats.
- `packages/wallet_core/` — SQLite repo, change log + HLC, encrypted folder sync, categories, budget engine.
- `artifact/` — v1 single-file web app (claude.ai artifact) and its JS tests (`npm test`).
- `docs/architecture.md`, `docs/setup.md`.

## Building without a local Flutter SDK
The Claude workspace cannot download Flutter/Dart. Push to `v2` (or `master`); CI runs tests, analyze and
builds, then pushes the full log to the `ci-logs` branch:
`git fetch origin ci-logs:refs/remotes/origin/ci-logs && git show origin/ci-logs:latest.txt`.
Job status: `gh api repos/marcelicmateo/buggetwallet/commits/<sha>/check-runs`. The Actions API itself is blocked.

## Conventions
- Amounts are integers in minor units (cents). Dates are `YYYY-MM-DD` strings.
- All writes go through `WalletRepo._write` so they become sync ops; never write tables directly.
- Transaction ids must stay compatible with v1 (`transactionId` in wallet_importer).

## Workflow
Owner sends one request or piece of feedback (often by voice: keep replies short). Claude builds,
gets CI green, commits code, and updates STATUS.md in the claude.ai Project.
