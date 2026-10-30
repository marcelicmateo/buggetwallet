# RX1 — Dashboard redesign: concept (2026-10-30)

Owner: "too much text; we track simple numbered data, so it should look like a dashboard, and we need more dashboards."
Rules kept: one label per thing (no note restating a title), short plain text, one add button (Today's Add expense),
phone first, then Linux desktop, then web. No new data: everything below uses numbers wallet_core already computes,
except the few marked **new core** in §6. Net worth and investments stay out (owner).

Mockups: `index.html` in this folder (self-contained; only Google Fonts; synthetic numbers). Add `?d=a` or `?d=b` to the
URL to see one direction. Screenshots at 1280 wide: `ledger-board.png` (A), `paper-tiles.png` (B).

## 1. Research (patterns, not assets)
The Figma Community page is JS-only (WebFetch got HTTP 403), so I used the apps and free kits it points to. Nothing was
copied: no artwork, names or layouts.

| Source | What it shows |
|---|---|
| Copilot Money dashboard: https://intercom.help/copilotmoney/en/articles/6045480-dashboard-tab-overview | One headline ("Free to Spend") over a line chart with a dotted ideal pace; then stacked sections (To review, Budgets, Upcoming, Net this month vs last month to date), each with a "›" link to its full page |
| Monarch: https://www.monarchmoney.com/features/dashboard, https://help.monarch.com/hc/en-us/articles/360058127551-Customize-Your-Dashboard | Dashboard of widgets (budget, cash flow, goals, recent transactions); fixed vs flexible split of spending |
| Emma: https://emma-app.com/features/tracking/budgeting/, https://community.emma-app.com/t/safe-to-spend-feature/1377 | "Left to spend" = budget minus committed (bills) minus spent; daily allowance net of upcoming bills |
| PocketGuard: https://www.experian.com/blogs/ask-experian/pocketguard-budgeting-app-review/, https://pocketguard.com/news/stay-on-track-with-new-home-screen-widgets/ | One number ("In My Pocket" / Leftover) as the home screen and as a widget |
| Free Figma kits (roundups): https://speckyboy.com/free-admin-dashboard-templates-figma.md (BankDash free kit), https://forum.figma.com/showcase-your-work-14/introducing-mini-finance-ui-kit-for-figma-39716, https://line25.com/articles/free-figma-templates-ui-kits-2026/ (Untitled UI) | Card grid ("bento") with KPI cards: label, big number, delta badge (▲ 12 % vs last month), small sparkline; donut "expense statistics"; weekly activity bars; progress cards for goals |
| Tremor (free, open-source dashboard blocks): https://dev.to/0012303/tremor-has-a-free-dashboard-component-library-build-react-analytics-uis-in-minutes-3m0n | KPI card, BadgeDelta, CategoryBar (one segmented bar), BarList (ranked rows with bars), ProgressCircle, **Tracker** (a row of coloured squares, one per day: our day dots) |
| YNAB (general knowledge, not fetched) | Targets as progress bars per category; one "Ready to assign" number on top |

Patterns taken:
1. **One headline number** per screen, ≥ 48 px, with exactly one state chip under it.
2. **KPI tile** = label (1–3 words, sentence case, no colon) + value + optional delta ("▼ 4 % vs avg") + optional
   sparkline. Never a sentence.
3. **Bento grid**: 2 columns on a phone, 4 on desktop; a wide tile spans 2.
4. **Segment bar or donut** for "where the salary goes" (fixed / saved / spending) instead of a list with notes.
5. **Ranked bar list** for categories and shops; budget as a meter with an over-stretch.
6. **Day tracker / calendar heatmap**: one square per day (our DD day dots), also for past periods.
7. **Progress ring** for goals and for "how far through the period".
8. **Drill-in, not explain**: every tile is a link; the explanation lives on the page it opens (or behind ⓘ).
9. **Comparison deltas** only against a named base ("vs avg", "vs Aug"), arrow + word, colour by good/bad direction.

## 2. Numbers the app already computes (inventory)
- **Period (`computePeriod` → `PeriodBudget`)**: safe to spend today, allowance today/tomorrow, plan per day, flexible
  budget, spent, spent today, remaining, days left, elapsed share, over by / over today, payday passed, received,
  extras, income, goal monthly, fixed plan, fixed paid per line, reserved bills + due bills/cycles (held until paid),
  reserved planned costs, expected income cycles, landed income, other currencies.
- **Day dots (`periodDays`, DD, being built)**: per day of the current period: within / over / today / to come, with
  spent and allowance.
- **Plan**: ledger lines (salary, fixed lines, savings, goals), spending money, plan suggestions (`planProposals`),
  loan left (`loanLeft`: payments, cents, end month).
- **Budgets**: `budgetVsActual(month)` per category (budget, actual, 6-month average, elapsed days), tightest budget,
  suggested budgets, presets.
- **Insights**: spending by month, category share (and tag share), income vs spending, budget vs actual series,
  merchants per category, merchant trend, compare category (this / last month / 6-month avg), biggest payments.
- **Pay periods**: `periodSummaries` (in, out, by category), `periodReports` (fixed / flex split, net),
  `savingsOverview` (periods, saved count, net, savings rate), `trendNet` (3-period average), `categoryByPeriod`.
- **Bills**: expected bills and incomes, `billsCost` / recurring cost (per month, per year), `dueCycles`, parts paid,
  instalments left, `upcoming()` items (bills + planned costs with dates), `headsUps`, bills to review (slips).
- **Accounts**: balance per account, held totals per currency, bank checks, balance warnings, `forecastToPayday`
  (balance steps with causes).
- **Save**: goals (saved, target, monthly, finish month), wishlist (waiting / ready / bought / skipped, cooling hours),
  `affordability(price)` verdict + new daily, `savedByWaiting` (all time or a range), IOUs (`owedTotals`, open IOUs).
- **Habits**: review state (due, next review day, streak, steps), month summary, foreign-currency notes.

## 3. Shared information architecture (both directions)
- **Tab bar unchanged**: Today · Budget · Bills · Save · Settings (Ctrl+1..5, muscle memory, rail on desktop). Settings
  stays a list, not a dashboard.
- **Every tab opens on its dashboard**; each tile opens its detail (the current panels, unchanged in logic, become the
  drill-in pages: payday plan editor, Expected bills, Goals editor, Insights, category detail).
- **New dashboards**: Spending (Budget tab), Bills, Save, and the **Pay-period report** (new page: tap the period
  chip in the app bar / rail; ‹ › steps through past periods). Category/tag detail becomes a small dashboard too.
- **One label per thing across the app**: "Before payday" = bills + planned costs due before payday, the same number on
  Today, Bills and the plan line (today three different labels: "Due by payday", "Coming up", "Set aside for coming
  costs"). "Held" = money in accounts. "Kept" = net kept per period / savings rate.
- **State = icon + word + colour**: ✓ On pace / Paid, ▲ Over (red hatch), ⏱ date, 🔒 Held. Never colour alone.
- **Series colours** (validated with the dataviz palette checker, light and dark, all checks pass):
  flexible spending `#3a559e` / `#7088d6`, bills and fixed `#b0721a` / `#bd7f22`, saved and goals `#008f96` / `#1a9aa0`.
  Status colours (`bad`, `good`) stay reserved for state.
- **Money on tiles** uses the existing money formatter; rows in drill-ins keep exact cents (see open question 4).
- **Fit**: tiles/cells reflow to one column when a column would be under ~150 dp (320 dp at text scale 2.0); numbers
  scale down (`FittedBox`), never wrap; day dots move under the hero number (as DD already specifies).

## 4. Direction A — Ledger Board (stays close to Ledger)
Principles:
1. One number per cell; the label (mono eyebrow) says what it is in 1–3 words.
2. A ruled grid, not cards: hairlines split the page into cells like a ledger sheet; double rule under the hero only.
3. Paper and ink, Plex Mono figures, no radius, no shadows; colour only in marks (meters, bars, dots).
4. Every cell is a link; sentences live on the page it opens.
5. The first screen answers the tab's question; lists start below the fold.

Kit: `LedgerCell` (eyebrow + mono value + sub or meter or sparkline), `CellStrip` (3 cells), `CellGrid` (2×2), `PaceMeter`
(10 px ruled bar + pace tick), `SplitBar` (plan: fixed / saved / spending), `CategoryMeter` row (budget mark, hatched over),
`NetBars` (per pay period), `DayDots`, `DayStrip` (11-day bills strip, bar height = amount), `BarList`, `TxTile` (as now).

Navigation: unchanged; period chip → Pay-period report; Budget = plan split bar on top, then spending.

Identity: this *is* Ledger with less prose: same tokens, fonts, rules; the margin line stays on wide windows.

## 5. Direction B — Paper Tiles (moves further)
Principles:
1. Tiles, one job each: label + one number + at most one visual + at most one chip.
2. Bento grid: 2 columns on the phone, 4 on desktop; a hero tile spans 2 (2×2 on desktop); order is the same at every size.
3. Colour carries series (spending / bills / saved); state carries icon + word.
4. Explanations live behind the tile (drill-in) or an ⓘ, never on the dashboard.
5. A dashboard per question: Today (can I spend?), Spending (where did it go?), Plan (where will the salary go?),
   Bills (what is due?), Save (how far are my goals?), Pay period (how did it go?).

Kit: `Tile` (12 dp radius, `surface` on a darker `desk`, 1 px `line` border, no shadow), `StatTile` (label, value in Plex
Sans 600 proportional figures, sub, `DeltaChip`), `HeroTile` (number + `StateChip` + `DayDots` + pace meter), `RingTile`
(progress ring + value: goals, tightest budget, period elapsed), `SparkTile` (12-month out, held forecast), `DonutTile`
(salary split with values, 2 dp gaps), `BarListTile` (budget meters), `NetBarsTile`, `CalendarTile` (until payday:
filled = bill, dashed = planned cost, dashed teal = payday), `HeatmapTile` (day dots of a past period), `ListTile`
(ruled rows, mono amounts: Ledger lives on here), `AddTile` (dashed "+ Goal").

Navigation: tabs unchanged; Budget gets a two-way switch **Spending | Plan** (remembered on the device); the period chip
opens the Pay-period report; Add expense is the last tile on Today (thumb reach) and Ctrl+N on desktop.

Identity: Ledger's palette, Plex, mono amounts in lists and the ruled list rows stay; paper becomes tiles on a desk;
tile numbers switch to Plex Sans semibold (proportional figures read better large); radius 12 on tiles only.

## 6. Text cut (before → after, from today's screens)
| Screen | Before | After |
|---|---|---|
| Today | "SAFE TO SPEND TODAY" + "Over the plan" badge + "Today's allowance is 0.00 €." + cell "over the plan 549 €" + "You're 549 € over the plan for this period." | Label "Today", the number, one chip "▲ 549 € over plan" (said once, not four times) |
| Today | "552 € of 3 € used" · "550 € behind pace" | Pace meter + "552 / 3 €" + "▲ Behind pace" |
| Today | "Due by payday: 1 bill (2 payments), 24 €" + "Demo Domain Renewal 36 € held until paid" + "Coming up: 4 costs before payday · 474 €" + "Car insurance in 2 days · 340 €" | One tile "Before payday 474 € · 4 costs" (held and dates on Bills) |
| Today | "Held: 1,803.32 € · 80 $" / "Groceries: over by 125.23 €" / "1 bill to review" | Tiles "Held 1,803 €" (+ "80 $" sub), "Groceries ▲ 125 € over" (ring), "To review 1" on Bills |
| Budget | "3.01 € to spend · 0.10 €/day" + "Salary minus bills minus savings. Whatever is left is your spending money until the next payday." | Split bar / donut "Fixed · Saved · Spending" with values + "Per day" tile |
| Budget | "Paid since payday: 550 €" under each fixed line; "savings goal" under each goal line | ✓ icon on paid lines; goal lines grouped by colour (Saved) |
| Budget | "Extra income received … Regular income that is in; it is spending money now" / "Set aside for coming costs … Bills and planned costs due before payday" | "Extra in +150" / "Before payday −534" (same label as Today) |
| Spending | "Saved 540 € over the last 8 pay periods. You kept 5% of what came in. 6 of 8 periods saved. Each bar runs from one salary to the next; the line is the 3-period average. The faded bar is still running." | Tile "Kept 5 %" + "6 saved · 2 lost" + the bars (faded = running, legend-free) |
| Spending | "October 2026: 1,339 € out" + "2 over, 1 behind pace, over by 26.10 € in total" + "Income 1,400 €. Spending and bills by category; the solid mark is the budget, the dark tick is your average of the 6 months before." | Tiles "Out in October 1,339 € ▼ 4 % vs avg", "In 1,400 €", "Where it goes ▲ 2 over" |
| Bills | "1 bill (2 payments) before payday: 24 €" + "These come off your daily money until they are paid." | Tile "Before payday" (the help moves behind ⓘ) |
| Bills | "Read from a code, file or photo. Nothing counts until you check and confirm it." | Tile "To review 1" |
| Bills | "Found in your imports, or added by you. A confirmed bill is set aside … already counted." (4 lines) + "Bills and subscriptions: about 48.62 € a month · about 583.50 € a year" | Tiles "Per month 48.62 €", "Per year 583.50 €"; row states ✓ Paid / ⏱ 1 Nov / 🔒 Held |
| Save | "0 € put aside" + "Each goal takes its monthly amount off the top on payday. Emergency fund first: 3 months of rent, loan and bills." | Tile "Put aside 0 € of 4,200" + bar |
| Save | "Check before you buy" + "Anything over 50 € waits 72 hours on the wishlist first." / "Ready to decide — Nothing has finished waiting yet." / "Cooling off — Your wishlist is empty. Check something above to add it." | "Can I afford it?" + chip "> 50 € waits 72 h"; tiles "Waiting 0", "Ready 0" |

## 7. Recommendation: B, Paper Tiles
- It is what the owner asked for: "look like a dashboard" and "a new experience" from dashboard kits; tiles are the
  shared language of every kit and app above. A mostly removes prose, which helps, but still reads as a document.
- The tile is a hard limit that enforces the text rule: a tile has no room for a sentence.
- It keeps the Ledger identity where it matters (palette, Plex, mono amounts, ruled lists inside tiles), so it is an
  evolution, not a new brand, and the contrast tests and tokens carry over.
- It scales cleanly: 2 → 4 columns, the same order on phone and desktop; the web build gets the same grid.
- Both directions share the IA and most components (`StatTile` vs `LedgerCell` is a skin); if the owner prefers A, the
  build plan is the same minus the tile skin.

## 8. Owner decisions (2026-10-30)
1. **B · Paper Tiles.**
2. Budget tab: **Spending | Plan switch** (remembered on the device).
3. Today **keeps the last 3 payments** under Add expense.
4. **Always exact cents**, on tiles too (the hero included); tiles keep their size by scaling the number down
   (`FittedBox`), never by rounding. Mockups at https://claude.ai/artifact/Nh3PjMvaTu6jqoywVURDAP (private).

## 9. Build split (rough)
| Step | Work | Kind |
|---|---|---|
| RX2 | Tokens: `desk`, series `s1..s3` (+ dark), `goodSoft`/`badSoft`; contrast test cases. Kit in `widgets/dash.dart`: Tile/StatTile, DeltaChip, StateChip, Ring, Sparkline, SplitBar/Donut, BarList, NetBars, CalendarTile, `DashGrid` (1/2/4 columns, span). Widget tests at 320 dp × 2.0, 360, 1280, light and dark | pure UI |
| RX3 | Today dashboard (hero + DayDots from DD + tiles); "Before payday" label everywhere | pure UI (uses `period()`, `periodDays()`, `tightestBudget()`, `heldTotals()`, `paydayForecast()`, `reviewState()`) |
| RX4 | Budget: Spending dashboard + Plan (split/donut, lines with ✓) | UI + **small core**: month out vs 6-month average as one number (today only per category) |
| RX5 | Bills dashboard (tiles, calendar until payday, expected rows with one state) | pure UI (`upcoming()`, `dueCycles`, `billsCost()`, review queue) |
| RX6 | Save dashboard (put aside, goal rings, check field, wishlist and IOU tiles) | pure UI (goals, wishlist, `savedByWaiting`, `owedTotals`) |
| RX7 | Pay-period report (period chip → page, ‹ › through `periodReports`) | **new core**: `periodDays` for a past period (DD's rule with a given period), out delta vs previous period, reviews done per period (needs the review history, if it is stored), wishes skipped in the period (`savedByWaiting` range exists) |
| RX8 | Tag detail as a dashboard; desktop 4-column layout; screenshots and layout tests | pure UI |

Per step: ui-builder (sonnet/high) in its own worktree, scout first; core-builder (session model/high) only for RX4's
average and RX7. No schema or sync change in any step.
