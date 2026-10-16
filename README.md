# Budget Wallet

Personal finance tracker and budgeting app for one person. Phone-first, published as a private claude.ai web app with its own database.

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
