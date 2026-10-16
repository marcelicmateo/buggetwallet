# Budget Wallet

Personal finance tracker and budgeting app for one person. Standalone Flutter app (Android, iPhone, desktop), offline-first with its own database and end-to-end encrypted sync. See `ARCHITECTURE.md` in the project docs.

## Development
Everything runs in a Docker container, so the only thing you need to install is Docker (Docker Desktop on Windows/Mac).

```sh
docker compose build                                  # first time, ~10–15 min
docker compose run --rm dev flutter test              # run tests
docker compose run --rm dev flutter build apk --debug # Android app → build/app/outputs/flutter-apk/
docker compose run --rm dev                           # shell inside the container
```

- **Android phone:** copy the built `.apk` to the phone and install it.
- **iPhone / macOS builds** need a Mac with Xcode; they can't run in Docker.
- The container runs as root. On a Linux host, files it creates are root-owned; fix with `sudo chown -R $USER .` if needed.

## What it does
- Imports bank exports: PBZ (.xls) and Revolut (.xlsx), plus quick manual entry for cash.
- Home screen shows one number: **safe to spend today**.
- Goal funds for big purchases, "Can I afford it?" check, and a wishlist with a cooling-off period for impulse buys.
- Views: spending by category, over time, budget vs actual, saving or losing per pay period.

## Project docs
Planning docs live in the claude.ai Project, not in this repo:
- `WORKFLOW.md` — how we work
- `BRIEF.md` — what we're building
- `STATUS.md` — current version, decisions, next steps
- `BASELINE.md` — analysis of past spending

## Privacy
This repo holds **code only**. Bank exports, statements and any real transaction data must never be committed. `.gitignore` blocks the common export formats.

## Structure
- `app/index.html` — the app (single file, published as a private claude.ai artifact)
- `tests/` — unit tests for the parsing and budget logic, synthetic data only. Run `npm test`.
- `CLAUDE.md` — rules and notes for Claude working in this repo

## Milestones
- M0 Setup
- M1 Core — imports, categories, list view, safe-to-spend, quick entry, wishlist (v1 live)
- M2 Budgets
- M3 Views
- M4 Polish
