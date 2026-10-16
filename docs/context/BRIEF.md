# Budget Wallet — Brief

## Purpose
Personal finance tracker and budgeting tool for one person. The design should enforce a chosen budgeting philosophy, not just record numbers.

## Owner goals
- See where money goes; know if saving or losing money; know if a purchase is affordable now / later / when; plan big purchases. Open to lifestyle changes.
- Income: salary from one employer, paid as several payments per month (10th–15th), all counted as salary.
- Effort: automate as much as possible; daily expense entry; weekly review.
- Main pain point: impulse buys.

## Fixed requirements
- **Users:** single user (owner only). No sharing or multi-user features.
- **Currency:** currency-agnostic data model; EUR is the default display currency.
- **Data in:** imports from PBZ (.xls) and Revolut (.xlsx / .csv) + quick daily manual entry (mainly cash). Manual entries are matched to bank rows on import (no duplicates). PBZ → Revolut top-ups are internal transfers, not spending.
- **Platform:** v1 private claude.ai web app; v2 standalone app on phone and computer (see ARCHITECTURE.md).

## Budgeting strategy — approved 2026-10-16
Hybrid: **Pay yourself first + Sinking funds + Daily safe-to-spend**, with impulse friction.

Payday plan (once per pay period, salary-to-salary, mostly automatic):
monthly salary (sum of all employer payments, planned at the normal/lowest month) − fixed bills (rent, loan, subscriptions) − savings (off the top) − goal funds (monthly share of each big purchase) = flexible money.
Anything above the planned salary, plus tax refunds, bonuses and other one-offs, is never part of daily money; it goes to the emergency fund, then goals.

How the design enforces it:
- **Home screen = one number:** safe to spend today (flexible money left ÷ days to next payday). Rolls over: spend less today, more tomorrow.
- **Big purchases = goal funds** with target amount + date; app shows the monthly amount needed, or the date reachable at a chosen monthly amount.
- **"Can I afford it?" check:** any item → now / in N weeks / by date, based on safe-to-spend and goal funds.
- **Impulse rule:** any purchase over €50 goes to the wishlist first, with a 72-hour cooling-off (defaults, adjustable). Buy only after it expires and still fits.
- **Saving or losing:** net per pay period (in − out) and savings rate, trend line across both banks.
- **Where it goes:** spending by category and top merchants.
- **Weekly review (~5 min):** import exports, confirm categories, check pace, decide on wishlist items.
- **Automation:** merchant → category rules learned from corrections; recurring bills detected from exports; rent cash withdrawal auto-tagged.
- **Nudges at risk moments:** food-delivery window (15–18h) and Sundays.
- **Baseline first:** initial numbers come from the owner's bank analysis (kept in the claude.ai Project, not in git), not guessed.

## Out of scope (for now)
- Live bank connections (exports only)
- Investments, tax, multi-user
