# Budget Wallet — Feature Parity Review (fintech product engineer's pass)

Companion to `docs/SYSTEM_DESIGN_REVIEW.md` (§3.4) and `docs/UI_UX_DESIGN_REVIEW.md`. Written 2026-10-22 against the
feature inventory in `docs/TECHNICAL_SPEC.md` §3 and the comparison in §8, the code (`wallet_core` models, repo,
categories, export; `wallet_importer` profiles), and the competitors' own 2026 release notes where I could reach
them (sources at the end). Where I state a competitor capability from memory rather than a 2026 source I say so.

Peer set, chosen by what a Croatian salaried household would realistically install instead:

| Group | Products | Why they matter here |
|---|---|---|
| Envelope budgeters | YNAB, Actual Budget | The reference for "plan the money you have"; Actual is the closest architecture |
| Self-hosted trackers | Firefly III | The reference for self-hosting, bills, rules, importer |
| Aggregator PFMs | Monarch, Copilot | The reference for forecasting, recurring detection, household |
| Mobile-first trackers | Cashew, Ivy Wallet, Spendee, Wallet by BudgetBakers, Toshl, Money Manager | What most people actually use on a phone; fast entry, custom categories, widgets |
| Daily-allowance apps | Daily Budget Original, Pennies, Buckets | The reference for the "safe to spend per day" number |
| The banks themselves | PBZ mobile, Erste George, Revolut | Where the data lives; Revolut's own analytics and budgets are a real competitor |

## 1. Verdict

Budget Wallet is **a strong daily-allowance budgeter with a bills-and-documents layer and a privacy model no
competitor matches**, and **an incomplete transaction tracker**. The daily number, the payday period, reserved future
costs, the owner-confirms rule, the wishlist cooling-off and the weekly review together form a product thesis that
none of the peer set has; the Croatian bill ingestion (fiscal QR with JIR, HUB-3 slips, UBL e-invoices) is unique.
Against that, the things every tracker in the peer set has had for years are missing or thin: accounts and
balances, custom categories, split transactions, multi-currency rows, reports beyond one screen, recurring income,
a rules screen, undo, home-screen widgets.

For the stated user (one Croatian household, PBZ + Revolut, salary on a fixed day) the gaps that matter most are,
in order: foreign-currency rows counted as euros (a correctness bug, see the system review), no custom categories,
no account balances to notice a missed or partial import, calendar-month budgets on payday periods, narrow
recurring detection, and no splits. Three of those are days of work each; two are hours.

## 2. Corrected capability matrix

Legend: **Ahead** = better than the group; **Parity** = comparable; **Behind** = present but weaker; **Absent** = not
present. Competitor cells marked (m) are from memory of the product, not a 2026 source.

| Capability | Budget Wallet | YNAB | Actual Budget | Firefly III | Monarch | Mobile trackers (Cashew/Ivy/Spendee) | Verdict |
|---|---|---|---|---|---|---|---|
| Primary number | Safe to spend today, payday period, reserves subtracted | Category "Available" (m) | Category balances; "Age of Money" report stable in 26.8 | None | Cash-flow forecast (launched Mar 2026) | Monthly budget left (m) | **Ahead** |
| Payday-based periods | Yes, core | No, monthly (m) | No, monthly | No | No | Some allow custom start day (m) | **Ahead** |
| Reserved future costs | Confirmed bills + planned costs + calendar events | Scheduled transactions reduce Available (m) | Schedules show as upcoming (m) | Bills with ranges (m) | Recurring calendar | Planned payments (Ivy) (m) | **Ahead** |
| Bank data in | File import, PBZ `.xls` + Revolut `.xlsx/.csv`, deterministic ids | Plaid direct import incl. more European banks (Feb 2025); CSV-first file import (Aug 2026) | GoCardless / SimpleFIN / Pluggy bank sync, mobile setup (26.8); file import | Data importer: GoCardless/Salt Edge/Nordigen + CSV (m) | Plaid/Finicity (m) | CSV import, some bank sync via Salt Edge (m) | **Behind** (two formats, no mapping UI) |
| Accounts and balances | Not stored by design (`repo.dart:754`) | Core (m) | Core | Core | Core | Core | **Absent** |
| Reconciliation | None | Reconcile to statement (m) | Reconcile (m) | Reconcile (m) | Balance from bank | Balance adjustment (m) | **Absent** |
| Categories | Fixed list of 20 (`categories.dart:11-32`) | Custom groups + categories (m) | Custom | Custom + groups | Custom | Custom, icons, colours | **Behind** |
| Split transactions | None | Yes (m) | Yes, with proportional/tax-style distribution (26.5) | Yes (m) | Yes (m) | Most yes (m) | **Absent** |
| Rules / auto-categorise | Importer hints + merchant rules learned on tap; no rules screen | Payee rules (m) | Rules UI with conditions/actions (m) | Rules engine, triggers, groups (m) | Rules (m) | Keyword rules (m) | **Behind** (works, invisible) |
| Recurring detection | 3+ payments, 30±3 d, ±10 % | Scheduled by hand (m) | Schedules, detection on import (m) | Bills with amount range + weekly..yearly (m) | Automatic detection incl. annual (m) | Manual planned payments (m) | **Behind** (monthly only) |
| Bills with documents | Fiscal QR (JIR), HUB-3, UBL e-invoice, PDF text, OCR photo; sealed storage; warranty / return-by | No | No | Attachments on transactions (m) | No | Receipts photo on some (Spendee) (m) | **Ahead**, unique |
| Budgets per category | Monthly, 6-month suggestion, pace | Core (targets, auto from 90 days) | Core, templates | Budgets (m) | Budgets, rollover (m) | Core | **Parity**, but calendar-month on payday periods |
| Reports | Spending view, CSV | Spending Breakdown, net worth, income v expense (m) | Reports incl. custom, Age of Money | Charts, custom reports (m) | Many | Charts (m) | **Behind** |
| Goals / sinking funds | Goals with deadline, paid from payday checklist | Targets (m) | Goal templates (m) | Piggy banks (m) | Goals | Goals/savings (m) | **Parity** |
| Wishlist with cooling-off | 72 h, affordability in days | No | No | No | No | No | **Ahead**, unique |
| Weekly review habit | Guided 4 steps, streak | Reports (m) | No | No | Weekly email review (m) | No | **Ahead** |
| Multi-currency | Single; foreign rows mis-summed today | Per budget currency (m) | No multi-currency (still, 2026) | Yes, per account (m) | Yes (m) | Most yes (m) | **Behind**, with a bug |
| Recurring income | One salary (`WalletSettings.salary`) | Any scheduled inflow (m) | Schedules (m) | Recurring transactions (m) | Yes | Yes (m) | **Behind** |
| Loans | `loan` amount + `loanEnd` month, nothing computed | Loan accounts with planner (m) | Liability accounts (m) | Liability accounts (m) | Liabilities | Some (m) | **Behind** |
| Undo | Only planned paid/skip | Undo (m) | Undo (m) | No (m) | Yes (m) | Varies | **Behind** |
| Multi-device sync | Self-hosted relay, E2E, offline-first | Cloud | Self-hosted server, E2E optional | Self-hosted server | Cloud | Cloud or none | **Ahead** |
| Local encryption | Encrypted SQLite, key from wallet key | n/a | Optional | Server-side | n/a | Rare | **Ahead** |
| Household / shared | No | Together / sharing (m) | Shared server (m) | Multi-user | Household at no extra cost | Some (Spendee shared wallets) (m) | **Absent**, by decision |
| Platforms | Android, Linux, web local | iOS, Android, web | Web, desktop, PWA | Web | iOS, Android, web | iOS + Android | **Behind** on mobile (no iOS) |
| Widgets / Wear / quick entry | None; share-to-app for bills | Widgets (m) | No (m) | No | Widgets (m) | Widgets, quick-add, Wear (m) | **Absent** |
| Notifications | Nudges, heads-ups, bill reminders, no amounts | Yes (m) | No (m) | Email/Slack via webhooks (m) | Yes | Yes | **Parity** |
| Export / portability | CSV, `.ics`, encrypted backup | CSV (m) | CSV, full export | JSON/CSV, API | CSV | CSV | **Parity** |
| Import from another app | No | Mint/CSV (m) | YNAB, nYNAB, Mint importers (m) | CSV | Mint importer | CSV | **Absent** |
| Price / ownership | Free, self-hosted, your data | Subscription | Free OSS | Free OSS | Subscription | Freemium | **Ahead** |

Corrections to the spec's §8 table: "Rules: never amount-based" is not true of hand-added-expense matching (equal
amount ± 3 days, see system review §3.3); "Multi-currency: single currency, exchange rows handled as transfers"
hides that non-EUR card payments are summed as EUR; YNAB's "n/a" on local encryption should read "cloud, encrypted
at rest server-side"; Actual's bank data cell should name GoCardless, SimpleFIN and Pluggy, not only SimpleFIN and
GoCardless; Firefly's bills carry amount ranges and any frequency, which is relevant to the recurring row.

## 3. Capability deep dives

### 3.1 The primary number — keep it, and make it survive the edges

The safe-to-spend-today number on a payday period with reserved costs is the strongest product idea here and
the one thing a user would switch for. Daily Budget Original and Pennies prove that one number beats a grid for
people who do not want to budget; YNAB and Actual prove that envelopes beat one number for people who do. This app
picks the first camp and adds the second camp's rigour (reserves, confirms). Keep it.

What the peer set does better: Monarch's forecasting shows the number *over time* (what the balance will be on each
day of the month); Pennies lets the period be weekly, biweekly or monthly; Daily Budget rolls unspent allowance
forward explicitly and shows it. Recommendations: a small "rest of period" strip under the hero (per-day allowance
for each remaining day given planned costs on their dates, which the Upcoming grid already knows); an explicit
over-budget state (system review §3.2); period lengths other than monthly (biweekly pay exists in Croatia for some
employers; the model already takes any `paydayDay`, so this is mostly UI).

### 3.2 Accounts and balances — the largest structural gap

The repository never stores the account name "because it names the owner's account" (`repo.dart:754`), and there is
no balance anywhere. Every product in the peer set has accounts, and not for prestige: a balance is how you *know*
the data is complete. Without it the app cannot tell the owner "your PBZ export ends on the 19th, the bank shows a
later balance, you are missing eleven days", cannot show cash on hand, cannot reconcile a cash withdrawal against
cash spending, and cannot answer "can I actually pay this bill on the 27th" (safe-to-spend is a plan figure, not
a liquidity figure).

Privacy does not require dropping accounts. An opaque account id (hash of the export's account identifier) and a
per-import closing balance (both exports carry it: PBZ as a running balance column, Revolut as `Balance`) are enough
for: completeness checks ("last row 19 Oct, balance 1,234 €"), a liquidity line on Today ("in the bank: 1,234 €"),
and transfer pairing without hints. Firefly's "asset account with opening balance" and Actual's "cleared balance"
are the two models; the lighter one (balance snapshot per import, no ledger-derived balance) fits this app.
Recommendation: build the light version. Effort: one entity, two profile changes, one Today line.

### 3.3 Getting data in — file-first is right for this user; the import UX is behind

The 2026 direction of the market is instructive: YNAB, after years of pushing direct import, made CSV the preferred
file format in August 2026; Actual's bank sync is self-hosted-key based (GoCardless, SimpleFIN, Pluggy); Firefly's
data importer carries a standing warning about duplicates on development builds. Direct bank connection is a support
burden every one of them carries, and for a privacy-first app it means a third party (an aggregator) in the loop,
which breaks the "no third party ever sees the data" promise. Croatian banks do expose PSD2 APIs (PBZ, Zaba, Erste
among them per the open-banking trackers) and aggregators list coverage, but using them means an aggregator account
and consent renewals every 90 to 180 days. Keep file import as the primary path.

Where the app is behind is the import experience, not the principle: two bank profiles, no column-mapping fallback
(on the roadmap already), no `.ofx`/`.qif`/`.mt940`/CAMT.053 (Croatian banks issue CAMT and MT940 for business
accounts; consumers get XLS/CSV/PDF), no import of a PDF statement, no "import from another app" (YNAB, Actual and
Monarch all ship a Mint or CSV importer because switching cost decides adoption). Recommendations, in order: column
mapping saved as a synced setting; Erste/Zaba/OTP/RBA profiles with golden tests (one afternoon each if the owner can
obtain synthetic exports); a generic CSV with the mapping UI; CAMT.053 later if a business use case appears.

### 3.4 Categories, rules, splits — table stakes that are missing

- **Custom categories.** Twenty fixed categories with Croatian merchant regexes compiled into the core. Every peer
  allows custom categories; Cashew and Ivy make them the first onboarding step. The fixed list is defensible for
  v1 ("fewer decisions") but it blocks the two most common real needs: a category for a child, a pet, a hobby, a
  second car, and renaming "Food delivery" to the user's language. The model needs a `category` entity with kind
  (income / fixed / flex / transfer), order and an optional parent; synced like everything else. The categoriser's
  regex hints can stay as seeds.
- **Rules.** The merchant rule learned on "always use this" is the right default UX (YNAB does the same), but there
  is no screen to see, edit or delete rules, and no condition beyond merchant text. Add a Rules section under
  Settings: list, edit, delete, plus amount-range and description-contains conditions. Firefly's rule groups are
  over-engineering for this user.
- **Splits.** Absent. One supermarket row that is groceries plus household plus a gift is the single most common
  edit in a tracker; Actual added proportional distribution to splits in 26.5 because people use them that much. The
  op-log model handles a split as child rows with `parent_id` and amounts that must sum to the parent; the UI is a
  sheet with N lines and a "remaining" figure. Two to three days.

### 3.5 Recurring and bills — ahead on documents, behind on patterns, with a Croatian tailwind

Nobody in the peer set ingests a fiscal receipt by its QR code, reads a HUB-3 slip, parses a UBL e-invoice and
stores the sealed document next to the transaction with a warranty and return-by date. That is a real moat for a
Croatian user, and the timing is good: Fiscalization 2.0 made structured e-invoices mandatory between businesses
from 1 January 2026 (consumers still receive fiscal receipts with the QR/JIR, and utilities increasingly offer
e-invoice delivery through bank and e-mail channels). The UBL reader already in `wallet_importer` positions the app
to accept those files as they reach households. Keep investing here; it is the differentiator a reviewer would
quote.

Behind: recurring detection accepts only monthly patterns within ±10 % (system review §3.3). Firefly bills carry an
amount range and any frequency; Monarch detects annual subscriptions. Real households have quarterly insurance,
annual car registration, weekly gym, bimonthly utilities, and variable electricity. Add period classes (weekly,
monthly, quarterly, semi-annual, annual) and a per-bill amount range, and let the owner create an expected bill by
hand (today only detection creates one; a hand-added expected bill becomes a planned cost instead).

Also missing on bills: a bill with instalments; a bill paid in parts; "pay this" deep-linking into the bank app with
the HUB-3 data (Croatian bank apps accept HUB-3 payloads by camera; generating the barcode or a `hub3` QR for the
owner's bank app to scan would close the loop from paper slip to payment without typing an IBAN).

### 3.6 Budgets and reports

Budgets are at parity in mechanics (monthly amount, pace, suggestion from history, hatch when over) and behind in one
design decision: they run on calendar months while everything else runs payday to payday (system review §3.3).
YNAB and Actual are consistent because everything is monthly; this app should be consistent because everything is
payday. Rollover (Actual, Monarch) is a frequent request in envelope apps; in a daily-allowance app the rollover is
implicit in the formula, so skip it.

Reports are the parity gap users notice second (after categories). The data exists (`periodSummaries`, `trendNet`,
per-category sums); the screens do not. Three reports cover 90 % of asks: net per period over 12 to 24 periods;
one category over time against its budget; income versus fixed versus flex as a stacked bar per period. Net worth,
investments and property values (Monarch's territory) are out of scope by the product's own definition and should
stay out.

### 3.7 Multi-currency

Actual still has none in 2026 and gets away with it because its users are mostly single-currency; this app's second
supported bank is Revolut, whose exports carry a `Currency` column and whose users hold several balances. Today
non-EUR rows are summed at face value (bug). Minimum: count only wallet-currency rows and show the rest in a
"foreign, not counted" line. Better, and still small: store the row currency and a converted amount at import using
the Revolut row's own counter-amount where present (exchange rows carry both sides), otherwise a rate the owner
enters once per currency; budget in EUR, display both. Full multi-currency budgeting (per-currency envelopes) is not
needed for this user.

### 3.8 Income

One salary, planned or received, with a "salary landed" confirmation. Households have two salaries, child benefit,
freelance invoices, rent received. YNAB and Monarch treat any inflow as income to assign; Firefly has recurring
transactions of any sign. Add recurring income entries (name, amount, day, account hint) feeding the payday plan;
the period detection already groups salary parts within 20 days.

### 3.9 Behavioural features — the quiet advantage

The wishlist with a 72-hour cooling-off and an affordability answer in days ("spend 5 €/day less, ready by 15 Nov"),
the weekly review with four ruled steps and a streak, the payday checklist that pays goals first, and notifications
that never carry amounts: no competitor has this set. Monarch's weekly review e-mail and YNAB's "Reflect" tab are the
nearest. Keep, and make them more visible (the UI review proposes a Save tab and a persistent add action). One
addition with high leverage: a "saved by waiting" and "streak" summary on the weekly review's Done screen.

### 3.10 Platform reach

Android plus Linux plus a localhost web build is unusual; the peer set is iOS + Android + web. For a one-household
product the owner's devices define the platform list, so this is acceptable. Two things the mobile trackers have that
cost little here: a home-screen widget with the safe-to-spend number (Android `AppWidget` through a small platform
channel or the `home_widget` package; the number is already cached per data version) and a quick-add shortcut
(long-press icon → Add expense). Wear OS is not worth it.

### 3.11 Household

Absent by decision and the system review agrees the design cannot take multi-user without identity in the op log.
Monarch offers household sharing at no extra cost; Spendee has shared wallets; YNAB sells "Together". The honest
positioning is "one wallet per person, shared bills through the same relay" and a documented recipe for a couple:
two wallets, two keys, one relay, the shared bills imported into whichever wallet pays them.

### 3.12 Onboarding and time-to-first-number

YNAB's mobile onboarding analyses 90 days of past spending to propose targets; Cashew asks for currency and
categories first; Monarch imports Mint history. This app's onboarding is: create wallet, save key, import files, set
the payday plan. The spec says "two taps" for daily use; the first-run path to a trustworthy number is longer than it
needs to be. Recommendation: after the first import, propose the payday plan from history (salary detected from
the largest recurring inflow, rent/loan from the largest fixed outflows, budgets from the 6-month suggestion that
already exists) as one "Looks right?" screen.

## 4. Table stakes for a daily driver — effort and order

| Gap | Pain for the stated user | Effort | Order |
|---|---|---|---|
| Foreign-currency rows counted as EUR | Wrong number every month with Revolut | Hours (filter) / 2 days (converted amount) | 1 |
| Explicit past-payday state | Wrong number for days each month | Hours | 2 |
| Custom categories (entity, kinds, order) | Blocks personal fit; first feature request | 3 days incl. migration of fixed list | 3 |
| Light accounts: opaque id + closing balance per import, completeness check | Catches missed imports; liquidity line | 2 days | 4 |
| Budgets on the pay period | Today and Spending disagree today | 1 day | 5 |
| Recurring: period classes + amount range + hand-created expected bills | Quarterly/annual bills never reserved | 2 days | 6 |
| Split transactions | Weekly edit for most households | 3 days | 7 |
| Rules screen (view/edit/delete, amount and text conditions) | Trust in auto-categorisation | 2 days | 8 |
| Reports: net per period, category over time, income/fixed/flex | Second most common ask | 3 days | 9 |
| Recurring income entries | Two-salary households | 1 day | 10 |
| Column-mapping import + 2–3 more Croatian bank profiles | Adoption beyond PBZ/Revolut | 3 days + fixtures | 11 |
| Undo on delete; home-screen widget; quick-add shortcut | Polish the mobile trackers all have | 2 days | 12 |

Roughly five to six weeks of focused work closes the table-stakes gap without touching the architecture; the system
review's pre-M6 fixes come first.

## 5. Differentiators to protect and extend

1. Safe to spend today on a payday period with reserved costs, owner-confirmed.
2. Bills as documents: fiscal QR, HUB-3, UBL e-invoice, OCR, sealed storage, warranty and return reminders. Extend
   with HUB-3 payload hand-off to the bank app and instalments.
3. Wishlist cooling-off with an answer in days; weekly review; payday checklist; amount-free notifications.
4. Ownership: self-hosted E2E relay, encrypted local database, no third party, free.
5. Calendar events as planned costs (device calendars and `.ics`), which no peer does.

## 6. What not to build

Net worth and investment tracking; direct open-banking connections through an aggregator; multi-user inside one
wallet; per-currency envelopes; Wear OS; a research-projects tracker (already dropped). Each either breaks the
privacy promise, contradicts the product thesis, or costs more than the owner would use.

## 7. Sources consulted (2026)

- Actual Budget release notes and blog: [releases](https://master.www.actualbudget.org/docs/releases),
  [26.5.0](https://actualbudget.org/blog/release-26.5.0), [26.4.0](https://actualbudget.org/blog/release-26.4.0),
  [release tag](https://actualbudget.org/blog/tags/release)
- YNAB: [release notes](https://youneedabudget.com/release-notes), [what's new](https://ynab.com/whats-new),
  [more banks, Europe edition](https://www.ynab.com/whats-new/more-banks-europe-edition),
  [updates to YNAB](https://support.ynab.com/en_us/updates-to-ynab-S1f4aRLeC.md),
  [automatic targets](https://support.ynab.com/en_us/does-ynab-create-targets-automatically-HJ4k1nBWfg.md)
- Firefly III: [self-host listing](https://www.selfhostyourself.com/services/firefly-iii),
  [data importer development builds](https://newreleases.io/project/github/firefly-iii/data-importer/release/develop-20260307)
- Monarch: [forecasting launch](https://www.monarch.com/blog/forecasting), [features](https://monarchmoney.com/features),
  [review 2026](https://www.thepennyhoarder.com/budgeting/monarch-money-review/)
- Croatia open banking: [Open Banking Tracker, Croatia](https://www.openbankingtracker.com/country/croatia),
  [Fiskil open finance tracker](https://www.fiskil.com/open-finance-tracker/croatia)
- Fiscalization 2.0: [Porezna uprava guide](https://porezna-uprava.gov.hr/hr/vodic-kroz-fiskalizaciju-2-0-8151/8151),
  [KPMG summary](https://kpmg.com/hr/hr/mediji/press-releases/2025/07/fiskalizacija-2-0.html)
