# Stage P9 spec: recurring income (2026-10-25)

Plan item: PATH_FORWARD P9 ("Recurring income entries feeding the payday plan"). Owner decisions in `NEXT_DECISIONS.md`.

## Owner decisions
- An expected extra income (side job, rent received, allowance) is **shown as expected** in the payday plan and counts toward safe-to-spend **only once the money lands**. Never before.
- The pay period stays monthly (no biweekly periods).
- Detected like recurring bills: suggested, used only after the owner confirms.

Rules that stay: exact cents; never classify or match on amount alone (payee key required); one-off extras keep going to goals as today (decision 2026-10-16): only rows that pay a **confirmed recurring income** are added to the spending money; a wallet without recurring income gives identical numbers.

## 1. Model (schema 14)
- `recurring` gains `direction` text column, nullable: `null`/`out` = a bill (everything as today), `in` = an income. Entity def, `sim.dart`, `schema_test` oracle, `schemaVersion` 14.
- `RecurringBill.isIncome` (`direction == 'in'`). For an income, `expectedAmount` is the positive cents expected in; ranges allowed (they only narrow matching); no instalments, no parts, no `isLong` hold (nothing is reserved for income).
- An income's category must be live and of kind **extra** (a salary-kind category already counts as salary: refused with "This tag already counts as salary."). A **payee is required** for an income (that is what matches the landed money).

## 2. Detection (`detectRecurring`)
- Same period classes, lookbacks, row minimums and 10 % band as bills, on **inflows**: live, not manual, `amount > 0`, kind **extra**, not transfer, same currency. Candidates get `direction: 'in'`, id `recin:<payee>` (so a payee can have both a bill and an income).
- Bills detection unchanged (outflows only).

## 3. Landing (`planRecurringPayments`)
- For an income the sign flips: a positive row of the payee within tolerance of `nextDue`, amount in band/range. `refreshRecurring` moves `nextDue` on exactly as for bills.

## 4. Money (`computePeriod`)
- New `PeriodBudget` fields:
  - `List<IncomeCycle> expectedIncome` — confirmed incomes with a cycle due in `[start, end)` not landed yet (`IncomeCycle {bill, due, amount}`, amount = `expectedAmount`, or the range's **low** end). Shown only; **never added**.
  - `int landedIncome` — Σ of the period's rows (in `[start, lastDay]`, home currency, kind extra, positive, live) whose `merchantKey` is the payee of a **confirmed** income. These rows are added to the money for spending: `flexBudget += landedIncome`. The actual landed amount counts (not the expected one).
- `extras` (all extra rows) stays as it is for goals and history, but excludes nothing; the goals flow must not count `landedIncome` twice — check how `extras` is used (the payday "put extras into goals" path) and exclude rows counted in `landedIncome` there.
- Identity: no confirmed income → every number as today.

## 5. Repo API
- `addRecurring(..., String direction = 'out')`: for `in`, payee required, category kind extra, no instalments; same validation otherwise.
- `updateRecurring` keeps the direction (not editable).
- `confirmRecurring`/`dismissRecurring`/`deleteRecurring`/`skipRecurring` unchanged.

## 6. App
- **Plan › Expected income** panel (next to Expected bills, same look): candidates ("Looks like regular income": Confirm / Not regular), confirmed incomes with period, amount or range, next date, Edit, Delete with Undo, Add income (the recurring sheet with "Income" mode: payee required, main tags of kind extra only).
- **Payday plan ledger:** a line "Extra income received +300 €" (landedIncome, when > 0) adding to Spending money, and under it "Expected, not counted yet: Side job 300 € on 20 Nov" for each `expectedIncome`.
- **Today:** "Expected income: 300 € by 20 Nov (counts when it lands)" line when there is any; nothing changes in the hero until it lands.
- Keys: `addIncome`, `incomeSheet` (or the recurring sheet in income mode), `expectedIncomePanel`, `ledgerLandedIncome`, `ledgerExpectedIncome`.

## 7. Tests (synthetic)
- Detection of monthly/weekly inflows of kind extra; salary-kind and transfer inflows not detected; bills detection unchanged; a payee with both a bill and an income.
- computePeriod: expected income before landing → flexBudget unchanged; after landing → +actual amount; a landed row of another payee or an unconfirmed income → not counted; foreign currency not counted; a row landing after payday counts in the next period; not counted twice with the goals/extras path.
- addRecurring income validation (payee required, kind extra, salary kind refused, no instalments).
- Schema 13 → 14; two devices confirm/dismiss; backup round trip.
