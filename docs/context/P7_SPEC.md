# Stage P7 spec: Rules screen (2026-10-25)

Plan item: PATH_FORWARD P7 ("Rules screen: list, edit, delete; description-contains and amount-range conditions").

Owner rule: **never classify on amount alone.**
- Every rule must have a text condition: a payee, or the description contains some text, or a regex.
- An amount range only narrows a text rule. A rule with only an amount is refused.

## What exists today
Do not change how these are stored. Only add the new optional fields described below.
- **Payee rules** ("Always use this main tag for <payee>"): the synced `rule` entity, table `merchant_rules`, payee key → category. Written by `setMerchantRule`.
- **Pattern rules**: per-key settings `pattern:<16 hex>`, value `{category, pattern(regex), order}`. Written by `setMerchantPattern` / `removeMerchantPattern`.
- **Payee tag rules** (T1): the `ruletag` entity. Written by `setRuleTag`.
- **Built-in rules**: `builtInMerchantRules`, in code, read-only.

## Core changes (small)
1. **Text patterns without regex.**
   - The pattern value gains an optional `match`: `regex` (the default, so old rows read as before) or `contains` (case- and accent-folded substring, `foldText`).
   - `setMerchantPattern(category, pattern, {String match = 'regex', int? minCents, int? maxCents})`.
   - A `contains` pattern is 1–60 characters after trimming.
2. **Amount range** on a pattern: optional `minCents` / `maxCents`.
   - Both are compared against the absolute amount, inclusive, and the rule applies only when the text matches **and** the amount is in range.
   - `minCents <= maxCents`, both between 0 and `maxAmount`.
   - Validated in `WalletSettings.fromMap`. An invalid range drops only the range, never the rule, and logs `settings.invalid` with the key `merchantPatterns`.
   - Payee rules get no range in P7.
3. **Order.** `Categorizer` applies the rules in this order, which is unchanged except that the range is checked inside the pattern step:
   1. item override,
   2. transfer or kind hint,
   3. the payee rule,
   4. user patterns, by `order`,
   5. built-in patterns,
   6. fallback.
   With two user patterns, the first one that matches wins; a pattern whose text matches but whose range does not is skipped.
4. **Listing API (pure, for the screen):** `List<RuleView> rulesView(WalletSettings st, List<MerchantRule> payeeRules, Map<String, Set<String>> ruleTags, TagTable tags, CategoryTable table)`.
   - `RuleView { kind: payee|pattern|builtIn|payeeTags, id, text /* payee label or pattern */, match, minCents, maxCents, category?, tags, order, editable }`.
   - Sorted: payee rules by label, then patterns by `order`, then payee tag rules, then built-ins (read-only).
   - Labels go through the table.
5. **Rule hits (pure):** `Map<String, int> ruleHits(List<Tx> rows, Categorizer cz)`, counting live home-currency rows per rule id. It is used to show "used by N payments" and to preview an edit ("this rule would change N payments").
   - `Categorizer.ruleFor(Tx) → String?` gives the id of the rule that decided the row's main tag (`payee:<key>`, `pattern:<id>`, `builtIn:<n>`), or null.
6. **Edits:**
   - `updateMerchantPattern(id, {category, pattern, match, minCents, maxCents, clearRange})` keeps the row id when only the category or range changes. A text change is a new id (ids are a hash of the pattern), so the old row is removed and the new row takes the same `order`, in one write.
   - `movePattern(id, up|down)`.
   - The existing deletes stay.

## App: Plan › Rules
- **List of rules:** text, "→ main tag", `#tags`, a range like "12.00–30.00 €", and "used by N".
  - Built-in rules sit in a collapsed "Built in (read-only)" section.
- **Add rule:** what to match (the payee from a payment, or "description contains", or advanced regex), an optional amount range ("only when the amount is between"), the main tag, and optional tags (payee rules only).
  - Saving refuses a rule with only a range ("Add text to match: rules never use the amount alone.").
- **Before saving an edit**, show a preview: "This changes the main tag of N payments" (`ruleHits` before and after).
- **Edit, Delete (with Undo), and move up/down** for patterns.
- From a payment sheet, a link "Make a rule…" opens Add rule with the payee filled in.

## Tests
- `contains` with folding (č→c, case).
- The range is inclusive at both ends, and a range alone is refused.
- An invalid stored range drops only the range.
- Pattern order and first match; a range miss skips to the next rule.
- Old regex rows read unchanged (`match` missing = regex).
- A text edit keeps `order`; a category edit keeps the id.
- `ruleFor` / `ruleHits` counts, and the preview count.
- Two devices editing the same pattern offline: last writer wins on the per-key row.
- CSV and categorize results are unchanged when there are no new fields: the built-in identity test still passes.
