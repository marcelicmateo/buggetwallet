# Stage N4 spec: a monthly bill lists its bills (2026-10-25)

Owner decision D10: both. A confirmed recurring bill lists its stored slips (bills database) **and** its paying bank rows, one line per month.
Matching uses the payee key and exact evidence only, never the amount alone.

## Core (pure, `recurring.dart` or a new `bill_history.dart`)
`List<BillMonth> billHistory(RecurringBill bill, List<Tx> rows, List<Bill> slips, {required String today, int months = 12, required String currency})`.

`BillMonth { String month /*YYYY-MM*/; List<Tx> payments; List<Bill> slips; int paid; int? billed; BillMonthState state; }`.
- `month`: one line per calendar month, from the newest month that has a payment or slip back `months` months. The current month is included. Months with neither are included between the first and the newest, so gaps are visible.
- `payments`: live bank rows (not manual, not transfers, home currency) whose `merchantKey` equals `bill.payee`, dated in that month, plus the row in `bill.lastPaidTx`. These are the same rows that `planRecurringPayments`/`detectRecurring` accept for the payee. The amount is never used to pick a row.
- `slips`: live stored bills where `billPayeeKey(slip) == bill.payee`, dated in that month. Use the slip's own date (issue date, or due date when there is no issue date; follow the existing `Bill` fields), or a slip linked (`linked_tx`) to one of this month's payments.
  - A slip linked to a payment always goes in that payment's month.
  - A slip whose payee key differs is never listed, even when its amount equals a payment's.
- `paid` = the sum of −amount over `payments`, exact cents.
- `billed` = the sum of the slip totals, or null when the month has no slip with a total.
- `state`:
  - `paid`: there is a payment;
  - `slipOnly`: a slip, no payment;
  - `missing`: neither, and the month is before the current month while the bill was confirmed;
  - `upcoming`: the current month with no payment yet.
- Sorting: newest month first. Within a month, payments by date then id, and slips by date then id.

Reuse `billPayeeKey`, `merchantKey`, `Bill` and `RecurringBill` as they are. Find the existing names in `recurring.dart`, `bills.dart` and `models.dart`. Where this spec names a field differently from the code, follow the code and say so.

## App
In Plan › Expected bills, each confirmed bill opens a "History" view (a sheet or page):
- one line per month: month, state word, paid (exact) and billed when known;
- the month expands to the payment rows (they open the existing transaction sheet) and the slips (they open the existing bill sheet);
- a "Missing" month is marked plainly, with no amount guessed.

## Tests
Use synthetic data:
- a month with payment and slip;
- a slip only;
- a payment only;
- a missing month in the middle;
- the current month upcoming;
- a slip linked to a payment in another month, which is listed in the payment's month;
- a slip with another payee and the same amount, which is not listed;
- foreign-currency payments, which are left out;
- deleted rows and slips;
- manual rows;
- an own-transfer row;
- the 12-month limit;
- ordering.
