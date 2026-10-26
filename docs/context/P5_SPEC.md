# Stage P5 spec: new tabs (2026-10-26)

Plan item: PATH_FORWARD P5. Owner decisions (`NEXT_DECISIONS.md`): mockup approved 2026-10-26
(https://claude.ai/artifact/RQaEdzqDRhqBktTjW8oq8j); Settings two-pane on desktop (overnight answers).
UI only: no core API, schema or sync change. No new packages.

## Tabs
`Today · Budget · Bills · Save · Settings` (bottom bar on the phone, rail from 600 dp, same order and keyboard
shortcuts 1–5). Icons: `account_balance_wallet`, `bar_chart`, `receipt_long`, `savings`, `settings` (filled when
selected, outlined otherwise). Search and the period chip stay in the app bar on every tab.

- **Today:** unchanged content. Every link that opened Plan › Bills / Plan › Expected bills now opens the Bills tab;
  links to the payday plan open Budget; links to other Plan sections open that Settings section.
- **Budget:** the payday plan panel moved from Plan (heading "Planning on X a month", the ledger rows incl. the loan
  "payments left" line, Edit plan, the "Looks right?" first-import panel) on top, then everything from today's
  Spending tab in its current order (budgets, where it goes, saved or lost per pay period, payments, Insights).
- **Bills:** "Coming up" (bills before payday, with what each sets aside), "To review" (slips), then the expected bills
  list (moved from Plan › Expected bills, all actions unchanged) and the slips list (moved from Plan › Bills), with
  **Scan bill** (where there is a camera) and **Add bill** buttons. Empty state says how bills get here.
- **Save:** Goals panel first, then Wishlist (today's two tabs, content unchanged, one scroll). "Saved by waiting this
  pay period" line stays under the wishlist.
- **Settings:** every other Plan section, unchanged, in this order: Accounts, Main tags and tags, Rules, Expected
  income, Import, Sync, Backup and export, Calendars and reminders, Look, Diagnostics (plus any existing section not
  named here; nothing is dropped). As built: Budgets per category sits after Rules and Month after Calendars and
  reminders (lead, 2026-10-26: grouped by topic). Phone: one page. **From 1040 dp: two panes** — section list on the
  left (title + one-line sub as in the mockup), the chosen section on the right; first section selected by default;
  a link to a section selects it.

## Rules
- Behaviour of every moved section is unchanged; keep existing widget keys so tests keep finding them. Old tab keys
  are replaced by `tab:today|budget|bills|save|settings`.
- Deep links (`openPlan(section)` and the like) map to the new tab + section; nothing points at a removed tab.
- Layout at 320 dp, text scale 2.0, dark, 600 and 1040 dp; no overflows.
- Update `app/integration_test/screens_test.dart` (one screenshot per new tab, plus Settings two-pane on desktop) and
  the desktop/layout tests.

## Tests
- Each tab shows its panels; Budget shows the payday plan above budgets; Save shows goals above wishlist.
- Today's "Due by payday" and "N bills to review" open the Bills tab; the payday link opens Budget.
- Settings: phone = one scroll with all sections; 1040 dp = two panes, tapping a section shows it, deep link selects it.
- Keyboard 1–5 switch tabs on desktop.
