# Budget Wallet — notes for Claude

## Privacy (hard rule)
This repo holds **code only**. Never commit bank exports, statements, real transactions, balances,
salary/rent/loan figures, merchant lists derived from the owner's spending, or seed data.
- Real numbers live in the artifact database (`settings/main`), never in `DEFAULTS`.
- Personal merchant rules live in `settings.merchantPatterns` in the database; `MERCHANT_RULES` in code
  covers only well-known chains and brands.
- Test fixtures are synthetic (`tests/`). Planning docs live in the claude.ai Project; redacted copies are in `docs/context/` (read `docs/context/STATUS.md` first). Keep personal figures out of them.

## Layout
- `app/index.html` — the whole app (single file, vanilla JS, SheetJS 0.18.5 from cdnjs). This is what gets
  published as the artifact.
- Pure logic sits between `/*CORE-START*/` and `/*CORE-END*/` (no DOM) so `tests/load-core.js` can load it.
- `tests/` — `npm test` (Node built-in test runner, no dependencies).

## Deploy
Publish `app/index.html` with the Artifact tool to the existing URL
https://claude.ai/artifact/BNYCWfCudgsreWnmXuhLfG (pass it as `url`; omit `capabilities` to keep the stored
db rules: root read/write = owner only).

## Data model (artifact db)
- `tx/{pbz|rev|man}-YYYY-MM` → `{source, month, items:[{i,d,a,t,m,c?,man?,mt?}]}`; `i` is a deterministic id
  (date + FNV hash of date|amount|description + occurrence index) so re-imports never duplicate.
- Categories are computed at render: item override `c` → `settings.rules[merchantKey]` →
  `settings.merchantPatterns` → built-in rules.
- `settings/main`, `goals/*`, `wish/*`.

## Workflow
Owner sends one request or piece of feedback; Claude builds, runs `npm test`, republishes, commits code,
and updates STATUS.md in the claude.ai Project and `docs/context/STATUS.md` (redacted).
