# Stage UX — user-experience rework (owner feedback 2026-11-01)

Owner, 2026-11-01: "user experience is really bad, nothing is concise, everything is all over the place; not enough
generalization and customisation; the theme is heavy, not great to look at for long. UI/UX needs fixing so that users
actually want to use the app." Owner decisions the same day: theme = **mockups first** (UX-C waits for the owner's pick);
crypto value = **rate set by hand** (like FX rates; no network price fetch).

Three parts, merged in order: **UX-A** (direct fixes), **UX-B** (reorganisation), **UX-C** (theme + tightening pass).
Rules for every part: one place per action, no repeated text ([no duplicate info]), exact money (nothing is reclassified or
switched on a guess; suggestions ask), synthetic data only, logs carry no amounts/names/codes of the owner's data.

## Owner's points → where they land
| # | Owner said | Part | Item |
|---|---|---|---|
| 1 | Main tag and tag should be one window, with recommendations | B | B2 |
| 2 | On Linux, Today's dots tile ("… within · … over") has a lot of empty space | A | A-ui §3 |
| 3 | Return by: a clickable calendar, with options like 1m, 4d, 5y | A | A-ui §1 |
| 4 | Same for warranty (45d, …) | A | A-ui §1 |
| 5 | Reminder: tied to what exactly? | A | A-ui §2 |
| 6 | Budget/plan cannot be edited | B | B1 |
| 7 | All currencies; EUR default; offer another one when imports are mostly in it | A | A-core §1–2, A-ui2 §1 |
| 8 | Accounts: cash, bank, bitcoin, other kinds that hold money, with subfields | A | A-core §3, A-ui2 §2 |
| 9 | Rework handling of tags | B | B2 |
| 10 | Built-in rules editable like any other rule | A | A-core §4, A-ui2 §3 |
| 11 | Budget per category belongs in the Plan window | B | B1 |
| 12 | Expected income belongs in the Plan window | B | B1 |
| 13 | Settings › Month is wrong on many levels | A | A-ui §4 |
| – | Customisation, conciseness, lighter theme | B, C | B4, C |

## UX-A — core (core-builder, worktree `ux-a-core`, base v2)
**Schema 20** (relay, phone and laptop update together; document it the way schema 19 was: `repo.dart` migration,
`docs/context/STATUS.md` note, sync op compatibility for an older peer = refuse with the existing "update the app" path).

1. **Currency table** (`packages/wallet_core/lib/src/currencies.dart`, exported):
   `class CurrencyInfo { final String code; final String name; final int minorDigits; final bool crypto; }`,
   `const List<CurrencyInfo> allCurrencies` = every active ISO 4217 code (name in English, ISO minor digits: JPY 0, KWD 3, …)
   plus `BTC` (Bitcoin, 8 digits, crypto: true). `CurrencyInfo? currencyInfo(String code)`;
   `int minorDigitsOf(String code)` (unknown code → 2). Default wallet currency stays `EUR`.
   **Money with other digits:** every place in core that converts between currencies (FX rates → wallet currency) or turns
   text into minor units must use `minorDigitsOf` of the right currency (a 1,000 JPY row = 1000 minor units, not 100000;
   0.01 BTC = 1 000 000 minor units). The importer parses amounts into minor units with the digits of the row's currency
   when it knows it. Where a path cannot support non-2-digit currencies yet, it refuses with a clear error and the builder
   lists it in the report (owner rule: money limits are surfaced, never silent).
   `setFxRate` accepts any code in `allCurrencies` (BTC included) except the wallet currency.
2. **Prevalent currency** (pure function, exported): `String? prevalentCurrency(Iterable<Tx> txs, String walletCurrency)`
   → the code X ≠ walletCurrency when at least 10 payments are counted and ≥ 80 % of them (by count, never by amount)
   are in X; else null. The app only *offers* "Use X as your wallet's currency?"; nothing switches on its own. Changing the
   wallet currency keeps the existing setter; if none exists, add `setWalletCurrency(code)` through `_write`.
3. **Account kinds** (schema 20): `enum AccountKind { cash, bank, card, savings, investment, crypto, other }` with a
   stable wire name; `Account` gains `kind` (migration: `source == null` → cash, else bank) and optional `institution`
   (free text: bank/provider/exchange name). `isCash` keeps meaning `kind == cash`. `source` (import format) is allowed
   for bank, card and savings only. Crypto accounts: currency must be a crypto code (BTC), balance in its minor units;
   its value in the wallet currency uses the hand-set rate (§1). `addAccount(...)` and a new
   `updateAccount(id, {name, kind, institution, source, clearSource})` go through `_write`; refusals throw
   `ArgumentError` with a short message the UI can show.
4. **Built-in rules editable**: built-in merchant rules get **stable ids** (`builtIn:<slug>`, e.g. `builtIn:lidl`), and every
   stored ref to `builtIn:<index>` is migrated or still resolves. A synced setting `builtInRuleOverrides`
   (id → `{pattern?, category?, off}`) changes a built-in: `editBuiltInRule(id, {pattern, category})`,
   `setBuiltInRuleOff(id, off)`, `resetBuiltInRule(id)`. Categorisation applies the overrides; an app update that changes
   a built-in does not touch one the owner edited (the override wins), an unedited one follows the update.
   `RuleView` reports `editable: true`, `edited: bool`, `off: bool` for built-ins. The app's rules list keeps working.

Tests: core unit tests for each point, including edges (JPY/KWD/BTC digits through FX and the importer, 79 %/80 %/9 rows
for prevalentCurrency, migration of old accounts and old `builtIn:<index>` refs, override vs update, reset, off rule no
longer matches). One targeted check at the end (`tools/build.sh core` + `sync` + `importer`).

## UX-A — UI without core changes (ui-builder, worktree `ux-a-ui`, base v2)
1. **Return by / Warranty until** (`bill_sheet_sections.dart` `_BillWarranty`, `bill_sheet.dart` `_pick`): each is a
   full-width tappable field that opens the calendar; under it quick chips **4d · 14d · 1m · 1y · 2y · 5y** and a small
   "Length" text field that takes `<n>d|w|m|y` (e.g. `45d`, `5y`); lengths count from the bill's purchase date (today if
   it has none). A pure helper `String addLength(String fromIso, String text)` (throws `FormatException` on bad input,
   month-end clamps: 31 Jan + 1m = 28/29 Feb) with unit tests. Clearable as now. Dates are whole days: no hours.
2. **Reminder, tied to the date it serves**: directly under each date, one line "Reminder N days before · Change" (N =
   `returnReminderDays` / `warrantyReminderDays`), editing the same global setting inline; the line says it applies to every
   bill ("for all bills"). Remove the separate "Reminder days" section from the Bills panel.
3. **Today hero on wide screens** (`today.dart` ~110, `widgets/dash.dart` `HeroTile`): no empty block — on the expanded
   layout the hero is one row tall (or its height follows its content) with the day dots beside the figure; phones unchanged.
   Check with `tools/live.sh` at 1280 and a phone width.
4. **Month**: remove Settings › Month (`SettingsSection.month`, `MonthPanel`). The period range shown in the rail (and its
   place on phones) becomes tappable and opens a **Period** sheet: this period's dates, the expected next payday, and
   "Salary came: start a new month" (date picker limited as now). Fix p5_tabs and day_change tests accordingly.

## UX-A — UI on the new core (ui-builder, after A-core merges)
1. **Currency picker**: one searchable picker (code + name) used everywhere a currency is chosen (wallet currency,
   account form, rate form). After an import, when `prevalentCurrency` returns X, one dismissible offer "Most payments are
   in X. Use X as your wallet's currency?".
2. **Account form**: kind first (Cash, Bank, Card / e-money, Savings, Investment, Crypto, Other), then only that kind's
   fields (bank/card/savings: institution, import format; crypto: coin, rate; all: name, currency, balance, date).
   Existing accounts editable (kind, name, institution, format).
3. **Rules panel**: built-ins listed with the same row menu as own rules (edit, turn off, reset if edited); remove
   "Built in (read-only)".

## UX-B — reorganisation (after UX-A)
- **B1 Plan window** = Budget › Plan, edited in place (no Edit mode): expected income, plan lines, budgets per category.
  Settings › Budgets per category and Settings › Expected income move here (Today's income tile opens Plan).
- **B2 Tags window**: main tags, tags and rules in one window (sections), with recommendations (untagged payees that keep
  recurring → suggest a main tag or a rule; frequent words/payees → suggest a tag). One add flow.
- **B3 Settings = setup only**: Accounts (with currencies), Import, Sync, Backup, Calendars, Look, Diagnostics.
- **B4 Today customisation**: choose which Today tiles show and their order (stored per device).

## UX-C — theme + tightening (after the owner picks a mockup)
New palette and surfaces from the chosen mockup (`theme.dart`, light + dark, design-system artifact re-synced), normal
sans for text, mono only for amounts; then a pass over every screen (phone + wide screenshots) cutting repeated text,
double controls and boxes that carry nothing.
