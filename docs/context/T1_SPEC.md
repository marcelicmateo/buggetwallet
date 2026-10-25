# Stage T1 spec: tags (2026-10-25)

## Owner decisions (2026-10-25)
- **One main tag and any number of extra tags.**
  - Everything is called a tag in the UI.
  - The **main tag** is today's category: built-in or your own top-level category. It decides the kind (fixed / flex / income / extra / transfer) and counts once in safe-to-spend, budgets, the plan and the CSV. The money engine is unchanged.
  - **Extra tags** are for tracking. A payment can have any number of them, so their totals overlap, and the UI says so.
  - The suggested top 20 tags are today's 20 categories (main tags). There is room for any number more.
  - Tags are listed in recommended order, and the owner can add their own.
- **Subcategories are replaced by tags.** No released build has P1, so no real data has subcategories.
  - New writes refuse `parent`, and the `parent` column stays in the schema, unused.
  - Plan lines for your own fixed main tags stay.
- **The app tags by itself in three ways:**
  1. The main tag is picked as today (bank hint, then merchant rules, then patterns; never by amount).
  2. Merchant rules can also add extra tags.
  3. Extra tags you often use with a payee are suggested, never applied, until you tap them.

## 1. Core model (schema 11)
- **`tag` entity**, table `tags`:

  | column | kind | notes |
  |---|---|---|
  | `name` | text, searchable | 1–40 chars, trimmed |
  | `position` | integer, nullable | |
  | `hidden` | flag | |
  | `deleted` | flag | |

  - The id is `t` followed by 12 random hex characters.
  - A name must be unique (compared with `foldText`) among live tags, and must not equal the label of a live main tag; otherwise `ArgumentError`.
  - Two devices that add the same name offline make sync duplicates. They are handled like P1's: the smallest id wins, and `duplicateOf` marks the others. Reads merge a duplicate into its original, so its rows count under the original and never twice.
  - At most 500 live tags.
- **`txtag` entity** (link), table `tx_tags`, with fields `tx`, `tag` and `state`:
  - `state` is `on` (the owner added it) or `off` (the owner removed it, overriding a rule).
  - The id is `<txId>|<tagId>`, the same on every device, so edits merge per link by last-writer-wins.
  - Deleting a link means writing `state: off`; nothing is ever really deleted.
- **`ruletag` entity**, table `rule_tags`: `payee` (the `merchantKey`), `tag`, `deleted`.
  - The id is `<payee>|<tagId>`.
  - A rule tag applies to every row of that payee.

## 2. Effective tags (pure, read time, nothing written on import)
`TagTable.from(tagRows)`, like `CategoryTable`, with `label`, `isLive`, `duplicateOf`, `pickable()` and `resolve(id)` (a duplicate maps to its original).

`List<String> tagsOf(Tx t, {required TagTable tags, required Map<String, Set<String>> ruleTags, required Map<String, Map<String, bool>> links})`
- The result is (the live rule tags for `merchantKey(t)`, plus the links in state `on`) minus the links in state `off`.
- Tags are resolved through duplicates, and dead tags are dropped.
- Order: the order of `pickable`.
- `CategorizedTx` gets a `tags` field: an unmodifiable list, empty by default. `WalletRepo.categorize` / the app fill it from one read of the three tables, never per row.

## 3. Suggestions and order (pure)
`List<String> suggestTags(Tx t, List<CategorizedTx> history, TagTable tags, {int limit = 5})`
- Suggests tags used on at least 2 other live rows of the same payee, that are not already on this row and not turned `off` on it.
- Ordered by count, then the most recent use, then the label.

`List<String> recommendedMainTags(Tx t, List<CategorizedTx> history, CategoryTable table, {Set<BudgetKind>? kinds})`
- The main tags: built-in and your own, pickable ones only.
- Order: first those used with this payee, by count; then by how often they are used overall; then the table order.
- `List<String> recommendedTags(...)` gives the same order for extra tags.

## 4. Totals and drill-down (pure, `insights.dart`)
- `TagShare tagShare(txs, DateRange r, {required String currency})` gives `List<TagSlice{tag, spent, count}>`. Spending counts the same as "Where it goes" (`countsAsSpending`), per tag. Totals **overlap**, so there is no permille. `untaggedSpent` is the spending that has no extra tag.
- `rowsForTag(tag, txs, r, {required currency})` returns the rows newest first; their sum equals `-spent` for that tag.
- `tagTrend(tag, txs, r, {required today, required currency})` returns `MonthBar`s.
- `spendingByMonth`, `categoryShare` and all budget maths stay unchanged and ignore tags.

## 5. Repo API (`repo_tags.dart`), all through `_write`, logs with counts only
- `addTag(name)`, `updateTag(id, {name, position, hidden})`, `deleteTag(id)` and `undeleteTag(id)`.
- `tags({includeDeleted})` and `tagTable()`.
- `setTxTag(txId, tagId, bool on)`. It writes the link's state. Writing `on` for a tag that a rule already gives is a no-op, unless the link was `off` before.
- `setRuleTag(payee, tagId, bool on)` and `ruleTags()`.
- `searchAll(..., tags:)` matches a tag label against a row's tags.
- `transactionsCsv(..., tags:)` adds a `tags` column (labels joined with `; `). It comes after `category`, which stays the main tag's label.

## 6. P1 clean-up
- `addCategory`/`updateCategory` refuse `parent` (ArgumentError: "Use a tag for this.").
- `CategoryTable` ignores stored parents: every row is top-level. That way any test or dev data with children still sums correctly, because each child becomes its own main tag.
- `rollUp` and `childrenOf` stay, but now always return the row's own id or nothing.
- Update the P1 tests that pinned subcategories, and remove or adapt the subcategory parts of the app and tests.

## 7. Tests (synthetic)
- Name rules: 40/41 characters, case and accents, a clash with a main-tag label, the 500 limit.
- Duplicates after sync merge into one tag in totals.
- `tagsOf`:
  - a rule tag appears on every row of the payee;
  - an `off` link removes it from one row only;
  - `on` then `off` then `on` again;
  - a deleted tag disappears, and comes back after undelete;
  - two devices editing the same link offline: the later write wins.
- `suggestTags`: the ≥ 2 threshold, its ordering, and excluding tags already on the row or turned off.
- `recommendedMainTags`: payee first.
- `tagShare` sums per tag equal `rowsForTag`, and `untaggedSpent` is right.
- Foreign-currency, transfer and income rows are not counted as spending.
- CSV `tags` column; search by tag.
- Schema 10 → 11, backup round trip, a late third device.
- P1 clean-up: `parent` refused; an old child row counts as its own main tag.
