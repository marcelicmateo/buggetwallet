# Stage X — "Set up my wallet" first-run wizard (owner 2026-10-28; on-device, no AI)

## Owner decisions (2026-10-28)
- The owner asked for "AI sets up my wallet the first time". A real model was considered and **dropped by the owner**:
  Anthropic offers no "sign in with your Claude account" for third-party apps (only API keys, Workload Identity
  Federation for servers, App Attest for Apple apps), and the owner did not want an API key in the app.
- So the wizard runs **on the device** from the app's own detectors. Nothing leaves the device; works offline.
- Queued after Stage V (one feature at a time).

## What it is
One guided flow after creating a new wallet (and again from Settings › "Set up my wallet again") that turns bank files
into a ready wallet: every step shows what the app found, with the evidence, and the owner taps Accept, edits, or
Skip. **Nothing is written without a tap**; a step's Accept writes only that step; Skip writes nothing. Re-running on a
wallet with data shows current → suggested (the existing proposal pattern), never overwrites silently.

Steps (each skippable, progress "Step 3 of 8", Back works, leaving mid-way keeps what was accepted):
1. **Import:** pick one or more bank files (the existing import flow incl. preview and CSV mapping); "Skip, I'll add
   payments by hand" jumps to step 8.
2. **Accounts:** one account per imported source with its balance — from the file when the file has one (Q bank
   balance), else "What does your bank app show today?"; plus cash ("How much cash do you have?", the existing
   welcome-balance step). Foreign-currency accounts in their own currency.
3. **Payday plan:** salary, payday, rent, loan, subscriptions from `suggestPlan`/`planProposals` (N2) with the basis
   sentence each — replaces the one-off P13 "Looks right?" sheet for wallets that go through the wizard.
4. **Bills and subscriptions:** detected recurring payments (`detectRecurring`), each Confirm / Not a bill, with the
   monthly/yearly total (Q "Bills and subscriptions: X a month · Y a year").
5. **Extra income:** detected expected incomes (P9), Confirm / Not income.
6. **Payees without a main tag:** the payees with the most uncategorised rows (top 10 by count), pick a main tag →
   "Always put X in Y" rule (Q rule pattern, Undo). Only what the owner picks; never guessed from amounts.
7. **Budgets:** `suggestBudgets` / `budgetProposals` per category (6-month average), Accept all or per row.
8. **Done:** "Here's your wallet": safe to spend today, payday, bills held, accounts — and what was skipped, with a
   button per skipped step.

## Rules
- Money: exact cents, home currency only in sums (foreign rows "not counted" as everywhere), never reclassify on
  amount alone; every write through `WalletRepo._write`; logs counts only (step reached, accepted/skipped counts).
- No new packages, no network. Works at 320 dp, text scale 2, dark, desktop two-pane.
- Wizard progress is device-local (resume where left off after a restart); a wallet joined with a key from another
  device does not start the wizard (its data is already set up).

## Likely split (confirm with a scout pack before briefing)
- Core (small): a pure `setupProposals(...)` bundling the existing detectors per step, and `uncategorisedPayees(txs,
  {limit})` ranked by row count (merchant key + name + count, no amounts needed for ranking). Unit tests.
- UI (most of the work): wizard shell + 8 steps reusing existing panels/sheets (import, accounts, Plan › Suggestions,
  expected bills, incomes, rules, budgets), entry after onboarding and from Settings, widget tests per step
  (skip/accept/back/resume), screenshots at 320 dp.
- Delegation: scout (haiku/low) → core-builder (session model/high) + ui-builder (sonnet/high) in parallel on the
  fixed API → reviewer per half → stage run.

## Lead decisions (2026-10-28, after the scout pack)
- Entry: after `createWallet` only (device-local flag `setupWizard` = `pending` set there; join never sets it). HomeShell
  (main.dart:340-348) after the key-backup prompt opens the wizard instead of `openWelcomeBalance`; the wizard's
  accounts step holds the cash question (the WelcomeBalanceSheet logic moves into it, sheet kept for nothing else or
  removed if unused).
- Progress device-local (`setupWizard` = `step:<n>` / `done` / `skipped`); leaving mid-way → Today's `_SetupPanel`
  gets a step `wizard` ("Finish setting up") that reopens it at the saved step; "done" removes it.
- P13 "Looks right?" (`offerFirstPlan`) is not shown while the wizard is pending or after it ran (`markFirstPlanShown`
  when step 3 is shown).
- Settings: a row "Set up my wallet again" (new NavRow, not a SettingsSection) reopens it from step 1 with current
  values as `current` in every proposal.
- No `setupProposals` bundle: each step calls the existing controller methods. Core adds only
  `uncategorisedPayees(rows, categorizer, {limit})` → `PayeeCount {merchantKey, merchantName, count}` (XC).
