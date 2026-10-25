# Stage N2 core spec: accounts, balances, plan suggestions (2026-10-25)

Owner decisions: D9 (accounts), plan defaults from imports, budget Suggest. Exact cents, home-currency rule, never classify on amount alone.
Builder and test-writer both work from this file; names and fields are fixed here.

## 1. Accounts (synced entity, schema 9)
`entitySchema['account']`, table `accounts`:
| column | kind | notes |
|---|---|---|
| `name` | text, searchable | owner's label ("Cash", "Bank 1"), trimmed, 1–60 chars |
| `source` | text, nullable | `pbz` / `revolut` (bank profile ids from the importer), or null = **cash** |
| `currency` | text | `^[A-Z]{3}$` |
| `opening` | integer | cents, signed, `abs <= WalletSettings.maxAmount` |
| `openingDate` | text | `YYYY-MM-DD`, a real date, not after today |
| `deleted` | flag | |

Model `Account` (models.dart): `id, name, source, currency, opening, openingDate, deleted`; `bool get isCash => source == null`.

Repo (`repo_accounts.dart`, `extension WalletRepoAccounts`), all through `_write`, log keys/counts only:
- `Future<String> addAccount({required String name, String? source, required String currency, required int opening, required String openingDate})`. Id `_newId('a')`.
- `Future<void> updateAccount(String id, {String? name, int? opening, String? openingDate})`. Unknown id gives `ArgumentError('No such account.')`. Source and currency cannot change; to change them, delete the account and add a new one.
- `Future<void> correctBalance(String id, {required int balance, required String date})`. The owner's "the real balance is X today" writes `opening = balance, openingDate = date`.
- `Future<void> deleteAccount(String id)` (`deleted: 1`) and `Future<void> undeleteAccount(String id)` (the undeleteGoal pattern).
- `List<Account> accounts({bool includeDeleted = false})`, ordered by name, then id.
- Validation throws `ArgumentError` with an owner-readable message for each of these cases:
  - an empty or too long name;
  - a bad currency;
  - an unknown source;
  - a bad, future or unparseable date;
  - an amount over the cap;
  - a second **live** account with the same `(source, currency)`, cash included, so no row is ever counted twice.

## 2. Balances (pure, `accounts.dart`)
`List<AccountBalance> accountBalances(List<Account> accounts, List<Tx> rows)`.
`AccountBalance { Account account; int balance; int rowsCounted; String? lastRowDate; }`.

A row counts for an account when all of these hold:
- it is not deleted;
- `row.currency == account.currency`;
- `row.date > account.openingDate` (the opening is the balance at the end of that day);
- it matches the account:
  - **bank** account: `row.source == account.source`, `row.manual == false`. Every kind counts: spending, income, fees, ATM, own transfers and exchanges. Own transfers move money between two accounts, so the total stays right without special cases.
  - **cash** account: `row.manual == true && row.matchedTo == null && !row.matchPending`. A manual row matched or pending against a bank row is already counted in the bank account. ATM withdrawals are **not** added to cash: the app treats withdrawn cash as spent, and rent is paid in cash. The owner corrects cash with `correctBalance`.

`balance = opening + sum(row.amount)`. `lastRowDate` is the latest counted row date, or null; the UI shows it as "as of last import". Deleted accounts are skipped.

`Map<String, int> balanceTotals(List<AccountBalance> b)`: sums per currency only, never mixed. Keys are sorted.

## 3. Plan suggestions (pure, `suggest.dart`)
`PlanSuggestion suggestPlan(List<CategorizedTx> txs, WalletSettings st, String today)`.
`PlanSuggestion { Suggested? salary, paydayDay, rent, loan, subs; }`.
`Suggested { int value; String basis; List<String> evidence; }`:
- `basis` is a short fixed key: `salaryRows`, `paydayDates`, `rentRows`, `loanRows`, `confirmedBills`;
- `evidence` holds the transaction ids, or the bill ids for `subs`.

Only home-currency rows (`st.currency`) count. A value is null when there is not enough evidence:
- **salary**: from `salaryPaydays` (income kind only). The median of the totals of the last up to 3 *complete* payday groups, where complete means the next payday has started. Needs ≥2 complete groups.
- **paydayDay**: the most common day of month of the payday group starts. Needs ≥2 groups; a tie goes to the later day. Clamp 1–28 only if `WalletSettings` already clamps; follow its rule.
- **rent** / **loan**: rows whose *category* (owner, merchant rule or `autoCategory` from `kindHint`) is Rent or Loan. Use the monthly sums of the last 3 complete calendar months that have such rows, and take the median. Needs ≥2 months. The amount never chooses the category; only the existing categoriser does.
- **subs**: the sum of the median amounts of the owner-**confirmed** recurring bills (expected bills) in the fixed category (Bills & subscriptions). Unconfirmed candidates are never included. Use the existing confirmed-bill reader; if this needs repo data, take `List<RecurringBill> confirmed` as a parameter instead of reading.

`List<SettingProposal> planProposals(PlanSuggestion s, WalletSettings st)`. `SettingProposal { String key; int? current; int suggested; String basis; }`:
- Make one proposal per non-null suggestion whose value differs from the current setting.
- `current` is null when the setting is unset or 0 for money, or unset for `paydayDay`.
- Nothing is ever written. The app applies what the owner accepts, through `updateSettings`.

## 4. Budget Suggest diff (pure, next to `suggestBudgets`)
`List<BudgetProposal> budgetProposals(Map<String, int> current, Map<String, int> suggested)`.
`BudgetProposal { String category; int? current; int suggested; bool get fillsEmpty => current == null; }`:
- Include each suggested category whose current value is missing or 0 (`fillsEmpty`), or differs from the suggestion.
- Equal values are left out.
- Order: empty fields first, then by category name.

## 5. Schema 9
- `WalletRepo.schemaVersion = 9`, with the doc line "version 9: accounts".
- No data migration.
- Update `test/schema_test.dart` (the DDL oracle) and `test/support/sim.dart` `entityTables`/`dataTables`.
- Update the `isEmpty` doc comment.
- Snapshot, `.bwb` and sync need no code. Add tests that prove it:
  - two devices sync an account and a correction;
  - a backup round-trip keeps accounts;
  - the schema-7 old-build fixtures still open and migrate to 9.
- Search: accounts are searchable by name if `searchAll` gets an `accounts:` parameter. Optional; skip it if it is more than a few lines.

## 6. Tests the spec requires (test-writer writes these independently)
Use synthetic data only.

Balances:
- opening only;
- rows on the opening date are excluded, rows on the next day are included;
- deleted rows are excluded;
- a foreign-currency row is excluded from a home account and counted in its own currency account;
- an own transfer between two accounts leaves the total unchanged;
- cash: manual rows are counted; manual rows that are matched or pending are not;
- ATM rows are not counted in cash;
- a duplicate `(source, currency)` is refused, also for cash, and is allowed again after the first is deleted;
- after `correctBalance`, the balance equals the corrected value.

Validation boundaries:
- name at 0, 1, 60 and 61 characters;
- amount at the cap and at cap+1;
- a future date and an invalid date;
- currency `eur` and `EURO` refused.

Suggestions:
- not enough evidence gives null;
- salary in parts is grouped;
- foreign rows are ignored;
- a big ATM row under the rent threshold is not rent;
- unconfirmed bills are left out of subs;
- `planProposals` skips equal values;
- `budgetProposals` order and `fillsEmpty`.

Sync, backup and migration: as in §5.
