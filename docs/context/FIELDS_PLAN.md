# Field refactor — adding a field should be one line (owner 2026-11-01)

Owner: "software design must be easily extendable and this kind of addition should take one line in code."

## Where we are (traced on `warrantyUntil`, v2 39177fc)
Storage is already declarative: `packages/wallet_core/lib/src/schema.dart` `entitySchema` (19 entities) generates the
`CREATE TABLE`, the add-column migration, the type check of incoming sync ops, the snapshot/backup writer, `isEmpty`
and search. One `ColumnDef` line covers all of that. What is still hand-written, per field:

| Place | Example for `warranty_until` | Lines |
|---|---|---|
| Model field + constructor param + `fromRow` mapping | `bills.dart:67, 93, 137` | 3 |
| Update method: param, clear flag, validation, map entry | `repo_bills.dart:145, 148, 151, 169` | 4 |
| `WalletRepo.schemaVersion` bump + `test/fixtures/schema/vNN.sql` | `repo.dart:184` | 2 |
| Controller pass-through | `controller_bills.dart:424-433` | 3–5 |
| Form widget, label, save wiring | `bill_sheet.dart`, `bill_sheet_sections.dart` | 10–30 |
| Conflict text label (sync conflicts screen) | `conflict_text.dart` | 1 |

So a new bill field costs ~25–45 lines in 7–8 files, most of them in the app's form and the update method's
`clearX` flags.

## Target: one declaration per field
```dart
// packages/wallet_core/lib/src/fields.dart (new)
abstract final class BillF {
  static const warrantyUntil = DateField('warranty_until', label: 'Warranty until');
  static const returnBy = DateField('return_by', label: 'Return by');
  static const returnReminderDays = IntField('return_reminder_days', label: 'Reminder', min: 0, max: 30, unit: 'days before');
  static const all = <Field>[..., warrantyUntil, returnBy, returnReminderDays];
}
```
- **`Field<T>`** (sealed: `TextField`, `DateField`, `IntField`, `MoneyField(currencyFrom:)`, `FlagField`, `EnumField<E>`,
  `RefField(entity)`) carries: column name, Dart type, nullable/default, validation (ISO date, range, enum wire names,
  ref exists), searchable, and UI metadata (label, unit, editor hint). `ColumnDef` is derived from it, so
  `entitySchema` is built from the field lists — **one line adds a synced, migrated, validated, searchable column**.
- **Models read through fields:** `class Bill extends Row` keeps the row map; typed getters stay where code reads them
  (`String? get warrantyUntil => BillF.warrantyUntil.of(this)`), and generic code can read any field with
  `bill[BillF.x]`. `fromRow` boilerplate goes away.
- **One generic write:** `repo.patch(BillF.entity, id, {BillF.warrantyUntil: '2027-05-01', BillF.returnBy: Field.clear})`
  validates every value by its field, writes through `_write` (same sync ops, same HLC per field), and refuses with an
  `ArgumentError` naming the field. Business methods (`markPaid`, `confirmSuggestion`…) stay as they are; plain
  "set this property" methods like `updateBill`'s date/reminder part become one-line wrappers or disappear. The
  `clearX` flags go away (`Field.clear`).
- **One generic editor in the app:** `FieldEditor(field, value, onSave)` renders by field type (date → calendar + length
  chips from UX-A, int → stepper with unit, enum → choice chips, money → amount field in the row's currency, text) and
  shows the field's own refusal message. A sheet lists its fields: `for (final f in [BillF.warrantyUntil, BillF.returnBy]) FieldEditor(...)`
  — **adding the field to that list is the one line that puts it on screen**. Conflict text reads `field.label`.
- **Schema version:** still bumped by hand when a column is added (older peers must replay ops), but checked by a test
  that fails when `entitySchema` changes without a bump and a new `vNN.sql` fixture (so it cannot be forgotten).

## What does not change
Wire format and sync semantics (op = entity, id, field, value, HLC; per-field last-writer-wins): the refactor is internal,
needs **no schema bump of its own**, and an old and a new build sync with each other. `test/support/sim.dart` stays an
independent oracle (it must not be generated from the same declarations, or it would test nothing).

## Stages
| # | Item | Agent (model/effort) | Worktree | Depends on | Output |
|---|---|---|---|---|---|
| F0 | Context pack: every model's `fromRow`, update methods, app forms per entity | scout (haiku/low) | no | UX-A-core merged | pack for F1 |
| F1-core | `Field` types, `entitySchema` from fields, `Row` base, `repo.patch` + `Field.clear`; pilot **Bill + Account** (the two UX-A just changed); schema-bump guard test | core-builder (Opus/high) | yes | F0 | API + tests, no wire change |
| F1-tests | Wire-compat tests: ops written by old and new code for the same edits are identical; patch refusals per field type | test-writer (sonnet/medium) | yes | F0, parallel to F1-core | tests from this spec |
| F1-ui | `FieldEditor` (date/int/enum/money/text), bill sheet and account form built from field lists | ui-builder (sonnet/high) | yes | F0, parallel to F1-core (API fixed here) | UI + widget tests |
| F1-review | Reviewer on the merged pilot (sync safety, money fields, refusals shown) | reviewer (Opus/high) | no | F1 merged | findings → same builders |
| F2 | Roll out to the other 17 entities, a few per commit (tx, planned, goal, wish, iou… — highest-churn first) | core-builder + ui-builder | yes | F1 green | each entity's `fromRow`/update boilerplate gone |
| Run | Full stage run (test, desktop, perf) | watcher (haiku/low) | no | each of F1, F2 | pass/fail list |

Order with Stage UX: **UX-A → F1 → UX-B → F2 → UX-C2.** F1 goes before UX-B because UX-B's Plan window edits income,
plan lines and budgets in place — built on `FieldEditor` it gets inline editing everywhere for free instead of three
more hand-made forms. F2 runs after UX-B so the two don't fight over the same screens.

Done when: adding a synced, validated, editable bill field is **one `Field` line in `BillF` + one line in the sheet's
field list + the schema bump the guard test asks for**, shown by a test that adds a throwaway field in a test-only entity.
