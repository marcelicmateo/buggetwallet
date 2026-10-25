# Stage P4 spec: recurring bills beyond monthly (2026-10-25)

Plan item: PATH_FORWARD P4 ("period classes (weekly … annual) + amount range; hand-created expected bills; instalments;
a bill paid in parts").

## Owner decisions (2026-10-25)
- **Long bills are held in full.** A confirmed bill that repeats less often than monthly (quarterly, yearly) holds its
  whole amount from the day it is confirmed until it is paid. The money must always be there. Safe-to-spend is lower
  by the full amount in every period until the payment lands.
- **Amount range:** a bill whose amount changes (electricity 40–70 €) sets aside the **highest** amount in the range.
- **Paid in parts:** a cycle is done **when the parts add up** (or the owner marks it paid / skips it). Until then the
  rest stays set aside.
- **Detection:** weekly, every-2-weeks, quarterly and yearly bills are found from history and **suggested for the owner
  to confirm**, like monthly ones today. Nothing is reserved before confirmation.

Rules that stay: exact cents; never classify or match on amount alone (every match needs the payee key); nothing in
existing data is rewritten; a monthly bill with no new fields behaves exactly as today (identity tests pin this).

## 1. Model (schema 12)
`recurring` gains nullable columns (entity def, `sim.dart` `entityTables`, the `schema_test` DDL oracle, `schemaVersion` 12; no data migration):

| column | kind | notes |
|---|---|---|
| `min_amount` | integer, nullable | cents > 0; with `max_amount`: an amount range |
| `max_amount` | integer, nullable | cents ≥ `min_amount`, ≤ `maxAmount` |
| `ends_on` | text, nullable | `YYYY-MM-DD`: the last due date (instalments). No cycle after it. |
| `manual` | flag | created by hand (`addRecurring`), never touched by detection |

`interval_days` already exists and becomes the period. **Period classes** (`enum RecurringPeriod { weekly, biweekly, monthly, quarterly, yearly }`, `RecurringPeriod.days` = 7, 14, 30, 91, 365; `RecurringPeriod.of(int days)` = the class whose days are nearest, else null for a custom value). A stored `interval_days` outside 1..400 reads as 30.

`RecurringBill` gets `minAmount`, `maxAmount`, `endsOn`, `manual` (fromRow/copyWith) and getters:
- `bool get hasRange` — both min and max set and valid (`0 < min ≤ max ≤ maxAmount`); an invalid stored pair reads as no range (logged once as `recurring.invalid`, field name only).
- `int get reserveAmount` — `hasRange ? maxAmount : expectedAmount`.
- `bool get isLong` — `intervalDays > 31`.
- `bool get finished` — `endsOn != null && nextDue > endsOn`.
- `int tolerance` — match/gap days: ≤ 7 → 1, ≤ 14 → 2, ≤ 31 → 3 (`recurringDays`, unchanged), ≤ 92 → 7, else 10.

## 2. Detection (`detectRecurring`)
- Per payee, consecutive gaps must all be within `tolerance` of one class's days (weekly, biweekly, monthly, quarterly, yearly; tried in that order, first that fits wins).
- Lookback and minimum rows per class: weekly 8 weeks / 4 rows; biweekly 16 weeks / 3 rows; monthly 7 months / 3 rows (today's rule exactly); quarterly 13 months / 3 rows; yearly 25 months / 2 rows.
- Amount band unchanged (10 % of the median). `intervalDays` = the class days; `nextDue = last.date + days`.
- A payee that a live **manual** bill uses is never detected (no duplicate). A dismissed id stays dismissed (as today).

## 3. Matching a payment and parts (`planRecurringPayments`, pure)
Returns, per bill, the rows that pay its **current cycle** (due date `nextDue`):
- **Single payment** (as today): a live, non-manual outflow row, same currency, `merchantKey == payee`, within `tolerance` days of `nextDue`, not `lastPaidTx`, and amount in range (`hasRange`: `min ≤ |amount| ≤ max`, inclusive) or in the 10 % band of `expectedAmount`. The closest wins (then earliest, then smallest id). **A monthly bill without new fields matches exactly as today.**
- **Parts:** when no single payment matches, the rows of the payee dated in `[nextDue − partsDays, nextDue + tolerance]`, after the `lastPaidTx` row's date (strictly), not `lastPaidTx`, each with `|amount| ≤ reserveAmount`, are summed oldest first. `partsDays` = `min(14, intervalDays − tolerance − 1)`. The cycle is **paid** when the sum reaches the threshold: `hasRange ? minAmount : expectedAmount − expectedAmount ~/ 10` (the band's low end). The completing row is the paying row.
- New result: `class RecurringPayments { Map<String, Tx> paidBy; Map<String, List<Tx>> parts; }` — `parts[b.id]` = the counted rows of a cycle that is **not** paid yet (empty / absent when none). `int partsPaid(String id)` = Σ |amount|.
- `refreshRecurring`: on a paid cycle, `last_paid_tx` = paying row and `next_due` = paying row date + interval for a single payment (as today), `nextDue + interval` when paid in parts. A `finished` bill is left alone. Manual bills are refreshed the same way (payment matching), never re-detected.

## 4. Money (`computePeriod`)
New pure type and function (keep `dueBills` and `PeriodBudget.dueBills` = the distinct bills, same order):
```dart
class DueCycle { final RecurringBill bill; final String due; final int reserve; final int paid; }
List<DueCycle> dueCycles(List<RecurringBill> bills, List<CategorizedTx> txs, String start, String end, {RecurringPayments? payments});
```
- **Monthly and shorter (`!isLong`):** every occurrence `nextDue + k·interval` (k ≥ 0) before `end` (overdue `nextDue` included, as today), not past `endsOn`. Weekly bills therefore reserve each week in the period. The first cycle's `paid` = `partsPaid`; `reserve = max(0, reserveAmount − paid)`; later occurrences reserve `reserveAmount`.
- **Long (`isLong`):** the next cycle only, **whatever its due date** (also after `end`), until paid or skipped. `reserve = max(0, reserveAmount − paid)`.
- `finished` bills and unconfirmed ones: none. The paid-in-this-period rule of `dueBills` (lastPaidTx dated ≥ start) still drops the first cycle.
- **Plan lines:** a `!isLong` bill in a fixed category stays covered by its monthly plan line (listed, not added; as today). A **long bill is never covered by a monthly plan line**: always reserved (owner: the money must be there). Instalments with a monthly interval behave as monthly.
- `PeriodBudget` gains `List<DueCycle> dueCycles`; `reservedBills` = Σ `reserve` of cycles not covered (as above). The occurrence keys for `plannedReserves` / `counted` come from the cycles (`occurrenceKey(bill.id, due)`), so a slip that covers a cycle is still never reserved twice.
- `billOccurrences` / `upcoming` / `headsUps` / `.ics`: stop after `endsOn`; amount shown = `reserveAmount`. Upcoming stays date-ranged (a long bill appears on its due date); Today's bills line shows the held long bills (they are in `dueCycles`).

## 5. Bill history (`billHistory`)
- Monthly bills: unchanged (one line per month).
- Other periods: one line per **cycle** (due date), newest first, the same number of lines (`months` param = cycles). States as today. A cycle paid in parts is `paid` when its rows reach the threshold; `BillMonth` gains `int paidCents` and `List<String> txIds` (parts). Never matched by amount alone.

## 6. Repo API (all through `_write`; logs: ids and counts only)
- `String addRecurring({required String label, required String category, required int amount, int? minAmount, int? maxAmount, required int intervalDays, required String firstDue, String? payee, int? instalments})`
  - id `rec:m` + 12 random hex; `manual` 1; status `confirmed` at once (the owner made it).
  - `payee` (a `merchantKey`) is optional: **without a payee the bill never matches a payment** (never on amount alone); the owner marks each cycle paid (`skipRecurring`).
  - `instalments` N ≥ 1 → `ends_on = firstDue + (N − 1)·interval`.
  - `ArgumentError` (owner-readable): label 1–40, amount 1..`maxAmount`, range `0 < min ≤ max ≤ maxAmount` and amount within it, interval 1..400, `firstDue` ISO, category live, instalments 1..600, a payee that another live bill already uses.
- `void updateRecurring(String id, {String? label, String? category, int? amount, int? minAmount, int? maxAmount, bool clearRange = false, int? intervalDays, String? nextDue, String? endsOn, bool clearEnd = false})` — works on detected and manual bills; same validation; writes only changed fields; editing a candidate does not confirm it.
- `int? instalmentsLeft(RecurringBill b)` (pure, on the model is fine): cycles from `nextDue` to `endsOn` inclusive; null without `endsOn`.
- `skipRecurring` unchanged (moves `next_due` by the interval) and is the "Mark paid" for a cycle paid in parts or a bill without payee. `confirmRecurring`, `dismissRecurring`, `deleteRecurring` unchanged.
- Two devices: per-field last-writer-wins; an edit on one device and a payment refresh on the other merge field by field.

## 7. App
- **Plan › Expected bills:** each bill shows its period ("every week", "every 3 months", "yearly"), range ("40–70 €, sets aside 70 €"), "3 of 12 left" for instalments, "60 of 100 € paid" while in parts, and "held in full until paid" for a long bill.
- **Add bill** (button in Expected bills): name, main tag, amount or "amount changes" (from–to), how often (Weekly / Every 2 weeks / Monthly / Every 3 months / Yearly), first due date, optional payee (picked from payees in history), optional "Instalments: N payments".
- **Edit** on every bill (same sheet), **Mark paid** when a cycle is in parts or the bill has no payee.
- **Today bills line:** includes held long bills ("Car insurance 600 € held until paid").
- **Bill history:** per-cycle lines for non-monthly bills; parts listed under a cycle.

## 8. Tests (synthetic payees only, e.g. zorblex)
- Detection: each class found at its minimum rows and lookback, not one row fewer; mixed gaps not detected; monthly identity (existing habits tests pass unchanged); a manual bill's payee not detected.
- Ranges: inclusive bounds; invalid stored range ignored; reserve = max.
- Parts: 60 + 40 pays a 100 € cycle; 60 alone reserves 40; a part before `lastPaidTx` never counted twice; another payee's row never counted; parts outside the window ignored; refresh anchors to `nextDue + interval`.
- Money: weekly bill reserves each occurrence before payday; yearly bill held in full from confirmation, also when due in 10 months; long bill in a fixed category still reserved; finished instalment reserves nothing; a slip covering a cycle not reserved twice.
- addRecurring/updateRecurring validation, ids, no-payee bill never matches, instalmentsLeft.
- Schema 11 → 12, backup round trip, two devices editing the same bill offline.
- Bill history per cycle for quarterly/yearly; monthly unchanged.
