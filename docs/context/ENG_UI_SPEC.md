# Stage ENG: "the curious engineer" UI (owner pick 2026-11-02): handoff

**Owner, 2026-11-02:** "build something for an engineer who is always curious where money is going, how something is
correlated and tracked over a long period of time, what did I spend on some project that spanned over years, how much
will I need to spend and save to buy a house; it needs to be informative, a little fun, and easy to use since I'm
lazy." After seeing the mockups: "I like it … let's go in this direction" (dark and light both).

This replaces the visual direction of UX-C ("Clean neutral") and the navigation of the current shell. All the money
rules stay exactly as they are (§2). Mockups: `docs/design/engineer/` (README there) and the live canvas
https://claude.ai/artifact/HEyzibzxFzy4cnHFQfrCFf (page **Engineer**: dark row plus light row; page **Structure (v1)**:
the flows these screens sit on). All numbers in the mockups are synthetic.

Design principle in one line: **lazy by default, curious on demand.** The app notices things and shows them as cards
(findings, project leftovers, ways to reach the house sooner). Every number opens its series. Every series can be
compared, zoomed over years and exported. Nothing changes money without a tap.

---

## 1. What to build: summary

| # | Part | Kind | Builds on (existing) |
|---|---|---|---|
| E1 | New theme (dark + light tokens, fonts, type scale) and the new shell (4 destinations + Add) | UI | `theme.dart` `WalletColors`/`BwType`, `main.dart` destinations (~249, rail ~683, bar ~822) |
| E2 | **Overview** (home): safe to spend, € ↔ hours switch, "Found this week", pinned series, house progress | UI + core (hours, pins) | `today.dart`/`today_view.dart`, `widgets/dash_charts.dart` `Sparkline` |
| E3 | **Findings**: auto-found patterns with their evidence chart | core (new pure module) + UI | `insights.dart` (core), `series.dart`, `recurring.dart`, review streak rows |
| E4 | **Explore**: query by chips → long-range chart, table, heatmap, "move together?", saved views | core (query + long windows) + UI | `series.dart` (`bucketFor`, `bucketsOf`, 5-year cap), `insights.dart`, `chart_window.dart`, `widgets/chart_viewport.dart`, `widgets/insight_charts.dart` |
| E5 | **Project** = a tag over years (upgrade of the tag detail) | core (project stats) + UI | `screens/tag_detail.dart`, `tags.dart` (`TagTable`, txtag, ruletag), `planned.dart` |
| E6 | **House planner** = a goal of kind "home" | core (goal fields, home math) + UI | `Goal` in `models.dart` (`GoalCols`), `screens/goals.dart`/`save.dart`, `loan.dart` (no interest today) |
| E7 | Restyle every other screen to the new tokens and move it to its new home (§3 table) | UI | all `screens/*` |

---

## 2. Rules that do not change (check every part against them)

1. **Exact money.** Integer cents; no `double` in a money path. Where the new math needs powers or ratios (loan
   payment, link strength, hours), compute with exact integers/`BigInt` rationals and round **once**, half away from
   zero, as the FX code already does. Results that are estimates (loan payment) say "estimate" on screen.
2. **Suggest, the owner confirms.** Findings, project "not tagged yet", house levers and pins are read-only views
   or proposals. Applying one goes through the existing confirm flows (rules, tags, plan suggestions). No auto-tagging,
   no auto plan change.
3. **Never reclassify on amount alone.** The project candidate list uses payee keys (`merchantKey`) of already-tagged
   rows, never amounts.
4. **Never a negative figure as a quantity.** Use words: "over by", "short by". Applies to the house planner
   ("short by X a month").
5. **Correlation wording:** always "moves together" plus strength in words; never "causes". Fixed line on Findings:
   "A link is not proof of a cause."
6. **No amounts or names in logs, notifications or the widget.** New modules log counts and kinds only.
7. **One label per thing, one add button, no repeated help text** (memory "no duplicate info").
8. **No new packages** (no fl_chart, no google_fonts): charts with `CustomPainter` as today; fonts bundled as assets
   (OFL), like Inter/Plex today.
9. **Synced, offline-first, last-writer-wins per field.** New settings and entities are declared as F1 `Col`s and
   synced. A schema change follows the schema-20 process (migration in `repo.dart`, STATUS note, an older peer
   refuses with "update the app"). Fold it into the unpushed schema if there still is one; the lead decides.
10. **Accessibility as today:** 320 dp at text scale 2.0, 360 dp, 1280 dp, light and dark, with real fonts; 44 dp
    minimum targets (48 on Android where cheap); colour is never the only signal; every chart has a text or table
    view of its exact values; no golden tests (structural widget tests + screenshots).

---

## 3. Navigation and where every existing screen goes

**Destinations** (bottom bar < 600 dp, rail ≥ 600 dp): **Overview · Money · [+] · Explore · Plan**.
- [+] is the only add button (centre of the bar; first item in the rail, "Add  Ctrl N"). It opens the Add sheet:
  Expense (default), Scan bill, Import file, More (planned cost, lent/borrowed). Over the wishlist threshold the sheet
  shows the impulse check (v1 `structure/Add.dc.html`).
- **Settings** opens from the gear in the Overview header (phone) and the bottom of the rail (desktop) only. `Ctrl ,`.
- **Needs you** (one queue for every suggestion) opens from the Overview header badge (phone) and is a standing right
  pane on Overview at ≥ 1280 dp (v1 `structure/Inbox.dc.html`, `structure/Desktop.dc.html`).
- Keyboard: Ctrl+1–4 destinations, Ctrl+N add, Ctrl+K focuses the Explore query bar (also from any screen: jumps to
  Explore), Ctrl+F search in Money, Ctrl+R sync, Ctrl+, settings.

| Today (current) | Goes to |
|---|---|
| Today tab: hero, tiles, payday checklist, below-zero, held money | **Overview** (top panel + tiles; tile choice/order stays: `today_tiles_panel.dart`) |
| Budget tab: spending, insights, period reports, tag detail, category detail, bucket payments | **Explore** (charts, reports) and **Findings**; tag detail → **Project** screen |
| Bills tab: bills, upcoming, recurring, scan | **Money** (one timeline: coming up above "Today", past below; bills and planned costs are rows) + Needs you for the review items |
| Save tab: goals, wishlist, owed | **Plan › Saving** (`structure/Save.dc.html`); a goal of kind home opens the **House planner** |
| Budget › Plan, budgets | **Plan › Payday plan** (`structure/Plan.dc.html`) |
| Weekly review | **Needs you** in review mode (import → decide → pace → done) |
| Settings tab | Settings (setup only: accounts & currencies, tags & rules, bank file formats, sync & devices, wallet key, backup & export, nudges, calendars, weekly review day, look, Today tiles, set up again, diagnostics) |

Keep: state across resize, sheets as bottom sheets on phones and as 480 dp dialogs from 600 dp, the search behaviour.

---

## 4. Visual system (E1)

Name: **Engineer** (dark default for this persona; follows the system setting; Settings › Look offers System / Dark /
Light). Two token sets from one table. Not a flipped theme: the light set has its own steps.

### 4.1 Colour tokens

| Role (`WalletColors` field) | Dark | Light | Use |
|---|---|---|---|
| `bg` / `desk` | `#0F1418` | `#F4F6F8` | page |
| `surface` (panel) | `#161D23` | `#FFFFFF` | cards ("panels"), sheets |
| `surface2` | `#1B232A` | `#EEF2F6` | query chips, selected rail item, inputs |
| `line` | `#26313A` | `#E1E6EB` | panel border 1 px, row dividers |
| `lineStrong` | `#33404B` | `#CBD3DA` | chip/button outlines, axes |
| grid (new `chartGrid`) | `#222C34` | `#EDF0F3` | chart gridlines (recessive) |
| `ink` | `#E8EEF2` | `#121A21` | text, active chip fill |
| `muted` | `#9AAAB6` | `#56636F` | secondary text, axis labels, eyebrows |
| `accent` | `#8DB8F5` | `#1F5FBF` | primary button fill, links, active nav; text on it = `bg` |
| `good` | `#3FB37F` | `#1F7A50` | "ahead", pace up (with ▲ + word) |
| `bad` | `#F07167` | `#C2412F` | over, short by, badge fill (text on it = `bg`) |
| `accentSoft` (nudge card) | `#172231` / border `#3B4B66` | `#EAF1FC` / border `#BFD3F0` | the "3 not tagged yet" card |

Keep `theme_contrast_test.dart` green: text pairs ≥ 4.5:1, non-text ≥ 3:1. Re-derive the test's pair list for the new
tokens.

### 4.2 Data colours (charts only, never text)

Fixed categorical order, assigned by **entity**, never by rank (a filter never repaints a survivor). Validated with the
dataviz validator (`node scripts/validate_palette.js`, both modes: ALL PASS; light has a contrast WARN on slots 3–5,
so the matching chart must have visible values or a table, which every chart here has; draw those lines 2.5 px).

| Slot | Dark | Light | Default entity in the mockups |
|---|---|---|---|
| 1 | `#3987E5` | `#2A78D6` | Groceries / first series |
| 2 | `#D95926` | `#EB6834` | Eating out |
| 3 | `#199E70` | `#1BAF7A` | Kept / saved |
| 4 | `#C98500` | `#EDA100` | the project |
| 5 | `#D55181` | `#E87BA4` | Transport |
| 6 | `#9085E9` | `#6250D6` | house fund / goals |

A series' colour is stored per tag/main tag (first free slot at creation, editable later). A 7th+ series in one chart
folds into "Other" or small multiples. Sequential (heatmap, one hue; "less → more"): dark `#1C2B3A #24405C #2E5C86
#3A7BB5 #5C9CE0`, light `#E3EDF9 #BBD3F1 #86B2E6 #4F8CD6 #2A65B3`. Never use a status colour for a series.

### 4.3 Type

- **Manrope** (400/500/600/700/800) for text, **JetBrains Mono** (400/500/700) with tabular figures for every amount,
  date-in-table, axis number and "eyebrow" label. Both OFL: bundle the TTFs in `app/assets/fonts/` with their OFL
  texts and replace Inter + IBM Plex Mono in `pubspec.yaml` (owner decision of 2026-11-01 superseded by this pick).
- Scale (`BwType`): eyebrow 11 mono caps, letter-spacing 0.1em, `muted`; meta 13; body 14–15; heading 16–17 / 800;
  title 22–26 / 800, letter-spacing −0.02em; amount 15 mono; amountLg 22–30 mono 700; hero 52 mono 700 (phone),
  64 (desktop). Nothing under 11.
- Money format unchanged (`format.dart`): sign in front, symbol after a non-breaking space, U+2212 minus, right edge
  aligned in lists.

### 4.4 Shapes and components

- Panel: radius 18, 1 px `line` border, no shadow. Inner padding 14–16. Chips/buttons radius 10–12; pills 999.
- **Seg toggle** (`€ | hours of work`, `Payday plan | Saving`): track `bg` + border, selected = `lineStrong` fill.
- **Query chip**: `surface2` fill, 1 px `lineStrong`, 38 dp tall, colour swatch 10 px + label + ×; a dashed "+ tag,
  payee or project" chip adds one.
- **Range chips** (`1y 3y 5y All`, `Pay period Month 3 mo …`): outline; selected = `ink` fill with `bg` text.
- **Sparkline / PinTile**: one series, 2 px line, last point dot with a 2 px `surface` ring, no axes; value under it in
  mono + delta in `muted` (existing `Sparkline` painter, restyled).
- **Finding card**: eyebrow (kind) · one-sentence finding (17/800) · evidence chart · one muted line with the basis
  (period, n, strength) · actions "Open in Explore", "Not interesting".
- **Status badge** (Needs-you count): `bad` fill, `bg` text, mono 11.
- Icons: outlined, 2 px stroke, round caps. The mockups hand-draw them; use Material Symbols outlined where one exists.
- Fun, kept small: the hours-of-work switch, milestone numbers (days tracked, payments, best streak), "saved by
  waiting" total, a short haptic tick on confirm (`HapticFeedback.selectionClick`, Android), count-up of the hero on
  change (`TweenAnimationBuilder`, ≤ 300 ms, off when `MediaQuery.disableAnimations`).

---

## 5. Screens

Each screen: order of content → interactions → data → acceptance. Mockup file in brackets.

### 5.1 Overview (E2) [`screens/E-Home*.dc.html`]
1. Header: eyebrow `Mon 2 Nov · period day 18/31` (taps → Period sheet, v1 `Payday.dc.html`), title "Overview";
   icon buttons: query (→ Explore, focused) and Needs you (badge count).
2. **Safe to spend today** panel: hero amount; line "Tomorrow X · pace ▲ N € ahead" (or "▼ N € behind", or the
   over-budget words, never a negative). Seg toggle **€ | hours of work** (§6.1) switches every amount on this
   screen.
3. **Found this week**: up to 2 finding cards in compact form (sparkline or mini scatter + sentence + basis);
   "All N ›" → Findings.
4. **Pinned**: 2-column grid of PinTiles (default pins on a new wallet: Kept per period, the biggest flexible main
   tag per month, the newest project tag if any, the home goal if any). "+ Pin a series" → Explore; long-press /
   secondary click on a tile → Unpin. Tap → Explore with that query (projects → Project screen, home goal → House).
5. Home goal progress (only when a home goal exists): bar, "ready ~ <month year>", "X of Y for deposit and costs".
6. Existing attention tiles (below zero, bills to review, finish setup, other currencies) keep their rule: they show
   first, between 2 and 3.
- Desktop ≥ 1280: three panes: rail · Overview (two columns: safe-to-spend + held money / found + pinned) · Needs you.
- Acceptance: switching to hours changes every amount and its unit and nothing else; pins survive restart and sync;
  with no data the found/pinned sections are absent (not empty boxes).

### 5.2 Findings (E3) [`screens/E-Findings*.dc.html`]
Header subtitle: "Found in N days of your data. A link is not proof of a cause." Cards newest first, max ~7. Kinds
(§6.2): weekly rhythm (7 bars, tap a bar → exact value label), moves together (scatter, dashed trend line, axis names,
strength), slow creep (step line with first/last values), above usual (sparkline + "34 % above your usual month"),
seasonality ("December is your priciest month"), milestones (3 numbers). Actions per card: Open in Explore (prefilled
query), Not interesting (hides that finding id; Undo toast), and where it applies a confirm action from the existing
flows ("See the 5 new ones" → Money filtered).
- Acceptance: identical data gives identical findings on every device; a dismissed finding stays hidden on the
  other device after sync; no finding without its basis line.

### 5.3 Explore (E4) [`screens/E-Explore*.dc.html`; desktop first, phone = stacked]
1. Title + actions **Save view**, **Export CSV** (existing CSV export, for exactly the query's buckets).
2. **Query bar** (chips, one row, wraps): `Show [spent ▾] on [series chips …] [+ tag, payee or project] by [month ▾]`
   + range chips `1y 3y 5y All` (+ custom dates in the "by" menu). Measures: spent, came in, kept, count of payments.
   Series: main tag, extra tag/project, payee (`merchantKey`), account. "by": week, month, quarter, year, pay period.
3. **Chart**: one y-axis only (never dual-axis); lines for ≤ 4 series with direct labels at the line end (nudge apart
   when closer than 14 px) + legend; > 4 → small multiples. Hover/press: crosshair + tooltip listing every series'
   exact value for that bucket. Drag to zoom, double-tap/Reset (existing `chart_viewport.dart` behaviour). Partial
   buckets faded, as now.
4. **Table** under the chart: one row per bucket, newest first, exact cents, a "Together" column (labelled "overlaps"
   when extra tags overlap, as `T1_SPEC.md` requires).
5. Side panel (desktop) / sections below (phone):
   - **Heatmap** month × year for the first series (sequential ramp, legend "less → more", tap a cell → exact value),
     plus one sentence when a month is the top one in ≥ 3 of the years.
   - **Do two series move together?** two chip pickers → strength number + words + n months; same wording rules.
   - **Saved views** list (tap → load the query; swipe/menu → rename, delete with Undo).
- Acceptance: "All" works over the whole wallet history (see §6.3, the 5-year cap); every value in the chart
  matches the table to the cent; tooltip and table agree with the existing spending totals for the same window.

### 5.4 Project (E5) [`screens/E-Project*.dc.html`]
Any extra tag can be a project. Opened from a tag chip, a pin, a saved view, or Explore.
1. Eyebrow "Project · tag", title = tag label.
2. Summary panel: `<first month> → today` (or the last payment's month when the newest one is older than 90 days:
   "ended"), duration, payment count; total (hero 44 mono); "N % of everything you spent in that time · about H h of
   work" (hours only when §6.1 is set up).
3. **Running total** (step line + light area, project's colour slot) with year ticks and year chips
   `All 2023 2024 …`; a chip highlights that year's band and shows its total. Optional labels: the owner can name a
   burst (a note on the tag's month; v2, skip in the first cut).
4. **What it went on**: split bar by **main tag** (2 px gaps) + rows with swatch, label, amount; sums to the total.
5. **Not tagged yet** nudge (`accentSoft` card): "N payments at the same places aren't tagged yet. Review N": opens a
   list with per-row Tag / Skip and "Tag all" (writes txtags through the existing tag flow, with Undo).
6. **Still coming**: planned costs carrying the tag (held before payday).
- Acceptance: total = Σ tagged rows (splits per part) = Σ by main tag = Σ by year; overlap note when another extra tag
  shares rows; candidates never include a row already carrying the tag or a transfer.

### 5.5 Big purchases: from saving to a loan to paid off (E6) [`screens/E-House*.dc.html` = the saving phase]
**Owner, 2026-11-02:** the house "was an example of a goal, not a hard limit; the same can be said for a car or a
boat. It is a suggestion of how to think about goals that have loans, and how to process those loans once they go
into spending." So this is **one general model for any big purchase**, with the house as the mockup's example.
Nothing here is house-specific: no "home" kind, no house wording in code. The owner names the goal ("Home", "Car",
"Boat") and the copy uses that name.

A goal is **paid in full** (save the whole price, as goals work today) or **financed** (save a deposit + one-off
costs; the rest is a loan). One goal goes through five phases. The screen for the goal shows the phase it is in.

1. **Saving** (the mockup). The planner screen, for any financed goal:
   - **Ready to buy** `<Mon YYYY>` + "in X y Y m at Z a month". Chart: the fund line from today's saved total, a
     dashed "Needed" line, a dot where they meet.
   - Inputs (sliders + tap-to-type): price, deposit % (0–100; 100 = paid in full, so the loan rows hide), costs on
     top % ("one-off costs the loan doesn't cover: taxes, fees, registration"; default 6 % for a goal the owner marks
     as property, 0 % otherwise; editable per goal), into the fund each month, loan rate "typed by you" (0.1 steps),
     loan length (months; chips 5 / 10 / 20 / 30 y and custom; default 30 y for property, 5 y otherwise).
   - **The numbers** (a ledger that foots): deposit · costs on top · already in the fund (−) · **still to save** ·
     loan · payment / month (estimate) · "vs <a fixed line the owner picks to compare with, e.g. rent>" (optional) ·
     "spending money per period after" = today's to-spend − payment (+ the compared line if it ends), or "short by X".
   - **Get there sooner** (from your own data): toggle chips with "N mo sooner" (a main tag back to its 12-month
     median, expected side income into the fund). What-if only; "Use this" → the existing plan-suggestion confirm.
   - Footer: "Estimate only. The lender's offer gives the exact numbers."
2. **Ready.** When saved ≥ needed (or the goal's month arrives), a Needs-you card: "<Goal> is ready: you have the
   deposit and costs." Actions: "I bought it", "Not yet".
3. **Bought** ("I bought it", also on the goal screen at any time). One sheet, prefilled from the plan, each
   prefilled value marked *Unsure* until the owner changes or confirms it (as the bill sheet does):
   - What it cost: the purchase payment rows (pick from Money; down payment, costs). Evidence is the owner's pick,
     never an amount match.
   - The loan as the lender wrote it: amount borrowed, rate (fixed, or variable: "changes on <date>" can be added
     later), length, first payment date, monthly payment, the account it is paid from, the lender (payee) and
     optionally the reference the bank shows on each payment.
   - On **Confirm** (one write, Undo):
     - the goal closes as bought. Its saved money counts as spent on the purchase rows, not on the flexible budget
       (as goal money does today);
     - a **project tag** with the goal's name is created and put on the purchase rows, so the Project screen (§5.4)
       tracks everything the thing costs over years (insurance, repairs, registration can be tagged later);
     - a **Loan** item is created (§6.5) and its payment becomes a **fixed line** in the payday plan (its own line,
       next to rent; nothing else in the plan changes).
   A paid-in-full goal does the same without the loan part.
4. **Paying off.** The Loan screen (open from the plan line, the goal, the project, or Money's row):
   - Owed now · months left · paid off in `<Mon YYYY>` · interest paid so far · interest still to pay (estimate).
   - Chart per year: principal vs interest (stacked, 2 px gap, interest in a series slot, never `bad`), and the
     balance line going down.
   - **Payments**: each month the lender's bank row is matched to the loan the way confirmed recurring bills are
     (payee/reference evidence; the first match asks "Loan payment?", after that it matches silently with an Unlink).
     A month without a matched payment shows "Not seen yet" after its due date + 3 days (Needs-you card, no alarm).
   - **"What did the lender show?"**: type the balance from the lender's statement; the app shows "matches" or
     "off by X" and, on confirm, continues the schedule from that balance (never corrected on its own; same pattern
     as the account balance check).
   - What-if (not saved until "Use this"): an extra one-off or monthly payment → months and interest saved; a new
     rate from a date (variable loans) → new payment.
5. **Paid off.** When the last payment is matched (or the owner confirms the balance is 0): the loan closes, its
   plan line ends, and a plan suggestion offers the freed money: "Your <name> loan of X a month has ended. Move X to
   savings or a goal?" (suggest, confirm). A finding 6 months before the end: "<name> loan ends in 6 months: X a month
   frees up".

- The existing single loan in the plan (`WalletSettings.loan` + `loanEnd`, `loan.dart` `LoanLeft`) becomes the
  first Loan item on migration (payment = `loan`, end = `loanEnd`, rate/balance unknown → the screen asks for them
  once; until then it shows only months left and payments left, as today).
- A loan taken without a goal (car bought before using the app) is added from Plan › Payday plan › "+ Loan" with the
  same sheet as step 3.
- Acceptance: every ledger foots to the cent; ready month = ceil(still to save ÷ monthly); 0 left → "Now";
  monthly 0 → "set a monthly amount" (no division); rate 0 → payment = loan ÷ months; the schedule's last payment
  absorbs the rounding so the balance ends at exactly 0; Undo of "I bought it" restores the goal, removes the loan,
  its plan line and the tag rows it added; a paid-off loan no longer changes safe-to-spend.

### 5.6 Everything else (E7)
Restyle with the tokens. Layout and copy from `docs/design/engineer/structure/`: Money timeline (accounts strip,
filters, coming-up rows dashed, past rows by day), Add sheet with impulse check, Needs you (cards with one filled
primary + outline alternative + Undo toast; weekly-review progress), Payment detail, Bill check (unsure fields in an
attention outline, sticky confirm), Plan (payday plan edited in place, suggestions inline, budgets per tag), Saving
(goals with "Skip this period / Take out…", wishlist with cooling-off and "saved by waiting", owed), Settings index,
first run.

---

## 6. New core capabilities (core-builder; pure functions + tests first)

### 6.1 Money as hours of work
- Synced settings: `workHoursPerWeek` (int, default unset → the switch is hidden until set; Settings › Look asks
  once: "Hours you work a week").
- Rate = planned salary (plan's income line, cents) ÷ (hours/week × 52 ÷ 12) as an exact rational; hours for an
  amount = cents ÷ rate, shown with 1 decimal ("8.4 h"). Display only; never stored, never in sums.
- Tests: rounding at .05 boundaries, no salary → null, very large amounts.

### 6.2 Findings engine (`packages/wallet_core/lib/src/findings.dart`, exported)
`List<Finding> findings(List<CategorizedTx> txs, WalletSettings st, CategoryTable cats, TagTable tags, String today)`;
`Finding { String id; FindingKind kind; String subjectKey; …basis (n, from, to, strength permille or ratio
permille); series data for the evidence chart }`. Stable ids: `<kind>:<subjectKey>:<window end month>`.
Kinds and thresholds (tune in tests, not in UI):
- **aboveUsual**: this calendar month's spend for a main tag ≥ 1.25 × its 12-month median (≥ 6 months of history,
  ≥ 20 € difference).
- **weeklyRhythm**: mean spend per weekday over 12 months; fire when max ÷ min-weekday mean ≥ 1.6.
- **movesTogether**: Pearson r over monthly totals of two main tags, ≥ 12 shared months, |r| ≥ 0.5; words: 0.5–0.69
  "fairly strong", ≥ 0.7 "strong"; negative r: "when one goes up the other goes down". Exact integer sums, r as
  permille via integer square root of the products (no doubles); pairs limited to the top 8 main tags by spend.
- **slowCreep**: a confirmed recurring bill group (or the subscriptions fixed line) whose monthly amount rose ≥ 25 %
  over ≥ 12 months (uses recurring history, never single rows).
- **seasonality**: the same calendar month is the max of a main tag in ≥ 3 years.
- **milestone**: days tracked, payment count, best review streak (`reviewStreak` in `budget.dart`).
- Dismissed: synced setting `dismissedFindings` (set of ids). Logged: counts per kind only.
- Tests: synthetic fixtures for each kind at, below and above the thresholds; determinism (same input → same ids and
  order); refunds and transfers excluded as in `spendingSeries`; other currencies "not counted" excluded.

### 6.3 Explore query and long windows
- `SeriesQuery { Measure measure; List<SeriesKey> keys; Bucket bucket; DateRange window }` with `SeriesKey` =
  (kind: mainTag | tag | payee | account, id). `List<QueryRow> runQuery(...)` returns one row per bucket with exact
  cents per key, built on `bucketsOf`/`spendingSeries` (same filters, so totals match Insights).
- Add `Bucket.year`. The 5-year cap (`series.dart` `_maxYears`) blocks "All": lift it when the bucket is quarter or
  year (keep the bar count limit through `bucketFor`), document it in `ZC_SPEC.md`.
- **Saved views and pins**: one synced entity `view` (`id`, `name`, `query` JSON, `pinned` bool, `sort`) declared
  with `Col`s; Overview reads pinned ones. Deleting → Undo.
- `heatmap(query)` (month × year cells, exact cents + level 0–4 by quantiles) and `moveTogether(a, b, window)`
  (shared with §6.2).

### 6.4 Project stats (`projects.dart`)
`ProjectStats projectStats(String tagId, List<CategorizedTx> txs, ...)`: first/last date, total, count, share of all
spending in the span (permille), by main tag, by year, running total per month, planned costs carrying the tag, and
`candidates`: untagged rows whose `merchantKey` is among the tag's payees within the span (+ 30 days), never transfers,
never already tagged. Sums must foot (tests).

### 6.5 Big-purchase goals and loans
**Goal fields** (synced, nullable; "model the real property": per-goal values on the goal; no kind enum, no house
names): `price`, `depositPermille` (null = paid in full = today's goals), `costsPermille`, `loanRateBp`
(hand-typed, basis points), `loanMonths`, `compareLineId` (optional plan line to compare with), `boughtAt`
(date, set by "I bought it"), `loanId` (the loan it became).

**Loan entity** `loan` (synced, declared with `Col`s; one row per loan; schema change → §2.9): `id`, `name`,
`principal` (cents borrowed), `rateBp`, `months`, `firstDue` (date), `payment` (cents, as the lender wrote it),
`accountId`, `payeeKey` (`merchantKey` of the lender's rows), `reference` (optional, text the bank shows),
`goalId` (optional), `tagId` (optional project tag), `closedAt` (date or null). Rate changes: a child entity
`loanrate` (`loanId`, `from` date, `rateBp`, `payment`). Balance checks: `loancheck` (`loanId`, `date`, `balance`
as the lender showed it, confirmed by the owner). Matched payments use the existing recurring/match machinery
(the loan is a confirmed recurring group whose amount is `payment`; match by payee key or reference, never by
amount alone; a matched row's main tag is the fixed "Loan" tag).

**Pure functions** (exact integer/BigInt, rounded once, half away from zero):
- `GoalPlan goalPlan(Goal g, int savedCents, int monthlyCents, {int? compareCents, required int toSpendPerPeriod})`
  → deposit, costs, need, left, months (ceil), readyMonth, loan, payment estimate (annuity
  `L·r / (1 − (1+r)^−n)`, r = bp / 120 000 as a `BigInt` fraction; rate 0 = L ÷ n), vsCompare, afterPerPeriod or
  shortBy.
- `List<LoanMonth> loanSchedule(Loan l, List<LoanRate> rates, List<LoanCheck> checks)`: per month interest =
  round(balance × r), principal = payment − interest, the last month pays the exact rest; a confirmed check resets
  the balance from its date; a rate row changes r (and payment) from its date. Gives balance, interest paid / still
  to pay, months left, payoff month.
- `LoanState loanState(schedule, matchedPayments, today)`: paid months, "not seen yet" months (due + 3 days, no
  match), owed now (schedule balance after the last matched month).
- `loanWhatIf(loan, extraOnce, extraMonthly, newRateFrom)` → months saved, interest saved. Read-only.
- `goalLevers(...)`: main tags whose last 3-month mean exceeds their 12-month median (cut = the difference,
  rounded down to whole euros) and confirmed expected income not yet assigned; each with months saved; a lever that
  saves no month is dropped. Read-only.
- Plan: the fixed-costs total = rent + subscriptions + own fixed lines + Σ open loans' current payment (each loan
  its own line). Migration: `WalletSettings.loan`/`loanEnd` → one `loan` row (principal/rate unknown = null;
  `loanLeft` keeps working from `payment` + end month until they are filled in).
- Tests: three published annuity examples (values as literals); 0 %; schedule ends at exactly 0; a balance check
  mid-way; a rate change mid-way; extra payment; Undo of "bought" restores everything; migration of the old single
  loan; a paid-off loan leaves the plan; a payment matched by reference with an amount that differs (the lender
  changed it) is still matched and flagged "amount changed".

---

## 7. Order of work (team, per CLAUDE.md; cap 4 agents)

| Step | Agents (model/effort per `.claude/agents`) | Worktree | Notes |
|---|---|---|---|
| E1 theme + fonts + shell | ui-builder | `eng-e1` | tokens both modes, fonts swap, 4 destinations + Add, Settings move, contrast test; screenshots of every tab in both themes |
| E2–E3 core: hours + findings | core-builder ∥ test-writer | `eng-core-1` | §6.1, §6.2 |
| E3–E2 UI: Findings + Overview | ui-builder (after E1 + core-1 API fixed) | `eng-ui-2` | uses core API names from §6 |
| E4 core: query, year bucket, views entity, heatmap | core-builder ∥ test-writer | `eng-core-2` | schema: `view` entity |
| E4 UI: Explore (desktop + phone) | ui-builder | `eng-ui-3` | perf: `make perf` budget must hold on Explore "All" |
| E5 project stats + Project screen | core-builder then ui-builder | `eng-5` | replaces `tag_detail.dart` |
| E6 home goal + House planner | core-builder ∥ test-writer, then ui-builder | `eng-6` | schema: goal fields |
| E7 restyle remaining + moves | ui-builder | `eng-7` | Money timeline, Needs you, Plan/Saving, Settings |
| Each stage end | reviewer; haiku test-watcher for full `make test`, `make desktop-test`, emulator screens | — | owner tests at the end (checklist in STATUS) |

Bump nothing on CI; the owner starts `ci` by hand.

---

## 8. Owner questions (ask once, before the step that needs them; defaults in brackets)

1. Hours you work a week for the hours view [40].
2. Buying costs default for the house [6 %]; loan years default [25].
3. Default theme for this persona: follow the system, or dark always [follow system].
4. "All" in Explore: the whole history as quarters/years beyond 5 years [yes].
5. Keep the Candy Pop / Coin Jar "fun" bits (sticker badges, swipe cards) out [out; only §4.4 fun].

**Owner answers (2026-11-02):** 1 → 40 h (default `workHoursPerWeek` = 40, so the hours switch shows once a salary is set; editable in Settings › Look). 2 → buying costs 6 %, loan **30** years. 3 → follow the system. 4 → yes, whole history (quarters/years past 5 years). 5 → out (default).
**Lead decisions (2026-11-02):** "main tag" = the row's resolved category (T1 naming; top level of `CategoryTable`). `findings(..., reviewDates:)` takes the review dates so `milestone` stays pure. History window for aboveUsual/seasonality = calendar months, home currency, `spendingSeries` rules. `dismissedFindings` = one synced setting row (JSON list of ids, newest 500 kept). All thresholds as integer ratios, r via integer square root (BigInt), hours rounded once half away from zero.

## 9. Out of scope
Net worth, investments, live bank links, AI/LLM explanations, notifications for findings (a later nudge could say
"New findings" without amounts), sharing views with other people, iOS/macOS/Windows.
