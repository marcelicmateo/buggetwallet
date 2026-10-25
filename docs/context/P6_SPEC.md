# Stage P6 spec: split transactions (2026-10-25)

Plan item: PATH_FORWARD P6 ("Split transactions, sums checked").

## Owner decisions (2026-10-25)
- **Parts must add up before saving.** Save is refused until the parts sum to exactly the payment's amount.
- **Each part has** an amount, a main tag (category), extra tags and a note. It is tracked like its own payment.
- **Spending list:** one row per payment with a "split" mark and the parts underneath; category, tag and insight views and every total use the parts.
- **Bank and hand-added payments** (expenses and income) can be split. Transfers cannot.

Rules: exact cents; never classify on amount alone; nothing in existing data is rewritten; a wallet without splits gives byte-identical results everywhere (identity tests).

## 1. Model (schema 13)
New synced entity **`split`**, table `tx_splits`, **id = the tx id** (one split per payment):

| column | kind | notes |
|---|---|---|
| `parts` | text | JSON list of `{a: cents, c: category id, t: [tag ids], n: note?}` |
| `deleted` | flag | removing a split = `deleted: 1` |

- The whole split is **one field**, so last-writer-wins always keeps a consistent set of parts (two devices editing offline: the later split wins whole; never a mix).
- Entity def, `sim.dart` `entityTables`, `schema_test` oracle, `schemaVersion` 13, the synced-entities list for backup; no data migration.

```dart
class SplitPart { final int amount; final String category; final List<String> tags; final String? note; }
```

## 2. Validation (on write: `ArgumentError`, owner-readable)
- 2..20 parts; every amount non-zero and of the payment's sign; Σ amounts == the payment's amount exactly.
- Category: live and not of kind transfer. Tags: live tag ids (resolved through duplicates), no repeats, at most 20 per part. Note ≤ 200 chars, trimmed, empty = null.
- The payment exists, is live, is not a transfer (`transferTo` set or its category is a transfer), and its currency is any (a part is in the payment's currency).

## 3. Read time (pure; nothing written)
- `Categorizer.expand(Tx t) → List<CategorizedTx>`: the payment alone (as `categorize`) when it has no live split; else one `CategorizedTx` per part, in stored order.
- A stored split that **no longer adds up** (a hand-added amount was edited; a synced split arrived for a changed row) or is unreadable is **ignored**: the payment counts whole and is marked `splitBroken`. A part whose category is no longer live falls back to the payment's own automatic category (like an override, P1 §3); a dead tag is dropped.
- `CategorizedTx` gains: `int amount` (the part's amount; the payment's amount when not split — keep the getter name), `int? part` (0-based index), `int parts` (count, 0 when not split), `String? partNote`, `bool splitBroken`. `tx` stays the payment. Part tags are the part's own list only (payee rule tags and the payment's own tag links do not apply to parts; the split editor pre-fills them).
- **A hand-added expense matched to a bank row:** the split follows the entry onto the bank row the same way T1's tags do (read the T1 code and do the same: copy on match, or read through `matchedTo`); state which in the report.
- `WalletRepo.categorizer()` loads the live splits once (like the tag context), never per row.

## 4. Who sees parts and who sees whole payments
- **Money by category / tag / kind uses parts** (iterate the expanded list): `computePeriod`, `monthSummary`, budgets (`budgetVsActual*`, `averageByCategory`, `suggestBudgets`, `reviewState`), insights (`spendingByMonth`, `categoryShare`, `incomeVsSpending`, `merchantsIn`, `rowsFor`, `merchantTrend`, `compareCategory`, `biggestRows`, `tagShare`, `rowsForTag`, `tagTrend`), ranges, `periodSummaries`, `suggestPlan`, `monthlySummaryCsv`.
  - Every `.tx.amount` inside these must become `.amount` (grep them all); totals must equal the expanded sum, and with no splits stay identical.
- **Picking or detecting a payment uses whole payments** (`categorize`, one row per payment): matching, transfers, `planBillLinks`, `billCandidates`, `paidCandidates`, `detectRecurring`, `planRecurringPayments`, `billHistory`, `salaryPaydays`/`detectPaydays`, `accountBalances`, `ruleHits`, `suggestTags`/`recommended*` history.
- `transactionsCsv`: one line per part (same id + `#<n>` with n from 1, the part's amount, main tag, tags, note); an unsplit payment as today.
- `searchAll`: a part's note and tags match; the result is the whole payment once (with the matching part known).

## 5. Repo API (`repo_splits.dart`, through `_write`, logs counts only)
- `void setSplit(String txId, List<SplitPart> parts)` (replaces the whole split; also undeletes).
- `void removeSplit(String txId)`.
- `List<SplitPart>? splitOf(String txId)` (live, valid or not) and `Map<String, List<SplitPart>> splits()`.
- `deleteTransaction` leaves the split row alone (an undelete brings it back).

## 6. App
- **Payment sheet:** "Split" opens the split editor: rows of amount + main tag picker + tags + note; "Add part"; a running "Left to split: 12.40 €" line; **Save disabled until it is 0.00** (and shows why); "Remove split" with Undo. Editing an existing split pre-fills it.
- First open pre-fills two parts: the whole amount on the payment's main tag with its tags, and an empty second part.
- **Spending list:** one tile per payment with a "Split · 3" mark; the parts listed under it (indented, amount + main tag). Category / tag / insight detail lists show the parts, each with "part of <amount> <payee>".
- A broken split shows "Split doesn't add up" on the payment with a button to fix it.
- Keys: `ValueKey('splitOpen')`, `ValueKey('splitSheet')`, `ValueKey('splitAddPart')`, `ValueKey('splitLeft')`, `ValueKey('splitSave')`, `ValueKey('splitRemove')`, `ValueKey('splitPart:<n>')`.

## 7. Tests (synthetic)
- Validation: each rule, boundaries (2 and 20 parts, 21; one cent short and over; sign; transfer; dead category/tag; note 200/201).
- Identity: no splits → `monthSummary`, budgets, CSV, insights, computePeriod byte-identical.
- With a split: totals per category/tag equal the parts; the payment is never counted with its parts; safe-to-spend uses parts (part in Rent counts as fixed, part in Groceries as flex).
- Broken split (amount edited) → counted whole, `splitBroken`; dead category part falls back.
- Whole-payment paths unaffected: matching, recurring detection, bill candidates, account balances, transfers.
- Manual entry with a split matched to a bank row keeps the split.
- CSV one line per part; search by part note.
- Two devices: both split the same payment offline → one whole split wins; split vs remove; split vs a hand-added amount edit → broken, counted whole.
- Schema 12 → 13, backup round trip.
