# Stage P1 spec: your own categories and subcategories (2026-10-25)

Owner notes:
- Spending needs more categories, so more can be concluded from the data.
- D12: drill-down first (done in N3), then subcategories.
- Plan item: PATH_FORWARD P1.

Rules:
- Exact cents.
- Never reclassify on amount alone.
- Nothing in existing data is rewritten.
- The built-in names stay as they are (v1 and existing rows use them).

## 1. Model
- **Built-in categories:** the 20 in `categories.dart`, unchanged.
  - Their id is their name, e.g. `Groceries`.
  - They cannot be deleted, but can be **hidden** (not offered in pickers; existing rows still show them).
  - They can be **relabelled**; the id stays the same.
- **Custom categories:** a new synced entity `category`, table `categories`, schema 10.

  | column | kind | notes |
  |---|---|---|
  | `name` | text, searchable | label, trimmed, 1–40 chars |
  | `kind` | text | `income` / `extra` / `fixed` / `flex` / `transfer` (`BudgetKind.name`) |
  | `parent` | text, nullable | id of a top-level category (built-in or custom) |
  | `position` | integer | sort order among siblings, ≥ 0 |
  | `hidden` | flag | |
  | `deleted` | flag | |

  - The id is `k` + 12 random hex characters (`_newId('k')`).
  - A row whose id is a **built-in name** is an *override* of that built-in. It may set `name` (label), `hidden` and `position` only. Its `kind` and `parent` are ignored, and it cannot be deleted (`deleted` ignored).
- **Subcategories:**
  - One level only: a parent must be a live top-level category.
  - A child's `kind` must equal its parent's kind. This is checked on every write, and the effective kind is read from the parent, so sync can never split them.
  - A category that has live children cannot get a parent.
- **Limits:** at most 200 custom rows. A live top-level label must be unique against all other live top-level labels, built-in labels included; a child's label must be unique among its siblings. Uniqueness compares `foldText` (case and accents ignored).

## 2. `CategoryTable` (pure, `categories.dart`)
`CategoryTable.from(List<CategoryRow> rows)`. With no rows, `CategoryTable.builtIn` gives today's behaviour exactly.
- `String label(String id)`: the label. An unknown id returns the id itself.
- `BudgetKind kindOf(String id)`: built-in kind, custom kind, or the parent's kind for a child. Unknown → flex (as today).
- `String? parentOf(String id)`, and `String topLevel(String id)`: the parent, or itself.
- `List<String> childrenOf(String id)`: live children, by position then label.
- `bool isLive(String id)`: built-in, or a custom row that is not deleted.
- `List<String> pickable({Set<BudgetKind>? kinds})`: live and not hidden, top-level then their children, in order. This replaces the hand lists in the app's pickers.
- `List<String> spending`: live fixed + flex top-level ids, in order. It replaces `spendingCategories` in budgets and the CSV header; children roll up into their parent there.
- `bool isSpending(String id)`.
- `WalletRepo.categoryTable()` reads the rows. `WalletRepo.categorizer()` passes the table to `Categorizer`.

The existing globals (`categories`, `spendingCategories`, `flexCategories`, `kindOf`, `isSpendingCategory`) stay for code that knows only built-ins. **Every caller that can meet a custom id must switch to the table**, including:
- `Categorizer` (keep an override whose id `isLive`);
- `WalletSettings` budget validation and `setCategoryBudget`;
- `setMerchantPattern`;
- `monthlySummaryCsv`;
- `suggestBill­Category`;
- `Bill`/`RecurringBill.coveredByPlan` (via the table's kind);
- planned costs.

## 3. Rows that point at a deleted or unknown category
- When a tx override, bill category or merchant pattern points at a custom id that is deleted or unknown, the override is ignored. The row resolves as if there were no override: rules, then hint, then the fallback.
- Nothing is written to the row, so an undelete brings it back.
- This applies on every device, whatever the sync order.

## 4. Totals with subcategories
- `CategorizedTx.category` stays the row's own id; a child stays a child.
- New pure helper `rollUp(Map<String,int> byCategory, CategoryTable t) → Map<String,int>`, which sums children into their `topLevel`.
- Use it in budget-vs-actual (budgets are set on top-level only; `setCategoryBudget` refuses a child id) and in the CSV monthly summary.
- `monthSummary.byCategory` stays per row id, so drill-down can show children. `categoryShare` gets an optional `rollUp: true`.
- Exact sums: the rolled-up total always equals the sum of its children plus its own rows.

## 5. Repo API (`repo_categories.dart`)
All writes go through `_write`, and logs record counts and kinds only, never labels.
- `Future<String> addCategory({required String name, required BudgetKind kind, String? parent})`
- `Future<void> updateCategory(String id, {String? name, int? position, bool? hidden, String? parent, bool clearParent = false})`: works on a built-in id too, for an override (name/hidden/position only).
- `Future<void> deleteCategory(String id)`: custom only. Refused while it has live children; the owner moves or deletes them first.
- `Future<void> undeleteCategory(String id)`
- `List<CategoryRow> categoryRows({bool includeDeleted = false})`
- `ArgumentError` with an owner-readable message for every rule in §1.

## 6. Schema 10
- `entitySchema['category']`, `sim.dart` `entityTables`, the `schema_test` oracle, the `isEmpty` doc.
- No data migration.
- Old fixtures (schema 7) still open.
- Two-device sync tests:
  - the same label added offline on both devices: both rows survive, and the later one is marked by `CategoryTable` as `duplicateOf` (like accounts) and not offered in pickers;
  - a parent deleted on one device while a child is added on the other: the child is treated as top-level, with its own kind, until fixed. Picker and totals then roll it up nowhere.

## 7. Tests (synthetic)
- `CategoryTable.builtIn` gives byte-identical results to today for `monthSummary`, `budgetVsActual`, CSV and `categoryShare` over the existing synthetic months.
- Labels, hide and relabel of built-ins.
- Child kind follows the parent.
- One level only.
- Uniqueness (case and accents).
- The 200 limit.
- An override pointing at a deleted custom id falls back, and comes back after undelete.
- A budget on a child is refused.
- `rollUp` sums exactly.
- CSV header with custom top-level categories.
- Merchant pattern to a custom category.
- Sync duplicates.
- Backup round-trip.
- Schema 9 → 10.
