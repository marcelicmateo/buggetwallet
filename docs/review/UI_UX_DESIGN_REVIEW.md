# Budget Wallet — UI/UX Design Review (designer's pass)

Companion to `docs/SYSTEM_DESIGN_REVIEW.md` §5. Written 2026-10-22 from: the design spec (`docs/design/ledger-spec.md`),
`app/lib/src/theme.dart`, `format.dart`, the shipped screenshots in `docs/spec/screens/`, **and the running app**: the
Linux build in live demo mode (`tools/live.sh start --demo`, window on the desktop) plus a scripted walk through the
daily flows on the real Linux app under Xvfb at phone size (360 × 800) and desktop size (1280 × 720), one frame per
step, in `dist/screens/linux/designer_walk/01…33-*.png`. The walk is `app/integration_test/designer_walk_test.dart`
and can be re-run after changes with `tools/build.sh desktop-test designer_walk`. Frames are cited as `[NN]`.

Method note: the UI/UX skill's design-system generator was queried for this product class; its best database match
was a landing-page pattern with a handwritten display font, which does not apply to a shipped ledger-style app with a
chosen direction, so it was not used. Its UX guideline rules, Flutter stack rules and the native-app pre-delivery
checklist were used as the audit frame. Dark mode was verified only through the repository's contrast and text-scale
tests, not by eye; every frame below is light mode.

Verdicts use KEEP / CHANGE as in the system review.

## 1. Verdict

The visual direction is distinctive, consistent and well built. "D3 Ledger" (paper, ink, ruled sections, tabular
mono figures, no cards) is executed through tokens and component themes rather than per-screen styling, and it
holds up in the running app: the hero number, the ruled stat strip, the double rules under totals and the ledger
transaction table all read as one system. The product's best interaction ideas are visible at every step: nothing
counts until you tap, guessed fields are marked, affordability is explained in days. This is a better foundation
than almost any open-source Flutter finance app I know, and better than several commercial ones.

What the walk exposed is not a styling problem but five flow and state problems, in order of how often a daily
user meets them:

1. **The over-budget state is undesigned.** Negative flex produces copy and figures that read as nonsense: "Spent
   72.45 € today of −18.78 €", "plan per day −3 €", "342 € of −87 € used", "−147 € to spend · −5 €/day" `[01][06][21]`.
   The demo wallet is over budget, so these are the first strings a reviewer sees.
2. **Today's first screen is not the number** on a first run: two amber panels (save the key, confirm the salary)
   push the hero to the middle of a 360 × 800 phone and "Add expense" off screen entirely `[01]`. Once dismissed
   the page is right `[02]`.
3. **The impulse flow mislabels the wish.** Adding 120 € with no note and tapping "Put on wishlist" creates a wish
   called "Groceries" (the category) `[07][08][16]`, `sheets.dart:168`. The best behavioural idea in the app ends in
   an item the user cannot recognise three days later.
4. **Plan's payday ledger does not add up on screen.** The rows shown (1,400 − 550 − 250 − 13 − 100 − 100 = 387 €)
   do not produce the total shown (−147 €), because the 534 € of reserved costs is subtracted but not listed
   `[21]`. A ledger that does not foot is the one thing a ledger aesthetic must never do.
5. **Toasts outlive their context.** "On the wishlist" is still showing on Upcoming three screens later; "Added to
   your plan" follows the user to Spending `[09][12][13]`. They also carry no action (no Undo, no "Open").

None of these needs a visual redesign. Each is a copy rule, a layout rule, or one line of logic.

## 2. Design system

### 2.1 Colour and surfaces — KEEP

Seventeen opaque tokens per brightness as a `ThemeExtension`; every text pair ≥ 4.5:1 and non-text ≥ 3:1 enforced
by a test; no raw colours in screens; red reserved for negative and over-budget, green for income; accent used once
per view for the primary action. Material 3 widgets re-skinned through component themes. The amber warning band
with a 3 px left bar is the right amount of emphasis for "attention, not danger". Comparable: Ivy Wallet and Cashew
lean on colourful category chips and gradients; this is quieter and ages better.

### 2.2 Typography — KEEP the pairing, CHANGE the ramp

IBM Plex Sans for text and Plex Mono with tabular figures for every amount is a strong, legible pairing and the
right call for money (figures align, signs are unambiguous, U+2212 minus). The ramp, however, is 18 distinct
`fontSize` literals across the app (12.5 × 21 uses, 14 × 13, 13 × 13, 16 × 9, 12 × 7, 11 × 5, 15, 14.5, 13.5, 26,
17, 11.5, 10, 78, 30, 24, 20, 19) and `textTheme` is never read in a screen. Visible consequences in the frames:
secondary mono figures at 10–11 px in the Spending category rows and the "Budgeted" line (`[13][31]`: "538.60 € of
500 €" in grey mono, "over by 38.60 €" in red at about 10 px), below the 12 px floor the UX guideline sets for body
text and hard to read on a desktop monitor at 1280 px. Define seven named styles in `theme.dart` (eyebrow 11 mono
caps, meta 12.5, body 14, bodyStrong 14/600, heading 17/600, hero 78 mono, amount 15 mono/500) and replace the
literals; forbid anything under 12 except the eyebrow.

### 2.3 Spacing and rhythm — KEEP, with one rule to add

Vertical rhythm is mostly 8-based (`symmetric(vertical: 8)` × 13, 16/20/24 blocks) and the page gutter is one
constant. Rows are 44 dp minimum. Add one rule: a section's top rule, its eyebrow and its first content line should
sit on a fixed 8 dp grid; today the eyebrow-to-heading gap varies between panels (Spending's "SAVING OR LOSING" vs
Plan's "PAYDAY PLAN") by a few pixels.

### 2.4 Iconography — KEEP, CHANGE one

Material outlined icons at one weight, selected tab icons filled, status icons always paired with a word (`!` +
"Over today", `✓` + "Paid"). Consistent. The Wishlist tab icon (hourglass) does not read as "wishlist" at a glance;
Goals (flag) is fine. If Bills gets a tab (see §8), use the receipt glyph already used on the "bill to review" line.

### 2.5 Components — KEEP most, CHANGE three

- KEEP: `Panel` with top rule + hairline, `SectionHead`, `TotalRule`/`DoubleRule`, the ruled `TxTile` with date |
  particulars | amount, `StatusLabel` (icon + text, never colour alone), the pace bar with the hatch for over
  budget, the Upcoming month grid with marks that differ by shape.
- CHANGE: **form labels are inconsistent.** In one Goal sheet, "Name", "Target" and "Put aside so far" are
  placeholder-only while "Each month" is a floating label `[20]`; Wishlist's "What" and "Price" are placeholder-only
  until focused `[16]` and then float `[17]`. The UX rule is visible labels always. Use floating labels everywhere
  (the bill sheet already does, `[23]`).
- CHANGE: **primary action hierarchy inside a row.** Upcoming suggestions offer Confirm (outlined accent), Change
  (outlined ink) and No cost (text) side by side `[09]`; Review rows offer Change (text) and Looks right (outlined)
  `[26]`. The expected action should be the filled one. Reserve outlined for the alternative and text for the
  dismissive option.
- CHANGE: **sheets have no close affordance on phones.** Bottom sheets open with a title and no X or handle
  (`[04][20][23]`); dismissal is scrim tap or system back. The ledger spec forbids the handle for style reasons; add
  a small X in the title row instead, as the dialog variant already has.

## 3. The daily flow, as walked

| Step | Frame | What happened | Feel |
|---|---|---|---|
| Open app, first run | 01 | Key prompt + salary check above the hero; hero at mid-screen; no Add button visible | The number is not first |
| Dismiss both | 02 | Hero, explanation, stat strip, pace bar, four "what changes it" lines, Add expense, all in one screen | Exactly right; this is the app |
| Scroll Today | 03 | Weekly review, payday checklist, delivery-hour panel, Recent | Good order; delivery-hour panel is personal |
| Add expense | 04 | Sheet: amount, 11 chips, note, date, CTA, explainer | Two taps + typing; category pre-selected silently |
| Type 12,50, pick Eating out | 05 | Comma accepted; chip selected | Good |
| Add | 06 | Hero −91 → −104 €; toast "Expense added" | Immediate; toast has no Undo |
| Add 120 € | 07 | Inline "Over 50 €: wishlist first?" panel with Put on wishlist | Best idea in the app, well placed |
| Put on wishlist | 08 | Toast "On the wishlist. Decide in 72 hours." | No link to the wishlist; the wish is named "Groceries" |
| Coming up | 09 | Upcoming page: period toggle, grid, legend, list | Clear; the previous toast is still on screen |
| Confirm a suggestion | 10 | Row becomes a planned cost; toast "Added to your plan" | One tap; good |
| Spending | 12–14 | Trend chart, prose explainer, month chips, category bars, top places, all transactions | Dense but readable; merchant names truncate at 360 |
| Tap a row | 15 | Small sheet: amount, date, category dropdown, Save, Delete | Right size; Delete without confirm or undo |
| Wishlist check | 17 | "Not this month" + "Spend 5 €/day less → ready by 15 Nov" + two CTAs | Excellent; the clearest money explanation in the app |
| Goals, New goal | 19–20 | Ruled goals + total; sheet with mixed label styles | Fine; label inconsistency |
| Plan | 21 | Payday ledger with a total the rows don't produce; numbers form below | Trust problem |
| Plan › Bills | 22 | Three lists; reminder-days form with its own Save | Scattered Save buttons |
| Bill to review | 23–24 | Long form with "Unsure" marks, Confirm at the very bottom | Marks are great; Confirm should be sticky |
| Weekly review | 26–28 | Four ruled steps with counts; Looks right removes the row; Pace step; Done | Five minutes is plausible; satisfying |
| Ctrl+N on Spending | 29 | Add expense opens | Keyboard path works; touch path does not exist off Today |
| Desktop Today | 30 | Rail + two columns; header strip holds only the period chip | Good use of width; empty header |
| Desktop Spending | 31 | Category table + transaction ledger side by side | Good; 10 px figures in "Budgeted" row |
| Desktop Upcoming | 32 | 600 px dialog | Fine |
| Desktop Plan | 33 | One 720 px column, long scroll, margin line | Works; feels like a settings page |

## 4. Screen notes

**Today.** KEEP the structure of `[02]`: number → sentence → three stats → pace → four lines → one button. CHANGE:
(a) the over-budget state needs its own copy and figures: when `allowanceToday ≤ 0` say "You're 91 € over for
today. Nothing more today; tomorrow starts at X €" and show "over by" instead of "plan per day −3 €" and "of −87 €
used"; (b) first-run panels should be one panel, not two, and should sit *below* the hero or collapse to one line
after the first dismissal; (c) the "Add expense" button is a page-content button, so it scrolls away; make it the
one persistent action (a bottom-right FAB on phones is the Material answer and is compatible with the ledger look at
radius 3, or a "+" in the app bar on every tab); (d) the "After-work delivery hour" panel is charming for its owner
and bewildering for anyone else; gate it on a setting or on detected delivery merchants.

**Add expense sheet.** KEEP the inline impulse interception and the explainer. CHANGE: default category should be
the last used, not Groceries, or no default with the CTA disabled until one is chosen (a wrong silent category is the
most common data-quality error in every expense app); the explainer paragraph belongs above the CTA or behind an
info icon, not under the primary button where a thumb has to pass it; name the wish from the note or ask for a name.

**Upcoming.** KEEP the grid, the shape-coded marks and the legend. CHANGE: 31 bordered day cells is heavy ink for a
phone; drop cell borders for days without marks (keep the ruled week rows) and the grid will breathe; make Confirm
the filled button; the "Added" tag on manual planned costs is unclear, use "Planned by you".

**Spending.** KEEP the trend chart with the running-period bar dashed and the 3-period average line; KEEP the
category bars with budget mark, average tick and hatch. CHANGE: the lone search icon occupies a full row at the top
of the page `[12]`; put it in the app bar. The two prose explainers under each heading repeat on every visit; show
once, then an info icon. Secondary figures at 10–11 px (see 2.2). Merchant names truncate at 360 dp because the date
column takes 52 dp; on compact widths move the date under the name (the TxTile already restacks at text scale
1.15, reuse that layout below 400 dp).

**Wishlist.** KEEP the affordability answer `[17]`; it is the most persuasive screen in the app. CHANGE: labels (2.5);
the empty "Ready to decide / Cooling off / Decided" sections with counters "0" are three ruled empty states on first
use; collapse empties into one line until there is content.

**Goals.** KEEP. Minor: the sheet's label inconsistency; "Put aside so far" as a placeholder reads as a hint, not a
field.

**Plan.** CHANGE: (a) the payday ledger must list every row that the total subtracts (add "Set aside for coming
costs −534 €" between the goals and the total) `[21]`; (b) split the page: Plan = payday ledger + numbers; a
Settings index page (Bills, Budgets, Expected bills, Calendars, Weekly review day, Reminders, Sync, Backup & export,
Diagnostics) with one route each; (c) one save model: either every field saves on blur with a brief confirmation
(the toggles already apply instantly) or one Save per page, not "Save reminder days", "Save address", "Save plan"
scattered down a 9-section scroll.

**Bill sheet.** KEEP the "Unsure: read from text. Check it." marks and the help icons; they are the product's rule
made visible. CHANGE: pin "Confirm bill" to the sheet's bottom edge so it is reachable without scrolling the whole
form `[24]`; move Delete out of the footer into an overflow or the top row so the primary and the destructive
action are not neighbours; the date controls are outlined buttons while every other field is a text field, which
reads as two different forms, use a text-field-styled date picker.

**Weekly review.** KEEP everything: the one-line promise ("About five minutes. Nothing changes until you tap."),
the checkboxes that tick as steps complete, the count badges, the Pace step, Done. One CHANGE: "Change" is a text
button and "Looks right" outlined; make "Looks right" filled since it is the expected tap six times in a row, and
consider a swipe-right gesture as an accelerator with the buttons kept.

## 5. Accessibility and interaction audit (native-app checklist)

| Check | Status | Note |
|---|---|---|
| Text contrast ≥ 4.5:1 both themes | Pass | Enforced by `theme_contrast_test.dart` |
| Body text ≥ 12 px | Fail in places | 10–11.5 px literals in Spending figures and chart axes |
| Touch targets ≥ 48 dp (Android) | Partial | 44 dp minimums in theme and rows; Android guideline is 48 |
| Colour never the only signal | Pass | Icons + words, shapes in the grid, `+` on income |
| Visible labels on fields | Fail in places | Placeholder-only labels in Wishlist and Goal sheet |
| Error next to the field | Pass | Bill sheet, Plan form; add-expense amount error under the field |
| Tap feedback 80–150 ms | Pass | InkWell on rows, M3 button states, `NoSplash` by design |
| Screen reader order and labels | Partial | Semantics on bars and day cells; `TxTile` reads as five stops, no `MergeSemantics` |
| Text scale 2.0 without overflow | Pass | Tested at 320 and 360 dp with real fonts |
| Reduced motion | Pass by absence | Almost no motion; toasts and sheets only |
| Safe areas | Pass | Bottom bar and sheets respect insets |
| Dark mode checked independently | Not by eye | Contrast test only; recommend one dark frame per tab in the walk |
| Keyboard navigation (desktop) | Pass | Ctrl+1–5, N, F, R; focus returns to the shell |
| Undo for destructive actions | Fail | Delete transaction and delete goal have neither confirm nor undo |

## 6. Copy and language

The voice is good: short, second person, concrete ("Spend less today and tomorrow gets more", "Nothing changes
until you tap"). Three rules to add: (1) never print a negative allowance, budget or denominator; switch to the
over-budget phrasing; (2) explainer paragraphs show once per screen per install, then collapse to an info icon;
(3) numbers follow the user's locale: input already accepts `12,50`, output must print `12,50 €` for a Croatian
user, and `$12.50` for USD (the live window showed "27 $", `format.dart:48`). No strings are externalised; before any
localisation, move widget tests from copy to keys (see the system review).

## 7. Desktop

The rail, two-column Today and Spending, and sheets-as-dialogs are right. Two changes: the 56 px top strip holds
only the period chip `[30]`, so put the page title, search and the period chip there and reclaim the vertical space;
and Plan at 720 px in a 1280 px window leaves two empty paper margins with a 9-section scroll between them `[33]`,
which is exactly where a two-pane Settings (index left, section right) would feel native.

## 8. Information architecture proposal

Current: Today · Spending · Wishlist · Goals · Plan, add expense only on Today, Bills inside Plan.

Proposed: **Today · Spending · Bills · Save · Plan**, with a persistent add action on every tab.

- Bills earns a tab: it has the most code, the most "owner confirms" moments and a review queue that Today already
  advertises ("1 bill to review"); today it is reached by scrolling Plan or through one line on Today.
- Wishlist and Goals merge into **Save** (two ruled sections on one page; both are about money not spent now). They
  are low-frequency and together make one coherent destination.
- Plan keeps the payday ledger and numbers; everything else moves to a Settings index reached from Plan's header.
- The add action: Ctrl+N already exists; the touch equivalent is missing. A FAB at radius 3 in ink with a white "+"
  fits the ledger better than it sounds; the alternative is a "+" icon in every app bar.

## 9. Prioritised changes

**Quick wins (hours each):**
1. Over-budget copy and figures on Today and Plan (`today.dart:124-137`, Plan header line).
2. Name the wish from the note, or ask; never the category (`sheets.dart:168`).
3. List "Set aside for coming costs" in the payday ledger so it foots (`plan.dart`).
4. Toasts: 2.5 s, dismissed on navigation, with an action where one exists (Undo on add/delete, Open on wishlist).
5. Floating labels everywhere; filled primary in Upcoming and Review rows; X on phone sheets.
6. Search icon into the app bar; explainers collapse after first view.
7. Type tokens; nothing under 12 px except the eyebrow; 48 dp targets; `MergeSemantics` on rows.

**Structural (days each):**
8. Persistent add action on every tab.
9. Plan split into payday ledger + Settings index with sub-pages; one save model.
10. Bills tab; Wishlist + Goals → Save.
11. Compact-width TxTile layout (date under name) below 400 dp.
12. Sticky Confirm in the bill sheet; Delete away from the primary.
13. A dark-mode frame per tab added to the walk so dark is reviewed by eye, not only by ratio.

## 10. What to keep no matter what

The ledger direction and its tokens; mono tabular amounts with the sign in front and the symbol after; the hero →
sentence → stat strip → pace → "what changes it" order on Today; the inline impulse interception; the wishlist
affordability answer in days; the Upcoming grid with shape-coded marks; the "Unsure" marks on guessed fields; the
weekly review's four ruled steps; the keyboard shortcuts; and the structural tests at 320 dp × text scale 2.0 that
make all of the above safe to change.
